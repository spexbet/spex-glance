import Foundation
import Security

/// Stores the credential in the shared Keychain access group so the widget
/// extension can read it. Accessible after first unlock so widget timelines
/// can refresh in the background; ThisDeviceOnly so the key never rides along
/// in a backup to another machine.
public enum KeychainStore {
    private static let service = "\(SharedIDs.bundlePrefix).credential"
    private static let account = "kalshi"

    public enum Error: Swift.Error, LocalizedError {
        case osStatus(OSStatus)
        public var errorDescription: String? {
            if case .osStatus(let s) = self {
                return SecCopyErrorMessageString(s, nil) as String? ?? "Keychain error \(s)"
            }
            return nil
        }
    }

    private static var baseQuery: [CFString: Any] {
        var q: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ]
        if let group = accessGroup {
            q[kSecAttrAccessGroup] = group
        }
        // Without this, macOS puts the item in the legacy login keychain, where the
        // widget (a separate process) cannot read it without a prompt.
        q[kSecUseDataProtectionKeychain] = true
        return q
    }

    /// "<TeamID>.<bundlePrefix>.shared", read from Info.plist (where the build system
    /// substitutes $(AppIdentifierPrefix)). nil when running unsigned, e.g. in a simulator
    /// without a team, in which case the item is app-private.
    static var accessGroup: String? {
        guard let g = Bundle.main.object(forInfoDictionaryKey: "SpexKeychainAccessGroup") as? String,
              !g.isEmpty, !g.contains("$(") else { return nil }
        return g
    }

    public static func save(_ credential: KalshiCredential) throws {
        let data = try JSONEncoder().encode(credential)
        let update: [CFString: Any] = [kSecValueData: data]
        var status = SecItemUpdate(baseQuery as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var attrs = baseQuery
            attrs[kSecValueData] = data
            attrs[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(attrs as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw Error.osStatus(status) }
    }

    public static func load() -> KalshiCredential? {
        var q = baseQuery
        q[kSecReturnData] = true
        q[kSecMatchLimit] = kSecMatchLimitOne
        var out: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        guard status == errSecSuccess, let data = out as? Data else { return nil }
        return try? JSONDecoder().decode(KalshiCredential.self, from: data)
    }

    public static func delete() {
        SecItemDelete(baseQuery as CFDictionary)
    }

    // MARK: Pre-0.3.0 item (com.example.spexglance), read once by Migration

    static var legacyAccessGroup: String? {
        accessGroup?.replacingOccurrences(of: SharedIDs.bundlePrefix, with: SharedIDs.legacyBundlePrefix)
    }
    private static var legacyQuery: [CFString: Any] {
        var q: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: "\(SharedIDs.legacyBundlePrefix).credential",
            kSecAttrAccount: account,
            kSecUseDataProtectionKeychain: true,
        ]
        if let g = legacyAccessGroup { q[kSecAttrAccessGroup] = g }
        return q
    }
    public static func loadLegacy() -> KalshiCredential? {
        var q = legacyQuery
        q[kSecReturnData] = true
        q[kSecMatchLimit] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return try? JSONDecoder().decode(KalshiCredential.self, from: data)
    }
    public static func deleteLegacy() {
        SecItemDelete(legacyQuery as CFDictionary)
    }
}
