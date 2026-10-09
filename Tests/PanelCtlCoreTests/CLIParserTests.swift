import XCTest
@testable import PanelCtlCore

final class CLIParserTests: XCTestCase {
    func testAppStatusWatchRequiresJSONAndRejectsMutatingCommands() throws {
        XCTAssertEqual(try CLIParser.parse(["app", "status", "--watch", "--json"]), .appStatusWatch)
        XCTAssertEqual(try CLIParser.parse(["app", "status", "--json", "--watch"]), .appStatusWatch)
        XCTAssertThrowsError(try CLIParser.parse(["app", "status", "--watch"])) {
            XCTAssertEqual($0 as? CLIParseError, .appWatchRequiresJSON)
        }
        XCTAssertThrowsError(try CLIParser.parse(["app", "status", "--watch", "--watch", "--json"]))
        for command in ["enable", "disable", "hide", "run-action", "run-rule"] {
            XCTAssertThrowsError(try CLIParser.parse(["app", command, "--watch", "--json"]))
        }
    }

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
    func testHiddenMirrorSourceOverlayOptionsAreNarrowAndExplicit() throws {
        let source = "00000000-0000-0000-0000-000000000003"
        let command = try CLIParser.parse([
            "blackout", "--display", source,
            "--panelctl-hidden-mirror-source", source,
            "--mode", "blocking", "--overlay-opacity", "100",
            "--watch", "--idle-after", "300", "--timeout", "1800"
        ])
        guard case .blackout(let options) = command else {
            return XCTFail("expected scoped blackout command")
        }
        XCTAssertEqual(options.hiddenMirrorSourceUUID, source)
        XCTAssertNil(options.hardwareBrightnessPercent)
        XCTAssertNil(options.sleepAfter)
        XCTAssertFalse(options.keepDisplaysAwake)
        XCTAssertFalse(options.blackoutEmptyDisplays)
        XCTAssertTrue(options.watch)
        XCTAssertNoThrow(try BlackoutController.validateOptions(options))

        let rejected: [([String], CLIParseError)] = [
            (["--display", source, "--display", source, "--panelctl-hidden-mirror-source", source, "--panelctl-hidden-mirror-source", "00000000-0000-0000-0000-000000000002", "--watch", "--idle-after", "10", "--timeout", "60"], .invalidHiddenMirrorSourceOverlay),
            (["--display", source, "--panelctl-hidden-mirror-source", "00000000-0000-0000-0000-000000000002", "--watch", "--idle-after", "10", "--timeout", "60"], .invalidHiddenMirrorSourceOverlay),
            (["--display", source, "--panelctl-hidden-mirror-source", source, "--watch", "--idle-after", "10"], .invalidHiddenMirrorSourceOverlay),
            (["--display", source, "--panelctl-hidden-mirror-source", source, "--watch", "--idle-after", "10", "--timeout", "60", "--dim-to", "20"], .invalidHiddenMirrorSourceOverlay),
            (["--display", source, "--panelctl-hidden-mirror-source", source, "--watch", "--idle-after", "10", "--timeout", "60", "--sleep-after", "30"], .conflictingBlackoutLimits)
        ]
        for (arguments, expected) in rejected {
            XCTAssertThrowsError(try CLIParser.parse(["blackout"] + arguments)) {
                XCTAssertEqual($0 as? CLIParseError, expected)
            }
        }
        guard case .blackout(let normal) = try CLIParser.parse(["blackout", "--display", source]) else {
            return XCTFail("expected normal blackout")
        }
        XCTAssertNil(normal.hiddenMirrorSourceUUID, "ordinary CLI blackout has no mirror permission")
    }

    func testRemovalSessionOneShotRequiresBoundedHardwareFreeOverlay() throws {
        let source = "00000000-0000-0000-0000-000000000003"
        for authorization in [["--panelctl-hidden-mirror-source", source], ["--panelctl-removal-session-overlay"]] {
            let base = ["blackout", "--display", source] + authorization + ["--panelctl-run-once"]
            let arguments = base + ["--timeout", "60"]
            guard case .blackout(let options) = try CLIParser.parse(arguments) else {
                return XCTFail("expected blackout")
            }
            XCTAssertTrue(options.runOnce)
            XCTAssertTrue(options.removalSessionOverlay)
            XCTAssertFalse(options.watch)
            XCTAssertNil(options.idleAfter)
            XCTAssertNoThrow(try BlackoutController.validateOptions(options))
            for extra in [["--dim-to", "0"], ["--sleep-after", "30"], ["--all"],
                          ["--mode", "working"], ["--blackout-empty-displays"], ["--caffeinate"],
                          ["--overlay-opacity", "50"], ["--watch", "--idle-after", "10"],
                          ["--idle-after", "10"], ["--keep-displays-awake"]] {
                XCTAssertThrowsError(try CLIParser.parse(arguments + extra), extra.joined(separator: " "))
            }
            XCTAssertThrowsError(try CLIParser.parse(base))
            XCTAssertThrowsError(try CLIParser.parse(arguments.filter { $0 != "--panelctl-run-once" }))
        }
    }

    func testBoundedOverlayCanCombineMirrorSourcesWithOrdinaryUUIDTargets() throws {
        let source = "00000000-0000-0000-0000-000000000003"
        let ordinary = "00000000-0000-0000-0000-000000000001"
        let arguments = ["blackout", "--display", source, "--display", ordinary,
                         "--panelctl-hidden-mirror-source", source,
                         "--watch", "--idle-after", "300", "--timeout", "1800"]
        guard case .blackout(let options) = try CLIParser.parse(arguments) else {
            return XCTFail("expected blackout")
        }
        XCTAssertEqual(options.selectors, [source, ordinary])
        XCTAssertEqual(options.hiddenMirrorSourceUUIDs, [source])
        XCTAssertNoThrow(try BlackoutController.validateOptions(options))
        XCTAssertThrowsError(try CLIParser.parse(arguments + ["--display", ordinary]))
        XCTAssertThrowsError(try CLIParser.parse(arguments + ["--display", "1"]))
        XCTAssertThrowsError(try CLIParser.parse(arguments + ["--dim-to", "0"]))
        XCTAssertThrowsError(try CLIParser.parse(arguments + ["--sleep-after", "30"]))
        XCTAssertThrowsError(try CLIParser.parse(arguments + ["--blackout-empty-displays"]))
        XCTAssertThrowsError(try BlackoutController.validateTarget(isMirrored: true, selector: ordinary))
        XCTAssertNoThrow(try BlackoutController.validateTarget(isMirrored: false, selector: ordinary))
    }

    func testOrdinaryRemovalSessionOverlayRequiresBoundedHardwareFreeWatch() throws {
        let arguments = ["blackout", "--display", "00000000-0000-0000-0000-000000000001",
                         "--panelctl-removal-session-overlay", "--watch", "--idle-after", "300",
                         "--timeout", "1800"]
        guard case .blackout(let options) = try CLIParser.parse(arguments) else {
            return XCTFail("expected blackout")
        }
        XCTAssertTrue(options.removalSessionOverlay)
        XCTAssertTrue(options.hiddenMirrorSourceUUIDs.isEmpty)
        XCTAssertNoThrow(try BlackoutController.validateOptions(options))
        for extra in [["--dim-to", "0"], ["--sleep-after", "30"], ["--all"],
                      ["--mode", "working"], ["--blackout-empty-displays"], ["--caffeinate"],
                      ["--panelctl-removal-session-overlay"]] {
            XCTAssertThrowsError(try CLIParser.parse(arguments + extra))
        }
        XCTAssertThrowsError(try CLIParser.parse(Array(arguments.dropLast(2))))
        XCTAssertThrowsError(try CLIParser.parse(arguments.filter { $0 != "--watch" }))
    }

    func testHiddenDisplaysAreWatchedUUIDsOutsideTheSelection() throws {
        let selected = "00000000-0000-0000-0000-000000000001"
        let hidden = "00000000-0000-0000-0000-000000000002"
        let other = "00000000-0000-0000-0000-000000000003"
        let watched = ["--watch", "--idle-after", "300", "--timeout", "60"]
        let command = try CLIParser.parse([
            "blackout", "--all", "--panelctl-hidden-display", hidden,
            "--panelctl-hidden-display", other
        ] + watched)
        guard case .blackout(let options) = command else { return XCTFail("expected blackout") }
        XCTAssertEqual(options.hiddenDisplayUUIDs, [hidden, other])
        XCTAssertNoThrow(try BlackoutController.validateOptions(options))
        XCTAssertNoThrow(try CLIParser.parse(
            ["blackout", "--display", selected, "--panelctl-hidden-display", hidden] + watched
        ))
        // The source-only overlay counts hidden displays as covered too.
        guard case .blackout(let overlay) = try CLIParser.parse([
            "blackout", "--display", selected, "--panelctl-hidden-mirror-source", selected,
            "--panelctl-hidden-display", hidden
        ] + watched) else { return XCTFail("expected blackout") }
        XCTAssertEqual(overlay.hiddenDisplayUUIDs, [hidden])
        XCTAssertNoThrow(try BlackoutController.validateOptions(overlay))

        let rejected: [[String]] = [
            ["--display", selected, "--panelctl-hidden-display", hidden, "--timeout", "60"],
            ["--display", selected, "--panelctl-hidden-display", "not-a-uuid"] + watched,
            ["--display", selected, "--panelctl-hidden-display", hidden,
             "--panelctl-hidden-display", hidden.lowercased()] + watched,
            ["--display", selected, "--panelctl-hidden-display", selected.lowercased()] + watched,
            ["--display", selected, "--panelctl-hidden-mirror-source", selected,
             "--panelctl-hidden-display", selected] + watched
        ]
        for arguments in rejected {
            XCTAssertThrowsError(try CLIParser.parse(["blackout"] + arguments), "\(arguments)") {
                XCTAssertEqual($0 as? CLIParseError, .invalidHiddenDisplay)
            }
        }
        XCTAssertThrowsError(try CLIParser.parse(["blackout", "--all", "--panelctl-hidden-display"] + watched)) {
            XCTAssertEqual($0 as? CLIParseError, .missingValue("--panelctl-hidden-display"))
        }
        let unwatched = BlackoutOptions(
            selectors: [selected], all: false, idleAfter: nil, timeout: nil, sleepAfter: nil,
            caffeinate: false, hiddenDisplayUUIDs: [hidden]
        )
        XCTAssertThrowsError(try BlackoutController.validateOptions(unwatched)) {
            XCTAssertEqual($0 as? BlackoutError, .invalidHiddenDisplay)
        }
    }

    func testSiblingRuleAndRuleJournalFlagsArePrivateAndStrict() throws {
        let target = "00000000-0000-0000-0000-000000000001"
        let sibling = "00000000-0000-0000-0000-000000000002"
        let ruleID = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
        let valid = [
            "blackout", "--display", target,
            "--panelctl-other-rule-display", sibling,
            "--panelctl-rule", ruleID.uuidString,
            "--watch", "--idle-after", "10", "--timeout", "30"
        ]
        guard case .blackout(let options) = try CLIParser.parse(valid) else {
            return XCTFail("expected blackout options")
        }
        XCTAssertEqual(options.ruleID, ruleID)
        XCTAssertEqual(options.otherRuleDisplayUUIDs, [sibling])
        XCTAssertNoThrow(try BlackoutController.validateOptions(options))

        let invalid: [[String]] = [
            ["--display", target, "--panelctl-other-rule-display", "not-a-uuid"] + ["--watch", "--idle-after", "10"],
            ["--display", target, "--panelctl-other-rule-display", sibling,
             "--panelctl-other-rule-display", sibling.lowercased()] + ["--watch", "--idle-after", "10"],
            ["--display", target, "--panelctl-other-rule-display", target.lowercased()] + ["--watch", "--idle-after", "10"],
            ["--all", "--panelctl-other-rule-display", sibling, "--timeout", "30"],
            ["--display", target, "--panelctl-hidden-display", sibling,
             "--panelctl-other-rule-display", sibling] + ["--watch", "--idle-after", "10"]
        ]
        for arguments in invalid {
            XCTAssertThrowsError(try CLIParser.parse(["blackout"] + arguments)) { error in
                if arguments.contains("--all") {
                    XCTAssertEqual(error as? CLIParseError, .invalidOtherRuleDisplay)
                } else if arguments.contains("--panelctl-hidden-display") {
                    XCTAssertEqual(error as? CLIParseError, .invalidOtherRuleDisplay)
                } else {
                    XCTAssertEqual(error as? CLIParseError, .invalidOtherRuleDisplay)
                }
            }
        }
        XCTAssertThrowsError(try CLIParser.parse([
            "blackout", "--display", target, "--panelctl-other-rule-display"
        ] + ["--watch", "--idle-after", "10"])) {
            XCTAssertEqual($0 as? CLIParseError, .missingValue("--panelctl-other-rule-display"))
        }
        XCTAssertThrowsError(try CLIParser.parse([
            "blackout", "--display", target, "--panelctl-rule", "invalid"
        ])) {
            XCTAssertEqual($0 as? CLIParseError, .invalidRuleID)
        }
        XCTAssertThrowsError(try CLIParser.parse([
            "blackout", "--display", target, "--panelctl-rule", ruleID.uuidString,
            "--panelctl-rule", ruleID.uuidString
        ])) {
            XCTAssertEqual($0 as? CLIParseError, .duplicateOption("--panelctl-rule"))
        }

        let oneShot = try CLIParser.parse([
            "blackout", "--display", target,
            "--panelctl-hidden-display", "00000000-0000-0000-0000-000000000004",
            "--panelctl-other-rule-display", sibling,
            "--panelctl-rule", ruleID.uuidString,
            "--panelctl-run-once", "--blackout-empty-displays", "--timeout", "30"
        ])
        guard case .blackout(let oneShotOptions) = oneShot else {
            return XCTFail("expected one-shot blackout options")
        }
        XCTAssertTrue(oneShotOptions.runOnce)
        XCTAssertFalse(oneShotOptions.watch)
        XCTAssertNoThrow(try BlackoutController.validateOptions(oneShotOptions))
        for extra in [["--watch"], ["--idle-after", "10"]] {
            XCTAssertThrowsError(try CLIParser.parse([
                "blackout", "--display", target, "--panelctl-run-once"
            ] + extra)) {
                XCTAssertEqual($0 as? CLIParseError, .invalidRunOnce)
            }
        }
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
        XCTAssertEqual(try CLIParser.parse(["ddc-input", "--display", "index:2"]), .ddcInput(selector: "index:2", setValue: nil, json: false))
        XCTAssertEqual(try CLIParser.parse(["ddc-input", "--display", "0x5", "--set", "hdmi1", "--json"]), .ddcInput(selector: "0x5", setValue: 0x11, json: true))
        XCTAssertEqual(try CLIParser.parse(["ddc-input", "--display", "1", "--set", "0x0f"]), .ddcInput(selector: "1", setValue: 0x0F, json: false))
        XCTAssertThrowsError(try CLIParser.parse(["ddc-input"])) { XCTAssertEqual($0 as? CLIParseError, .missingValue("--display")) }
        XCTAssertThrowsError(try CLIParser.parse(["ddc-input", "--display", "1", "--set", "0"])) { XCTAssertEqual($0 as? CLIParseError, .invalidInputValue("0")) }
        XCTAssertThrowsError(try CLIParser.parse(["ddc-input", "--display", "1", "--set", "1", "--set", "2"])) { XCTAssertEqual($0 as? CLIParseError, .duplicateOption("--set")) }
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
        XCTAssertEqual(CLIHelp.version, "panelctl 0.8.0")
        XCTAssertTrue(CLIHelp.text(for: "app").contains("snooze --for <duration>"))
        XCTAssertTrue(CLIHelp.text(for: "app").contains("toggle-hide --display <UUID> [--style black-out]"))
        XCTAssertTrue(CLIHelp.text(for: "app").contains(AppControlCommand.blackoutNowMigrationGuidance))
        XCTAssertTrue(CLIHelp.text(for: "app").contains("run-rule --rule <UUID>"))
        XCTAssertTrue(CLIHelp.text(for: "app").contains("rules[].id"))
        XCTAssertTrue(CLIHelp.text(for: "app").contains("runningRule"))
        XCTAssertTrue(CLIHelp.text(for: "app").contains("0 done or no-op"))
        XCTAssertFalse(CLIHelp.text(for: "app").contains("confirmation"), "exit 4 is no longer used")
        XCTAssertTrue(CLIHelp.text(for: "blackout").contains("--watch"))
        XCTAssertTrue(CLIHelp.text(for: "blackout").contains("--dim-to"))
        XCTAssertFalse(CLIHelp.text(for: "blackout").contains("--dim "))
        XCTAssertTrue(CLIHelp.text(for: "blackout").contains("--ignore-playback"))
        XCTAssertTrue(CLIHelp.text(for: "blackout").contains("--defer-camera"))
        XCTAssertTrue(CLIHelp.text(for: "blackout").contains("--keep-blackout-on-input"))
        XCTAssertTrue(CLIHelp.text(for: "blackout").contains("--blackout-empty-displays"))
        XCTAssertTrue(CLIHelp.text(for: "blackout").contains(
            "Hardware dimming applies to inactivity treatment, not empty-display-only blackouts."
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
