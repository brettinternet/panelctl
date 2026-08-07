import XCTest
@testable import PanelCtlCore

final class CLIParserTests: XCTestCase {
    func testListAndProbeJSON() throws {
        XCTAssertEqual(try CLIParser.parse(["list", "--json"]), .list(json: true))
        XCTAssertEqual(try CLIParser.parse(["probe"]), .probe(json: false))
    }

    func testBlackoutOptions() throws {
        let options = BlackoutOptions(
            selectors: ["1", "index:3"],
            all: false,
            idleAfter: 600,
            timeout: 2.5,
            sleepAfter: nil,
            caffeinate: true,
            watch: true,
            dimDisplays: true
        )
        XCTAssertEqual(
            try CLIParser.parse([
                "blackout", "--display", "1", "--index", "3",
                "--idle-after", "10m", "--timeout", "2.5s",
                "--caffeinate", "--watch", "--dim"
            ]),
            .blackout(options)
        )
    }

    func testKeepBlackoutOnInputOptions() throws {
        let defaultOptions = BlackoutOptions(
            selectors: ["1"],
            all: false,
            idleAfter: nil,
            timeout: nil,
            sleepAfter: nil,
            caffeinate: false
        )
        XCTAssertFalse(defaultOptions.keepBlackoutOnInput)

        let command = try CLIParser.parse([
            "blackout", "--display", "1", "--keep-blackout-on-input"
        ])
        guard case .blackout(let options) = command else {
            return XCTFail("expected blackout command")
        }
        XCTAssertTrue(options.keepBlackoutOnInput)

        XCTAssertThrowsError(try CLIParser.parse([
            "blackout", "--display", "1",
            "--keep-blackout-on-input", "--keep-blackout-on-input"
        ])) {
            XCTAssertEqual($0 as? CLIParseError, .duplicateOption("--keep-blackout-on-input"))
        }
        XCTAssertThrowsError(try CLIParser.parse([
            "blackout", "--all", "--keep-blackout-on-input"
        ])) {
            XCTAssertEqual($0 as? CLIParseError, .allRequiresLimit)
        }
        XCTAssertThrowsError(try CLIParser.parse([
            "blackout", "--display", "1", "--keep-blackout-on-input", "--dim"
        ])) {
            XCTAssertEqual($0 as? CLIParseError, .persistentDimming)
        }
        XCTAssertThrowsError(try CLIParser.parse([
            "blackout", "--all", "--keep-blackout-on-input", "--dim"
        ])) {
            XCTAssertEqual($0 as? CLIParseError, .persistentDimming)
        }
    }

    func testAllBlackoutSafetyOptions() throws {
        let options = BlackoutOptions(selectors: [], all: true, idleAfter: 10, timeout: nil, sleepAfter: 60, caffeinate: true)
        XCTAssertEqual(try CLIParser.parse(["blackout", "--all", "--idle-after", "10", "--sleep-after", "60", "--caffeinate"]), .blackout(options))
        XCTAssertThrowsError(try CLIParser.parse(["blackout", "--all"])) { XCTAssertEqual($0 as? CLIParseError, .allRequiresLimit) }
        XCTAssertThrowsError(try CLIParser.parse(["blackout", "--all", "--display", "1", "--timeout", "1"])) { XCTAssertEqual($0 as? CLIParseError, .conflictingTargets) }
        XCTAssertThrowsError(try CLIParser.parse(["blackout", "--display", "1", "--timeout", "1", "--sleep-after", "2"])) { XCTAssertEqual($0 as? CLIParseError, .conflictingBlackoutLimits) }
    }

    func testBoundedDisplayAssertionRequiresSleepAfter() throws {
        let command = try CLIParser.parse([
            "blackout", "--display", "1", "--sleep-after", "60", "--keep-displays-awake"
        ])
        guard case .blackout(let options) = command else { return XCTFail("expected blackout") }
        XCTAssertTrue(options.keepDisplaysAwake)
        XCTAssertThrowsError(try CLIParser.parse([
            "blackout", "--display", "1", "--keep-displays-awake"
        ])) {
            XCTAssertEqual($0 as? CLIParseError, .keepDisplaysAwakeRequiresSleepAfter)
        }
        XCTAssertThrowsError(try CLIParser.parse([
            "blackout", "--display", "1", "--sleep-after", "60", "--keep-displays-awake", "--keep-displays-awake"
        ])) {
            XCTAssertEqual($0 as? CLIParseError, .duplicateOption("--keep-displays-awake"))
        }
    }

    func testBlackoutCanIgnorePlaybackDeferral() throws {
        let command = try CLIParser.parse(["blackout", "--display", "1", "--ignore-playback"])
        guard case .blackout(let options) = command else {
            return XCTFail("expected blackout command")
        }
        XCTAssertFalse(options.deferPlayback)
        XCTAssertTrue(BlackoutOptions(
            selectors: ["1"], all: false, idleAfter: nil, timeout: nil,
            sleepAfter: nil, caffeinate: false
        ).deferPlayback)
    }

    func testBlackoutCanDeferForCameraUse() throws {
        let command = try CLIParser.parse([
            "blackout", "--display", "1", "--defer-camera"
        ])
        guard case .blackout(let options) = command else {
            return XCTFail("expected blackout command")
        }
        XCTAssertTrue(options.deferCamera)
        XCTAssertFalse(BlackoutOptions(
            selectors: ["1"], all: false, idleAfter: nil, timeout: nil,
            sleepAfter: nil, caffeinate: false
        ).deferCamera)
    }

    func testDisplaySleepOptions() throws {
        XCTAssertEqual(try CLIParser.parse(["sleep-displays"]), .sleepDisplays(keepSystemAwake: false, timeout: nil))
        XCTAssertEqual(try CLIParser.parse(["sleep-displays", "--keep-system-awake", "--timeout", "30"]), .sleepDisplays(keepSystemAwake: true, timeout: 30))
        XCTAssertEqual(try CLIParser.parse(["sleep-displays", "--keep-system-awake", "--timeout", "0.5h"]), .sleepDisplays(keepSystemAwake: true, timeout: 1_800))
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
        XCTAssertThrowsError(try CLIParser.parse(["blackout", "--display", "1", "--timeout", "0"])) {
            XCTAssertEqual($0 as? CLIParseError, .invalidDuration(option: "--timeout", value: "0"))
        }
        XCTAssertThrowsError(try CLIParser.parse(["blackout", "--display", "1", "--watch"])) {
            XCTAssertEqual($0 as? CLIParseError, .watchRequiresIdleAfter)
        }
        XCTAssertThrowsError(try CLIParser.parse(["list", "--nope"])) { XCTAssertEqual($0 as? CLIParseError, .unknownOption("--nope")) }
        XCTAssertThrowsError(try CLIParser.parse(["sleep-displays", "--timeout", "30"])) { XCTAssertEqual($0 as? CLIParseError, .timeoutRequiresKeepAwake) }
        XCTAssertThrowsError(try CLIParser.parse(["wake-displays", "--nope"])) { XCTAssertEqual($0 as? CLIParseError, .unknownOption("--nope")) }
    }

    func testDurationSyntaxAndValidation() throws {
        let valid: [(String, TimeInterval)] = [
            ("30", 30),
            ("30s", 30),
            ("5M", 300),
            ("2h", 7_200)
        ]
        for (raw, seconds) in valid {
            let command = try CLIParser.parse([
                "blackout", "--display", "1", "--idle-after", raw
            ])
            guard case .blackout(let options) = command else {
                return XCTFail("expected blackout command")
            }
            XCTAssertEqual(options.idleAfter, seconds)
        }

        let invalid = [
            "0", "-1", ".5h", "1h30m", "nan", "inf", "1e3", "1d",
            String(repeating: "9", count: 1_000)
        ]
        for raw in invalid {
            XCTAssertThrowsError(
                try CLIParser.parse([
                    "blackout", "--display", "1", "--idle-after", raw
                ])
            ) {
                XCTAssertEqual(
                    $0 as? CLIParseError,
                    .invalidDuration(option: "--idle-after", value: raw)
                )
            }
        }
    }

    func testHelpVersionAndErrorDescriptions() throws {
        XCTAssertEqual(try CLIParser.parse(["--help"]), .help(command: nil))
        XCTAssertEqual(try CLIParser.parse(["help", "blackout"]), .help(command: "blackout"))
        XCTAssertEqual(try CLIParser.parse(["blackout", "-h"]), .help(command: "blackout"))
        XCTAssertEqual(try CLIParser.parse(["--version"]), .version)
        XCTAssertEqual(CLIHelp.version, "panelctl 0.3.14")
        XCTAssertTrue(CLIHelp.text(for: "app").contains("snooze --for <duration>"))
        XCTAssertTrue(CLIHelp.text(for: "blackout").contains("--watch"))
        XCTAssertTrue(CLIHelp.text(for: "blackout").contains("--dim"))
        XCTAssertTrue(CLIHelp.text(for: "blackout").contains("--ignore-playback"))
        XCTAssertTrue(CLIHelp.text(for: "blackout").contains("--defer-camera"))
        XCTAssertTrue(CLIHelp.text(for: "blackout").contains("--keep-blackout-on-input"))
        XCTAssertEqual(CLIParseError.unknownOption("--bad").description, "unknown option: --bad")
    }

    func testDuplicateScalarOptionsAreRejected() {
        let cases: [([String], CLIParseError)] = [
            (["list", "--json", "--json"], .duplicateOption("--json")),
            (["blackout", "--display", "1", "--idle-after", "1m", "--idle-after", "2m"], .duplicateOption("--idle-after")),
            (["blackout", "--display", "1", "--caffeinate", "--caffeinate"], .duplicateOption("--caffeinate")),
            (["blackout", "--display", "1", "--dim", "--dim"], .duplicateOption("--dim")),
            (["blackout", "--display", "1", "--ignore-playback", "--ignore-playback"], .duplicateOption("--ignore-playback")),
            (["blackout", "--display", "1", "--defer-camera", "--defer-camera"], .duplicateOption("--defer-camera")),
            (["ddc-luminance", "--display", "1", "--display", "2"], .duplicateOption("--display")),
            (["ddc-luminance", "--display", "1", "--json", "--json"], .duplicateOption("--json")),
            (["sleep-displays", "--keep-system-awake", "--keep-system-awake"], .duplicateOption("--keep-system-awake"))
        ]
        for (arguments, expected) in cases {
            XCTAssertThrowsError(try CLIParser.parse(arguments)) {
                XCTAssertEqual($0 as? CLIParseError, expected)
            }
        }
    }

    func testBlackoutSafetyDecisions() {
        XCTAssertThrowsError(try BlackoutController.validateSelection(selectedCount: 2, drawableCount: 2)) {
            XCTAssertEqual($0 as? BlackoutError, .allScreensSafety)
        }
        XCTAssertThrowsError(try BlackoutController.validateSelection(selectedCount: 3, drawableCount: 2)) {
            XCTAssertEqual($0 as? BlackoutError, .allScreensSafety)
        }
        XCTAssertNoThrow(
            try BlackoutController.validateSelection(
                selectedCount: 2,
                drawableCount: 2,
                hasSafetyLimit: true
            )
        )
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
