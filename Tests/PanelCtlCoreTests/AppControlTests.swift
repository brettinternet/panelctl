import XCTest
@testable import PanelCtlCore

final class AppControlTests: XCTestCase {
    func testRequestUsesVersionOneAndStableCommandNames() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        XCTAssertEqual(
            String(data: try encoder.encode(AppControlRequest(command: .openSettings)), encoding: .utf8),
            #"{"command":"open-settings","protocol":1}"#
        )
        let actionID = UUID(uuidString: "80B92489-591F-45A5-8B5C-1B9D203020A4")!
        XCTAssertEqual(
            String(data: try encoder.encode(AppControlRequest(command: .runAction, actionID: actionID)), encoding: .utf8),
            #"{"actionID":"80B92489-591F-45A5-8B5C-1B9D203020A4","command":"run-action","protocol":1}"#
        )
        XCTAssertEqual(
            String(data: try encoder.encode(AppControlRequest(command: .runRule, ruleID: actionID)), encoding: .utf8),
            #"{"command":"run-rule","protocol":1,"ruleID":"80B92489-591F-45A5-8B5C-1B9D203020A4"}"#
        )
        XCTAssertEqual(
            String(data: try encoder.encode(AppControlRequest(command: .blackoutNow)), encoding: .utf8),
            #"{"command":"blackout-now","protocol":1}"#
        )
        XCTAssertEqual(
            String(data: try encoder.encode(AppControlRequest(command: .restore)), encoding: .utf8),
            #"{"command":"restore","protocol":1}"#
        )
        XCTAssertEqual(
            String(
                data: try encoder.encode(
                    AppControlRequest(
                        command: .snooze,
                        durationSeconds: 300
                    )
                ),
                encoding: .utf8
            ),
            #"{"command":"snooze","durationSeconds":300,"protocol":1}"#
        )
    }

    func testRequestDecodesWithoutOptionalDuration() throws {
        XCTAssertEqual(
            try JSONDecoder().decode(
                AppControlRequest.self,
                from: Data(#"{"command":"status","protocol":1}"#.utf8)
            ),
            AppControlRequest(command: .status)
        )
    }

    func testResponseOmitsOptionalFieldsWhenAbsent() throws {
        let response = AppControlResponse(ok: true, running: true, enabled: false, state: "disabled", summary: "Disabled")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let json = String(data: try encoder.encode(response), encoding: .utf8)!
        XCTAssertFalse(json.contains("detail"))
        XCTAssertFalse(json.contains("error"))
        XCTAssertFalse(json.contains("nextAction"))
        XCTAssertFalse(json.contains("secondsRemaining"))
        XCTAssertFalse(json.contains("snoozedUntil"))
        XCTAssertEqual(
            try JSONDecoder().decode(AppControlResponse.self, from: Data(json.utf8)),
            response
        )
    }

    func testStatusRuleArrayIsAdditiveAndRoundTrips() throws {
        let rule = AppControlRuleStatus(
            id: UUID(uuidString: "80B92489-591F-45A5-8B5C-1B9D203020A4")!,
            name: "Desk dimming", enabled: true, state: "waiting",
            summary: "Watching for inactivity", detail: nil,
            displays: ["display-uuid"], nextAction: "dim", secondsRemaining: 12
        )
        let response = AppControlResponse(
            ok: true, running: true, enabled: true, state: "waiting",
            summary: "Watching for inactivity", rules: [rule]
        )
        let decoded = try JSONDecoder().decode(AppControlResponse.self, from: JSONEncoder().encode(response))
        XCTAssertEqual(decoded, response)
        XCTAssertEqual(decoded.rules, [rule])
        let oldResponse = try JSONDecoder().decode(
            AppControlResponse.self,
            from: Data(#"{"protocol":1,"ok":true,"running":true,"enabled":true,"state":"waiting","summary":"Watching"}"#.utf8)
        )
        XCTAssertNil(oldResponse.rules, "protocol 1 responses without the additive field remain compatible")
    }

    func testResponseAutomationFieldsRoundTrip() throws {
        let response = AppControlResponse(
            ok: true,
            running: true,
            enabled: true,
            state: "snoozed",
            summary: "Snoozed",
            nextAction: "resume",
            secondsRemaining: 299,
            snoozedUntil: "2026-07-28T18:00:00Z"
        )
        let data = try JSONEncoder().encode(response)
        XCTAssertEqual(
            try JSONDecoder().decode(AppControlResponse.self, from: data),
            response
        )
    }

    func testStatusDoesNotLaunchAndReportsUnavailable() throws {
        var launched = false
        let client = try AppControlClient(
            socketPath: "/private/tmp/panelctl-test-no-such-socket-\(UUID().uuidString)",
            launch: { launched = true },
            isAppRunning: { false }
        )
        let response = try client.execute(.status)
        XCTAssertFalse(launched)
        XCTAssertFalse(response.running)
        XCTAssertFalse(response.ok)
        XCTAssertEqual(response.state, "unavailable")
    }

    func testSocketPathRejectsTraversalAndOverflow() throws {
        XCTAssertThrowsError(try AppControlSocket.path(name: "../other.sock")) {
            XCTAssertEqual(
                $0 as? AppControlError,
                .socketPathOutsideUserDirectory
            )
        }
        XCTAssertThrowsError(
            try AppControlSocket.path(name: String(repeating: "x", count: 200))
        ) {
            guard case .socketPathTooLong = $0 as? AppControlError else {
                return XCTFail("expected socketPathTooLong, got \($0)")
            }
        }
    }

    func testDisplayRequestsParsingOutcomesAndUnavailableApp() throws {
        let uuid = "00000000-0000-0000-0000-000000000002"
        for command in [AppControlCommand.hide, .show, .toggleHide] {
            XCTAssertTrue(command.isDisplayCommand)
            XCTAssertEqual(
                try CLIParser.parse(["app", command.rawValue, "--display", uuid, "--json"]),
                .app(command: command, durationSeconds: nil, targetUUID: uuid, json: true)
            )
            for arguments in [
                ["app", command.rawValue],
                ["app", command.rawValue, "--display", "123"],
                ["app", command.rawValue, "--display", uuid, "--display", uuid],
                ["app", command.rawValue, "--display", uuid, "--for", "5m"]
            ] { XCTAssertThrowsError(try CLIParser.parse(arguments)) }
            let request = AppControlRequest(command: command, targetUUID: uuid)
            XCTAssertEqual(try JSONDecoder().decode(AppControlRequest.self, from: JSONEncoder().encode(request)), request)
            let client = try AppControlClient(
                socketPath: "/private/tmp/panelctl-absent-\(UUID().uuidString)",
                launch: { XCTFail("Hide/Show must not launch the app") },
                isAppRunning: { false }
            )
            XCTAssertEqual(try client.execute(command, targetUUID: uuid).exitCode, 3)
        }
        XCTAssertFalse(AppControlCommand.toggle.isDisplayCommand)
        XCTAssertTrue(AppControlCommand.runAction.isManualDisplayCommand)
        XCTAssertTrue(AppControlCommand.runRule.isManualDisplayCommand)
        XCTAssertFalse(AppControlCommand.runAction.isDisplayCommand)
        XCTAssertFalse(AppControlCommand.runRule.isDisplayCommand)
        let actionID = UUID(uuidString: "80B92489-591F-45A5-8B5C-1B9D203020A4")!
        XCTAssertEqual(
            try CLIParser.parse(["app", "run-action", "--action", actionID.uuidString, "--json"]),
            .app(command: .runAction, durationSeconds: nil, actionID: actionID, json: true)
        )
        let ruleID = UUID(uuidString: "C4D9E188-2D26-4EE5-A492-A7E122E854D7")!
        XCTAssertEqual(
            try CLIParser.parse(["app", "run-rule", "--rule", ruleID.uuidString, "--json"]),
            .app(command: .runRule, durationSeconds: nil, ruleID: ruleID, json: true)
        )
        for invalid in [
            ["app", "run-rule"],
            ["app", "run-rule", "--rule", "not-a-uuid"],
            ["app", "run-rule", "--rule", ruleID.uuidString, "--rule", ruleID.uuidString],
            ["app", "run-rule", "--rule", ruleID.uuidString, "--display", uuid],
            ["app", "status", "--rule", ruleID.uuidString],
            ["app", "run-action", "--rule", ruleID.uuidString],
            ["app", "run-action"],
            ["app", "run-action", "--action", "not-a-uuid"],
            ["app", "run-action", "--action", actionID.uuidString, "--action", actionID.uuidString],
            ["app", "run-action", "--action", actionID.uuidString, "--display", uuid],
            ["app", "status", "--action", actionID.uuidString]
        ] {
            XCTAssertThrowsError(try CLIParser.parse(invalid), "\(invalid)")
        }
        XCTAssertThrowsError(try CLIParser.parse(["app", "enable", "--display", uuid]))
        XCTAssertNil(AppControlOutcome(rawValue: "confirmation-required"), "scripts act instead of asking for the UI")
        for (outcome, exitCode) in [(AppControlOutcome.done, Int32(0)), (.noOp, 0), (.refused, 1),
                                    (.busy, 1), (.failed, 1), (.partial, 5),
                                    (.recoveryNeeded, 6), (.responseLost, 1)] {
            let response = AppControlResponse(ok: exitCode == 0, running: true, enabled: false,
                                              state: "disabled", summary: "fixture", outcome: outcome)
            XCTAssertEqual(response.exitCode, exitCode)
            XCTAssertEqual(try JSONDecoder().decode(AppControlResponse.self, from: JSONEncoder().encode(response)), response)
        }
    }

    func testDisplayCommandLineParsesBackAndQuotesOnlyWhenNeeded() throws {
        let uuid = "37D8832A-2D66-02CA-B9F7-8F30A301B230"
        let bundled = "/Applications/PanelCtl.app/Contents/Helpers/panelctl"
        let line = AppControlCommand.toggleHide.commandLine(executable: bundled, displayUUID: uuid)
        XCTAssertEqual(line, "/Applications/PanelCtl.app/Contents/Helpers/panelctl app toggle-hide --display \(uuid)")
        let words = line.split(separator: " ").map(String.init)
        XCTAssertEqual(words.first, bundled)
        XCTAssertEqual(try CLIParser.parse(Array(words.dropFirst())),
                       .app(command: .toggleHide, durationSeconds: nil, targetUUID: uuid, json: false))
        XCTAssertEqual(
            AppControlCommand.hide.commandLine(executable: "/Users/me/My Apps/Bob's/PanelCtl.app/Contents/Helpers/panelctl",
                                               displayUUID: uuid),
            "'/Users/me/My Apps/Bob'\\''s/PanelCtl.app/Contents/Helpers/panelctl' app hide --display \(uuid)"
        )
    }

    func testRunActionCommandLineIsShellSafeAndUsesStableActionID() throws {
        let actionID = UUID(uuidString: "80B92489-591F-45A5-8B5C-1B9D203020A4")!
        let bundled = "/Applications/PanelCtl.app/Contents/Helpers/panelctl"
        let command = AppControlCommand.runAction.commandLine(executable: bundled, actionID: actionID)
        XCTAssertEqual(command, "\(bundled) app run-action --action \(actionID.uuidString)")
        let words = command.split(separator: " ").map(String.init)
        XCTAssertEqual(
            try CLIParser.parse(Array(words.dropFirst())),
            .app(command: .runAction, durationSeconds: nil, actionID: actionID, json: false)
        )
        XCTAssertEqual(
            AppControlCommand.runAction.commandLine(
                executable: "/Users/me/My Apps/Bob's/PanelCtl.app/Contents/Helpers/panelctl",
                actionID: actionID
            ),
            "'/Users/me/My Apps/Bob'\\''s/PanelCtl.app/Contents/Helpers/panelctl' app run-action --action \(actionID.uuidString)"
        )
        let client = try AppControlClient(
            socketPath: "/private/tmp/panelctl-no-action-app-\(UUID().uuidString)",
            launch: { XCTFail("run-action must never launch PanelCtl.app") },
            isAppRunning: { false }
        )
        XCTAssertEqual(try client.execute(.runAction, actionID: actionID).exitCode, 3)
    }

    func testRunRuleCommandLineIsShellSafeAndNeverLaunchesTheApp() throws {
        let ruleID = UUID(uuidString: "C4D9E188-2D26-4EE5-A492-A7E122E854D7")!
        let bundled = "/Applications/PanelCtl.app/Contents/Helpers/panelctl"
        let command = AppControlCommand.runRule.commandLine(executable: bundled, ruleID: ruleID)
        XCTAssertEqual(command, "\(bundled) app run-rule --rule \(ruleID.uuidString)")
        XCTAssertEqual(
            AppControlCommand.runRule.commandLine(
                executable: "/Users/me/My Apps/Bob's/PanelCtl.app/Contents/Helpers/panelctl",
                ruleID: ruleID
            ),
            "'/Users/me/My Apps/Bob'\\''s/PanelCtl.app/Contents/Helpers/panelctl' app run-rule --rule \(ruleID.uuidString)"
        )
        let words = command.split(separator: " ").map(String.init)
        XCTAssertEqual(
            try CLIParser.parse(Array(words.dropFirst())),
            .app(command: .runRule, durationSeconds: nil, ruleID: ruleID, json: false)
        )
        let client = try AppControlClient(
            socketPath: "/private/tmp/panelctl-no-rule-app-\(UUID().uuidString)",
            launch: { XCTFail("run-rule must never launch PanelCtl.app") },
            isAppRunning: { false }
        )
        XCTAssertEqual(try client.execute(.runRule, ruleID: ruleID).exitCode, 3)
    }

    func testRunningRuleStatusRoundTripsAndOldStatusRemainsCompatible() throws {
        let run = AppControlRunningRule(
            id: UUID(uuidString: "C4D9E188-2D26-4EE5-A492-A7E122E854D7")!,
            name: "Desk dimming"
        )
        let response = AppControlResponse(
            ok: true, running: true, enabled: false, state: "disabled",
            summary: "Automation off", runningRule: run
        )
        XCTAssertEqual(try JSONDecoder().decode(AppControlResponse.self, from: JSONEncoder().encode(response)), response)
        let old = try JSONDecoder().decode(
            AppControlResponse.self,
            from: Data(#"{"protocol":1,"ok":true,"running":true,"enabled":false,"state":"disabled","summary":"Automation off"}"#.utf8)
        )
        XCTAssertNil(old.runningRule)
    }

    func testEightStepActionReplyFitsTheControlMessageBudget() throws {
        XCTAssertEqual(AppControlClient.actionResponseTimeout, 240)
        let targetUUIDs = (0..<8).map { _ in UUID().uuidString }
        let steps = targetUUIDs.enumerated().map { offset, targetUUID in
            AppControlActionStepResult(
                index: offset + 1,
                targetUUID: targetUUID,
                effect: "remove-from-desktop",
                outcome: .partial,
                desktopSummary: String(repeating: "d", count: 64),
                inputOutcome: .failed,
                inputDetail: String(repeating: "i", count: 64)
            )
        }
        let displays = targetUUIDs.map { targetUUID in
            AppControlDisplayStatus(
                targetUUID: targetUUID,
                observedState: "unavailable",
                operation: "idle",
                recoveryNeeded: false,
                lastInputOutcome: nil
            )
        }
        let response = AppControlResponse(
            ok: false,
            running: true,
            enabled: false,
            state: "waiting",
            summary: String(repeating: "s", count: 120),
            detail: String(repeating: "i", count: 120),
            error: String(repeating: "e", count: 120),
            outcome: .partial,
            displays: displays,
            steps: steps
        )
        let data = try JSONEncoder().encode(response)
        XCTAssertLessThanOrEqual(data.count + 1, AppControlSocket.messageLimit)
        XCTAssertEqual(try JSONDecoder().decode(AppControlResponse.self, from: data), response)
    }

    func testAppCommandParsing() throws {
        XCTAssertEqual(try CLIParser.parse(["app", "enable"]), .app(command: .enable, durationSeconds: nil, json: false))
        XCTAssertEqual(try CLIParser.parse(["app", "open-settings", "--json"]), .app(command: .openSettings, durationSeconds: nil, json: true))
        XCTAssertEqual(try CLIParser.parse(["app", "blackout-now"]), .app(command: .blackoutNow, durationSeconds: nil, json: false))
        XCTAssertEqual(try CLIParser.parse(["app", "restore", "--json"]), .app(command: .restore, durationSeconds: nil, json: true))
        XCTAssertEqual(try CLIParser.parse(["app", "sleep-now"]), .app(command: .sleepNow, durationSeconds: nil, json: false))
        XCTAssertEqual(try CLIParser.parse(["app", "snooze", "--for", "5m", "--json"]), .app(command: .snooze, durationSeconds: 300, json: true))
        XCTAssertEqual(try CLIParser.parse(["app", "snooze", "--for", "720h"]), .app(command: .snooze, durationSeconds: 2_592_000, json: false))
        XCTAssertEqual(try CLIParser.parse(["app", "resume"]), .app(command: .resume, durationSeconds: nil, json: false))
        XCTAssertThrowsError(try CLIParser.parse(["app"])) { XCTAssertEqual($0 as? CLIParseError, .missingAppCommand) }
        XCTAssertThrowsError(try CLIParser.parse(["app", "enable", "--json", "--json"])) { XCTAssertEqual($0 as? CLIParseError, .duplicateOption("--json")) }
        XCTAssertThrowsError(try CLIParser.parse(["app", "snooze"])) { XCTAssertEqual($0 as? CLIParseError, .missingValue("--for")) }
        XCTAssertThrowsError(try CLIParser.parse(["app", "snooze", "--for", "0"])) { XCTAssertEqual($0 as? CLIParseError, .invalidDuration(option: "--for", value: "0")) }
        XCTAssertThrowsError(try CLIParser.parse(["app", "snooze", "--for", "721h"])) { XCTAssertEqual($0 as? CLIParseError, .snoozeDurationTooLong) }
        XCTAssertThrowsError(try CLIParser.parse(["app", "resume", "--for", "5m"])) { XCTAssertEqual($0 as? CLIParseError, .unknownOption("--for")) }
    }
}
