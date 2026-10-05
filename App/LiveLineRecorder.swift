import Foundation
import os

private let log = Logger(subsystem: "bet.spex.glance", category: "liveline")

/// Feeds Live Line from the snapshot: one sample per minute at most while the socket ticks,
/// plus one on every REST refresh so a quiet market still gets a point every five minutes.
/// Does nothing unless the user turned Live Line on in Settings.
@MainActor
final class LiveLineRecorder {
    private var lastSampleAt: Date = .distantPast
    private var lastDownsampleAt: Date = .distantPast
    /// Fires after a sample is written, so the chart can reload.
    var onSample: ((Date) -> Void)?

    static var enabled: Bool { Prefs.defaults.bool(forKey: Prefs.liveLineEnabledKey) }

    func sample(_ s: PortfolioSnapshot, force: Bool = false) {
        guard Self.enabled else { return }
        guard s.errorMessage == nil, let total = s.sportsTotal else {
            log.notice("sample skipped: error=\(s.errorMessage ?? "nil", privacy: .public) total=\(s.sportsTotal.map { String($0) } ?? "nil", privacy: .public)")
            return
        }
        // Ticks: one a minute. Refreshes (`force`): the 5-minute poll and live-push reloads, which
        // can come seconds apart — still floor those at 30 s so a busy minute isn't ten points.
        let now = Date()
        guard now.timeIntervalSince(lastSampleAt) >= (force ? 30 : 60) else { return }
        lastSampleAt = now
        let env = s.environment
        let sample = LiveSample(ts: now, sportsTotal: total, unrealized: s.totalUnrealized)
        let downsample = now.timeIntervalSince(lastDownsampleAt) > 3600
        if downsample { lastDownsampleAt = now }
        Task.detached(priority: .utility) {
            LiveLineStore.append(sample, env: env)
            if downsample { LiveLineStore.downsample(env: env) }
            await MainActor.run {
                self.onSample?(now)
                LiveLineSync.shared.enqueue(hour: LiveLineStore.hourName(now))
            }
        }
    }
}
