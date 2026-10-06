import Foundation

/// A one-use, short-lived selection. General experimental consent is not consent
/// to this operation. Runtime checks are not a guarantee of hardware recovery.
public final class DisplayDisconnectRequest {
    public let target: DisplayHideIdentity
    public let survivor: DisplayHideIdentity
    public let timeout: TimeInterval = 15
    let snapshot: RecoverySnapshot
    let expires: TimeInterval
    var consumed = false

    init(target: RecoveryDisplay, survivor: RecoveryDisplay, snapshot: RecoverySnapshot, now: TimeInterval) {
        self.target = Self.identity(target); self.survivor = Self.identity(survivor)
        self.snapshot = snapshot; expires = now + 30
    }

    static func identity(_ display: RecoveryDisplay) -> DisplayHideIdentity {
        .init(uuid: display.uuid, displayID: display.id, name: display.name,
              vendor: display.vendor, model: display.model, serial: display.serial)
    }
}

/// Dropping the parent lease requests recovery; it never kills the watchdog.
public final class DisplayDisconnectLease {
    public let id: UUID
    private var release: (() throws -> Void)?
    init(id: UUID, release: @escaping () throws -> Void) { self.id = id; self.release = release }
    public func reconnect() throws {
        guard let release else { return }
        self.release = nil
        try release()
    }
    deinit { try? release?() }
}

public struct DisplayDisconnectStatus: Equatable {
    public let journalID: String
    public let journalPath: String
    public let target: DisplayHideIdentity?
    public let state: String
    public let deadline: Date?
    public let createdAt: Date
    public let failure: String?
    public let trigger: String?
    public let resolved: Bool
    public let canReconnect: Bool

    init(_ journal: RecoveryJournal, path: String) {
        journalID = journal.id.uuidString; journalPath = path
        target = journal.snapshot.displays.first { $0.id == journal.disabledByUsID }
            .map(DisplayDisconnectRequest.identity)
        state = journal.state.rawValue; deadline = journal.deadline; createdAt = journal.createdAt
        failure = journal.failure; trigger = journal.trigger; resolved = journal.state.resolved
        canReconnect = !resolved && journal.disabledByUsID != nil && journal.disableStaged == true
    }
}

/// Thin app adapter over the existing journal, watchdog and private recovery
/// engine. No independent writer, retry, persistent consent or automation entry.
public struct DisplayDisconnectController {
    let store: RecoveryStore
    var capture: () throws -> RecoverySnapshot
    var preflight: (RecoverySnapshot, UInt32) throws -> Void
    var arm: (RecoveryStore, URL, TimeInterval, RecoverySnapshot, UInt32) throws -> DisplayDisconnectLease
    var recover: (RecoveryStore, UUID) throws -> Void
    var now: () -> TimeInterval

    public init() {
        self.init(store: RecoveryStore())
    }

    public var journalPath: String { store.url.path }

    init(store: RecoveryStore,
         capture: @escaping () throws -> RecoverySnapshot = { try .capture() },
         preflight: @escaping (RecoverySnapshot, UInt32) throws -> Void = RecoveryCLI().preflight,
         arm: @escaping (RecoveryStore, URL, TimeInterval, RecoverySnapshot, UInt32) throws -> DisplayDisconnectLease = { store, executable, timeout, snapshot, target in
             let helper = try RecoveryWatchdog.start(store: store, executable: executable, timeout: timeout,
                 verifyOnly: false, expectedSnapshot: snapshot, privateLease: true)
             do { try helper.requestDisable(targetID: target) }
             catch { try? helper.releaseLease(); throw error }
             return DisplayDisconnectLease(id: helper.id, release: helper.releaseLease)
         },
         recover: @escaping (RecoveryStore, UUID) throws -> Void = { store, id in
             let journal = try store.load()
             guard journal.id == id, journal.disabledByUsID != nil, journal.disableStaged == true else {
                 throw RecoveryError.unsafe("journal changed or has no staged private target; inspect recovery status")
             }
             let session = RecoveryPrivateSession(snapshot: journal.snapshot)
             session.observeNotifications()
             _ = try session.engine.recover(store: store, trigger: "app-reconnect", ownedOnly: true, expectedID: id)
         }, now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.store = store; self.capture = capture; self.preflight = preflight
        self.arm = arm; self.recover = recover; self.now = now
    }

    public func inspect() throws -> DisplayDisconnectStatus? {
        guard try store.exists() else { return nil }
        let journal = try store.load()
        guard journal.privateLease == true || journal.disabledByUsID != nil else { return nil }
        return .init(journal, path: store.url.path)
    }

    /// Whether the shared recovery journal exists, even if it is not private.
    public func journalExists() throws -> Bool { try store.exists() }

    private func requireClearJournal() throws {
        if try store.exists(), try !store.load().state.resolved {
            throw RecoveryError.unsafe("unresolved journal; inspect status and recover before requesting another disconnect")
        }
    }

    public func prepare(targetUUID: String) throws -> DisplayDisconnectRequest {
        try requireClearJournal()
        let snapshot = try capture()
        let target = try Self.eligibleTarget(snapshot, uuid: targetUUID)
        // Read-only policy checks; prepareDisable resolves the verified ABI but
        // does not begin a transaction. The helper repeats all writer boundaries.
        try preflight(snapshot, target.id)
        guard let survivor = snapshot.displays.first(where: { $0.main && $0.id != target.id }) else {
            throw RecoveryError.unsafe("no main physical survivor; disconnect unavailable")
        }
        return .init(target: target, survivor: survivor, snapshot: snapshot, now: now())
    }

    public func disconnect(_ request: DisplayDisconnectRequest, consent: Bool, executable: URL) throws -> DisplayDisconnectLease {
        guard !request.consumed else { throw RecoveryError.unsafe("consent already consumed; select and confirm again") }
        request.consumed = true // A refusal also consumes this operation's consent.
        guard consent else { throw RecoveryError.unsafe("explicit scoped disconnect consent required") }
        guard now() < request.expires else { throw RecoveryError.unsafe("selection expired; check eligibility and confirm again") }
        try requireClearJournal()
        let current = try capture()
        try request.snapshot.verify(current)
        let target = try Self.eligibleTarget(current, uuid: request.target.uuid)
        guard target.id == request.target.displayID else { throw RecoveryError.unsafe("selected identity changed") }
        // Preserve consent-time transport evidence through preflight and helper
        // recapture. Public topology verification alone does not compare it.
        try preflight(request.snapshot, target.id)
        return try arm(store, executable, request.timeout, request.snapshot, target.id)
    }

    public func reconnect(expectedJournalID: String) throws {
        guard let id = UUID(uuidString: expectedJournalID) else { throw RecoveryError.unsafe("invalid journal identity") }
        try recover(store, id)
    }

    /// Selection is capability-based, not a list of previously tested hardware.
    /// The production preflight still verifies identity, physical eligibility,
    /// native drivers, lifecycle and ABI before a helper can be armed.
    static func eligibleTarget(_ snapshot: RecoverySnapshot, uuid: String) throws -> RecoveryDisplay {
        let matches = snapshot.displays.filter { $0.uuid.caseInsensitiveCompare(uuid) == .orderedSame }
        guard UUID(uuidString: uuid) != nil, matches.count == 1, let target = matches.first else {
            throw RecoveryError.unsafe("unavailable: select one display with an unambiguous stable identity")
        }
        guard !target.main, !target.builtin, target.active, target.mirrorUUID == nil else {
            throw RecoveryError.unsafe("unavailable: select an active, non-main external display that is not mirrored")
        }
        return target
    }
}
