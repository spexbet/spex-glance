import Foundation
import CryptoKit
import Security
import os

private let log = Logger(subsystem: "bet.spex.glance", category: "liveline")

/// One Live Line sample: the sports total (cash + sports positions) and the unrealized P&L
/// at one instant. Twenty-four bytes on disk.
public struct LiveSample: Equatable, Sendable {
    public var ts: Date
    public var sportsTotal: Double
    public var unrealized: Double
    public init(ts: Date, sportsTotal: Double, unrealized: Double) {
        self.ts = ts; self.sportsTotal = sportsTotal; self.unrealized = unrealized
    }
}

/// Live Line history on this Mac. Opt-in; nothing is written until the user turns it on.
///
/// Layout: `<App Group>/LiveLine/<env>/<yyyyMMddHH>.bin`, one file per UTC hour, each an
/// AES-GCM sealed box over a flat array of (Int64 ms, Float64, Float64) records. The 256-bit key
/// lives in the keychain, this-device-only and never in iCloud Keychain, so the files are
/// unreadable outside the app even without FileVault. The widget (same App Group, same keychain
/// access group) can read them in a later release.
public enum LiveLineStore {
    private static let lock = NSLock()
    private static let recordSize = 24

    // MARK: Paths

    public static func directory(_ env: KalshiEnvironment) -> URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: SharedIDs.appGroup)?
            .appendingPathComponent("LiveLine", isDirectory: true)
            .appendingPathComponent(env.rawValue, isDirectory: true)
    }

    private static let hourFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMddHH"
        return f
    }()
    public static func hourName(_ d: Date) -> String { hourFormatter.string(from: d) }
    public static func hourStart(_ name: String) -> Date? { hourFormatter.date(from: name) }

    // MARK: Key

    private static let keyService = "\(SharedIDs.bundlePrefix).liveline"
    private static let keyAccount = "chunk-key"

    private static var keyQuery: [CFString: Any] {
        var q: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: keyService,
            kSecAttrAccount: keyAccount,
            kSecUseDataProtectionKeychain: true,
        ]
        if let g = KeychainStore.accessGroup { q[kSecAttrAccessGroup] = g }
        return q
    }

    /// The chunk key, created on first use. Never leaves this Mac (ThisDeviceOnly, not synchronizable).
    static func key(create: Bool) -> SymmetricKey? {
        var q = keyQuery
        q[kSecReturnData] = true
        q[kSecMatchLimit] = kSecMatchLimitOne
        var out: CFTypeRef?
        if SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data, d.count == 32 {
            return SymmetricKey(data: d)
        }
        guard create else { return nil }
        let k = SymmetricKey(size: .bits256)
        let data = k.withUnsafeBytes { Data($0) }
        var attrs = keyQuery
        attrs[kSecValueData] = data
        attrs[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        attrs[kSecAttrSynchronizable] = false
        let st = SecItemAdd(attrs as CFDictionary, nil)
        if st != errSecSuccess { log.error("chunk key: SecItemAdd failed \(st)") }
        return st == errSecSuccess ? k : nil
    }

    /// Move the chunk key from the pre-0.3.0 service/access group, if one is there and we have none.
    public static func migrateLegacyKey() {
        guard key(create: false) == nil else { return }
        var old: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: "\(SharedIDs.legacyBundlePrefix).liveline",
            kSecAttrAccount: keyAccount,
            kSecUseDataProtectionKeychain: true,
        ]
        if let g = KeychainStore.legacyAccessGroup { old[kSecAttrAccessGroup] = g }
        var q = old
        q[kSecReturnData] = true
        q[kSecMatchLimit] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data, d.count == 32 else { return }
        var attrs = keyQuery
        attrs[kSecValueData] = d
        attrs[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        attrs[kSecAttrSynchronizable] = false
        if SecItemAdd(attrs as CFDictionary, nil) == errSecSuccess { SecItemDelete(old as CFDictionary) }
    }

    // MARK: Codec

    private static func encode(_ samples: [LiveSample]) -> Data {
        var d = Data(capacity: samples.count * recordSize)
        for s in samples {
            var ms = Int64(s.ts.timeIntervalSince1970 * 1000).littleEndian
            var a = s.sportsTotal.bitPattern.littleEndian
            var b = s.unrealized.bitPattern.littleEndian
            withUnsafeBytes(of: &ms) { d.append(contentsOf: $0) }
            withUnsafeBytes(of: &a) { d.append(contentsOf: $0) }
            withUnsafeBytes(of: &b) { d.append(contentsOf: $0) }
        }
        return d
    }
    private static func decode(_ d: Data) -> [LiveSample] {
        var out: [LiveSample] = []
        out.reserveCapacity(d.count / recordSize)
        var i = d.startIndex
        while i + recordSize <= d.endIndex {
            let ms = d[i ..< i + 8].withUnsafeBytes { Int64(littleEndian: $0.loadUnaligned(as: Int64.self)) }
            let a = d[i + 8 ..< i + 16].withUnsafeBytes { UInt64(littleEndian: $0.loadUnaligned(as: UInt64.self)) }
            let b = d[i + 16 ..< i + 24].withUnsafeBytes { UInt64(littleEndian: $0.loadUnaligned(as: UInt64.self)) }
            out.append(LiveSample(ts: Date(timeIntervalSince1970: Double(ms) / 1000),
                                  sportsTotal: Double(bitPattern: a), unrealized: Double(bitPattern: b)))
            i += recordSize
        }
        return out
    }

    private static func read(_ url: URL, key: SymmetricKey) -> [LiveSample] {
        guard let sealed = try? Data(contentsOf: url),
              let box = try? AES.GCM.SealedBox(combined: sealed),
              let plain = try? AES.GCM.open(box, using: key) else { return [] }
        return decode(plain)
    }
    private static func write(_ samples: [LiveSample], to url: URL, key: SymmetricKey) {
        guard let box = try? AES.GCM.seal(encode(samples), using: key), let combined = box.combined else { return }
        try? combined.write(to: url, options: .atomic)
    }

    // MARK: API

    /// Append one sample to its hour's chunk. Cheap: a chunk is at most ~60 records.
    public static func append(_ s: LiveSample, env: KalshiEnvironment) {
        lock.lock(); defer { lock.unlock() }
        guard let dir = directory(env) else { log.error("append: no App Group container"); return }
        guard let key = key(create: true) else { log.error("append: no chunk key (keychain add failed)"); return }
        do { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
        catch { log.error("append: mkdir failed \(error.localizedDescription, privacy: .public)"); return }
        let url = dir.appendingPathComponent(hourName(s.ts) + ".bin")
        var samples = FileManager.default.fileExists(atPath: url.path) ? read(url, key: key) : []
        samples.append(s)
        write(samples, to: url, key: key)
        log.notice("append: \(samples.count) sample(s) in \(url.lastPathComponent, privacy: .public)")
    }

    /// Every sample with `from <= ts <= to`, oldest first.
    public static func samples(env: KalshiEnvironment, from: Date?, to: Date = Date()) -> [LiveSample] {
        lock.lock(); defer { lock.unlock() }
        guard let dir = directory(env), let key = key(create: false),
              let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return [] }
        let lo = from.map { hourName($0) } ?? ""
        let hi = hourName(to)
        var out: [LiveSample] = []
        for n in names.sorted() where n.hasSuffix(".bin") {
            let h = String(n.dropLast(4))
            guard h >= lo, h <= hi else { continue }
            out += read(dir.appendingPathComponent(n), key: key)
        }
        return out.filter { s in (from == nil || from! <= s.ts) && s.ts <= to }.sorted { $0.ts < $1.ts }
    }

    // MARK: Sync hooks (plaintext in, plaintext out; the cloud copy is protected by Apple's own encryption)

    /// Every hour that has a chunk, oldest first.
    public static func hours(env: KalshiEnvironment) -> [String] {
        guard let dir = directory(env), let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return [] }
        return names.filter { $0.hasSuffix(".bin") }.map { String($0.dropLast(4)) }.sorted()
    }

    /// The hour's samples as the flat record array (not sealed), for upload. Nil if no chunk.
    public static func chunkData(env: KalshiEnvironment, hour: String) -> Data? {
        lock.lock(); defer { lock.unlock() }
        guard let dir = directory(env), let key = key(create: false) else { return nil }
        let url = dir.appendingPathComponent(hour + ".bin")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let samples = read(url, key: key)
        return samples.isEmpty ? nil : encode(samples)
    }

    /// Union a downloaded record array into the local chunk (dedupe by timestamp). True if it added anything.
    @discardableResult
    public static func mergeChunk(env: KalshiEnvironment, hour: String, data: Data) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let dir = directory(env), let key = key(create: true) else { return false }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(hour + ".bin")
        let mine = FileManager.default.fileExists(atPath: url.path) ? read(url, key: key) : []
        var byMs: [Int64: LiveSample] = [:]
        for s in mine { byMs[Int64(s.ts.timeIntervalSince1970 * 1000)] = s }
        var added = false
        for s in decode(data) {
            let k = Int64(s.ts.timeIntervalSince1970 * 1000)
            if byMs[k] == nil { byMs[k] = s; added = true }
        }
        if added { write(byMs.values.sorted { $0.ts < $1.ts }, to: url, key: key) }
        return added
    }

    /// (chunk count, bytes on disk, oldest sample hour) for the Settings "History" row.
    public static func info(env: KalshiEnvironment) -> (chunks: Int, bytes: Int, oldest: Date?) {
        guard let dir = directory(env),
              let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return (0, 0, nil) }
        let bins = names.filter { $0.hasSuffix(".bin") }.sorted()
        let bytes = bins.reduce(0) { acc, n in
            acc + ((try? FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent(n).path)[.size] as? Int) ?? 0)
        }
        return (bins.count, bytes, bins.first.flatMap { hourStart(String($0.dropLast(4))) })
    }

    /// Delete every chunk for the environment. The key stays, so recording can resume at once.
    public static func clear(env: KalshiEnvironment) {
        lock.lock(); defer { lock.unlock() }
        guard let dir = directory(env) else { return }
        try? FileManager.default.removeItem(at: dir)
    }

    /// Thin out old chunks: one point per 5 minutes after 24 h, one per hour after 7 days.
    /// Keeps the LAST sample in each bucket (it's a balance, not a rate). Idempotent.
    public static func downsample(env: KalshiEnvironment, now: Date = Date()) {
        lock.lock(); defer { lock.unlock() }
        guard let dir = directory(env), let key = key(create: false),
              let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return }
        let dayAgo = hourName(now.addingTimeInterval(-86400))
        let weekAgo = hourName(now.addingTimeInterval(-7 * 86400))
        for n in names where n.hasSuffix(".bin") {
            let h = String(n.dropLast(4))
            guard h < dayAgo else { continue }
            let bucket: TimeInterval = h < weekAgo ? 3600 : 300
            let url = dir.appendingPathComponent(n)
            let samples = read(url, key: key)
            var kept: [LiveSample] = []
            var lastBucket = -1.0
            for s in samples.sorted(by: { $0.ts < $1.ts }) {
                let b = (s.ts.timeIntervalSince1970 / bucket).rounded(.down)
                if b == lastBucket { kept[kept.count - 1] = s } else { kept.append(s); lastBucket = b }
            }
            if kept.count < samples.count { write(kept, to: url, key: key) }
        }
    }
}
