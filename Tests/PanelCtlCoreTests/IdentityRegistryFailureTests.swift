import XCTest
import IOKit
@testable import PanelCtlCore

/// All handles and native operations below are fake, including cleanup. These
/// tests cannot register a real notification or call a display/device API.
final class IdentityRegistryFailureTests: XCTestCase {
    private final class FakeRegistry {
        var entries: [UInt32] = []
        var iterator: UInt32 = 1000
        var matchingStatus: Int32 = 0
        var interestStatus: Int32 = 0
        var notification: UInt32 = 2000
        var retainStatus: Int32 = 0
        var valid = true
        var readFails = false
        var calls: [String] = []
        var released: [UInt32] = []
        var nextCalls = 0
        var reads = 0
        var interests = 0
        var retains = 0

        var api: IdentityRegistryAPI {
            IdentityRegistryAPI(next: { _ in
                self.calls.append("next"); self.nextCalls += 1
                return self.entries.isEmpty ? 0 : self.entries.removeFirst()
            }, valid: { _ in self.calls.append("valid"); return self.valid }, service: { entry in
                self.reads += 1
                if self.readFails { throw RecoveryError.unsafe("injected property failure") }
                return ["entryIDStatus": Int32(0), "pathStatus": Int32(0), "busyStatus": Int32(0),
                        "identityReadable": true, "registryEntryID": UInt64(entry)]
            }, retain: { _ in self.retains += 1; return self.retainStatus }, release: {
                self.released.append($0)
            }, equal: { $0 == $1 }, matching: { _, _, _, _, iterator in
                self.calls.append("register"); iterator = self.iterator; return self.matchingStatus
            }, interest: { _, _, _, notification in
                self.interests += 1; notification = self.notification; return self.interestStatus
            })
        }
    }

    private func collector(_ fake: FakeRegistry, recordLimit: Int = 512) throws -> IdentityLifetimeCollector {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("panelctl-observer-tests-\(UUID())")
        return IdentityLifetimeCollector(recording: try IdentityObservationRecording(root: root, recordLimit: recordLimit),
                                         registry: fake.api)
    }

    private func assertCannotArm(_ collector: IdentityLifetimeCollector, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try collector.arm { XCTFail("unexpected READY", file: file, line: line) }, file: file, line: line)
        XCTAssertFalse(collector.recording.ready, file: file, line: line)
    }

    func testInitialDrainExhaustsBeforeCountAndDeduplicatesOnlyInterest() throws {
        let fake = FakeRegistry(); fake.entries = [10, 10]
        let collector = try collector(fake)
        try collector.registerMatching(name: "fake", kind: kIOPublishNotification)
        XCTAssertEqual(fake.calls, ["register", "next", "next", "next", "valid"])
        XCTAssertEqual(collector.initialDrains, 1)
        XCTAssertEqual(fake.reads, 2) // Both observations retained; not identity qualification.
        XCTAssertEqual(fake.interests, 1); XCTAssertEqual(fake.retains, 1)
        XCTAssertEqual(fake.released, [10, 10])
        collector.stop(); collector.stop()
        XCTAssertEqual(fake.released, [10, 10, 2000, 10, 1000])
    }

    func testInvalidIteratorCannotArmOrResetAndReleasesPartialInventory() throws {
        let fake = FakeRegistry(); fake.entries = [10]; fake.valid = false
        let collector = try collector(fake)
        XCTAssertThrowsError(try collector.registerMatching(name: "fake", kind: kIOPublishNotification))
        XCTAssertEqual(collector.initialDrains, 0)
        XCTAssertTrue(collector.recording.failure!.contains("invalid iterator"))
        assertCannotArm(collector)
        collector.stop()
        XCTAssertEqual(fake.nextCalls, 2)
        XCTAssertEqual(fake.released, [10, 2000, 10, 1000])
    }

    func testIteratorBoundIncludesProbeAndReleasesOverflowObject() throws {
        for count in [0, 32, 33] {
            let fake = FakeRegistry(); fake.entries = Array(1...UInt32(max(1, count))).prefix(count).map { $0 }
            let collector = try collector(fake)
            if count <= 32 {
                try collector.registerMatching(name: "fake", kind: kIOTerminatedNotification)
                XCTAssertEqual(collector.initialDrains, 1)
                XCTAssertNil(collector.recording.failure)
            } else {
                XCTAssertThrowsError(try collector.registerMatching(name: "fake", kind: kIOTerminatedNotification))
                XCTAssertEqual(collector.initialDrains, 0)
                XCTAssertTrue(collector.recording.failure!.contains("overflow"))
                assertCannotArm(collector)
            }
            XCTAssertEqual(fake.nextCalls, min(count + 1, 33))
            XCTAssertEqual(fake.reads, min(count, 32))
            XCTAssertEqual(fake.released.count, count)
            collector.stop()
            XCTAssertEqual(fake.released.last, 1000)
        }
    }

    func testMatchingFailureOrNullIteratorNeverDrainAndStillReleaseHandles() throws {
        for (status, iterator): (Int32, UInt32) in [(KERN_FAILURE, 1000), (KERN_FAILURE, 0), (0, 0)] {
            let fake = FakeRegistry(); fake.matchingStatus = status; fake.iterator = iterator
            let collector = try collector(fake)
            XCTAssertThrowsError(try collector.registerMatching(name: "fake", kind: kIOPublishNotification))
            XCTAssertNotNil(collector.recording.failure)
            XCTAssertEqual(fake.nextCalls, 0)
            assertCannotArm(collector)
            collector.stop(); collector.stop()
            XCTAssertEqual(fake.released, iterator == 0 ? [] : [iterator])
        }
    }

    func testPartialRegistrationFailureCleansEarlierIteratorsAndCGContext() throws {
        let fake = FakeRegistry()
        let collector = try collector(fake)
        try collector.registerMatching(name: "first", kind: kIOPublishNotification)
        fake.iterator = 1001; fake.matchingStatus = KERN_FAILURE
        var removals = 0
        collector.cgReference = Unmanaged.passRetained(collector.cg).toOpaque()
        collector.removeCG = { _ in removals += 1; return .success }
        XCTAssertThrowsError(try collector.registerMatching(name: "second", kind: kIOTerminatedNotification))
        collector.stop(); collector.stop()
        XCTAssertEqual(Set(fake.released), [1000, 1001]); XCTAssertEqual(fake.released.count, 2)
        XCTAssertEqual(removals, 1)
        XCTAssertTrue(collector.iterators.isEmpty); XCTAssertTrue(collector.services.isEmpty)
        XCTAssertThrowsError(try collector.start()) // Restart refuses before any native API.
    }

    func testInterestAndRetainFailuresReleaseExactlyOwnedHandles() throws {
        for (status, notification, retain): (Int32, UInt32, Int32) in [
            (KERN_FAILURE, 2000, 0), (0, 0, 0), (0, 2000, KERN_FAILURE)
        ] {
            let fake = FakeRegistry(); fake.entries = [10]; fake.interestStatus = status
            fake.notification = notification; fake.retainStatus = retain
            let collector = try collector(fake)
            XCTAssertThrowsError(try collector.registerMatching(name: "fake", kind: kIOPublishNotification))
            assertCannotArm(collector)
            XCTAssertTrue(collector.services.isEmpty)
            collector.stop()
            XCTAssertEqual(fake.released, notification == 0 ? [10, 1000] : [2000, 10, 1000])
        }
    }

    func testPropertyFailureAndOutputOverflowStopDrainWithoutMoreNativeWork() throws {
        for readFails in [true, false] {
            let fake = FakeRegistry(); fake.entries = [10, 11]; fake.readFails = readFails
            let collector = try collector(fake, recordLimit: readFails ? 512 : 1)
            XCTAssertThrowsError(try collector.registerMatching(name: "fake", kind: kIOPublishNotification))
            XCTAssertEqual(fake.nextCalls, 1); XCTAssertEqual(fake.interests, 0)
            assertCannotArm(collector)
            collector.stop()
            XCTAssertEqual(fake.released, [10, 1000])
        }
    }

    func testInterestRegistrationRecordOverflowReleasesNotificationBeforeRetain() throws {
        let fake = FakeRegistry(); fake.entries = [10, 11]
        // Registration and initial-service fit; interest-registration does not.
        let collector = try collector(fake, recordLimit: 2)
        XCTAssertThrowsError(try collector.registerMatching(name: "fake", kind: kIOPublishNotification))
        XCTAssertTrue(collector.recording.failure!.contains("overflow"))
        XCTAssertEqual(fake.interests, 1); XCTAssertEqual(fake.retains, 0)
        XCTAssertEqual(fake.nextCalls, 1)
        XCTAssertTrue(collector.services.isEmpty)
        XCTAssertEqual(fake.released, [2000, 10])
        assertCannotArm(collector)
        collector.stop(); collector.stop()
        XCTAssertEqual(fake.released, [2000, 10, 1000])
    }

    func testSixActualInitialDrainsArmAndLaterTerminationDoesNotRegisterInterest() throws {
        let fake = FakeRegistry()
        let collector = try collector(fake)
        for name in IdentityObservationInventory.classes {
            for kind in [kIOPublishNotification, kIOTerminatedNotification] {
                try collector.registerMatching(name: name, kind: kind)
                fake.iterator += 1
            }
        }
        XCTAssertEqual(collector.initialDrains, 6)
        var acknowledgments = 0
        try collector.arm { acknowledgments += 1 }
        XCTAssertEqual(acknowledgments, 1)
        XCTAssertTrue(collector.recording.ready)
        fake.entries = [10]
        IdentityLifetimeCollector.matching(Unmanaged.passUnretained(collector).toOpaque(), 1001)
        XCTAssertTrue(collector.inventoryNeeded)
        XCTAssertEqual(collector.initialDrains, 6)
        XCTAssertEqual(fake.interests, 0); XCTAssertEqual(fake.retains, 0)
        XCTAssertEqual(fake.released, [10])
        collector.stop(); collector.stop()
        XCTAssertEqual(Set(fake.released), Set([10] + Array(UInt32(1000)...1005)))
        XCTAssertEqual(fake.released.count, 7)
        try collector.recording.finish(deadlineReached: true)
        let summary = try JSONSerialization.jsonObject(with: Data(contentsOf:
            collector.recording.root.appendingPathComponent("summary.json"))) as! [String: Any]
        XCTAssertEqual(summary["complete"] as? Bool, true)
        // Only the collector mechanics are exercised, not a live passive run.
    }

    func testPostReadinessInterestFailureSurvivesCleanupAndTerminalSummary() throws {
        let fake = FakeRegistry()
        let collector = try collector(fake)
        for index in 0..<6 {
            fake.iterator = UInt32(1000 + index)
            try collector.registerMatching(name: "fake", kind: kIOPublishNotification)
        }
        try collector.arm {}
        fake.readFails = true
        IdentityLifetimeCollector.interest(Unmanaged.passUnretained(collector).toOpaque(), 10, 123, nil)
        let failure = try XCTUnwrap(collector.recording.failure)
        collector.stop()
        try collector.recording.finish(deadlineReached: true)
        let summary = try JSONSerialization.jsonObject(with: Data(contentsOf:
            collector.recording.root.appendingPathComponent("summary.json"))) as! [String: Any]
        XCTAssertEqual(summary["ready"] as? Bool, true)
        XCTAssertEqual(summary["complete"] as? Bool, false)
        XCTAssertEqual(summary["failure"] as? String, failure)
        XCTAssertEqual(fake.reads, 1)
        XCTAssertFalse(fake.released.contains(10)) // Callback service was borrowed.
        XCTAssertEqual(fake.released.count, 6)
    }

    func testRetainedInventoryBoundStopsBeforeInterestRegistration() throws {
        let fake = FakeRegistry(); fake.entries = [97]
        let collector = try collector(fake)
        collector.services = (1...96).map { (UInt32($0), UInt32($0 + 2000)) }
        XCTAssertThrowsError(try collector.registerMatching(name: "fake", kind: kIOPublishNotification))
        XCTAssertEqual(fake.interests, 0); XCTAssertEqual(fake.retains, 0)
        XCTAssertTrue(collector.recording.failure!.contains("retained service inventory overflow"))
        collector.stop()
        XCTAssertEqual(fake.released.count, 194) // 97th entry + 96 owned pairs + iterator.
    }

    func testInterestCallbackReadFailureDoesNotReleaseBorrowedService() throws {
        let fake = FakeRegistry(); fake.readFails = true
        let collector = try collector(fake)
        IdentityLifetimeCollector.interest(Unmanaged.passUnretained(collector).toOpaque(), 10, 123, nil)
        XCTAssertEqual(fake.reads, 1)
        XCTAssertTrue(collector.recording.failure!.contains("interest collection failure"))
        assertCannotArm(collector)
        collector.stop()
        XCTAssertTrue(fake.released.isEmpty)
    }

    func testLaterEventsAreNotCountedAsInitialAndUnknownIteratorFailsClosed() throws {
        let fake = FakeRegistry()
        let collector = try collector(fake)
        try collector.registerMatching(name: "fake", kind: kIOTerminatedNotification)
        fake.entries = [10]
        collector.drain(1000, initial: false)
        XCTAssertEqual(collector.initialDrains, 1); XCTAssertTrue(collector.inventoryNeeded)
        let text = try String(contentsOf: collector.recording.root.appendingPathComponent("events.jsonl"))
        XCTAssertTrue(text.contains("service-event")); XCTAssertFalse(text.contains("initial-service"))
        let before = fake.nextCalls
        collector.drain(9999, initial: false)
        XCTAssertEqual(fake.nextCalls, before)
        XCTAssertTrue(collector.recording.failure!.contains("unknown iterator"))
        assertCannotArm(collector)
    }
}
