import Foundation
import Darwin

enum RecoveryState: String, Codable {
    case captured, armed, disabling, disabled, mirrored, restoring, verified, restored, needsAttention
    var resolved: Bool { self == .verified || self == .restored }
}

enum PublicMirrorRemovalState: String, Codable {
    case captured, mirrored, restoring, restored, cancelled, needsAttention
    // An exact pre-operation match retires an unchanged Hide, not a claim
    // that this display has returned to the session's original coordinates.
    var resolved: Bool { self == .restored || self == .cancelled }
}

struct PublicMirrorRemoval: Codable, Equatable, Identifiable {
    let id: UUID
    let targetUUID: String
    let targetID: UInt32
    let sourceUUID: String
    let sourceID: UInt32
    let beforeOperation: RecoverySnapshot
    var state: PublicMirrorRemovalState
    var failure: String?
    // Durable pre-Show snapshot. Partial-Show postconditions must survive a
    // crash after completion and must not disappear on read-only inspection.
    var restoreFrom: RecoverySnapshot?

    init(target: RecoveryDisplay, source: RecoveryDisplay, beforeOperation: RecoverySnapshot,
         state: PublicMirrorRemovalState = .captured) {
        id = UUID()
        targetUUID = target.uuid
        targetID = target.id
        sourceUUID = source.uuid
        sourceID = source.id
        self.beforeOperation = beforeOperation
        self.state = state
    }
}

struct PublicMirrorSession: Codable, Equatable {
    let version: Int
    let baseline: RecoverySnapshot
    var removals: [PublicMirrorRemoval]

    init(baseline: RecoverySnapshot, removals: [PublicMirrorRemoval]) {
        version = 1
        self.baseline = baseline
        self.removals = removals
    }
}

struct RecoveryJournal: Codable {
    var version: Int
    let id: UUID
    let createdAt: Date
    let snapshot: RecoverySnapshot
    let verifyOnly: Bool
    let deadline: Date?
    var state: RecoveryState
    var trigger: String?
    var failure: String?
    // Diagnostics only; never used to signal or identify a process for recovery.
    var watchdogPID: Int32?
    var reenableAttempted: Bool?
    // Absent in legacy/public-only captures; never inferred from disappearance.
    var disabledByUsID: UInt32?
    // Write-ahead attempt, not proof of a successful commit. Recovery must
    // consider a missing target even if the post-commit save never happened.
    var disableAttempted: Bool?
    // Successful staging is durable before completion can consume the
    // transaction. Pre-staging intent alone never authorizes private recovery.
    var disableStaged: Bool?
    // Final validation passed and completion may have been invoked. Staging
    // alone (including older journals) cannot authorize private recovery.
    var disableCommitStarted: Bool?
    var disableCompleted: Bool?
    var privateRecoveryClosed: Bool?
    var privateLease: Bool?
    // Public mirror intent only; original topology remains in snapshot.
    var mirrorTargetID: UInt32?
    var mirrorSourceID: UInt32?
    // Versioned atomic multi-display public-mirror session. Absent in legacy
    // journals and private-disable transactions.
    var publicMirrorSession: PublicMirrorSession?

    init(snapshot: RecoverySnapshot, verifyOnly: Bool = false, timeout: TimeInterval? = nil,
         disabledByUsID: UInt32? = nil, disableStaged: Bool? = nil, disableCommitStarted: Bool? = nil,
         publicMirrorSession: PublicMirrorSession? = nil) {
        let now = Date()
        version = publicMirrorSession == nil ? 2 : 3
        id = UUID(); createdAt = now; self.snapshot = snapshot
        self.publicMirrorSession = publicMirrorSession
        self.disabledByUsID = disabledByUsID
        self.disableStaged = disableStaged
        self.disableCommitStarted = disableCommitStarted
        self.verifyOnly = verifyOnly
        deadline = timeout.map { now.addingTimeInterval($0) }
        state = .captured
    }

    func validate() throws {
        guard version == 1 || version == 2 || version == 3 else { throw RecoveryError.unsafe("unsupported journal version \(version)") }
        let displays = snapshot.displays
        guard !snapshot.bootSession.isEmpty, !snapshot.osBuild.isEmpty,
              snapshot.userID == getuid(), !displays.isEmpty, displays.count <= 128,
              Set(displays.map(\.uuid)).count == displays.count,
              Set(displays.map(\.id)).count == displays.count,
              displays.filter(\.main).count == 1,
              createdAt.timeIntervalSince1970.isFinite else {
            throw RecoveryError.unsafe("invalid snapshot identity or display set")
        }
        if version == 3 || publicMirrorSession != nil {
            guard version == 3, let publicMirrorSession,
                  publicMirrorSession.version == 1,
                  publicMirrorSession.baseline == snapshot,
                  !publicMirrorSession.removals.isEmpty,
                  publicMirrorSession.removals.count <= 128,
                  disabledByUsID == nil, disableAttempted == nil, disableStaged == nil,
                  disableCommitStarted == nil, disableCompleted == nil, privateLease != true,
                  !verifyOnly, deadline == nil, reenableAttempted == nil,
                  Set(publicMirrorSession.removals.map(\.id)).count == publicMirrorSession.removals.count else {
                throw RecoveryError.unsafe("invalid public mirror session")
            }
            var activeTargets = Set<String>()
            for removal in publicMirrorSession.removals {
                guard UUID(uuidString: removal.targetUUID) != nil,
                      UUID(uuidString: removal.sourceUUID) != nil,
                      removal.targetUUID == removal.targetUUID.lowercased(),
                      removal.sourceUUID == removal.sourceUUID.lowercased(),
                      removal.targetUUID != removal.sourceUUID,
                      let target = displays.first(where: { $0.uuid == removal.targetUUID && $0.id == removal.targetID }),
                      let source = displays.first(where: { $0.uuid == removal.sourceUUID && $0.id == removal.sourceID }),
                      !target.builtin, target.active, source.active, target.mirrorUUID == nil,
                      source.mirrorUUID == nil,
                      removal.beforeOperation.displays.count == displays.count,
                      Set(removal.beforeOperation.displays.map(\.uuid)) == Set(displays.map(\.uuid)) else {
                    throw RecoveryError.unsafe("invalid public mirror removal identity")
                }
                try snapshot.validateRestoration(to: removal.beforeOperation)
                if let restoreFrom = removal.restoreFrom {
                    try snapshot.validateRestoration(to: restoreFrom)
                    try RecoveryJournal(snapshot: restoreFrom).validate()
                }
                guard let operationTarget = removal.beforeOperation.displays.first(where: { $0.uuid == removal.targetUUID }),
                      operationTarget.mirrorUUID == nil, operationTarget.active,
                      let operationSource = removal.beforeOperation.displays.first(where: { $0.uuid == removal.sourceUUID }),
                      operationSource.active, operationSource.mirrorUUID == nil else {
                    throw RecoveryError.unsafe("invalid public mirror pre-operation topology")
                }
                if !removal.state.resolved {
                    guard activeTargets.insert(removal.targetUUID).inserted else {
                        throw RecoveryError.unsafe("multiple unresolved removals for one target")
                    }
                }
            }
            if publicMirrorSession.removals.count == 1,
               mirrorTargetID != nil || mirrorSourceID != nil {
                guard mirrorTargetID == publicMirrorSession.removals[0].targetID,
                      mirrorSourceID == publicMirrorSession.removals[0].sourceID else {
                    throw RecoveryError.unsafe("public mirror compatibility fields mismatch")
                }
            } else if mirrorTargetID != nil || mirrorSourceID != nil {
                throw RecoveryError.unsafe("multi-display session cannot have singleton mirror fields")
            }
        } else if mirrorTargetID != nil || mirrorSourceID != nil || state == .mirrored {
            guard let target = displays.first(where: { $0.id == mirrorTargetID }),
                  let source = displays.first(where: { $0.id == mirrorSourceID }),
                  target.id != source.id, !target.builtin, target.active, source.active,
                  displays.allSatisfy({ $0.mirrorUUID == nil }),
                  disabledByUsID == nil, privateLease != true, !verifyOnly, deadline == nil else {
                throw RecoveryError.unsafe("invalid public mirror journal")
            }
        }
        if let deadline {
            guard (1...60).contains(deadline.timeIntervalSince(createdAt)) else {
                throw RecoveryError.unsafe("watchdog deadline must be 1–60 seconds after capture")
            }
        }
        for display in displays {
            if let digest = display.colorProfileDateIndependentDigest {
                func isSHA256(_ value: String) -> Bool {
                    value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
                }
                guard let raw = display.colorProfileDigest, isSHA256(raw), isSHA256(digest) else {
                    throw RecoveryError.unsafe("invalid ICC fingerprint evidence")
                }
            }
            guard UUID(uuidString: display.uuid) != nil, display.id != 0,
                  display.mode.width > 0, display.mode.height > 0,
                  display.mode.pixelWidth > 0, display.mode.pixelHeight > 0,
                  display.mode.refreshRate.isFinite, display.mode.refreshRate >= 0,
                  display.rotation.isFinite else { throw RecoveryError.unsafe("invalid display snapshot") }
            if let mirror = display.mirrorUUID {
                guard mirror != display.uuid,
                      displays.contains(where: { $0.uuid == mirror && $0.mirrorUUID == nil }) else {
                    throw RecoveryError.unsafe("invalid mirror relationship")
                }
            }
        }
    }
}

private struct StablePublicMirrorRemovalIdentity: Codable {
    let id: UUID
    let targetUUID: String
    let targetID: UInt32
    let sourceUUID: String
    let sourceID: UInt32
    let beforeOperationIdentity: String?
    let state: String
    let failure: String?
    let restoreFromIdentity: String?
}

private struct StablePublicMirrorSessionIdentity: Codable {
    let version: Int
    let baselineIdentity: String?
    let removals: [StablePublicMirrorRemovalIdentity]
}

private struct StableMirrorJournalIdentity: Codable {
    let id: UUID
    let state: String
    let trigger: String?
    let failure: String?
    let baselineIdentity: String?
    let sessionIdentity: String?
    let mirrorTargetID: UInt32?
    let mirrorSourceID: UInt32?
}

extension RecoveryJournal {
    func wakeResumeIdentity() -> String? {
        let sessionIdentity = publicMirrorSession.flatMap { session -> String? in
            let stable = StablePublicMirrorSessionIdentity(
                version: session.version,
                baselineIdentity: session.baseline.stableTopologyIdentity(),
                removals: session.removals.map { removal in
                    StablePublicMirrorRemovalIdentity(
                        id: removal.id, targetUUID: removal.targetUUID, targetID: removal.targetID,
                        sourceUUID: removal.sourceUUID, sourceID: removal.sourceID,
                        beforeOperationIdentity: removal.beforeOperation.stableTopologyIdentity(),
                        state: removal.state.rawValue, failure: removal.failure,
                        restoreFromIdentity: removal.restoreFrom?.stableTopologyIdentity()
                    )
                }
            )
            return stableRecoveryDigest(stable)
        }
        return stableRecoveryDigest(StableMirrorJournalIdentity(
            id: id, state: state.rawValue, trigger: trigger, failure: failure,
            baselineIdentity: (publicMirrorSession?.baseline ?? snapshot).stableTopologyIdentity(),
            sessionIdentity: sessionIdentity, mirrorTargetID: mirrorTargetID, mirrorSourceID: mirrorSourceID
        ))
    }
}

/// A private directory, atomic replacement, explicit fsync, and an advisory
/// process-held lock. Unresolved journals cannot be overwritten by a new trial.
final class RecoveryStore {
    static let defaultURL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        .appendingPathComponent("Library/Application Support/PanelCtl/Recovery/current.json")
    // All CLI recovery writers/helpers also hold this lock, including those
    // using custom journals. Other display applications cannot honor it.
    static func operationLock() -> RecoveryStore {
        RecoveryStore(url: defaultURL.deletingLastPathComponent().appendingPathComponent("operation"))
    }

    let url: URL
    private var lockFD: Int32?

    init(url: URL = defaultURL) { self.url = url.standardizedFileURL }
    deinit { unlock() }

    func lock() throws {
        guard lockFD == nil else { throw RecoveryError.unsafe("journal lock already held") }
        try prepareDirectory()
        let fd = open(url.appendingPathExtension("lock").path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw RecoveryError.unsafe("cannot open recovery lock") }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == getuid(),
              info.st_mode & S_IFMT == S_IFREG, info.st_mode & 0o077 == 0,
              flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            throw RecoveryError.unsafe("recovery is busy or lock permissions are unsafe")
        }
        lockFD = fd
    }

    func unlock() {
        if let fd = lockFD { _ = flock(fd, LOCK_UN); close(fd); lockFD = nil }
    }

    func exists() throws -> Bool {
        try prepareDirectory()
        var info = stat()
        if lstat(url.path, &info) == 0 { return true }
        guard errno == ENOENT else { throw RecoveryError.unsafe("cannot inspect existing journal") }
        return false
    }

    func load() throws -> RecoveryJournal {
        try prepareDirectory()
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw RecoveryError.unsafe("cannot read journal at \(url.path)") }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == getuid(),
              info.st_mode & S_IFMT == S_IFREG, info.st_mode & 0o077 == 0,
              info.st_size > 0, info.st_size <= 1_048_576 else {
            throw RecoveryError.unsafe("unsafe journal permissions, type, or size")
        }
        let data = try file.readToEnd() ?? Data()
        let journal = try JSONDecoder().decode(RecoveryJournal.self, from: data)
        try journal.validate()
        return journal
    }

    func create(_ journal: RecoveryJournal) throws {
        guard lockFD != nil else { throw RecoveryError.unsafe("journal write requires lock") }
        var info = stat()
        if lstat(url.path, &info) == 0 {
            let previous = try load()
            guard previous.state.resolved else {
                throw RecoveryError.unsafe("unresolved journal \(previous.id); verify or restore it before capturing again")
            }
            let archive = url.deletingLastPathComponent().appendingPathComponent("recovery-\(previous.id.uuidString).json")
            // Preserve the previous evidence before replacing current.json.
            if FileManager.default.fileExists(atPath: archive.path) {
                // A previous create may have archived successfully but failed
                // to replace current.json. Permit only a byte-identical retry.
                guard try Data(contentsOf: archive) == Data(contentsOf: url) else {
                    throw RecoveryError.unsafe("conflicting recovery archive; preserve both files for inspection")
                }
            } else {
                try FileManager.default.copyItem(at: url, to: archive)
            }
        } else if errno != ENOENT {
            throw RecoveryError.unsafe("cannot inspect existing journal")
        }
        try save(journal)
    }

    func save(_ journal: RecoveryJournal) throws {
        guard lockFD != nil else { throw RecoveryError.unsafe("journal write requires lock") }
        try journal.validate()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(journal)
        // .atomic is the existing project's journal convention; restrictive
        // permissions and synchronization are added before acknowledging READY.
        try data.write(to: url, options: [.atomic])
        guard chmod(url.path, 0o600) == 0 else { throw RecoveryError.unsafe("cannot secure journal") }
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw RecoveryError.unsafe("cannot synchronize journal") }
        defer { close(fd) }
        guard fsync(fd) == 0 else { throw RecoveryError.unsafe("cannot synchronize journal") }
        let directoryFD = open(url.deletingLastPathComponent().path, O_RDONLY | O_CLOEXEC)
        guard directoryFD >= 0 else { throw RecoveryError.unsafe("cannot synchronize journal directory") }
        defer { close(directoryFD) }
        guard fsync(directoryFD) == 0 else { throw RecoveryError.unsafe("cannot synchronize journal directory") }
    }

    private func prepareDirectory() throws {
        let directory = url.deletingLastPathComponent()
        var info = stat()
        if lstat(directory.path, &info) != 0 {
            guard errno == ENOENT else { throw RecoveryError.unsafe("cannot inspect journal directory") }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                   attributes: [.posixPermissions: 0o700])
        }
        guard lstat(directory.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
              info.st_uid == getuid(), info.st_mode & 0o077 == 0 else {
            throw RecoveryError.unsafe("journal directory must be owned by you, mode 0700, and not a symlink: \(directory.path)")
        }
    }
}
