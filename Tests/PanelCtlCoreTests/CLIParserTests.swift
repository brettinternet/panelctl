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
            mode: .working,
            overlayOpacityPercent: 60,
            hardwareBrightnessPercent: 25
        )
        XCTAssertEqual(
            try CLIParser.parse([
                "blackout", "--display", "1", "--index", "3",
                "--idle-after", "10m", "--timeout", "2.5s",
                "--caffeinate", "--watch", "--mode", "working",
                "--overlay-opacity", "60", "--dim-to", "25"
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
        XCTAssertFalse(defaultOptions.effectiveKeepBlackoutOnInput)

        let command = try CLIParser.parse([
            "blackout", "--display", "1", "--keep-blackout-on-input"
        ])
        guard case .blackout(let options) = command else {
            return XCTFail("expected blackout command")
        }
        XCTAssertTrue(options.keepBlackoutOnInput)
        XCTAssertTrue(options.effectiveKeepBlackoutOnInput)

        let working = try CLIParser.parse([
            "blackout", "--display", "1", "--mode", "working"
        ])
        guard case .blackout(let workingOptions) = working else {
            return XCTFail("expected blackout command")
        }
        XCTAssertFalse(workingOptions.keepBlackoutOnInput)
        XCTAssertTrue(workingOptions.effectiveKeepBlackoutOnInput)

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
            "blackout", "--display", "1", "--keep-blackout-on-input", "--dim-to", "0"
        ])) {
            XCTAssertEqual($0 as? CLIParseError, .persistentDimming)
        }
        XCTAssertNoThrow(try CLIParser.parse([
            "blackout", "--display", "1", "--mode", "working",
            "--keep-blackout-on-input", "--dim-to", "0"
        ]))
    }
    func testBlackoutModeAndChannelDefaults() throws {
        let command = try CLIParser.parse(["blackout", "--display", "1"])
        guard case .blackout(let options) = command else {
            return XCTFail("expected blackout command")
        }
        XCTAssertEqual(options.mode, .blocking)
        XCTAssertEqual(options.overlayOpacityPercent, 100)
        XCTAssertNil(options.hardwareBrightnessPercent)

        let noOverlay = try CLIParser.parse([
            "blackout", "--display", "1", "--mode", "working", "--no-overlay"
        ])
        guard case .blackout(let noOverlayOptions) = noOverlay else {
            return XCTFail("expected blackout command")
        }
        XCTAssertNil(noOverlayOptions.overlayOpacityPercent)
    }

    func testBlackoutModeAndOverlayValidation() {
        let errors: [([String], CLIParseError)] = [
            (["--mode", "other"], .invalidBlackoutMode("other")),
            (["--mode", "working", "--overlay-opacity", "0"], .invalidOverlayOpacity("0")),
            (["--mode", "working", "--overlay-opacity", "101"], .invalidOverlayOpacity("101")),
            (["--mode", "working", "--overlay-opacity", "1.5"], .invalidOverlayOpacity("1.5")),
            (["--mode", "working", "--overlay-opacity", "+1"], .invalidOverlayOpacity("+1")),
            (["--mode", "working", "--no-overlay", "--overlay-opacity", "60"], .conflictingOverlayOptions),
            (["--no-overlay"], .workingOverlayRequired),
            (["--overlay-opacity", "99"], .workingOverlayRequired)
        ]
        for (arguments, expected) in errors {
            XCTAssertThrowsError(
                try CLIParser.parse(["blackout", "--display", "1"] + arguments)
            ) {
                XCTAssertEqual($0 as? CLIParseError, expected)
            }
        }
        XCTAssertNoThrow(try CLIParser.parse([
            "blackout", "--display", "1", "--overlay-opacity", "100"
        ]))
        XCTAssertNoThrow(try CLIParser.parse([
            "blackout", "--display", "1", "--mode", "working",
            "--overlay-opacity", "1"
        ]))
    }

    func testHardwareBrightnessValidation() {
        for value in ["-1", "101", "1.5", "+1", "NaN", "inf"] {
            XCTAssertThrowsError(try CLIParser.parse([
                "blackout", "--display", "1", "--dim-to", value
            ])) {
                XCTAssertEqual($0 as? CLIParseError, .invalidHardwareBrightness(value))
            }
        }
        XCTAssertNoThrow(try CLIParser.parse([
            "blackout", "--display", "1", "--dim-to", "0"
        ]))
        XCTAssertNoThrow(try CLIParser.parse([
            "blackout", "--display", "1", "--dim-to", "100"
        ]))
        XCTAssertThrowsError(try CLIParser.parse([
            "blackout", "--display", "1", "--dim"
        ])) {
            XCTAssertEqual($0 as? CLIParseError, .unknownOption("--dim"))
        }
    }
    func testEmptyDisplayBlackoutOptions() throws {
        let defaults = BlackoutOptions(
            selectors: ["1"],
            all: false,
            idleAfter: nil,
            timeout: nil,
            sleepAfter: nil,
            caffeinate: false
        )
        XCTAssertFalse(defaults.blackoutEmptyDisplays)

        let command = try CLIParser.parse([
            "blackout", "--display", "1", "--idle-after", "10", "--watch",
            "--blackout-empty-displays", "--dim-to", "0"
        ])
        guard case .blackout(let options) = command else {
            return XCTFail("expected blackout command")
        }
        XCTAssertTrue(options.blackoutEmptyDisplays)
        XCTAssertEqual(options.hardwareBrightnessPercent, 0)

        XCTAssertThrowsError(try CLIParser.parse([
            "blackout", "--display", "1", "--idle-after", "10", "--watch",
            "--blackout-empty-displays", "--blackout-empty-displays"
        ])) {
            XCTAssertEqual(
                $0 as? CLIParseError,
                .duplicateOption("--blackout-empty-displays")
            )
        }
        XCTAssertThrowsError(try CLIParser.parse([
            "blackout", "--display", "1", "--idle-after", "10",
            "--blackout-empty-displays"
        ])) {
            XCTAssertEqual(
                $0 as? CLIParseError,
                .emptyDisplayBlackoutRequiresWatch
            )
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
        XCTAssertEqual(CLIHelp.version, "panelctl 0.3.19")
        XCTAssertTrue(CLIHelp.text(for: "app").contains("snooze --for <duration>"))
        XCTAssertTrue(CLIHelp.text(for: "blackout").contains("--watch"))
        XCTAssertTrue(CLIHelp.text(for: "blackout").contains("--dim-to"))
        XCTAssertFalse(CLIHelp.text(for: "blackout").contains("--dim "))
        XCTAssertTrue(CLIHelp.text(for: "blackout").contains("--ignore-playback"))
        XCTAssertTrue(CLIHelp.text(for: "blackout").contains("--defer-camera"))
        XCTAssertTrue(CLIHelp.text(for: "blackout").contains("--keep-blackout-on-input"))
        XCTAssertTrue(CLIHelp.text(for: "blackout").contains("--blackout-empty-displays"))
        XCTAssertTrue(CLIHelp.text(for: "blackout").contains(
            "Hardware dimming applies to inactivity and Blackout Now cycles, not empty-display-only blackouts."
        ))
        XCTAssertEqual(CLIParseError.unknownOption("--bad").description, "unknown option: --bad")
    }

    func testDuplicateScalarOptionsAreRejected() {
        let cases: [([String], CLIParseError)] = [
            (["list", "--json", "--json"], .duplicateOption("--json")),
            (["blackout", "--display", "1", "--idle-after", "1m", "--idle-after", "2m"], .duplicateOption("--idle-after")),
            (["blackout", "--display", "1", "--caffeinate", "--caffeinate"], .duplicateOption("--caffeinate")),
            (["blackout", "--display", "1", "--mode", "working", "--mode", "blocking"], .duplicateOption("--mode")),
            (["blackout", "--display", "1", "--mode", "working", "--overlay-opacity", "60", "--overlay-opacity", "70"], .duplicateOption("--overlay-opacity")),
            (["blackout", "--display", "1", "--mode", "working", "--no-overlay", "--no-overlay"], .duplicateOption("--no-overlay")),
            (["blackout", "--display", "1", "--dim-to", "1", "--dim-to", "2"], .duplicateOption("--dim-to")),
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
