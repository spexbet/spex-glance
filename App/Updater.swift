import SwiftUI
import Sparkle

/// Thin wrapper around Sparkle's standard updater. The feed URL and EdDSA public key
/// live in Info.plist (SUFeedURL / SUPublicEDKey); releases are signed by scripts/release.sh.
/// Dev builds have no public key baked in, so the updater stays idle rather than showing
/// Sparkle's "Unable to Check For Updates" alert at every launch.
@MainActor
final class Updater: ObservableObject {
    static let shared = Updater()
    private let controller: SPUStandardUpdaterController
    @Published var canCheck = false
    /// False in builds made without `scripts/release.sh setup` (no SUPublicEDKey).
    let isConfigured: Bool

    private init() {
        let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String ?? ""
        isConfigured = !key.isEmpty
        controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)
        guard isConfigured else { return }
        do {
            try controller.updater.start()
            controller.updater.publisher(for: \.canCheckForUpdates).assign(to: &$canCheck)
        } catch {
            NSLog("Sparkle failed to start: \(error.localizedDescription)")
        }
    }

    func checkForUpdates() { if isConfigured { controller.checkForUpdates(nil) } }

    var automaticallyChecks: Bool {
        get { isConfigured && controller.updater.automaticallyChecksForUpdates }
        set { if isConfigured { controller.updater.automaticallyChecksForUpdates = newValue } }
    }
}
