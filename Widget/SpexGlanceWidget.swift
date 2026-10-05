import WidgetKit
import SwiftUI

struct OpenBetsEntry: TimelineEntry {
    let date: Date
    let snapshot: PortfolioSnapshot?
    let notConnected: Bool
}

struct OpenBetsProvider: TimelineProvider {
    func placeholder(in context: Context) -> OpenBetsEntry {
        OpenBetsEntry(date: Date(), snapshot: .sample, notConnected: false)
    }

    func getSnapshot(in context: Context, completion: @escaping (OpenBetsEntry) -> Void) {
        if context.isPreview {
            completion(OpenBetsEntry(date: Date(), snapshot: .sample, notConnected: false))
            return
        }
        completion(OpenBetsEntry(date: Date(), snapshot: SnapshotCache.load(), notConnected: KeychainStore.load() == nil))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<OpenBetsEntry>) -> Void) {
        Task {
            let connected = KeychainStore.load() != nil
            // The app reloads timelines after its own refresh and after live pushes; reuse a
            // snapshot that's under two minutes old instead of hitting Kalshi again from the extension.
            let snap: PortfolioSnapshot?
            if !connected {
                snap = nil
            } else if let cached = SnapshotCache.load(), cached.errorMessage == nil,
                      Date().timeIntervalSince(cached.updatedAt) < 120 {
                snap = cached
            } else {
                snap = await Refresher.refresh()
            }
            let entry = OpenBetsEntry(date: Date(), snapshot: snap, notConnected: !connected)
            // WidgetKit budgets refreshes; ask for ~15 min and let the system decide.
            let next = Calendar.current.date(byAdding: .minute, value: 15, to: Date())!
            completion(Timeline(entries: [entry], policy: .after(next)))
        }
    }
}

@main
struct SpexGlanceWidgetBundle: WidgetBundle {
    var body: some Widget {
        OpenBetsWidget()
    }
}

struct OpenBetsWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: SharedIDs.widgetKind, provider: OpenBetsProvider()) { entry in
            OpenBetsWidgetView(entry: entry)   // sets its own container background per family
                .widgetURL(DeepLink.positions.url)   // opens Glance, not the browser
        }
        .configurationDisplayName("Open Bets")
        .description("Your open Kalshi sports bets and unrealized P&L.")
        .supportedFamilies(families)
    }

    private var families: [WidgetFamily] {
        return [.systemSmall, .systemMedium, .systemLarge]
    }
}

// MARK: - Sample data for placeholders / gallery

extension PortfolioSnapshot {
    static let sample = PortfolioSnapshot(
        environment: .prod, fetchedAt: Date(), balanceDollars: 212.40, portfolioValueDollars: 260.10,
        bets: [
            OpenBet(ticker: "KXMLB-1", eventTicker: "E1", eventTitle: "Dodgers vs Giants", gameKey: "E1", gameTitle: "Dodgers vs Giants", label: "Dodgers", isWinnerMarket: true, sideTitle: "Dodgers", yesTitle: "Dodgers", noTitle: "Giants", sport: "Baseball",
                    isYes: true, contracts: 12, avgCostDollars: 0.58, realizedPnL: 1.20, feesPaid: 0.14, currentDollars: 0.63, yesBid: 0.62, yesAsk: 0.64, yesLast: 0.63,
                    marketStatus: "active", closeTime: Date().addingTimeInterval(3600)),
            OpenBet(ticker: "KXMLB-1B", eventTicker: "E1", eventTitle: "Dodgers vs Giants", gameKey: "E1", gameTitle: "Dodgers vs Giants", qualifier: "Total Runs", label: "Over 8.5 runs scored", sideTitle: "Dodgers", yesTitle: "Giants", noTitle: "Dodgers", sport: "Baseball",
                    isYes: false, contracts: 4, avgCostDollars: 0.40, realizedPnL: nil, feesPaid: 0.04, currentDollars: 0.37, yesBid: 0.36, yesAsk: 0.38, yesLast: 0.37,
                    marketStatus: "active", closeTime: Date().addingTimeInterval(3600)),
            OpenBet(ticker: "KXNHL-2", eventTicker: "E2", eventTitle: "Sharks vs Kraken", gameKey: "E2", gameTitle: "Sharks vs Kraken", label: "Sharks", isWinnerMarket: true, sideTitle: "Kraken", yesTitle: "Sharks", noTitle: "Kraken", sport: "Hockey",
                    isYes: false, contracts: 5, avgCostDollars: 0.44, realizedPnL: nil, feesPaid: 0.05, currentDollars: 0.41, yesBid: 0.58, yesAsk: 0.60, yesLast: 0.59,
                    marketStatus: "active", closeTime: Date().addingTimeInterval(7 * 3600)),
            OpenBet(ticker: "KXATP-3", eventTicker: "E3", eventTitle: "Alcaraz vs Sinner", gameKey: "E3", gameTitle: "Alcaraz vs Sinner", label: "Alcaraz", isWinnerMarket: true, sideTitle: "Alcaraz", yesTitle: "Alcaraz", noTitle: "Sinner", sport: "Tennis",
                    isYes: true, contracts: 20, avgCostDollars: 0.52, realizedPnL: -0.40, feesPaid: 0.22, currentDollars: 0.55, yesBid: 0.54, yesAsk: 0.56, yesLast: 0.55,
                    marketStatus: "active", closeTime: Date().addingTimeInterval(26 * 3600)),
        ],
        orders: [
            OpenOrder(id: "o1", ticker: "KXWTA-4", eventTitle: "Swiatek vs Gauff", sideTitle: "Gauff", sport: "Tennis",
                      isYes: true, isBuy: true, remaining: 10, limitDollars: 0.40),
        ],
        hiddenNonSports: 1, errorMessage: nil)
}
