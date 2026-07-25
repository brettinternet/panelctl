import XCTest
import CoreGraphics
import Darwin
@testable import PanelCtlApp
@testable import PanelCtlCore

final class ProtectionPreferencesTests: XCTestCase {
    func testAllDisplaysEmitsAllAndRequiresSafetyLimit() throws {
        var preferences = ProtectionPreferences()
        preferences.allDisplays = true

        let expected = ["blackout", "--all", "--idle-after", "300", "--watch", "--sleep-after", "1800", "--caffeinate"]
        XCTAssertEqual(try preferences.commandArguments(for: displays), expected)

        preferences.followUpAction = .untilActivity
        XCTAssertThrowsError(try preferences.commandArguments(for: displays)) {
            XCTAssertEqual($0 as? ProtectionConfigurationError, .allDisplaysRequireLimit)
        }
    }

    func testManualUUIDSelectionEmitsStableDisplayArguments() throws {
        var preferences = ProtectionPreferences()
        preferences.selectedDisplayUUIDs = ["bbbb-uuid", "aaaa-uuid"]
        preferences.followUpAction = .restore

        XCTAssertEqual(
            try preferences.commandArguments(for: displays),
            ["blackout", "--display", "AAAA-UUID", "--display", "BBBB-UUID", "--idle-after", "300", "--watch", "--timeout", "1800", "--caffeinate"]
        )
    }

    func testManualSelectionCoveringAllDrawableDisplaysIsRejected() {
        var preferences = ProtectionPreferences()
        preferences.selectedDisplayUUIDs = Set(displays.compactMap(\.uuid))

        XCTAssertThrowsError(try preferences.commandArguments(for: displays)) {
            XCTAssertEqual($0 as? ProtectionConfigurationError, .selectionWouldCoverAllDisplays)
        }
    }

    func testMissingAndEmptySelectionsAreRejected() {
        var preferences = ProtectionPreferences()
        XCTAssertThrowsError(try preferences.commandArguments(for: displays)) {
            XCTAssertEqual($0 as? ProtectionConfigurationError, .noSelection)
        }

        preferences.selectedDisplayUUIDs = ["MISSING-UUID"]
        XCTAssertThrowsError(try preferences.commandArguments(for: displays)) {
            XCTAssertEqual($0 as? ProtectionConfigurationError, .selectedDisplayUnavailable("MISSING-"))
        }
    }

    func testDefaultConfigurationUsesFiveMinuteIdleSleepAndCaffeinate() throws {
        let defaults = ProtectionPreferences()
        XCTAssertEqual(defaults.idleSeconds, 5 * 60)
        XCTAssertEqual(defaults.followUpAction, .sleepDisplays)
        XCTAssertEqual(defaults.followUpSeconds, 30 * 60)
        XCTAssertTrue(defaults.caffeinate)

        var preferences = defaults
        preferences.selectedDisplayUUIDs = ["AAAA-UUID"]
        XCTAssertEqual(
            try preferences.commandArguments(for: displays),
            ["blackout", "--display", "AAAA-UUID", "--idle-after", "300", "--watch", "--sleep-after", "1800", "--caffeinate"]
        )
    }

    func testInvalidDurationsAreRejectedBeforeIntegerConversion() {
        let invalidIdle: [TimeInterval] = [0, -1, .nan, .infinity, 30 * 24 * 60 * 60 + 1]
        for duration in invalidIdle {
            var preferences = ProtectionPreferences()
            preferences.selectedDisplayUUIDs = ["AAAA-UUID"]
            preferences.idleSeconds = duration
            XCTAssertThrowsError(try preferences.commandArguments(for: displays), "idle \(duration)") {
                XCTAssertEqual($0 as? ProtectionConfigurationError, .invalidIdleDuration)
            }
        }

        let invalidFollowUp: [TimeInterval] = [0, -1, .nan, .infinity, 30 * 24 * 60 * 60 + 1]
        for duration in invalidFollowUp {
            var preferences = ProtectionPreferences()
            preferences.selectedDisplayUUIDs = ["AAAA-UUID"]
            preferences.followUpAction = .restore
            preferences.followUpSeconds = duration
            XCTAssertThrowsError(try preferences.commandArguments(for: displays), "follow-up \(duration)") {
                XCTAssertEqual($0 as? ProtectionConfigurationError, .invalidFollowUpDuration)
            }
        }
    }

    @MainActor
    func testLatestConfigurationWinsWhileWatcherIsStopping() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("panelctl-service-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let helper = directory.appendingPathComponent("fake-panelctl")
        let log = directory.appendingPathComponent("launches.log")
        let script = """
        #!/bin/bash
        printf '%s\\n' "$1" >> "$PANELCTL_TEST_LOG"
        trap 'exit 0' TERM
        while true; do /bin/sleep 0.05; done
        """
        try Data(script.utf8).write(to: helper)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: helper.path
        )
        setenv("PANELCTL_HELPER", helper.path, 1)
        setenv("PANELCTL_TEST_LOG", log.path, 1)
        defer {
            unsetenv("PANELCTL_HELPER")
            unsetenv("PANELCTL_TEST_LOG")
        }

        let service = ProtectionService()
        service.run(arguments: ["A"])
        _ = try await waitForLaunches(1, at: log)

        service.run(arguments: ["B"])
        service.run(arguments: ["A"])
        let afterConfigurationChange = try await waitForLaunches(2, at: log)
        XCTAssertEqual(afterConfigurationChange, ["A", "A"])

        service.disable()
        service.run(arguments: ["A"])
        let afterDisableAndEnable = try await waitForLaunches(3, at: log)
        XCTAssertEqual(afterDisableAndEnable, ["A", "A", "A"])

        let stopped = expectation(description: "watcher stopped")
        service.shutdown {
            stopped.fulfill()
        }
        await fulfillment(of: [stopped], timeout: 3)
        XCTAssertEqual(service.state, .disabled)
    }

    private func waitForLaunches(
        _ count: Int,
        at log: URL
    ) async throws -> [String] {
        for _ in 0..<100 {
            if let data = try? Data(contentsOf: log),
               let contents = String(data: data, encoding: .utf8) {
                let launches = contents.split(separator: "\n").map(String.init)
                if launches.count >= count {
                    return launches
                }
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("Timed out waiting for \(count) watcher launches")
        return []
    }

    private var displays: [DisplayRecord] {
        [
            display(index: 1, id: 101, uuid: "AAAA-UUID", width: 1920, height: 1080),
            display(index: 2, id: 202, uuid: "BBBB-UUID", width: 2560, height: 1440),
            display(index: 3, id: 303, uuid: "CCCC-UUID", width: 3840, height: 2160)
        ]
    }

    private func display(index: Int, id: UInt32, uuid: String?, width: Double, height: Double) -> DisplayRecord {
        DisplayRecord(
            index: index,
            id: id,
            uuid: uuid,
            name: nil,
            active: true,
            online: true,
            asleep: false,
            builtin: false,
            main: index == 1,
            vendor: 0,
            model: 0,
            serial: 0,
            bounds: DisplayBounds(CGRect(x: 0, y: 0, width: width, height: height)),
            pixelWidth: Int(width),
            pixelHeight: Int(height)
        )
    }
}
