import SwiftUI
import UniformTypeIdentifiers
import AppKit

/// "Connect Kalshi" — feels like an app sign-in, is actually read-only API key setup.
/// Default path: import the key Kalshi generated (the downloaded .txt / PEM).
/// Advanced path: generate an Ed25519 key here, paste the PUBLIC key into Kalshi.
/// Production only; the demo exchange is reachable by changing `environment` below.
@MainActor
struct ConnectWizardView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    enum Method { case generate, importKey }

    @State private var step = 0
    private let environment: KalshiEnvironment = .prod
    @State private var method: Method = .importKey
    @State private var generated: (credential: KalshiCredential, publicKeyPEM: String)?
    @State private var keyID = ""
    @State private var pastedPEM = ""
    @State private var importedKey: (KalshiKeyType, Data)?
    @State private var importError: String?
    @State private var testState: TestState = .idle
    @State private var showFileImporter = false
    @State private var copied = false

    enum TestState: Equatable { case idle, running, ok(String), failed(String) }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                ProgressView(value: Double(step + 1), total: 3).padding(.bottom, 4)
                switch step {
                case 0: stepMethod
                case 1: method == .generate ? AnyView(stepPublicKey) : AnyView(stepImport)
                default: stepKeyID
                }
                Spacer()
                disclaimer
                navButtons
            }
            .padding()
            .frame(maxWidth: 560)
            .navigationTitle("Connect Kalshi")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
            .fileImporter(isPresented: $showFileImporter,
                          allowedContentTypes: [.plainText, .data, UTType(filenameExtension: "pem") ?? .data, UTType(filenameExtension: "key") ?? .data]) { result in
                if case .success(let url) = result {
                    let ok = url.startAccessingSecurityScopedResource()
                    defer { if ok { url.stopAccessingSecurityScopedResource() } }
                    if let s = try? String(contentsOf: url, encoding: .utf8) { pastedPEM = s }
                }
            }
        }
        .frame(width: 520, height: 580)
    }

    // MARK: Steps

    /// Why this is a wizard and not a "Sign in with Kalshi" button.
    private var disclaimer: some View {
        Label {
            Text("Kalshi has no way for an app to sign you in. API keys are created by hand on Kalshi's website, once; this app only stores the read-only key you make there. It can never place, amend, or cancel orders.")
        } icon: {
            Image(systemName: "info.circle")
        }
        .font(.footnote).foregroundStyle(.secondary)
        .padding(10)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
    }

    private var stepMethod: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("1. Key setup").font(.title2.bold())
            methodCard(.importKey, title: "Create the key on Kalshi (recommended)",
                       detail: "On Kalshi's profile page click Create New API Key, set it to Read only, and save. Kalshi downloads a .txt with the private key — you'll open it in the next step. The key goes into your Keychain and nowhere else.")
            methodCard(.generate, title: "Advanced: generate on this device",
                       detail: "We create an Ed25519 key pair here and you register only the public half on Kalshi, so the private key never passes through a browser download. Kalshi's own button now makes the same kind of key, so the option above is just as strong.")
        }
    }

    private func methodCard(_ m: Method, title: String, detail: String) -> some View {
        Button {
            method = m
        } label: {
            HStack(alignment: .top) {
                Image(systemName: method == m ? "largecircle.fill.circle" : "circle")
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).fontWeight(.semibold)
                    Text(detail).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.leading)
                }
                Spacer()
            }
            .padding()
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }

    private var stepPublicKey: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("2. Register the public key").font(.title2.bold())
            Text("Copy this, then on Kalshi's profile page choose **Create New API Key**, set it to **Read only**, name it \"Spex Glance\", and paste it into the public key field.")
                .foregroundStyle(.secondary)
            ScrollView {
                Text(generated?.publicKeyPEM ?? "")
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .frame(maxHeight: 140)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
            HStack {
                Button {
                    Clipboard.set(generated?.publicKeyPEM ?? "")
                    copied = true
                } label: { Label(copied ? "Copied" : "Copy public key", systemImage: copied ? "checkmark" : "doc.on.doc") }
                Button {
                    Browser.open(environment.apiKeysPageURL)
                } label: { Label("Open Kalshi API keys page", systemImage: "safari") }
            }
            Text("Sign in on Kalshi however you normally do (Google, Apple, passkey, 2FA). This app never sees your Kalshi login.")
                .font(.footnote).foregroundStyle(.tertiary)
        }
        .onAppear { if generated == nil { generated = KalshiCredential.generateEd25519(environment: environment) } }
    }

    private var stepImport: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("2. Private key").font(.title2.bold())
            Text("Open the .txt Kalshi downloaded (or paste its contents). RSA and Ed25519 both work.")
                .foregroundStyle(.secondary)
            Button {
                Browser.open(environment.apiKeysPageURL)
            } label: { Label("Open Kalshi API keys page", systemImage: "safari") }
            TextEditor(text: $pastedPEM)
                .font(.system(.caption, design: .monospaced))
                .autocorrectionDisabled()
                .frame(minHeight: 140, maxHeight: 200)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary))
            HStack {
                Button { showFileImporter = true } label: { Label("Open file…", systemImage: "folder") }
                Button { pastedPEM = Clipboard.get() } label: { Label("Paste", systemImage: "doc.on.clipboard") }
            }
            if !pastedPEM.isEmpty {
                if let k = importedKey {
                    Label("Looks good: \(k.0.rawValue.uppercased()) key", systemImage: "checkmark.circle").foregroundStyle(.green)
                } else {
                    Label(importError ?? "Couldn't read that key.", systemImage: "xmark.circle").foregroundStyle(.red)
                }
            }
        }
        .onChange(of: pastedPEM, initial: true) { _, pem in
            do { importedKey = try PEM.parsePrivateKey(pem); importError = nil }
            catch { importedKey = nil; importError = pem.isEmpty ? nil : error.localizedDescription }
            testState = .idle
        }
    }

    private var stepKeyID: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("3. Key ID").font(.title2.bold())
            Text("Kalshi shows a Key ID (a UUID) next to the new key. Paste it here. It is not secret.")
                .foregroundStyle(.secondary)
            HStack {
                TextField("xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx", text: $keyID)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .autocorrectionDisabled()
                Button { keyID = Clipboard.get().trimmingCharacters(in: .whitespacesAndNewlines) } label: { Image(systemName: "doc.on.clipboard") }
                    .accessibilityLabel("Paste Key ID")
            }
            .onAppear {
                // Auto-fill when the clipboard already holds a UUID.
                let clip = Clipboard.get().trimmingCharacters(in: .whitespacesAndNewlines)
                if keyID.isEmpty, UUID(uuidString: clip) != nil { keyID = clip }
            }
            .onChange(of: keyID) { _, _ in testState = .idle }
            if !keyID.isEmpty, UUID(uuidString: keyID.trimmingCharacters(in: .whitespacesAndNewlines)) == nil {
                Label(keyID.hasPrefix("MC") || keyID.contains("BEGIN")
                      ? "That's a key, not the Key ID. The Key ID is the UUID shown next to the key on Kalshi's page."
                      : "The Key ID is a UUID like 1b2c3d4e-…-… (36 characters).",
                      systemImage: "info.circle")
                    .font(.footnote).foregroundStyle(.orange)
            }
            Button {
                Task { await testConnection() }
            } label: {
                Label("Test connection", systemImage: "bolt")
            }
            .disabled(UUID(uuidString: keyID) == nil || testState == .running)

            switch testState {
            case .idle: EmptyView()
            case .running: ProgressView("Checking…")
            case .ok(let msg): Label(msg, systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            case .failed(let msg): Label(msg, systemImage: "xmark.circle.fill").foregroundStyle(.red)
            }
        }
    }

    // MARK: Nav

    private var navButtons: some View {
        HStack {
            if step > 0 { Button("Back") { step -= 1 } }
            Spacer()
            if step < 2 {
                Button("Next") { step += 1 }
                    .buttonStyle(.borderedProminent)
                    .disabled(step == 1 && method == .importKey && importedKey == nil)
            } else {
                Button("Finish") { finish() }
                    .buttonStyle(.borderedProminent)
                    .disabled({ if case .ok = testState { return false } else { return true } }())
            }
        }
    }

    // MARK: Logic

    private func buildCredential() -> KalshiCredential? {
        let id = keyID.trimmingCharacters(in: .whitespacesAndNewlines)
        switch method {
        case .generate:
            guard var c = generated?.credential else { return nil }
            c.keyID = id
            c.environment = environment
            return c
        case .importKey:
            guard let (type, bytes) = importedKey else { return nil }
            return KalshiCredential(keyID: id, keyType: type, privateKey: bytes, environment: environment)
        }
    }

    private func testConnection() async {
        guard let cred = buildCredential() else { return }
        testState = .running
        do {
            let client = KalshiClient(credential: cred)
            let b = try await client.balance()
            // Refuse anything that can trade or move money. Spex Glance is read-only by construction,
            // and that only means something if the key is too.
            switch await client.checkOwnKeyScope() {
            case .notReadOnly(let extras, let missingRead):
                testState = .failed(KalshiClient.scopeProblem(extras: extras, missingRead: missingRead))
                return
            case .readOnly:
                testState = .ok("Connected · read-only key verified · balance \(Fmt.dollars(b.balanceDollars))")
            case .unknown(let why):
                testState = .ok("Connected · balance \(Fmt.dollars(b.balanceDollars)) · couldn't verify key scope (\(why))")
            }
        } catch {
            testState = .failed(error.localizedDescription)
        }
    }

    private func finish() {
        guard let cred = buildCredential() else { return }
        do {
            try model.connect(cred)
            dismiss()
        } catch {
            testState = .failed("Couldn't save to Keychain: \(error.localizedDescription)")
        }
    }
}

// MARK: - Browser

/// Opens a web page in the user's default browser, bypassing universal links.
/// `openURL` / `NSWorkspace.open(_:)` hand kalshi.com links to the Kalshi iPhone app when it is
/// installed on an Apple silicon Mac, and its API-key page doesn't exist in the phone UI.
enum Browser {
    static func open(_ url: URL) {
        let ws = NSWorkspace.shared
        if let browser = ws.urlForApplication(toOpen: URL(string: "https://example.com")!) {
            ws.open([url], withApplicationAt: browser, configuration: NSWorkspace.OpenConfiguration())
        } else {
            ws.open(url)
        }
    }
}

// MARK: - Clipboard shim

enum Clipboard {
    static func set(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }
    static func get() -> String {
        return NSPasteboard.general.string(forType: .string) ?? ""
    }
}
