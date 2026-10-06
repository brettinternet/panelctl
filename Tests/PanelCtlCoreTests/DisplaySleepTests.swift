import XCTest
@testable import PanelCtlCore

final class DisplaySleepTests: XCTestCase {
    func testAutomationSleepGateIssuesOnceUntilWakeAndUsesFakeSleepWriter() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("panelctl-sleep-gate-\(UUID().uuidString)", isDirectory: true)
        let marker = directory.appendingPathComponent("sleeping")
        defer { try? FileManager.default.removeItem(at: directory) }
        let firstHelper = AutomationSleepGate(markerURL: marker)
        let secondHelper = AutomationSleepGate(markerURL: marker)
        var writes = 0

        XCTAssertTrue(try firstHelper.sleepOnce { writes += 1 })
        XCTAssertFalse(try secondHelper.sleepOnce { writes += 1 })
        XCTAssertEqual(writes, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))

        secondHelper.wakeObserved()
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path), "a sibling cannot clear the active sleep owner's marker")
        firstHelper.wakeObserved()
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        XCTAssertTrue(try firstHelper.sleepOnce { writes += 1 })
        XCTAssertEqual(writes, 2)
    }

    func testExitedOwnerLeavesStaleMarkerThatDoesNotSuppressNextSleep() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("panelctl-sleep-gate-relaunch-\(UUID().uuidString)", isDirectory: true)
        let marker = directory.appendingPathComponent("sleeping")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data([1]).write(to: marker)

        var previousSession: AutomationSleepGate? = AutomationSleepGate(markerURL: marker)
        var writes = 0
        XCTAssertTrue(try previousSession?.sleepOnce { writes += 1 } ?? false)
        previousSession = nil
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path), "a terminated helper leaves only a stale marker")

        let relaunchedHelper = AutomationSleepGate(markerURL: marker)
        XCTAssertTrue(try relaunchedHelper.sleepOnce { writes += 1 })
        XCTAssertEqual(writes, 2, "the next valid Sleep deadline runs once after stale ownership is reaped")
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
        DisplaySleepController.automationScreensDidWake()
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path), "a non-owner wake observer cannot clear an active helper lease")
        relaunchedHelper.wakeObserved()
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    func testFailedAutomationSleepClearsItsMarkerForRetry() {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("panelctl-sleep-gate-failure-\(UUID().uuidString)", isDirectory: true)
        let marker = directory.appendingPathComponent("sleeping")
        defer { try? FileManager.default.removeItem(at: directory) }
        let gate = AutomationSleepGate(markerURL: marker)

        XCTAssertThrowsError(try gate.sleepOnce { throw TestSleepError.failed })
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        XCTAssertNoThrow(try gate.sleepOnce {})
    }

    private enum TestSleepError: Error {
        case failed
    }
}
