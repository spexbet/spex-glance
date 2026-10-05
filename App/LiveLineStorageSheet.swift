import SwiftUI

/// Shown when Live Line is switched on (or "Change…" is pressed): where should the history live?
/// Nothing is written until the user confirms.
struct LiveLineStorageSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State var pick: Prefs.LiveLineStore
    let onConfirm: (Prefs.LiveLineStore) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Where should Live Line history live?")
                .font(Theme.display(17, weight: .bold))
            Text("Spex Glance will keep a record of your sports total, sampled about once a minute while prices move. Your Kalshi key is never part of it. Pick where that record is stored:")
                .font(.footnote).foregroundStyle(.secondary)

            choice(.mac, title: "This Mac only",
                   body: "Encrypted and kept inside the app on this computer. The history will only exist here — another Mac starts its own line, and Disconnect erases it.")
            choice(.icloud, title: "iCloud",
                   body: "Syncs between your Macs through your private iCloud storage. Needs an iCloud account with Spex Glance allowed under iCloud → Apps. If iCloud is unavailable, history stays on this Mac and syncs once it is.",
                   disabled: !LiveLineSync.available,
                   note: LiveLineSync.available ? nil : "Not available in this build yet.")

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Turn on Live Line") { onConfirm(pick); dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
            .padding(.top, 4)
        }
        .padding(22)
        .frame(width: 460)
    }

    private func choice(_ v: Prefs.LiveLineStore, title: String, body: String, disabled: Bool = false, note: String? = nil) -> some View {
        let on = pick == v
        return Button {
            if !disabled { pick = v }
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(title).font(.headline)
                    Spacer()
                    Image(systemName: on ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(on ? StatTile.cobalt : Color.secondary)
                }
                Text(body).font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if let note {
                    Text(note).font(.caption.weight(.semibold)).foregroundStyle(.orange)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(on ? StatTile.cobalt : Color.primary.opacity(0.1), lineWidth: on ? 2 : 1))
            .opacity(disabled ? 0.55 : 1)
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}
