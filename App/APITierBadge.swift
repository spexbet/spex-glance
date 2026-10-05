import SwiftUI

/// The account's Kalshi API tier, fetched once per launch (one `GET /account/limits`, 10 read
/// tokens) the first time Settings → About is shown. A failure shows "—" and is retried the next
/// time Settings opens. Keyed by Key ID so a reconnect with another account refetches.
@MainActor
final class APITierLoader: ObservableObject {
    static let shared = APITierLoader()
    enum State: Equatable { case idle, loading, loaded(String), failed }
    @Published private(set) var state: State = .idle
    private var keyID: String?

    func load() {
        guard let cred = KeychainStore.load() else { state = .idle; keyID = nil; return }
        if keyID == cred.keyID, state == .loading { return }
        if keyID == cred.keyID, case .loaded = state { return }
        keyID = cred.keyID
        state = .loading
        Task {
            do {
                let r = try await KalshiClient(credential: cred).accountLimits()
                guard self.keyID == cred.keyID else { return }
                state = r.usage_tier.map { .loaded($0) } ?? .failed
            } catch {
                guard self.keyID == cred.keyID else { return }
                state = .failed
            }
        }
    }
}

/// "Kalshi API tier   [Expert]" — name only, no rates or progress. Basic is plain text.
struct APITierRow: View {
    @ObservedObject private var loader = APITierLoader.shared

    var body: some View {
        LabeledContent("Kalshi API tier") {
            switch loader.state {
            case .loaded(let raw):
                if let tier = APIUsageTier(rawValue: raw.lowercased()) {
                    TierPill(tier: tier)
                } else {
                    Text(raw.capitalized).foregroundStyle(.secondary)   // a tier Kalshi adds later
                }
            case .loading:
                ProgressView().controlSize(.small)
            case .idle, .failed:
                Text("—").foregroundStyle(.secondary)
            }
        }
        .help("Your account's API rate-limit tier on Kalshi. Spex Glance uses a small fraction of even the Basic tier.")
        .onAppear { loader.load() }
    }
}

struct TierPill: View {
    let tier: APIUsageTier
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let s = tier.style(dark: scheme == .dark)
        if tier == .basic {
            Text(tier.label).foregroundStyle(.secondary)
        } else {
            let pill = Text(tier.label)
                .font(Brand.display(13, weight: .medium))
                .foregroundStyle(s.text)
                .padding(.horizontal, 11)
                .frame(height: 24)
                .background { if let f = s.fill { Capsule().fill(f) } }
                .overlay { if let o = s.outline { Capsule().strokeBorder(o, lineWidth: 1.5) } }
            if let ring = s.ring {
                // Prestige: a second ring with a 2 pt gap.
                pill.padding(3.5).overlay(Capsule().strokeBorder(ring, lineWidth: 1.5))
                    .accessibilityLabel("API tier \(tier.label)")
            } else {
                pill.accessibilityLabel("API tier \(tier.label)")
            }
        }
    }
}
