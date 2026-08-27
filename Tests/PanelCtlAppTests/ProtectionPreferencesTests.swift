import XCTest
import CoreGraphics
import Darwin
@testable import PanelCtlApp
@testable import PanelCtlCore

final class ProtectionPreferencesTests: XCTestCase {
    func testSleepDisplayDefaultsEmitBoundedDisplayAssertion() throws {
        var preferences = ProtectionPreferences()
        preferences.selectedDisplayUUIDs = ["AAAA-UUID"]
        XCTAssertTrue(preferences.keepDisplaysAwake)
        let arguments = try preferences.commandArguments(for: displays)
        XCTAssertTrue(arguments.contains("--keep-displays-awake"))
        XCTAssertFalse(arguments.contains("--caffeinate"))

        preferences.followUpAction = .restore
        XCTAssertFalse(try preferences.commandArguments(for: displays).contains("--keep-displays-awake"))
    }

    func testLegacyCaffeinateDoesNotMigrateToSystemAssertion() throws {
        let data = Data(#"{"followUpAction":"sleepDisplays","caffeinate":true}"#.utf8)
        let preferences = try JSONDecoder().decode(ProtectionPreferences.self, from: data)
        XCTAssertTrue(preferences.keepDisplaysAwake)

        let restoreData = Data(#"{"followUpAction":"restore","caffeinate":true}"#.utf8)
        let restore = try JSONDecoder().decode(ProtectionPreferences.self, from: restoreData)
        XCTAssertTrue(restore.keepDisplaysAwake)
    }

    func testAllDisplaysEmitsAllAndRequiresSafetyLimit() throws {
        var preferences = ProtectionPreferences()
        preferences.allDisplays = true

        let expected = ["blackout", "--all", "--mode", "blocking", "--overlay-opacity", "100", "--idle-after", "300", "--watch", "--sleep-after", "1800", "--keep-displays-awake"]
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
            ["blackout", "--display", "AAAA-UUID", "--display", "BBBB-UUID", "--mode", "blocking", "--overlay-opacity", "100", "--idle-after", "300", "--watch", "--timeout", "1800"]
        )
    }

    func testManualSelectionCoveringAllDrawableDisplaysRequiresSafetyLimit() throws {
        var preferences = ProtectionPreferences()
        preferences.selectedDisplayUUIDs = Set(displays.compactMap(\.uuid))

        XCTAssertNoThrow(try preferences.commandArguments(for: displays))

        preferences.followUpAction = .untilActivity
        XCTAssertThrowsError(try preferences.commandArguments(for: displays)) {
            XCTAssertEqual($0 as? ProtectionConfigurationError, .selectionWouldCoverAllDisplays)
        }
    }

    func testSelectionRequiresAtLeastOneAvailableDisplay() throws {
        var preferences = ProtectionPreferences()
        XCTAssertThrowsError(try preferences.commandArguments(for: displays)) {
            XCTAssertEqual($0 as? ProtectionConfigurationError, .noSelection)
        }

        preferences.selectedDisplayUUIDs = ["MISSING-UUID"]
        XCTAssertThrowsError(try preferences.commandArguments(for: displays)) {
            XCTAssertEqual($0 as? ProtectionConfigurationError, .selectedDisplayUnavailable("MISSING-"))
        }

        preferences.selectedDisplayUUIDs = ["AAAA-UUID", "MISSING-UUID"]
        XCTAssertEqual(
            try preferences.commandArguments(for: displays),
            ["blackout", "--display", "AAAA-UUID", "--mode", "blocking", "--overlay-opacity", "100", "--idle-after", "300", "--watch", "--sleep-after", "1800", "--keep-displays-awake"]
        )
    }

    func testDefaultConfigurationUsesFiveMinuteIdleSleepAndBoundedDisplayAssertion() throws {
        let defaults = ProtectionPreferences()
        XCTAssertEqual(defaults.idleSeconds, 5 * 60)
        XCTAssertEqual(defaults.followUpAction, .sleepDisplays)
        XCTAssertEqual(defaults.followUpSeconds, 30 * 60)
        XCTAssertTrue(defaults.keepDisplaysAwake)
        XCTAssertFalse(defaults.hardwareDimmingEnabled)
        XCTAssertFalse(defaults.keepBlackoutOnInput)
        XCTAssertTrue(defaults.deferBlackoutDuringPlayback)
        XCTAssertFalse(defaults.deferBlackoutWhileCameraInUse)

        var preferences = defaults
        preferences.selectedDisplayUUIDs = ["AAAA-UUID"]
        XCTAssertEqual(
            try preferences.commandArguments(for: displays),
            ["blackout", "--display", "AAAA-UUID", "--mode", "blocking", "--overlay-opacity", "100", "--idle-after", "300", "--watch", "--sleep-after", "1800", "--keep-displays-awake"]
        )
    }

    func testWorkingDimmingEmitsCanonicalFlags() throws {
        var preferences = ProtectionPreferences()
        preferences.selectedDisplayUUIDs = ["AAAA-UUID"]
        preferences.mode = .working

        XCTAssertEqual(
            try preferences.commandArguments(for: displays),
            ["blackout", "--display", "AAAA-UUID", "--mode", "working", "--overlay-opacity", "60", "--idle-after", "300", "--watch", "--sleep-after", "1800", "--keep-displays-awake"]
        )

        preferences.workingOverlayEnabled = false
        preferences.hardwareDimmingEnabled = true
        preferences.hardwareBrightnessPercent = 25
        XCTAssertEqual(
            try preferences.commandArguments(for: displays),
            ["blackout", "--display", "AAAA-UUID", "--mode", "working", "--no-overlay", "--idle-after", "300", "--watch", "--sleep-after", "1800", "--keep-displays-awake", "--dim-to", "25"]
        )
    }

    func testEmptyDisplayBlackoutPreferenceDefaultsAndArgumentOrder() throws {
        let legacy = try JSONDecoder().decode(
            ProtectionPreferences.self,
            from: Data(#"{"isEnabled":true}"#.utf8)
        )
        XCTAssertFalse(legacy.blackoutEmptyDisplays)

        var preferences = ProtectionPreferences()
        preferences.selectedDisplayUUIDs = ["AAAA-UUID"]
        preferences.blackoutEmptyDisplays = true
        preferences.hardwareDimmingEnabled = true
        XCTAssertEqual(
            try preferences.commandArguments(for: displays),
            [
                "blackout", "--display", "AAAA-UUID", "--mode", "blocking",
                "--overlay-opacity", "100", "--idle-after", "300", "--watch",
                "--blackout-empty-displays", "--sleep-after", "1800",
                "--keep-displays-awake", "--dim-to", "25"
            ]
        )
    }

    func testPersistentBlackoutEmitsFlagAndRejectsDimming() throws {
        var preferences = ProtectionPreferences()
        preferences.selectedDisplayUUIDs = ["AAAA-UUID"]
        preferences.keepBlackoutOnInput = true

        XCTAssertEqual(
            try preferences.commandArguments(for: displays),
            ["blackout", "--display", "AAAA-UUID", "--mode", "blocking", "--overlay-opacity", "100", "--idle-after", "300", "--watch", "--sleep-after", "1800", "--keep-displays-awake", "--keep-blackout-on-input"]
        )

        preferences.hardwareDimmingEnabled = true
        XCTAssertThrowsError(try preferences.commandArguments(for: displays)) {
            XCTAssertEqual($0 as? ProtectionConfigurationError, .persistentDimming)
        }

        preferences.mode = .working
        XCTAssertNoThrow(try preferences.commandArguments(for: displays))
    }

    func testPlaybackDeferralOptOutEmitsIgnoreFlag() throws {
        var preferences = ProtectionPreferences()
        preferences.selectedDisplayUUIDs = ["AAAA-UUID"]
        preferences.deferBlackoutDuringPlayback = false

        XCTAssertEqual(
            try preferences.commandArguments(for: displays).last,
            "--ignore-playback"
        )
    }

    func testCameraDeferralOptInEmitsFlag() throws {
        var preferences = ProtectionPreferences()
        preferences.selectedDisplayUUIDs = ["AAAA-UUID"]
        preferences.deferBlackoutWhileCameraInUse = true

        XCTAssertEqual(
            try preferences.commandArguments(for: displays).last,
            "--defer-camera"
        )
    }

    func testLegacyPreferencesDefaultDimmingOff() throws {
        let legacy = Data(#"{"isEnabled":true,"idleSeconds":120,"followUpAction":"restore","followUpSeconds":15,"caffeinate":false,"allDisplays":false,"selectedDisplayUUIDs":["AAAA-UUID"],"didChooseDisplays":true}"#.utf8)

        let preferences = try JSONDecoder().decode(
            ProtectionPreferences.self,
            from: legacy
        )

        XCTAssertTrue(preferences.isEnabled)
        XCTAssertEqual(preferences.idleSeconds, 120)
        XCTAssertEqual(preferences.followUpAction, .restore)
        XCTAssertEqual(preferences.followUpSeconds, 15)
        XCTAssertEqual(preferences.selectedDisplayUUIDs, ["AAAA-UUID"])
        XCTAssertTrue(preferences.didChooseDisplays)
        XCTAssertEqual(preferences.mode, .blocking)
        XCTAssertTrue(preferences.workingOverlayEnabled)
        XCTAssertEqual(preferences.workingOverlayOpacityPercent, 60)
        XCTAssertFalse(preferences.hardwareDimmingEnabled)
        XCTAssertEqual(preferences.hardwareBrightnessPercent, 25)
        XCTAssertFalse(preferences.keepBlackoutOnInput)
        XCTAssertTrue(preferences.deferBlackoutDuringPlayback)
        XCTAssertFalse(preferences.deferBlackoutWhileCameraInUse)
    }

    func testLegacyHardwareDimmingMigrationAndNewKeyPrecedence() throws {
        let enabledLegacy = try JSONDecoder().decode(
            ProtectionPreferences.self,
            from: Data(#"{"dimDisplaysDuringBlackout":true}"#.utf8)
        )
        XCTAssertTrue(enabledLegacy.hardwareDimmingEnabled)
        XCTAssertEqual(enabledLegacy.hardwareBrightnessPercent, 0)

        let disabledLegacy = try JSONDecoder().decode(
            ProtectionPreferences.self,
            from: Data(#"{"dimDisplaysDuringBlackout":false}"#.utf8)
        )
        XCTAssertFalse(disabledLegacy.hardwareDimmingEnabled)
        XCTAssertEqual(disabledLegacy.hardwareBrightnessPercent, 25)

        let newKeysWin = try JSONDecoder().decode(
            ProtectionPreferences.self,
            from: Data(#"{"dimDisplaysDuringBlackout":true,"hardwareDimmingEnabled":false,"hardwareBrightnessPercent":25}"#.utf8)
        )
        XCTAssertFalse(newKeysWin.hardwareDimmingEnabled)
        XCTAssertEqual(newKeysWin.hardwareBrightnessPercent, 25)
    }

    func testEncodingWritesCurrentKeysAndOmitsLegacyDimmingKey() throws {
        var preferences = ProtectionPreferences()
        preferences.mode = .working
        preferences.workingOverlayEnabled = false
        preferences.workingOverlayOpacityPercent = 42
        preferences.hardwareDimmingEnabled = true
        preferences.hardwareBrightnessPercent = 0

        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(
                with: JSONEncoder().encode(preferences)
            ) as? [String: Any]
        )
        XCTAssertEqual(object["mode"] as? String, "working")
        XCTAssertEqual(object["workingOverlayEnabled"] as? Bool, false)
        XCTAssertEqual(object["workingOverlayOpacityPercent"] as? Int, 42)
        XCTAssertEqual(object["hardwareDimmingEnabled"] as? Bool, true)
        XCTAssertEqual(object["hardwareBrightnessPercent"] as? Int, 0)
        XCTAssertNil(object["dimDisplaysDuringBlackout"])
    }

    func testStoredPercentageBoundariesAndErrors() throws {
        var preferences = ProtectionPreferences()
        preferences.selectedDisplayUUIDs = ["AAAA-UUID"]

        for value in [1, 100] {
            preferences.workingOverlayOpacityPercent = value
            XCTAssertNoThrow(try preferences.commandArguments(for: displays))
        }
        for value in [0, 101, -1] {
            preferences.workingOverlayOpacityPercent = value
            XCTAssertThrowsError(try preferences.commandArguments(for: displays)) {
                XCTAssertEqual($0 as? ProtectionConfigurationError, .invalidOverlayOpacityPercent)
            }
        }

        preferences.workingOverlayOpacityPercent = 60
        for value in [0, 100] {
            preferences.hardwareBrightnessPercent = value
            XCTAssertNoThrow(try preferences.commandArguments(for: displays))
        }
        for value in [-1, 101] {
            preferences.hardwareBrightnessPercent = value
            XCTAssertThrowsError(try preferences.commandArguments(for: displays)) {
                XCTAssertEqual($0 as? ProtectionConfigurationError, .invalidHardwareBrightnessPercent)
            }
        }
    }

    func testInvalidDurationsAreRejectedBeforeIntegerConversion() {
        let invalidIdle: [TimeInterval] = [
            0, -1, 0.5, 1e-7, .nan, .infinity, 30 * 24 * 60 * 60 + 1
        ]
        for duration in invalidIdle {
            var preferences = ProtectionPreferences()
            preferences.selectedDisplayUUIDs = ["AAAA-UUID"]
            preferences.idleSeconds = duration
            XCTAssertThrowsError(try preferences.commandArguments(for: displays), "idle \(duration)") {
                XCTAssertEqual($0 as? ProtectionConfigurationError, .invalidIdleDuration)
            }
        }

        let invalidFollowUp: [TimeInterval] = [
            0, -1, 0.5, 1e-7, .nan, .infinity, 30 * 24 * 60 * 60 + 1
        ]
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
    func testFirstRunDoesNotInferAllDisplayPermission() throws {
        let suiteName = "panelctl-first-run-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let onlyDisplay = try XCTUnwrap(displays.first)
        let model = AppModel(
            defaults: defaults,
            displayProvider: { [onlyDisplay] }
        )

        XCTAssertFalse(model.preferences.allDisplays)
        XCTAssertEqual(model.preferences.selectedDisplayUUIDs, ["AAAA-UUID"])
        XCTAssertEqual(
            try model.preferences.commandArguments(for: [onlyDisplay]),
            ["blackout", "--display", "AAAA-UUID", "--mode", "blocking", "--overlay-opacity", "100", "--idle-after", "300", "--watch", "--sleep-after", "1800", "--keep-displays-awake"]
        )
    }

    @MainActor
    func testMenuBarIconPreferenceDefaultsVisibleAndIsStoredSeparately() throws {
        let suiteName = "panelctl-menu-bar-icon-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let model = AppModel(defaults: defaults, displayProvider: { [] })
        XCTAssertTrue(model.showMenuBarIcon)
        XCTAssertEqual(defaults.object(forKey: "showMenuBarIcon") as? Bool, true)
        let protectionData = defaults.data(forKey: "blackoutPreferences")

        model.setShowMenuBarIcon(false)

        XCTAssertFalse(model.showMenuBarIcon)
        XCTAssertEqual(defaults.data(forKey: "blackoutPreferences"), protectionData)
        XCTAssertEqual(defaults.object(forKey: "showMenuBarIcon") as? Bool, false)
    }

    @MainActor
    func testBlackoutNowEnablesAndControlsTheExistingWatcher() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "panelctl-immediate-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let helper = directory.appendingPathComponent("fake-panelctl")
        let log = directory.appendingPathComponent("control.log")
        let script = """
        #!/bin/bash
        printf 'launch:%s\\n' "$*" >> "$PANELCTL_TEST_LOG"
        printf '{"state":"waiting","blackedOutDisplayIDs":[]}\\n'
        trap 'exit 0' TERM
        while IFS= read -r command; do
            printf 'command:%s\\n' "$command" >> "$PANELCTL_TEST_LOG"
        done
        """
        try Data(script.utf8).write(to: helper)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: helper.path
        )

        let suiteName = "panelctl-immediate-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var preferences = ProtectionPreferences()
        preferences.didChooseDisplays = true
        preferences.selectedDisplayUUIDs = ["AAAA-UUID"]
        preferences.idleSeconds = 120
        preferences.followUpAction = .restore
        preferences.followUpSeconds = 15
        defaults.set(
            try JSONEncoder().encode(preferences),
            forKey: "blackoutPreferences"
        )

        setenv("PANELCTL_HELPER", helper.path, 1)
        setenv("PANELCTL_TEST_LOG", log.path, 1)
        defer {
            unsetenv("PANELCTL_HELPER")
            unsetenv("PANELCTL_TEST_LOG")
        }

        let model = AppModel(
            defaults: defaults,
            displayProvider: { [self.displays[0], self.displays[1]] }
        )
        XCTAssertFalse(try model.restoreBlackout())

        try model.blackoutNow()
        XCTAssertTrue(model.preferences.isEnabled)
        var lines = try await waitForLogLines(2, at: log)
        XCTAssertEqual(
            lines,
            [
                "launch:blackout --display AAAA-UUID --mode blocking --overlay-opacity 100 --idle-after 120 --watch --timeout 15",
                "command:blackout-now"
            ]
        )

        XCTAssertTrue(try model.restoreBlackout())
        lines = try await waitForLogLines(3, at: log)
        XCTAssertEqual(lines.last, "command:restore")
        XCTAssertEqual(lines.filter { $0.hasPrefix("launch:") }.count, 1)

        let stopped = expectation(description: "watcher stopped")
        model.shutdown { stopped.fulfill() }
        await fulfillment(of: [stopped], timeout: 3)
    }

    @MainActor
    func testDeferredActivityStatusPropagatesFromHelper() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("panelctl-playback-status-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let helper = directory.appendingPathComponent("fake-panelctl")
        let script = """
        #!/bin/bash
        printf '{"state":"waiting_for_playback","blackedOutDisplayIDs":[]}\n'
        trap 'exit 0' TERM
        while true; do /bin/sleep 0.02; done
        """
        try Data(script.utf8).write(to: helper)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)
        setenv("PANELCTL_HELPER", helper.path, 1)
        defer { unsetenv("PANELCTL_HELPER") }

        let service = ProtectionService()
        service.run(arguments: ["blackout"])
        try await waitUntil { service.state == .waitingForPlayback }
        XCTAssertEqual(
            service.state.label,
            "Active media or camera detected — blackout paused"
        )

        let stopped = expectation(description: "watcher stopped")
        service.shutdown { stopped.fulfill() }
        await fulfillment(of: [stopped], timeout: 3)
    }

    @MainActor
    func testBlackoutNowRejectsInvalidSettingsWithoutEnabling() throws {
        let suiteName = "panelctl-immediate-invalid-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var preferences = ProtectionPreferences()
        preferences.didChooseDisplays = true
        defaults.set(
            try JSONEncoder().encode(preferences),
            forKey: "blackoutPreferences"
        )
        let model = AppModel(defaults: defaults, displayProvider: { self.displays })

        XCTAssertThrowsError(try model.blackoutNow()) {
            XCTAssertEqual(
                $0 as? ProtectionConfigurationError,
                .noSelection
            )
        }
        XCTAssertFalse(model.preferences.isEnabled)
    }

    @MainActor
    func testControlCommandIsQueuedAcrossWatcherRestart() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "panelctl-control-restart-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let helper = directory.appendingPathComponent("fake-panelctl")
        let log = directory.appendingPathComponent("control.log")
        let script = """
        #!/bin/bash
        printf 'launch:%s\\n' "$1" >> "$PANELCTL_TEST_LOG"
        printf '{"state":"waiting","blackedOutDisplayIDs":[]}\\n'
        trap 'exit 0' TERM
        while IFS= read -r command; do
            printf 'command:%s\\n' "$command" >> "$PANELCTL_TEST_LOG"
        done
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

        var displaysAreAsleep = false
        let service = ProtectionService(
            displaysAreAsleep: { displaysAreAsleep }
        )
        service.run(arguments: ["A"])
        try await waitUntil { service.state == .waiting }
        XCTAssertFalse(try service.sendControl(.restore))
        try await Task.sleep(nanoseconds: 50_000_000)
        let initialLines = try await waitForLogLines(1, at: log)
        XCTAssertEqual(initialLines, ["launch:A"])
        displaysAreAsleep = true
        XCTAssertTrue(try service.sendControl(.restore))
        _ = try await waitForLogLines(2, at: log)
        service.run(arguments: ["B"])
        try service.sendControl(.blackoutNow)

        let lines = try await waitForLogLines(4, at: log)
        XCTAssertEqual(lines, [
            "launch:A",
            "command:restore",
            "launch:B",
            "command:blackout-now"
        ])

        let stopped = expectation(description: "watcher stopped")
        service.shutdown { stopped.fulfill() }
        await fulfillment(of: [stopped], timeout: 3)
    }

    @MainActor
    func testLatestControlCommandWinsAcrossWatcherRestart() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "panelctl-control-latest-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let helper = directory.appendingPathComponent("fake-panelctl")
        let log = directory.appendingPathComponent("control.log")
        let script = """
        #!/bin/bash
        printf 'launch:%s\\n' "$1" >> "$PANELCTL_TEST_LOG"
        printf '{"state":"waiting","blackedOutDisplayIDs":[]}\\n'
        trap 'exit 0' TERM
        while IFS= read -r command; do
            printf 'command:%s\\n' "$command" >> "$PANELCTL_TEST_LOG"
        done
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
        _ = try await waitForLogLines(1, at: log)
        try service.sendControl(.blackoutNow)
        _ = try await waitForLogLines(2, at: log)

        service.run(arguments: ["B"])
        try service.sendControl(.restore)

        let lines = try await waitForLogLines(4, at: log)
        XCTAssertEqual(lines, [
            "launch:A",
            "command:blackout-now",
            "launch:B",
            "command:restore"
        ])

        let stopped = expectation(description: "watcher stopped")
        service.shutdown { stopped.fulfill() }
        await fulfillment(of: [stopped], timeout: 3)
    }

    @MainActor
    func testAcknowledgedControlIntentSurvivesWatcherRestart() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "panelctl-control-intent-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let helper = directory.appendingPathComponent("fake-panelctl")
        let log = directory.appendingPathComponent("control.log")
        let script = """
        #!/bin/bash
        printf 'launch:%s\\n' "$1" >> "$PANELCTL_TEST_LOG"
        printf '{"state":"waiting","blackedOutDisplayIDs":[]}\\n'
        if [[ "$1" == "D" ]]; then
            printf '{"state":"sleeping","blackedOutDisplayIDs":[]}\\n'
        fi
        restore_attempt=0
        trap 'if [[ "$1" == "C" ]]; then printf "{\\"state\\":\\"blacked_out\\",\\"blackedOutDisplayIDs\\":[7]}\\n"; elif [[ "$1" == "E" ]]; then printf "{\\"state\\":\\"blacked_out\\",\\"blackedOutDisplayIDs\\":[7]}\\n{\\"state\\":\\"waiting\\",\\"blackedOutDisplayIDs\\":[]}\\n"; fi; exit 0' TERM
        while IFS= read -r command; do
            printf 'command:%s\\n' "$command" >> "$PANELCTL_TEST_LOG"
            if [[ "$command" == "blackout-now" && "$1" != "E" ]]; then
                printf '{"state":"blacked_out","blackedOutDisplayIDs":[7]}\\n'
            elif [[ "$1" == "D" && "$restore_attempt" == 0 ]]; then
                restore_attempt=1
                printf '{"state":"sleeping","blackedOutDisplayIDs":[]}\\n'
            else
                printf '{"state":"waiting","blackedOutDisplayIDs":[]}\\n'
            fi
        done
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
        try await waitUntil { service.state == .waiting }
        try service.sendControl(.blackoutNow)
        try await waitUntil { service.state == .blackedOut }

        service.run(arguments: ["B"])
        _ = try await waitForLogLines(4, at: log)
        try await waitUntil { service.state == .blackedOut }
        try service.sendControl(.restore)
        try await waitUntil { service.state == .waiting }

        service.run(arguments: ["C"])
        _ = try await waitForLogLines(7, at: log)
        try await Task.sleep(nanoseconds: 50_000_000)
        service.run(arguments: ["D"])
        try await Task.sleep(nanoseconds: 100_000_000)
        let lines = try await waitForLogLines(8, at: log)
        XCTAssertEqual(lines, [
            "launch:A",
            "command:blackout-now",
            "launch:B",
            "command:blackout-now",
            "command:restore",
            "launch:C",
            "command:restore",
            "launch:D"
        ])
        try await waitUntil { service.state == .sleeping }
        try service.sendControl(.restore)
        _ = try await waitForLogLines(9, at: log)
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(service.state, .sleeping)
        try service.sendControl(.restore)
        let retryLines = try await waitForLogLines(10, at: log)
        XCTAssertEqual(Array(retryLines.suffix(2)), [
            "command:restore",
            "command:restore"
        ])
        try await waitUntil { service.state == .waiting }

        let firstStopped = expectation(description: "first watcher stopped")
        service.shutdown { firstStopped.fulfill() }
        await fulfillment(of: [firstStopped], timeout: 3)

        let lateStatusService = ProtectionService()
        lateStatusService.run(arguments: ["E"])
        try await waitUntil { lateStatusService.state == .waiting }
        try lateStatusService.sendControl(.blackoutNow)
        _ = try await waitForLogLines(12, at: log)
        lateStatusService.run(arguments: ["F"])
        try await Task.sleep(nanoseconds: 100_000_000)
        let lateStatusLines = try await waitForLogLines(13, at: log)
        XCTAssertEqual(Array(lateStatusLines.suffix(3)), [
            "launch:E",
            "command:blackout-now",
            "launch:F"
        ])

        let secondStopped = expectation(description: "second watcher stopped")
        lateStatusService.shutdown { secondStopped.fulfill() }
        await fulfillment(of: [secondStopped], timeout: 3)
    }

    @MainActor
    func testBlackoutCommandSurvivesCleanExitWhileWatcherStarts() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "panelctl-control-exited-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let helper = directory.appendingPathComponent("fake-panelctl")
        let log = directory.appendingPathComponent("control.log")
        let marker = directory.appendingPathComponent("first-launch")
        let allowExit = directory.appendingPathComponent("allow-exit")
        let script = """
        #!/bin/bash
        printf 'launch:%s\\n' "$1" >> "$PANELCTL_TEST_LOG"
        if [[ ! -e "$PANELCTL_TEST_MARKER" ]]; then
            touch "$PANELCTL_TEST_MARKER"
            while [[ ! -e "$PANELCTL_TEST_ALLOW_EXIT" ]]; do
                /bin/sleep 0.01
            done
            exit 0
        fi
        printf '{"state":"waiting","blackedOutDisplayIDs":[]}\\n'
        trap 'exit 0' TERM
        while IFS= read -r command; do
            printf 'command:%s\\n' "$command" >> "$PANELCTL_TEST_LOG"
        done
        """
        try Data(script.utf8).write(to: helper)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: helper.path
        )
        setenv("PANELCTL_HELPER", helper.path, 1)
        setenv("PANELCTL_TEST_LOG", log.path, 1)
        setenv("PANELCTL_TEST_MARKER", marker.path, 1)
        setenv("PANELCTL_TEST_ALLOW_EXIT", allowExit.path, 1)
        defer {
            unsetenv("PANELCTL_HELPER")
            unsetenv("PANELCTL_TEST_LOG")
            unsetenv("PANELCTL_TEST_MARKER")
            unsetenv("PANELCTL_TEST_ALLOW_EXIT")
        }

        let service = ProtectionService()
        service.run(arguments: ["A"])
        _ = try await waitForLogLines(1, at: log)

        service.run(arguments: ["A"])
        try service.sendControl(.blackoutNow)
        try Data().write(to: allowExit)

        let lines = try await waitForLogLines(3, at: log)
        XCTAssertEqual(lines, [
            "launch:A",
            "launch:A",
            "command:blackout-now"
        ])

        let stopped = expectation(description: "watcher stopped")
        service.shutdown { stopped.fulfill() }
        await fulfillment(of: [stopped], timeout: 3)
    }

    @MainActor
    func testControlRecoveryStopsAfterOneCleanExitRetry() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "panelctl-control-retry-limit-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let helper = directory.appendingPathComponent("fake-panelctl")
        let log = directory.appendingPathComponent("control.log")
        let marker = directory.appendingPathComponent("first-launch")
        let allowExit = directory.appendingPathComponent("allow-exit")
        let script = """
        #!/bin/bash
        printf 'launch:%s\\n' "$1" >> "$PANELCTL_TEST_LOG"
        if [[ ! -e "$PANELCTL_TEST_MARKER" ]]; then
            touch "$PANELCTL_TEST_MARKER"
            while [[ ! -e "$PANELCTL_TEST_ALLOW_EXIT" ]]; do
                /bin/sleep 0.01
            done
            exit 0
        fi
        printf '{"state":"waiting","blackedOutDisplayIDs":[7]}\\n'
        IFS= read -r command
        printf 'command:%s\\n' "$command" >> "$PANELCTL_TEST_LOG"
        exit 0
        """
        try Data(script.utf8).write(to: helper)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: helper.path
        )
        setenv("PANELCTL_HELPER", helper.path, 1)
        setenv("PANELCTL_TEST_LOG", log.path, 1)
        setenv("PANELCTL_TEST_MARKER", marker.path, 1)
        setenv("PANELCTL_TEST_ALLOW_EXIT", allowExit.path, 1)
        defer {
            unsetenv("PANELCTL_HELPER")
            unsetenv("PANELCTL_TEST_LOG")
            unsetenv("PANELCTL_TEST_MARKER")
            unsetenv("PANELCTL_TEST_ALLOW_EXIT")
        }

        let service = ProtectionService()
        service.run(arguments: ["A"])
        _ = try await waitForLogLines(1, at: log)
        service.run(arguments: ["A"])
        try service.sendControl(.blackoutNow)
        try Data().write(to: allowExit)

        try await waitUntil {
            if case .failed = service.state { return true }
            return false
        }
        let lines = try await waitForLogLines(3, at: log)
        XCTAssertEqual(
            lines,
            ["launch:A", "launch:A", "command:blackout-now"]
        )
        XCTAssertFalse(service.hasManagedProcess)
        XCTAssertTrue(service.blackedOutDisplayIDs.isEmpty)
    }

    @MainActor
    func testStoppingIgnoresLateStatusFromOldWatcher() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("panelctl-late-status-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let helper = directory.appendingPathComponent("fake-panelctl")
        let script = """
        #!/bin/bash
        trap 'printf "{\\"state\\":\\"blacked_out\\",\\"blackedOutDisplayIDs\\":[7]}\\n"; /bin/sleep 0.1; exit 0' TERM
        printf '{"state":"waiting","blackedOutDisplayIDs":[]}\\n'
        while true; do /bin/sleep 0.02; done
        """
        try Data(script.utf8).write(to: helper)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: helper.path
        )
        setenv("PANELCTL_HELPER", helper.path, 1)
        defer { unsetenv("PANELCTL_HELPER") }

        let service = ProtectionService()
        var observed: [ProtectionRuntimeState] = []
        service.onStateChange = { observed.append($0) }
        var observedMembership: [Set<UInt32>] = []
        service.onMembershipChange = { observedMembership.append($0) }
        service.run(arguments: ["A"])
        try await waitUntil { service.state == .waiting }

        service.disable()
        try await waitUntil { service.state == .disabled }

        let stoppingIndex = try XCTUnwrap(observed.firstIndex(of: .stopping))
        XCTAssertFalse(observed[stoppingIndex...].contains(.blackedOut))
        XCTAssertFalse(observedMembership.contains([7]))
        XCTAssertTrue(service.blackedOutDisplayIDs.isEmpty)
    }

    @MainActor
    func testManagedWatcherReconfiguresForAvailableSelectedDisplays() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("panelctl-display-recovery-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let helper = directory.appendingPathComponent("fake-panelctl")
        let log = directory.appendingPathComponent("launches.log")
        let script = """
        #!/bin/bash
        printf 'launch:%s\\n' "$*" >> "$PANELCTL_TEST_LOG"
        if [[ "$*" == *"BBBB-UUID"* ]]; then
            printf '{"state":"waiting","blackedOutDisplayIDs":[202]}\\n'
        else
            printf '{"state":"waiting","blackedOutDisplayIDs":[]}\\n'
        fi
        trap 'exit 0' TERM
        while true; do /bin/sleep 0.02; done
        """
        try Data(script.utf8).write(to: helper)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: helper.path
        )

        let suiteName = "panelctl-display-recovery-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var preferences = ProtectionPreferences()
        preferences.isEnabled = true
        preferences.didChooseDisplays = true
        preferences.selectedDisplayUUIDs = ["AAAA-UUID", "BBBB-UUID"]
        defaults.set(try JSONEncoder().encode(preferences), forKey: "blackoutPreferences")

        var currentDisplays = displays
        setenv("PANELCTL_HELPER", helper.path, 1)
        setenv("PANELCTL_TEST_LOG", log.path, 1)
        defer {
            unsetenv("PANELCTL_HELPER")
            unsetenv("PANELCTL_TEST_LOG")
        }

        let model = AppModel(
            defaults: defaults,
            displayProvider: { currentDisplays }
        )
        try await waitUntil { model.runtimeState == .waiting }
        try await waitUntil { model.blackedOutDisplayIDs == [202] }
        let initialLaunches = try await waitForLaunches(1, at: log)
        XCTAssertEqual(initialLaunches, [
            "launch:blackout --display AAAA-UUID --display BBBB-UUID --mode blocking --overlay-opacity 100 --idle-after 300 --watch --sleep-after 1800 --keep-displays-awake"
        ])

        currentDisplays = [displays[0], displays[2]]
        model.refreshDisplays()
        XCTAssertTrue(model.blackedOutDisplayIDs.isEmpty)
        try await waitUntil { model.runtimeState == .waiting }
        let partialLaunches = try await waitForLaunches(2, at: log)
        XCTAssertEqual(partialLaunches, [
            "launch:blackout --display AAAA-UUID --display BBBB-UUID --mode blocking --overlay-opacity 100 --idle-after 300 --watch --sleep-after 1800 --keep-displays-awake",
            "launch:blackout --display AAAA-UUID --mode blocking --overlay-opacity 100 --idle-after 300 --watch --sleep-after 1800 --keep-displays-awake"
        ])

        currentDisplays = displays
        model.refreshDisplays()
        try await waitUntil { model.runtimeState == .waiting }
        try await waitUntil { model.blackedOutDisplayIDs == [202] }
        let recoveredLaunches = try await waitForLaunches(3, at: log)
        XCTAssertEqual(recoveredLaunches, [
            "launch:blackout --display AAAA-UUID --display BBBB-UUID --mode blocking --overlay-opacity 100 --idle-after 300 --watch --sleep-after 1800 --keep-displays-awake",
            "launch:blackout --display AAAA-UUID --mode blocking --overlay-opacity 100 --idle-after 300 --watch --sleep-after 1800 --keep-displays-awake",
            "launch:blackout --display AAAA-UUID --display BBBB-UUID --mode blocking --overlay-opacity 100 --idle-after 300 --watch --sleep-after 1800 --keep-displays-awake"
        ])

        currentDisplays = [displays[2]]
        model.refreshDisplays()
        XCTAssertTrue(model.blackedOutDisplayIDs.isEmpty)
        try await waitUntil {
            if case .waitingForDisplays = model.runtimeState {
                return true
            }
            return false
        }
        guard case .waitingForDisplays = model.runtimeState else {
            return XCTFail("Expected unavailable-display state, got \(model.runtimeState)")
        }

        let stopped = expectation(description: "watcher stopped")
        model.shutdown { stopped.fulfill() }
        await fulfillment(of: [stopped], timeout: 3)
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

    @MainActor
    func testWatcherFreshInputGateHasDistinctRuntimeState() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "panelctl-waiting-input-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let helper = directory.appendingPathComponent("fake-panelctl")
        let script = """
        #!/bin/bash
        printf '{"state":"waiting_for_input","blackedOutDisplayIDs":[]}\\n'
        trap 'exit 0' TERM
        while true; do /bin/sleep 0.02; done
        """
        try Data(script.utf8).write(to: helper)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: helper.path
        )
        setenv("PANELCTL_HELPER", helper.path, 1)
        defer { unsetenv("PANELCTL_HELPER") }

        let service = ProtectionService()
        service.run(arguments: ["blackout"])
        try await waitUntil { service.state == .waitingForInput }

        let stopped = expectation(description: "watcher stopped")
        service.shutdown { stopped.fulfill() }
        await fulfillment(of: [stopped], timeout: 3)
    }

    @MainActor
    func testSnoozePersistsAcrossRestartAndAutoResumesAtExpiry() throws {
        let suiteName = "panelctl-snooze-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var current = Date(timeIntervalSince1970: 1_800_000_000)

        let model = AppModel(
            defaults: defaults,
            displayProvider: { [] },
            now: { current }
        )
        model.snooze(for: 30 * 60)

        XCTAssertTrue(model.preferences.isEnabled)
        XCTAssertEqual(model.snoozedUntil, current.addingTimeInterval(30 * 60))
        XCTAssertEqual(model.runtimeState, .snoozed(current.addingTimeInterval(30 * 60)))
        XCTAssertEqual(model.nextAction, "resume")
        XCTAssertEqual(model.secondsRemaining, 30 * 60)
        XCTAssertFalse(try model.restoreBlackout())
        XCTAssertEqual(model.snoozedUntil, current.addingTimeInterval(30 * 60))

        let delegate = AppDelegate()
        delegate.model = model
        let menuTitles = delegate.makeMenu().items.map(\.title)
        XCTAssertTrue(menuTitles.contains("Disable Protection"))
        XCTAssertTrue(menuTitles.contains("Resume Protection"))

        let restarted = AppModel(
            defaults: defaults,
            displayProvider: { [] },
            now: { current }
        )
        XCTAssertEqual(restarted.runtimeState, .snoozed(current.addingTimeInterval(30 * 60)))

        current.addTimeInterval(30 * 60)
        restarted.refreshCountdown()

        XCTAssertNil(restarted.snoozedUntil)
        XCTAssertNil(defaults.object(forKey: "snoozedUntil"))
        guard case .waitingForDisplays = restarted.runtimeState else {
            return XCTFail("Expected protection to resume, got \(restarted.runtimeState)")
        }
    }

    @MainActor
    func testUntilTomorrowUsesNextLocalEightAM() throws {
        let suiteName = "panelctl-until-tomorrow-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "America/Denver"))
        let current = try XCTUnwrap(
            calendar.date(from: DateComponents(
                year: 2026,
                month: 7,
                day: 28,
                hour: 7,
                minute: 15
            ))
        )
        let expected = try XCTUnwrap(
            calendar.date(from: DateComponents(
                year: 2026,
                month: 7,
                day: 29,
                hour: 8
            ))
        )
        let model = AppModel(
            defaults: defaults,
            displayProvider: { [] },
            now: { current }
        )

        model.snoozeUntilTomorrow(calendar: calendar)

        XCTAssertEqual(model.snoozedUntil, expected)
        XCTAssertTrue(model.statusSummary.contains("Protection snoozed until"))
    }

    @MainActor
    func testSleepNowPreservesProtectionStateAndCancelsSnooze() throws {
        let suiteName = "panelctl-sleep-now-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var sleepRequests = 0
        let model = AppModel(
            defaults: defaults,
            displayProvider: { [] },
            sleepDisplays: { sleepRequests += 1 }
        )

        try model.sleepAllNow()
        XCTAssertEqual(sleepRequests, 1)
        XCTAssertFalse(model.preferences.isEnabled)

        model.snooze(for: 30 * 60)
        XCTAssertTrue(model.preferences.isEnabled)
        XCTAssertNotNil(model.snoozedUntil)

        try model.sleepAllNow()
        XCTAssertEqual(sleepRequests, 2)
        XCTAssertTrue(model.preferences.isEnabled)
        XCTAssertNil(model.snoozedUntil)
        guard case .waitingForDisplays = model.runtimeState else {
            return XCTFail("Expected enabled protection to resume, got \(model.runtimeState)")
        }
    }

    @MainActor
    func testWorkingCountdownResetsPartialButNotFullSelection() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("panelctl-countdown-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let helper = directory.appendingPathComponent("fake-panelctl")
        let script = """
        #!/bin/bash
        printf '{"state":"waiting","blackedOutDisplayIDs":[]}\\n'
        trap 'exit 0' TERM
        while IFS= read -r command; do
            if [[ "$command" == "blackout-now" ]]; then
                printf '{"state":"blacked_out","blackedOutDisplayIDs":[7]}\\n'
            elif [[ "$command" == "restore" ]]; then
                printf '{"state":"waiting","blackedOutDisplayIDs":[]}\\n'
            fi
        done
        """
        try Data(script.utf8).write(to: helper)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)

        let suiteName = "panelctl-countdown-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var preferences = ProtectionPreferences()
        preferences.isEnabled = true
        preferences.didChooseDisplays = true
        preferences.selectedDisplayUUIDs = ["AAAA-UUID"]
        preferences.mode = .working
        preferences.keepBlackoutOnInput = false
        preferences.idleSeconds = 300
        preferences.followUpAction = .restore
        preferences.followUpSeconds = 120
        defaults.set(try JSONEncoder().encode(preferences), forKey: "blackoutPreferences")
        var current = Date(timeIntervalSince1970: 1_800_000_000)
        var idle: TimeInterval = 100
        setenv("PANELCTL_HELPER", helper.path, 1)
        defer { unsetenv("PANELCTL_HELPER") }

        let model = AppModel(
            defaults: defaults,
            displayProvider: { [self.displays[0], self.displays[1]] },
            now: { current },
            idleSecondsProvider: { idle }
        )
        try await waitUntil { model.runtimeState == .waiting }
        XCTAssertEqual(model.nextAction, "dim")
        XCTAssertEqual(model.secondsRemaining, 200)

        try model.blackoutNow()
        try await waitUntil { model.runtimeState == .blackedOut }
        XCTAssertEqual(model.nextAction, "restore")
        XCTAssertTrue(model.statusSummary.hasPrefix("Dimming active"))
        XCTAssertEqual(model.secondsRemaining, 120)
        current.addTimeInterval(31)
        XCTAssertEqual(model.secondsRemaining, 89)
        idle = 0
        XCTAssertEqual(model.secondsRemaining, 120)

        XCTAssertTrue(try model.restoreBlackout())
        try await waitUntil { model.runtimeState == .waiting }
        idle = 250
        current.addTimeInterval(10)
        XCTAssertEqual(model.secondsRemaining, 290)

        let stopped = expectation(description: "watcher stopped")
        model.shutdown { stopped.fulfill() }
        await fulfillment(of: [stopped], timeout: 3)

        let fullSuiteName = "panelctl-full-countdown-\(UUID().uuidString)"
        let fullDefaults = try XCTUnwrap(UserDefaults(suiteName: fullSuiteName))
        defer { fullDefaults.removePersistentDomain(forName: fullSuiteName) }
        var fullPreferences = preferences
        fullPreferences.allDisplays = true
        fullPreferences.selectedDisplayUUIDs = []
        fullDefaults.set(
            try JSONEncoder().encode(fullPreferences),
            forKey: "blackoutPreferences"
        )
        var fullCurrent = Date(timeIntervalSince1970: 1_800_000_000)
        var fullIdle: TimeInterval = 100
        let fullModel = AppModel(
            defaults: fullDefaults,
            displayProvider: { [self.displays[0], self.displays[1]] },
            now: { fullCurrent },
            idleSecondsProvider: { fullIdle }
        )
        try await waitUntil { fullModel.runtimeState == .waiting }
        XCTAssertEqual(fullModel.nextAction, "dim")
        try fullModel.blackoutNow()
        try await waitUntil { fullModel.runtimeState == .blackedOut }
        fullCurrent.addTimeInterval(31)
        fullIdle = 0
        XCTAssertEqual(fullModel.secondsRemaining, 89)

        let fullStopped = expectation(description: "full watcher stopped")
        fullModel.shutdown { fullStopped.fulfill() }
        await fulfillment(of: [fullStopped], timeout: 3)
    }

    @MainActor
    func testPartialMembershipUpdatesModelAndRestoreWithoutFullLifecycle() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("panelctl-membership-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let helper = directory.appendingPathComponent("fake-panelctl")
        let log = directory.appendingPathComponent("control.log")
        let allowReblackout = directory.appendingPathComponent("allow-reblackout")
        let script = """
        #!/bin/bash
        printf '{"state":"waiting","blackedOutDisplayIDs":[202]}\\n'
        trap 'exit 0' TERM
        while IFS= read -r command; do
            printf 'command:%s\\n' "$command" >> "$PANELCTL_TEST_LOG"
            if [[ "$command" == "restore" ]]; then
                printf '{"state":"waiting","blackedOutDisplayIDs":[]}\\n'
                while [[ ! -e "$PANELCTL_TEST_ALLOW_REBLACKOUT" ]]; do
                    /bin/sleep 0.01
                done
                printf '{"state":"waiting","blackedOutDisplayIDs":[202]}\\n'
            elif [[ "$command" == "blackout-now" ]]; then
                printf '{"state":"waiting","blackedOutDisplayIDs":[202]}\\n'
            fi
        done
        """
        try Data(script.utf8).write(to: helper)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: helper.path
        )

        let suiteName = "panelctl-membership-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var preferences = ProtectionPreferences()
        preferences.isEnabled = true
        preferences.didChooseDisplays = true
        preferences.selectedDisplayUUIDs = ["AAAA-UUID", "BBBB-UUID"]
        preferences.followUpAction = .restore
        defaults.set(
            try JSONEncoder().encode(preferences),
            forKey: "blackoutPreferences"
        )

        setenv("PANELCTL_HELPER", helper.path, 1)
        setenv("PANELCTL_TEST_LOG", log.path, 1)
        setenv("PANELCTL_TEST_ALLOW_REBLACKOUT", allowReblackout.path, 1)
        defer {
            unsetenv("PANELCTL_HELPER")
            unsetenv("PANELCTL_TEST_LOG")
            unsetenv("PANELCTL_TEST_ALLOW_REBLACKOUT")
        }

        let model = AppModel(
            defaults: defaults,
            displayProvider: { [self.displays[0], self.displays[1]] },
            idleSecondsProvider: { 0 }
        )
        var statusChanges = 0
        model.onStatusChange = { statusChanges += 1 }
        try await waitUntil { model.blackedOutDisplayIDs == [202] }

        XCTAssertEqual(model.runtimeState, .waiting)
        XCTAssertEqual(model.statusSystemImage, "rectangle.fill")
        XCTAssertTrue(model.statusSummary.hasPrefix("Empty-display blackout active"))
        XCTAssertTrue(model.statusSummary.contains("to blackout"))
        XCTAssertEqual(model.nextAction, "blackout")
        XCTAssertEqual(model.secondsRemaining, 300)
        XCTAssertGreaterThan(statusChanges, 0)

        XCTAssertTrue(try model.restoreBlackout())
        try await waitUntil { model.blackedOutDisplayIDs.isEmpty }
        try Data().write(to: allowReblackout)
        try await waitUntil { model.blackedOutDisplayIDs == [202] }
        XCTAssertEqual(model.runtimeState, .waiting)

        try model.blackoutNow()
        _ = try await waitForLogLines(2, at: log)
        XCTAssertEqual(model.runtimeState, .waiting)
        XCTAssertEqual(model.blackedOutDisplayIDs, [202])

        let stopped = expectation(description: "watcher stopped")
        model.shutdown { stopped.fulfill() }
        await fulfillment(of: [stopped], timeout: 2)
        XCTAssertTrue(model.blackedOutDisplayIDs.isEmpty)
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

    private func waitForLogLines(
        _ count: Int,
        at log: URL
    ) async throws -> [String] {
        for _ in 0..<150 {
            if let data = try? Data(contentsOf: log),
               let contents = String(data: data, encoding: .utf8) {
                let lines = contents.split(separator: "\n").map(String.init)
                if lines.count >= count {
                    return lines
                }
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("Timed out waiting for \(count) log lines")
        return []
    }

    @MainActor
    private func waitUntil(
        _ predicate: @escaping @MainActor () -> Bool
    ) async throws {
        for _ in 0..<150 {
            if predicate() { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("Timed out waiting for condition")
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
