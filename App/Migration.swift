import Foundation
import Security

/// One-time move from the pre-0.3.0 `com.example.spexglance` ids to `bet.spex.glance`:
/// the App Group defaults (prefs, caches), the Kalshi credential and the Live Line key.
/// Runs before anything reads the keychain or defaults. Idempotent; a marker in the new
/// suite stops it from running twice. The legacy groups stay in the entitlements for one
/// release so this can read them; after that they go, and so does this file.
enum Migration {
    private static let marker = "migratedFromComExample"

    static func run() {
        guard let new = UserDefaults(suiteName: SharedIDs.appGroup), !new.bool(forKey: marker) else { return }

        // 1. Defaults: everything the old suite holds (prefs, snapshot/meta caches, ledger).
        if let old = UserDefaults(suiteName: SharedIDs.legacyAppGroup),
           let dict = old.persistentDomain(forName: SharedIDs.legacyAppGroup) {
            for (k, v) in dict where new.object(forKey: k) == nil { new.set(v, forKey: k) }
        }

        // 2. Kalshi credential.
        if KeychainStore.load() == nil, let cred = KeychainStore.loadLegacy() {
            if (try? KeychainStore.save(cred)) != nil { KeychainStore.deleteLegacy() }
        }

        // 3. Live Line: the chunk key, then the chunk files from the old container.
        LiveLineStore.migrateLegacyKey()
        if let oldDir = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: SharedIDs.legacyAppGroup)?
                .appendingPathComponent("LiveLine", isDirectory: true),
           let newDir = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: SharedIDs.appGroup)?
                .appendingPathComponent("LiveLine", isDirectory: true),
           FileManager.default.fileExists(atPath: oldDir.path), !FileManager.default.fileExists(atPath: newDir.path) {
            try? FileManager.default.moveItem(at: oldDir, to: newDir)
        }

        new.set(true, forKey: marker)
    }
}
