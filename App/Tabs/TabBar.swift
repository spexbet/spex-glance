import SwiftUI

/// Positions / Orders / Settled / P&L, as pills in the sport-filter style. ⌘1–⌘4 jump,
/// ⌘⇧[ and ⌘⇧] cycle. P&L is money, so Work Mode drops it from the row entirely.
struct TabBar: View {
    let selection: Prefs.MainTab
    let workMode: Bool
    let select: (Prefs.MainTab) -> Void

    var body: some View {
        HStack(spacing: 8) {
            ForEach(Prefs.MainTab.visible(workMode: workMode)) { tab in
                pill(tab)
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Sections")
    }

    private func pill(_ tab: Prefs.MainTab) -> some View {
        let on = tab == selection
        return Button {
            select(tab)
        } label: {
            HStack(spacing: 6) {
                Text(tab.label)
                    .font(Theme.display(14, weight: on ? .bold : .medium))
                Text("⌘\(String(tab.shortcutKey))")
                    .font(Theme.display(10, weight: .regular))
                    .opacity(0.65)
            }
            .padding(.horizontal, 16).padding(.vertical, 9)
            .background(on ? Color.accentColor : Color.secondary.opacity(0.15),
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .foregroundStyle(on ? Color.white : Color.primary)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// Stand-in for a tab whose content lands in a later beta.
struct PlaceholderTab: View {
    let title: String
    let note: String

    var body: some View {
        VStack(spacing: 8) {
            Spacer()
            Text(title).font(.headline)
            Text(note).font(.footnote).foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .background(Theme.paper)
    }
}
