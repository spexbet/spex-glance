import SwiftUI

/// ⌘1 — the original view: Live checkbox, sport pills and sort on top, the grouped positions list below.
struct PositionsTab: View {
    @EnvironmentObject var model: AppModel
    let sports: [String]
    let active: String
    @Binding var sportFilter: String
    @Binding var sort: Prefs.GroupSort
    /// "Live" checkbox: only games started and not yet settled.
    @Binding var liveOnly: Bool
    /// After every filter.
    let groups: [EventGroup]
    /// Every sports game held, before any filter — tells "nothing held" from "nothing matches".
    let heldGames: Int
    let marketCount: Int
    let hiddenNonSports: Int

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                if sports.count > 1 {
                    SportFilterBar(sports: sports, selection: $sportFilter, active: active)
                }
                HStack {
                    Toggle(isOn: $liveOnly) {
                        Text("Live").font(.caption.weight(liveOnly ? .semibold : .regular))
                    }
                    .toggleStyle(.checkbox)
                    .help("Only games being played now, or finished and awaiting settlement")
                    .accessibilityLabel("Show live games only")
                    Spacer()
                    Menu {
                        Picker("Sort", selection: $sort) {
                            ForEach(Prefs.GroupSort.allCases) { Label($0.label, systemImage: $0.symbol).tag($0) }
                        }
                    } label: {
                        Image(systemName: "arrow.up.arrow.down")
                            .font(.caption.weight(.semibold))
                            .padding(6)
                            .background(Color.secondary.opacity(0.15), in: Circle())
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("Sort: \(sort.label)")
                    .accessibilityLabel("Sort games")
                }
            }
            .padding(.vertical, 12)
            .padding(.horizontal, 20)
            .frame(maxWidth: .infinity)
            Divider()

            ScrollViewReader { proxy in
            List {
                Section(sectionTitle) {
                    if !groups.isEmpty {
                        ForEach(groups) { g in
                            GroupRow(group: g, expanded: Binding(
                                get: { model.expandedGroups.contains(g.id) },
                                set: { _ in model.toggleExpanded(g.id) }),
                                scores: model.snapshot?.liveScores ?? [:])
                            .id(g.id)
                        }
                        if hiddenNonSports > 0 {
                            Text("\(hiddenNonSports) non-sports position\(hiddenNonSports == 1 ? "" : "s") not shown")
                                .font(.footnote).foregroundStyle(.tertiary)
                        }
                    } else {
                        emptyState
                    }
                }
            }
            .refreshable { await model.refresh() }
            .scrollContentBackground(.hidden)
            .background(Theme.paper)
            .onAppear { scrollToFocus(proxy) }
            .onChange(of: model.focusGroup) { _, _ in scrollToFocus(proxy) }
            }
        }
    }

    /// A widget tapped this game: bring it into view once, then forget it.
    private func scrollToFocus(_ proxy: ScrollViewProxy) {
        guard let id = model.focusGroup else { return }
        DispatchQueue.main.async {
            withAnimation { proxy.scrollTo(id, anchor: .top) }
            model.focusGroup = nil
        }
    }

    /// One message for each way the list can be empty, most specific first.
    @ViewBuilder
    private var emptyState: some View {
        let err = model.snapshot?.errorMessage
        if model.snapshot == nil {
            Text("Loading…").foregroundStyle(.secondary)
        } else if heldGames == 0, let err, err.contains("(403)") {
            EmptyNote(icon: "lock.trianglebadge.exclamationmark",
                      title: "Kalshi won't share your positions with this key.",
                      detail: "The key has probably lost Read all data. On Kalshi, create a new key with only Read all data checked, then Disconnect here and connect with the new one.")
        } else if heldGames == 0, err != nil {
            EmptyNote(icon: "exclamationmark.triangle",
                      title: "Couldn't load positions.",
                      detail: "The status line above says why. The app tries again every five minutes, and right away when the network comes back.")
        } else if heldGames == 0, hiddenNonSports > 0 {
            EmptyNote(icon: "sportscourt",
                      title: "No open sports positions.",
                      detail: "You hold \(hiddenNonSports) non-sports position\(hiddenNonSports == 1 ? "" : "s"). Spex Glance counts \(hiddenNonSports == 1 ? "it" : "them") but only shows sports.")
        } else if heldGames == 0 {
            EmptyNote(icon: "eyeglasses",
                      title: "No open positions right now.",
                      detail: "A new sports bet shows up here within a second of filling on Kalshi.")
        } else if liveOnly {
            VStack(alignment: .leading, spacing: 6) {
                Text(active.isEmpty || active == SportFilterBar.combos
                     ? "No live games right now."
                     : "No live \(active.lowercased()) games right now.")
                    .foregroundStyle(.secondary)
                Button("Show all") { liveOnly = false }
                    .buttonStyle(.link)
            }
        } else {
            Text(active == SportFilterBar.combos ? "No open combos." : "No open \(active.lowercased()) positions.")
                .foregroundStyle(.secondary)
        }
    }

    private var sectionTitle: String {
        let games = groups.count
        let scope = active.isEmpty ? "sports" : active == SportFilterBar.combos ? "combo" : active.lowercased()
        let what = (liveOnly ? "Live " : "Open ") + scope + " bets"
        return "\(what) (\(games) game\(games == 1 ? "" : "s") · \(marketCount) market\(marketCount == 1 ? "" : "s"))"
    }
}

/// An empty-list message with a reason and what to do about it.
private struct EmptyNote: View {
    let icon: String
    let title: String
    let detail: String
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).font(.title3).foregroundStyle(.secondary).frame(width: 24)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.body.weight(.medium))
                Text(detail).font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 6)
    }
}
