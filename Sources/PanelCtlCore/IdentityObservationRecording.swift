import Foundation
import Darwin

/// Diagnostic-only evidence: never decoded as a recovery identity or journal.
/// A missing summary means interrupted/incomplete, never a successful recording.
final class IdentityObservationRecording {
    let root: URL
    let runID = UUID().uuidString
    private let events: FileHandle
    private(set) var records = 0
    private(set) var bytes = 0
    private(set) var failure: String?
    private(set) var ready = false
    private var finished = false
    let recordLimit: Int
    let byteLimit: Int
    // Persistence fault seam; tests never touch display APIs.
    var finishArtifact: (FileHandle) throws -> Void = { file in
        try file.synchronize(); try file.close()
    }

    init(root: URL, recordLimit: Int = 512, byteLimit: Int = 4 * 1_048_576) throws {
        self.root = root; self.recordLimit = recordLimit; self.byteLimit = byteLimit
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        let fd = open(root.appendingPathComponent("events.jsonl").path,
                      O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw RecoveryError.unsafe("cannot create observer recording") }
        events = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        try saveJSON(["runID": runID, "complete": false, "collectorRestart": false,
                      "note": "Fresh collector; never resumes/backfills. Missing summary means incomplete. Recording readiness is not recovery readiness."], name: "started.json")
    }

    static func stamp() -> [String: Any] {
        ["wallTime": Date().timeIntervalSince1970, "monotonicNanoseconds": DispatchTime.now().uptimeNanoseconds]
    }

    func fail(_ reason: String) { if failure == nil { failure = String(reason.prefix(2048)) } }

    func append(_ kind: String, _ payload: [String: Any] = [:], receipt: [String: Any]? = nil) {
        guard !finished, failure == nil else { return }
        do {
            var row = receipt ?? Self.stamp()
            row["kind"] = kind; row["payload"] = payload; row["sequence"] = records; row["runID"] = runID
            guard JSONSerialization.isValidJSONObject(row) else {
                fail("invalid JSON; incomplete recording"); return
            }
            var data = try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys])
            data.append(0x0a)
            guard data.count <= 65_536, records < recordLimit, data.count <= byteLimit - bytes else {
                fail("record/output overflow; incomplete recording"); return
            }
            try events.write(contentsOf: data)
            records += 1; bytes += data.count
        } catch { fail("recording failure: \(error)") }
    }

    func arm(initialIteratorsDrained: Bool) throws {
        guard !ready, !finished, initialIteratorsDrained, failure == nil else {
            fail("registration/initial iterator readiness failure or collector restart")
            throw RecoveryError.unsafe(failure!)
        }
        append("recording-ready", ["recoveryAvailable": false])
        try events.synchronize()
        guard failure == nil else { throw RecoveryError.unsafe(failure!) }
        ready = true
    }

    func save(_ data: Data, name: String) throws {
        let fd = open(root.appendingPathComponent(name).path,
                      O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw RecoveryError.unsafe("cannot create new evidence artifact \(name)") }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        try file.write(contentsOf: data); try finishArtifact(file)
    }

    func saveJSON(_ value: [String: Any], name: String) throws {
        guard JSONSerialization.isValidJSONObject(value) else { throw RecoveryError.unsafe("invalid evidence JSON") }
        try save(JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]), name: name)
    }

    func finish(deadlineReached: Bool) throws {
        guard !finished else { throw RecoveryError.unsafe("collector restart/duplicate finish") }
        if !deadlineReached { fail("observation ended early; incomplete recording") }
        if !ready { fail("recording was never armed") }
        append("end", ["deadlineReached": deadlineReached])
        finished = true
        try events.synchronize(); try events.close()
        try saveJSON(["runID": runID, "complete": failure == nil, "ready": ready,
                      "failure": failure as Any? ?? NSNull(), "records": records, "eventBytes": bytes,
                      "ended": Self.stamp(), "collectorRestart": false,
                      "note": "Complete means bounded recording completed, not complete event delivery or physical identity qualification."], name: "summary.pending.json")
        // Publish only fully written, synchronized, closed bytes. link is atomic
        // and refuses an existing name; keep the pending file as crash evidence.
        guard link(root.appendingPathComponent("summary.pending.json").path,
                   root.appendingPathComponent("summary.json").path) == 0 else {
            throw RecoveryError.unsafe("cannot publish terminal summary")
        }
    }
}

/// CG callbacks may arrive off-thread. Queue only fixed-size receipt data; never
/// look up a callback's ID (it may already be gone). Consumer enumerates afresh.
final class IdentityCGEvents {
    struct Event { let id: UInt32; let flags: UInt32; let wall: Double; let monotonic: UInt64 }
    private let lock = NSLock()
    private var pending: [Event] = []
    private var overflow = false
    private var closed = false
    let limit: Int
    init(limit: Int = 256) { self.limit = limit }
    func receive(id: UInt32, flags: UInt32) {
        let event = Event(id: id, flags: flags, wall: Date().timeIntervalSince1970,
                          monotonic: DispatchTime.now().uptimeNanoseconds)
        lock.lock(); defer { lock.unlock() }
        guard !closed else { return }
        guard pending.count < limit else { overflow = true; return }
        pending.append(event)
    }
    func whenEmpty(_ action: () throws -> Void) throws {
        lock.lock(); defer { lock.unlock() }
        guard !closed, !overflow, pending.isEmpty else {
            throw RecoveryError.unsafe("CG receipt queue not empty/healthy at readiness")
        }
        try action()
    }

    func drain(close: Bool = false) -> ([Event], Bool) {
        lock.lock(); defer { lock.unlock() }
        if close { closed = true }
        let result = pending; pending.removeAll(keepingCapacity: true)
        return (result, overflow)
    }
}
