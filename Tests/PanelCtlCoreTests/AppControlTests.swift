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
    }

    func testResponseOmitsOptionalFieldsWhenAbsent() throws {
        let response = AppControlResponse(ok: true, running: true, enabled: false, state: "disabled", summary: "Disabled")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let json = String(data: try encoder.encode(response), encoding: .utf8)!
        XCTAssertFalse(json.contains("detail"))
        XCTAssertFalse(json.contains("error"))
        XCTAssertEqual(
            try JSONDecoder().decode(AppControlResponse.self, from: Data(json.utf8)),
            response
        )
    }

    func testStatusDoesNotLaunchAndReportsUnavailable() throws {
        var launched = false
        let client = try AppControlClient(
            socketPath: "/private/tmp/panelctl-test-no-such-socket-\(UUID().uuidString)",
            launch: { launched = true }
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
        XCTAssertEqual(try CLIParser.parse(["app", "enable"]), .app(command: .enable, json: false))
        XCTAssertEqual(try CLIParser.parse(["app", "open-settings", "--json"]), .app(command: .openSettings, json: true))
        XCTAssertThrowsError(try CLIParser.parse(["app"])) { XCTAssertEqual($0 as? CLIParseError, .missingAppCommand) }
        XCTAssertThrowsError(try CLIParser.parse(["app", "enable", "--json", "--json"])) { XCTAssertEqual($0 as? CLIParseError, .duplicateOption("--json")) }
    }
}
