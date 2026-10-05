import SwiftUI

/// ⌘2 — resting orders that haven't filled. Read-only: Spex Glance never places, amends or
/// cancels anything, so the only action is to go to Kalshi.
struct OrdersTab: View {
    @EnvironmentObject var model: AppModel
    @AppStorage(Prefs.workModeKey, store: Prefs.defaults) private var workMode = false
    let orders: [OpenOrder]

    var body: some View {
        List {
            if !model.kalshiCancels.isEmpty {
                Section {
                    ForEach(model.kalshiCancels) { c in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(c.eventTitle).font(.headline).lineLimit(2)
                            Text("\(c.isBuy ? "Buy" : "Sell") · \(c.isYes ? "Yes" : "No") · \(c.sideTitle)")
                                .font(.caption).foregroundStyle(.secondary)
                            Text("\(c.reason) · \(c.at.formatted(date: .omitted, time: .shortened))")
                                .font(.caption).foregroundStyle(Brand.ember)
                        }
                        .padding(.vertical, 4)
                    }
                } header: {
                    Text("Recently cancelled by Kalshi")
                }
            }
            Section {
                if orders.isEmpty {
                    Text(model.isRefreshing && model.snapshot == nil ? "Loading…" : "No resting orders.")
                        .foregroundStyle(.secondary)
                }
                ForEach(orders) { o in
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(o.eventTitle).font(.headline).lineLimit(2)
                            HStack(spacing: 6) {
                                // Work Mode: no size, no price.
                                Text("\(o.isBuy ? "Buy" : "Sell")\(workMode ? "" : " " + Fmt.contracts(o.remaining)) · \(o.isYes ? "Yes" : "No") · \(o.sideTitle)")
                                if let sp = o.sport {
                                    Label(sp, systemImage: SportGlyph.symbol(for: sp))
                                }
                            }
                            .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if !workMode {
                            VStack(alignment: .trailing, spacing: 2) {
                                Text(Fmt.cents(o.limitDollars)).font(.body.monospacedDigit().weight(.semibold))
                                Text("limit").font(.caption2).foregroundStyle(.tertiary)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
            } header: {
                Text("Resting orders (\(orders.count))")
            } footer: {
                Text("Spex Glance never places, amends or cancels orders. Manage them on Kalshi.")
                    .font(.footnote).foregroundStyle(.tertiary)
            }
        }
        .refreshable { await model.refresh() }
        .scrollContentBackground(.hidden)
        .background(Theme.paper)
    }
}
