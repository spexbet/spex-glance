import Foundation
import CloudKit
import Combine
import os

private let log = Logger(subsystem: "bet.spex.glance", category: "sync")

/// Live Line → iCloud. Opt-in (Settings → Charts → Live Line → iCloud). Plain CloudKit, private
/// database, custom zone "LiveLine", one `Chunk` record per Mac per UTC hour, so two Macs never
/// write the same record and there is nothing to resolve: a pull unions the other Macs' samples
/// into the local chunk. Record bytes are the flat sample array; Apple encrypts the private
/// database (end-to-end under Advanced Data Protection). The Kalshi key is never involved.
///
/// Without an iCloud account the recorder keeps writing locally and this class just reports
/// `.noAccount`; it catches up when an account appears. Account changes are watched because
/// CloudKit stops silently otherwise.
@MainActor
final class LiveLineSync: ObservableObject {
    static let available = true
    static let shared = LiveLineSync()
    static let containerID = "iCloud.bet.spex.glance"

    enum Status: Equatable {
        case off, checking, syncing, noAccount, restricted, error(String)
        var line: String {
            switch self {
            case .off: return "Not syncing."
            case .checking: return "iCloud · checking account…"
            case .syncing: return "iCloud · syncing between your Macs."
            case .noAccount: return "iCloud · not syncing — no iCloud account on this Mac. History is kept here until one is available."
            case .restricted: return "iCloud · not syncing — iCloud is restricted on this Mac. History is kept here."
            case .error(let e): return "iCloud · not syncing — \(e). History is kept here; will retry."
            }
        }
    }
    @Published private(set) var status: Status = .off
    @Published private(set) var lastPullAt: Date?

    private let container = CKContainer(identifier: LiveLineSync.containerID)
    private var db: CKDatabase { container.privateCloudDatabase }
    private let zoneID = CKRecordZone.ID(zoneName: "LiveLine", ownerName: CKCurrentUserDefaultName)
    private static let tokenKey = "liveLineCKChangeToken"
    private static let machineKey = "liveLineMachineID"
    private static let zoneKey = "liveLineCKZoneCreated"

    private var env: KalshiEnvironment?
    private var pending: Set<String> = []
    private var pushTask: Task<Void, Never>?
    private var pullTimer: Timer?
    private var observer: NSObjectProtocol?
    private var running = false

    /// Stable per-Mac id (random, stored in the App Group). Not the hardware UUID.
    private var machine: String {
        if let m = Prefs.defaults.string(forKey: Self.machineKey) { return m }
        let m = String(UUID().uuidString.prefix(8)).lowercased()
        Prefs.defaults.set(m, forKey: Self.machineKey)
        return m
    }

    static var enabled: Bool {
        LiveLineRecorder.enabled && Prefs.defaults.string(forKey: Prefs.liveLineStoreKey) == Prefs.LiveLineStore.icloud.rawValue
    }

    // MARK: Lifecycle

    /// Call whenever the environment or the Live Line prefs change. Idempotent.
    func start(env: KalshiEnvironment) {
        self.env = env
        guard Self.enabled else { stop(); return }
        if running {
            // Already up: treat a repeat start (Change… → iCloud again) as "try now".
            Task { await checkAccount(thenPull: true) }
            return
        }
        running = true
        status = .checking
        observer = NotificationCenter.default.addObserver(forName: .CKAccountChanged, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in await self?.checkAccount(thenPull: true) }
        }
        pullTimer = Timer.scheduledTimer(withTimeInterval: 15 * 60, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.pull() }
        }
        Task { await checkAccount(thenPull: true) }
    }

    func stop() {
        running = false
        pullTimer?.invalidate(); pullTimer = nil
        if let o = observer { NotificationCenter.default.removeObserver(o); observer = nil }
        pushTask?.cancel(); pushTask = nil
        pending = []
        status = .off
    }

    private var accountOK: Bool { status == .syncing }

    private func checkAccount(thenPull: Bool) async {
        do {
            switch try await container.accountStatus() {
            case .available:
                status = .syncing
                if thenPull { await pull(); await pushPending() }
            case .noAccount, .temporarilyUnavailable: status = .noAccount
            case .restricted: status = .restricted
            default: status = .noAccount
            }
        } catch {
            status = .error(error.localizedDescription)
        }
    }

    // MARK: Zone

    private func ensureZone() async -> Bool {
        if Prefs.defaults.bool(forKey: Self.zoneKey) { return true }
        do {
            _ = try await db.modifyRecordZones(saving: [CKRecordZone(zoneID: zoneID)], deleting: [])
            Prefs.defaults.set(true, forKey: Self.zoneKey)
            return true
        } catch {
            status = .error(error.localizedDescription)
            return false
        }
    }

    // MARK: Push

    /// Called by the recorder after each local write. Debounced; one push a minute at most.
    func enqueue(hour: String) {
        guard Self.enabled else { log.notice("enqueue ignored: sync not enabled"); return }
        log.notice("enqueue \(hour, privacy: .public)")
        pending.insert(hour)
        guard pushTask == nil else { return }
        pushTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 60_000_000_000)
            self?.pushTask = nil
            await self?.pushPending()
        }
    }

    /// Everything on disk, for the switch to iCloud (and a safety net on each start).
    func uploadAll() {
        guard let env else { return }
        for h in LiveLineStore.hours(env: env) { pending.insert(h) }
        Task { await pushPending() }
    }

    private func pushPending() async {
        guard let env, !pending.isEmpty else { return }
        if !accountOK { await checkAccount(thenPull: false); guard accountOK else { return } }
        guard await ensureZone() else { return }
        let hours = pending; pending = []
        var records: [CKRecord] = []
        for h in hours {
            guard let data = LiveLineStore.chunkData(env: env, hour: h) else { continue }
            let id = CKRecord.ID(recordName: "\(env.rawValue)-\(h)-\(machine)", zoneID: zoneID)
            let r = CKRecord(recordType: "Chunk", recordID: id)
            r["env"] = env.rawValue as CKRecordValue
            r["hour"] = h as CKRecordValue
            r["machine"] = machine as CKRecordValue
            r["modified"] = Date() as CKRecordValue
            r["data"] = data as CKRecordValue
            records.append(r)
        }
        guard !records.isEmpty else { log.notice("push: nothing to send for \(hours.count) hour(s)"); return }
        log.notice("push: \(records.count) record(s)")
        do {
            // Each record belongs to this Mac alone, so overwriting is always right.
            _ = try await db.modifyRecords(saving: records, deleting: [], savePolicy: .allKeys)
            if status != .syncing { status = .syncing }
        } catch {
            log.error("push failed: \(error.localizedDescription, privacy: .public)")
            pending.formUnion(hours)   // try again next time
            if let ck = error as? CKError, ck.code == .notAuthenticated { status = .noAccount }
            else { status = .error(error.localizedDescription) }
        }
    }

    // MARK: Pull

    func pull() async {
        guard let env, Self.enabled else { return }
        if !accountOK { await checkAccount(thenPull: false); guard accountOK else { return } }
        guard await ensureZone() else { return }
        var token: CKServerChangeToken? = nil
        if let d = Prefs.defaults.data(forKey: Self.tokenKey) {
            token = try? NSKeyedUnarchiver.unarchivedObject(ofClass: CKServerChangeToken.self, from: d)
        }
        var merged = 0
        do {
            var more = true
            while more {
                let result = try await db.recordZoneChanges(inZoneWith: zoneID, since: token)
                for (_, res) in result.modificationResultsByID {
                    guard case .success(let mod) = res else { continue }
                    let r = mod.record
                    guard let hour = r["hour"] as? String,
                          let recEnv = r["env"] as? String, recEnv == env.rawValue,
                          let data = r["data"] as? Data else { continue }
                    if LiveLineStore.mergeChunk(env: env, hour: hour, data: data) { merged += 1 }
                }
                token = result.changeToken
                more = result.moreComing
            }
            if let token, let d = try? NSKeyedArchiver.archivedData(withRootObject: token, requiringSecureCoding: true) {
                Prefs.defaults.set(d, forKey: Self.tokenKey)
            }
            lastPullAt = Date()
            if status != .syncing { status = .syncing }
        } catch {
            if let ck = error as? CKError {
                switch ck.code {
                case .changeTokenExpired, .zoneNotFound, .userDeletedZone:
                    Prefs.defaults.removeObject(forKey: Self.tokenKey)
                    Prefs.defaults.removeObject(forKey: Self.zoneKey)
                case .notAuthenticated:
                    status = .noAccount
                default:
                    status = .error(error.localizedDescription)
                }
            } else {
                status = .error(error.localizedDescription)
            }
        }
        if merged > 0 { NotificationCenter.default.post(name: .liveLineMerged, object: nil) }
    }

    // MARK: Delete

    /// "Also delete from iCloud": drops the whole zone. Other Macs keep their local copies.
    func deleteCloudCopy() async -> String? {
        do {
            _ = try await db.modifyRecordZones(saving: [], deleting: [zoneID])
            Prefs.defaults.removeObject(forKey: Self.tokenKey)
            Prefs.defaults.removeObject(forKey: Self.zoneKey)
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}

extension Notification.Name {
    /// Posted after a pull merged samples from another Mac; the P&L chart reloads on it.
    static let liveLineMerged = Notification.Name("bet.spex.glance.liveLineMerged")
}
