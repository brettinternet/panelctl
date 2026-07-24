import XCTest
@testable import PanelCtlCore

final class CLIParserTests: XCTestCase {
    func testListAndProbeJSON() throws {
        XCTAssertEqual(try CLIParser.parse(["list", "--json"]), .list(json: true))
        XCTAssertEqual(try CLIParser.parse(["probe"]), .probe(json: false))
    }

    func testBlackoutOptions() throws {
        let options = BlackoutOptions(selectors: ["1", "index:3"], all: false, idleAfter: 10, timeout: 2.5, sleepAfter: nil, caffeinate: true)
        XCTAssertEqual(try CLIParser.parse(["blackout", "--display", "1", "--index", "3", "--idle-after", "10", "--timeout", "2.5", "--caffeinate"]), .blackout(options))
    }

    func testAllBlackoutSafetyOptions() throws {
        let options = BlackoutOptions(selectors: [], all: true, idleAfter: 10, timeout: nil, sleepAfter: 60, caffeinate: true)
        XCTAssertEqual(try CLIParser.parse(["blackout", "--all", "--idle-after", "10", "--sleep-after", "60", "--caffeinate"]), .blackout(options))
        XCTAssertThrowsError(try CLIParser.parse(["blackout", "--all"])) { XCTAssertEqual($0 as? CLIParseError, .allRequiresLimit) }
        XCTAssertThrowsError(try CLIParser.parse(["blackout", "--all", "--display", "1", "--timeout", "1"])) { XCTAssertEqual($0 as? CLIParseError, .conflictingTargets) }
        XCTAssertThrowsError(try CLIParser.parse(["blackout", "--display", "1", "--timeout", "1", "--sleep-after", "2"])) { XCTAssertEqual($0 as? CLIParseError, .conflictingBlackoutLimits) }
    }

    func testDisplaySleepOptions() throws {
        XCTAssertEqual(try CLIParser.parse(["sleep-displays"]), .sleepDisplays(keepSystemAwake: false, timeout: nil))
        XCTAssertEqual(try CLIParser.parse(["sleep-displays", "--keep-system-awake", "--timeout", "30"]), .sleepDisplays(keepSystemAwake: true, timeout: 30))
        XCTAssertEqual(try CLIParser.parse(["wake-displays"]), .wakeDisplays)
    }

    func testDDCLuminanceOptions() throws {
        XCTAssertEqual(try CLIParser.parse(["ddc-luminance", "--display", "index:2"]), .ddcLuminance(selector: "index:2", setValue: nil, json: false))
        XCTAssertEqual(try CLIParser.parse(["ddc-luminance", "--json", "--display", "0x5", "--set", "74"]), .ddcLuminance(selector: "0x5", setValue: 74, json: true))
        XCTAssertThrowsError(try CLIParser.parse(["ddc-luminance"])) { XCTAssertEqual($0 as? CLIParseError, .missingValue("--display")) }
        XCTAssertThrowsError(try CLIParser.parse(["ddc-luminance", "--display", "1", "--set", "65536"])) { XCTAssertEqual($0 as? CLIParseError, .invalidLuminance) }
        XCTAssertThrowsError(try CLIParser.parse(["ddc-luminance", "--display", "1", "--set", "1", "--set", "2"])) { XCTAssertEqual($0 as? CLIParseError, .duplicateOption("--set")) }
    }

    func testRejectsUnsafeValues() {
        XCTAssertThrowsError(try CLIParser.parse(["blackout"])) { XCTAssertEqual($0 as? CLIParseError, .noDisplays) }
        XCTAssertThrowsError(try CLIParser.parse(["blackout", "--display", "1", "--timeout", "0"])) { XCTAssertEqual($0 as? CLIParseError, .invalidTimeout) }
        XCTAssertThrowsError(try CLIParser.parse(["list", "--nope"])) { XCTAssertEqual($0 as? CLIParseError, .unknownOption("--nope")) }
        XCTAssertThrowsError(try CLIParser.parse(["sleep-displays", "--timeout", "30"])) { XCTAssertEqual($0 as? CLIParseError, .timeoutRequiresKeepAwake) }
        XCTAssertThrowsError(try CLIParser.parse(["wake-displays", "--nope"])) { XCTAssertEqual($0 as? CLIParseError, .unknownOption("--nope")) }
    }

    func testBlackoutSafetyDecisions() {
        XCTAssertThrowsError(try BlackoutController.validateSelection(selectedCount: 2, drawableCount: 2)) {
            XCTAssertEqual($0 as? BlackoutError, .allScreensSafety)
        }
        XCTAssertThrowsError(try BlackoutController.validateSelection(selectedCount: 3, drawableCount: 2)) {
            XCTAssertEqual($0 as? BlackoutError, .allScreensSafety)
        }
        XCTAssertNoThrow(try BlackoutController.validateSelection(selectedCount: 1, drawableCount: 2))
        XCTAssertThrowsError(try BlackoutController.validateTarget(isMirrored: true, selector: "1")) {
            XCTAssertEqual($0 as? BlackoutError, .mirroredDisplay("1"))
        }
        XCTAssertNoThrow(try BlackoutController.validateTarget(isMirrored: false, selector: "1"))
    }

    func testBlackoutWindowRectIsRelativeToTargetScreen() {
        let negativeOrigin = CGRect(x: -2560, y: 0, width: 2560, height: 1440)
        let stacked = CGRect(x: 1728, y: 415, width: 3440, height: 1440)
        XCTAssertEqual(BlackoutController.windowContentRect(for: negativeOrigin), CGRect(x: 0, y: 0, width: 2560, height: 1440))
        XCTAssertEqual(BlackoutController.windowContentRect(for: stacked), CGRect(x: 0, y: 0, width: 3440, height: 1440))
    }
}
