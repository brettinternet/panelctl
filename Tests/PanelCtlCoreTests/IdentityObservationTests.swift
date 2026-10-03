import XCTest
import Darwin
@testable import PanelCtlCore

final class IdentityObservationTests: XCTestCase {
    private func recorder(records: Int = 512, bytes: Int = 4 * 1_048_576) throws -> IdentityObservationRecording {
        try IdentityObservationRecording(root: FileManager.default.temporaryDirectory
            .appendingPathComponent("panelctl-observer-tests-\(UUID())"), recordLimit: records, byteLimit: bytes)
    }

    private func json(_ recorder: IdentityObservationRecording, _ name: String) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: Data(contentsOf: recorder.root.appendingPathComponent(name))) as! [String: Any]
    }

    func testPrivateFreshArtifactsAndNeverOverwriteOrResume() throws {
        let record = try recorder()
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: record.root.path)[.posixPermissions] as? Int, 0o700)
        for name in ["events.jsonl", "started.json"] {
            XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: record.root.appendingPathComponent(name).path)[.posixPermissions] as? Int, 0o600)
        }
        XCTAssertThrowsError(try IdentityObservationRecording(root: record.root))
        let before = try Data(contentsOf: record.root.appendingPathComponent("started.json"))
        XCTAssertThrowsError(try record.save(Data("replacement".utf8), name: "started.json"))
        XCTAssertEqual(try Data(contentsOf: record.root.appendingPathComponent("started.json")), before)
        XCTAssertEqual(try json(record, "started.json")["complete"] as? Bool, false)
        XCTAssertFalse(FileManager.default.fileExists(atPath: record.root.appendingPathComponent("summary.json").path))
    }

    func testReceiptTimesInitialInventoryAndReadyAreDistinct() throws {
        let record = try recorder()
        record.append("initial-service", ["entry": 123], receipt: ["wallTime": 42.5, "monotonicNanoseconds": UInt64(123456)])
        try record.arm(initialIteratorsDrained: true)
        record.append("service-event")
        try record.finish(deadlineReached: true)
        let lines = try String(contentsOf: record.root.appendingPathComponent("events.jsonl")).split(separator: "\n")
        let rows = try lines.map { try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any] }
        XCTAssertEqual(rows.map { $0["kind"] as! String }, ["initial-service", "recording-ready", "service-event", "end"])
        XCTAssertEqual(rows[0]["wallTime"] as? Double, 42.5)
        XCTAssertEqual(rows[0]["monotonicNanoseconds"] as? UInt64, 123456)
        XCTAssertEqual(rows.map { $0["sequence"] as! Int }, [0, 1, 2, 3])
        XCTAssertEqual(try json(record, "summary.json")["complete"] as? Bool, true)
        XCTAssertThrowsError(try record.finish(deadlineReached: true))
    }

    func testInitialDrainRegistrationAndRestartFailuresNeverArm() throws {
        let invalid = try recorder()
        XCTAssertThrowsError(try invalid.arm(initialIteratorsDrained: false))
        XCTAssertFalse(invalid.ready)
        try invalid.finish(deadlineReached: false)
        XCTAssertEqual(try json(invalid, "summary.json")["complete"] as? Bool, false)
        for failure in ["registration failure", "invalid iterator", "missing context", "collector restart"] {
            let record = try recorder()
            record.fail(failure)
            XCTAssertThrowsError(try record.arm(initialIteratorsDrained: true))
            try record.finish(deadlineReached: true)
            XCTAssertEqual(try json(record, "summary.json")["failure"] as? String, failure)
        }
        let restarted = try recorder()
        try restarted.arm(initialIteratorsDrained: true)
        XCTAssertThrowsError(try restarted.arm(initialIteratorsDrained: true))
        XCTAssertNotNil(restarted.failure)
    }

    func testRecordByteAndSingleRecordBoundsAreSticky() throws {
        let count = try recorder(records: 1)
        count.append("one"); count.append("two")
        XCTAssertEqual(count.records, 1); XCTAssertNotNil(count.failure)
        try count.finish(deadlineReached: true)
        XCTAssertEqual(try json(count, "summary.json")["complete"] as? Bool, false)
        let bytes = try recorder(bytes: 1)
        bytes.append("too-large")
        XCTAssertEqual(bytes.bytes, 0); XCTAssertNotNil(bytes.failure)
        let row = try recorder()
        row.append("too-large", ["data": String(repeating: "x", count: 65_536)])
        XCTAssertEqual(row.records, 0); XCTAssertNotNil(row.failure)
        row.append("must-not-resume")
        XCTAssertEqual(row.records, 0)
    }

    func testSerializationFailureAndEarlyExitRemainIncomplete() throws {
        let record = try recorder()
        record.append("bad-json", ["number": Double.nan])
        XCTAssertNotNil(record.failure)
        try record.finish(deadlineReached: false)
        XCTAssertEqual(try json(record, "summary.json")["complete"] as? Bool, false)
        let early = try recorder()
        try early.arm(initialIteratorsDrained: true)
        try early.finish(deadlineReached: false)
        XCTAssertEqual(try json(early, "summary.json")["complete"] as? Bool, false)
    }

    func testCGQueueIsBoundedThreadSafeAndNeverInspectsCallbackID() {
        let queue = IdentityCGEvents(limit: 2)
        queue.receive(id: UInt32.max, flags: 1); queue.receive(id: 0, flags: 2); queue.receive(id: 1, flags: 3)
        let (events, overflow) = queue.drain()
        XCTAssertTrue(overflow); XCTAssertEqual(events.map(\.id), [UInt32.max, 0])
        XCTAssertTrue(events.allSatisfy { $0.wall > 0 && $0.monotonic > 0 })
        XCTAssertTrue(queue.drain().1) // Loss remains sticky after draining.
        _ = queue.drain(close: true); queue.receive(id: 3, flags: 1)
        XCTAssertTrue(queue.drain().0.isEmpty)
        let concurrent = IdentityCGEvents(limit: 32)
        DispatchQueue.concurrentPerform(iterations: 1000) { concurrent.receive(id: UInt32($0), flags: 0) }
        XCTAssertEqual(concurrent.drain().0.count, 32)
        XCTAssertTrue(concurrent.drain().1)
    }

    func testConsoleContextRequiresObservedUUIDAuditAndCurrentConsoleUser() throws {
        let session: [String: Any] = ["kCGSSessionOnConsoleKey": true, "kCGSSessionUserIDKey": getuid(),
            "kCGSSessionAuditIDKey": 100131, "CGSSessionUniqueSessionUUID": "A5F4FE9F-44B1-4394-B78F-71BD67ADDEC2"]
        XCTAssertNoThrow(try IdentityObservationInventory.consoleContext(session))
        XCTAssertThrowsError(try IdentityObservationInventory.consoleContext(nil))
        for key in session.keys {
            var missing = session; missing.removeValue(forKey: key)
            XCTAssertThrowsError(try IdentityObservationInventory.consoleContext(missing), key)
        }
        for (key, value): (String, Any) in [("kCGSSessionOnConsoleKey", false), ("kCGSSessionUserIDKey", getuid() + 1),
                                            ("kCGSSessionAuditIDKey", 0), ("CGSSessionUniqueSessionUUID", "invalid")] {
            var bad = session; bad[key] = value
            XCTAssertThrowsError(try IdentityObservationInventory.consoleContext(bad), key)
        }
    }

    func testFailedCGRemovalKeepsClosedCallbackContextAlive() throws {
        let record = try recorder()
        weak var context: IdentityCGEvents?
        var reference: UnsafeMutableRawPointer!
        do {
            let collector = IdentityLifetimeCollector(recording: record)
            context = collector.cg
            reference = Unmanaged.passRetained(collector.cg).toOpaque()
            collector.cgReference = reference
            collector.removeCG = { _ in .failure }
            collector.stop()
        }
        XCTAssertNotNil(context)
        XCTAssertNotNil(record.failure)
        IdentityLifetimeCollector.reconfiguration(123, [], reference)
        XCTAssertTrue(context!.drain().0.isEmpty)
        // Simulated registration is now gone; release its intentionally retained
        // reference. Production never releases after failed removal.
        Unmanaged<IdentityCGEvents>.fromOpaque(reference).release()
        XCTAssertNil(context)
    }

    func testSuccessfulCGRemovalReleasesContextAndCleanupIsIdempotent() throws {
        let record = try recorder()
        weak var context: IdentityCGEvents?
        var removals = 0
        do {
            let collector = IdentityLifetimeCollector(recording: record)
            context = collector.cg
            collector.cgReference = Unmanaged.passRetained(collector.cg).toOpaque()
            collector.removeCG = { _ in removals += 1; return .success }
            collector.stop(); collector.stop()
        }
        XCTAssertEqual(removals, 1); XCTAssertNil(context)
    }

    func testSummaryPublicationWaitsForSuccessfulSynchronizationAndClose() throws {
        for failAfterSync in [false, true] {
            let record = try recorder()
            try record.arm(initialIteratorsDrained: true)
            record.finishArtifact = { file in
                if failAfterSync { try file.synchronize() }
                throw RecoveryError.unsafe("injected sync/close failure")
            }
            XCTAssertThrowsError(try record.finish(deadlineReached: true))
            XCTAssertFalse(FileManager.default.fileExists(atPath: record.root.appendingPathComponent("summary.json").path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: record.root.appendingPathComponent("started.json").path))
        }
    }

    func testTerminalSummaryCollisionPreservesExistingEvidenceAndCannotRetry() throws {
        for symlink in [false, true] {
            let record = try recorder()
            let existing = Data("existing evidence".utf8)
            try record.save(existing, name: symlink ? "preserved.json" : "summary.json")
            let summary = record.root.appendingPathComponent("summary.json")
            if symlink {
                try FileManager.default.createSymbolicLink(atPath: summary.path, withDestinationPath: "preserved.json")
            }
            try record.arm(initialIteratorsDrained: true)
            XCTAssertThrowsError(try record.finish(deadlineReached: true))
            XCTAssertEqual(try Data(contentsOf: summary), existing)
            let pending = try Data(contentsOf: record.root.appendingPathComponent("summary.pending.json"))
            XCTAssertThrowsError(try record.finish(deadlineReached: true))
            XCTAssertEqual(try Data(contentsOf: summary), existing)
            XCTAssertEqual(try Data(contentsOf: record.root.appendingPathComponent("summary.pending.json")), pending)
            if symlink {
                XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: summary.path), "preserved.json")
            }
        }
    }

    func testPendingCGReceiptAtCleanupMakesArmedRecordingIncomplete() throws {
        let record = try recorder()
        let collector = IdentityLifetimeCollector(recording: record)
        collector.initialDrains = 6
        try collector.arm {}
        collector.cg.receive(id: UInt32.max, flags: 123)
        collector.stop(); collector.stop()
        try record.finish(deadlineReached: true)
        XCTAssertEqual(try json(record, "summary.json")["ready"] as? Bool, true)
        XCTAssertEqual(try json(record, "summary.json")["complete"] as? Bool, false)
        XCTAssertTrue(record.failure!.contains("CG events at cleanup"))
        XCTAssertTrue(collector.cg.drain().0.isEmpty)
        let lines = try String(contentsOf: record.root.appendingPathComponent("events.jsonl")).split(separator: "\n")
        let rows = try lines.map { try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any] }
        XCTAssertEqual(rows.filter { $0["kind"] as? String == "cg-reconfiguration" }.count, 1)
    }

    func testServiceReadFailureIsStickyEvenAfterSuccessfulInventory() throws {
        let good: [String: Any] = ["entryIDStatus": Int32(0), "pathStatus": Int32(0),
                                  "busyStatus": Int32(0), "identityReadable": true]
        for key in ["entryIDStatus", "pathStatus", "busyStatus"] {
            let record = try recorder()
            let collector = IdentityLifetimeCollector(recording: record)
            var bad = good; bad[key] = Int32(1)
            collector.recordInterest(bad, message: 123, receipt: IdentityObservationRecording.stamp())
            XCTAssertNoThrow(try collector.checkService(good))
            XCTAssertNotNil(record.failure)
            XCTAssertThrowsError(try record.arm(initialIteratorsDrained: true))
            try record.finish(deadlineReached: true)
            XCTAssertEqual(try json(record, "summary.json")["complete"] as? Bool, false)
        }
    }

    func testSetupCGEventsAndOverflowPreventReadinessAcknowledgment() throws {
        for count in [1, 257] {
            let record = try recorder()
            let collector = IdentityLifetimeCollector(recording: record)
            collector.initialDrains = 6
            for _ in 0..<count { collector.cg.receive(id: 42, flags: 0) }
            XCTAssertThrowsError(try collector.arm { XCTFail("must not acknowledge readiness") })
            XCTAssertFalse(record.ready)
            XCTAssertFalse(try String(contentsOf: record.root.appendingPathComponent("events.jsonl")).contains("recording-ready"))
        }
    }

    func testRegistryPropertyBoundsAndBinaryFingerprint() throws {
        XCTAssertThrowsError(try IdentityObservationInventory.value(String(repeating: "x", count: 4097)))
        XCTAssertThrowsError(try IdentityObservationInventory.value(Array(repeating: 1, count: 65)))
        XCTAssertThrowsError(try IdentityObservationInventory.value(Data(count: 1_048_577)))
        XCTAssertThrowsError(try IdentityObservationInventory.value(Date()))
        var nested: Any = "leaf"
        for _ in 0..<8 { nested = ["child": nested] }
        XCTAssertThrowsError(try IdentityObservationInventory.value(nested))
        let data = Data([1, 2, 3])
        let value = try IdentityObservationInventory.value(data) as! [String: Any]
        XCTAssertEqual(value["sha256"] as? String, RecoveryColorProfile.digest(data))
        XCTAssertEqual(value["byteCount"] as? Int, 3)
    }
}
