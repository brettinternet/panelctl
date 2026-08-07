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
