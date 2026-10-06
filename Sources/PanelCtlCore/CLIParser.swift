import Foundation

public enum BlackoutMode: String, Codable, CaseIterable {
    case blocking
    case working
}

public struct BlackoutOptions: Equatable {
    public let selectors: [String]
    public let all: Bool
    public let idleAfter: TimeInterval?
    public let timeout: TimeInterval?
    public let sleepAfter: TimeInterval?
    public let caffeinate: Bool
    public let keepDisplaysAwake: Bool
    public let watch: Bool
    public let keepBlackoutOnInput: Bool
    public let blackoutEmptyDisplays: Bool
    public let mode: BlackoutMode
    public let overlayOpacityPercent: Int?
    public let hardwareBrightnessPercent: Int?
    public let deferPlayback: Bool
    public let deferCamera: Bool
    public let hiddenMirrorSourceUUIDs: [String]
    public var hiddenMirrorSourceUUID: String? { hiddenMirrorSourceUUIDs.first }
    /// Displays PanelCtl has hidden: blackout never covers them, but counts
    /// them as covered for the all-screens safety rules.
    public let hiddenDisplayUUIDs: [String]

    var effectiveKeepBlackoutOnInput: Bool {
        mode == .working || keepBlackoutOnInput
    }

    /// Hidden displays need --watch and distinct UUIDs that aren't selected.
    var hiddenDisplaysAreValid: Bool {
        guard !hiddenDisplayUUIDs.isEmpty else { return true }
        let keys = hiddenDisplayUUIDs.map { $0.uppercased() }
        return watch &&
            keys.allSatisfy { UUID(uuidString: $0) != nil } &&
            Set(keys).count == keys.count &&
            !selectors.contains { keys.contains($0.uppercased()) }
    }

    public init(
        selectors: [String],
        all: Bool,
        idleAfter: TimeInterval?,
        timeout: TimeInterval?,
        sleepAfter: TimeInterval?,
        caffeinate: Bool,
        keepDisplaysAwake: Bool = false,
        watch: Bool = false,
        blackoutEmptyDisplays: Bool = false,
        keepBlackoutOnInput: Bool = false,
        mode: BlackoutMode = .blocking,
        overlayOpacityPercent: Int? = 100,
        hardwareBrightnessPercent: Int? = nil,
        deferPlayback: Bool = true,
        deferCamera: Bool = false,
        hiddenMirrorSourceUUID: String? = nil,
        hiddenMirrorSourceUUIDs: [String] = [],
        hiddenDisplayUUIDs: [String] = []
    ) {
        self.selectors = selectors
        self.all = all
        self.idleAfter = idleAfter
        self.timeout = timeout
        self.sleepAfter = sleepAfter
        self.caffeinate = caffeinate
        self.keepDisplaysAwake = keepDisplaysAwake
        self.watch = watch
        self.blackoutEmptyDisplays = blackoutEmptyDisplays
        self.keepBlackoutOnInput = keepBlackoutOnInput
        self.mode = mode
        self.overlayOpacityPercent = overlayOpacityPercent
        self.hardwareBrightnessPercent = hardwareBrightnessPercent
        self.deferPlayback = deferPlayback
        self.deferCamera = deferCamera
        self.hiddenMirrorSourceUUIDs = hiddenMirrorSourceUUIDs.isEmpty
            ? hiddenMirrorSourceUUID.map { [$0] } ?? [] : hiddenMirrorSourceUUIDs
        self.hiddenDisplayUUIDs = hiddenDisplayUUIDs
    }
}

public enum PanelCommand: Equatable {
    case list(json: Bool)
    case probe(json: Bool)
    case mirror(selector: String, source: String, journalPath: String?)
    case unmirror(journalPath: String?)
    case unmirrorTarget(selector: String, journalPath: String?)
    case away(selector: String, source: String, input: UInt8?, journalPath: String?)
    case back(selector: String, input: UInt8?, journalPath: String?)
    case recovery(action: RecoveryAction, timeout: TimeInterval?, journalPath: String?)
    case recoverySelected(action: RecoveryAction, timeout: TimeInterval?, selector: String, journalPath: String?)
    case recoveryHelper(journalPath: String, id: UUID)
    case recoveryDisable(selector: String, timeout: TimeInterval, journalPath: String?)
    case blackout(BlackoutOptions)
    case ddcLuminance(selector: String, setValue: UInt16?, json: Bool)
    case ddcInput(selector: String, setValue: UInt8?, json: Bool)
    case ddcPower(selector: String, value: DDCPowerValue?, acceptedRisk: Bool, json: Bool)
    case sleepDisplays(keepSystemAwake: Bool, timeout: TimeInterval?)
    case wakeDisplays
    case app(
        command: AppControlCommand,
        durationSeconds: TimeInterval?,
        targetUUID: String? = nil,
        json: Bool
    )
    case help(command: String?)
    case version
}

public enum CLIParseError: Error, Equatable, CustomStringConvertible {
    case missingCommand
    case unknownCommand(String)
    case unknownOption(String)
    case missingValue(String)
    case invalidDuration(option: String, value: String)
    case noDisplays
    case timeoutRequiresKeepAwake
    case keepDisplaysAwakeRequiresSleepAfter
    case duplicateOption(String)
    case invalidIndex
    case conflictingTargets
    case conflictingBlackoutLimits
    case allRequiresLimit
    case watchRequiresIdleAfter
    case emptyDisplayBlackoutRequiresWatch
    case persistentDimming
    case invalidLuminance
    case invalidInputValue(String)
    case invalidPowerValue(String)
    case powerConsentRequired
    case missingAppCommand
    case missingRecoveryAction
    case invalidRecoveryTimeout
    case disableRequirements
    case mirrorRequirements
    case unmirrorRequirements
    case handoffRequirements(String)
    case snoozeDurationTooLong
    case invalidBlackoutMode(String)
    case invalidOverlayOpacity(String)
    case invalidHardwareBrightness(String)
    case conflictingOverlayOptions
    case workingOverlayRequired
    case invalidHiddenMirrorSourceOverlay
    case invalidHiddenDisplay
    public var description: String {
        switch self {
        case .missingCommand: return "missing command (use 'panelctl help' for usage)"
        case .unknownCommand(let command): return "unknown command: \(command)"
        case .unknownOption(let option): return "unknown option: \(option)"
        case .missingValue(let option): return "missing value for \(option)"
        case .invalidDuration(let option, let value):
            return "invalid duration for \(option): \(value) (expected positive seconds with optional s, m, or h suffix)"
        case .noDisplays: return "blackout requires at least one --display or --index selector"
        case .timeoutRequiresKeepAwake: return "--timeout requires --keep-system-awake"
        case .keepDisplaysAwakeRequiresSleepAfter: return "--keep-displays-awake requires --sleep-after"
        case .duplicateOption(let option): return "option may only be supplied once: \(option)"
        case .invalidIndex: return "display index must be a positive integer"
        case .conflictingTargets: return "--all cannot be combined with --display or --index"
        case .conflictingBlackoutLimits: return "--timeout and --sleep-after are mutually exclusive"
        case .allRequiresLimit: return "--all requires --timeout or --sleep-after"
        case .watchRequiresIdleAfter: return "--watch requires --idle-after"
        case .emptyDisplayBlackoutRequiresWatch:
            return "--blackout-empty-displays requires --watch"
        case .persistentDimming: return "--keep-blackout-on-input cannot be combined with --dim-to in blocking mode"
        case .invalidBlackoutMode(let value):
            return "invalid blackout mode: \(value) (expected blocking or working)"
        case .invalidOverlayOpacity(let value):
            return "invalid overlay opacity: \(value) (expected an integer from 1 through 100)"
        case .invalidHardwareBrightness(let value):
            return "invalid hardware brightness: \(value) (expected an integer from 0 through 100)"
        case .conflictingOverlayOptions:
            return "--no-overlay cannot be combined with --overlay-opacity"
        case .workingOverlayRequired:
            return "--no-overlay or overlay opacity below 100 requires --mode working"
        case .invalidHiddenMirrorSourceOverlay:
            return "--panelctl-hidden-mirror-source requires a single matching UUID target, --watch, --idle-after, and a finite --timeout; it cannot be combined with all-screen, sleep, dimming, or display-awake options"
        case .invalidHiddenDisplay:
            return "--panelctl-hidden-display requires --watch and a distinct UUID that isn't a --display target"
        case .invalidLuminance: return "luminance must be an integer from 0 through 65535"
        case .invalidInputValue(let value):
            return "invalid input value: \(value) (expected dp1, dp2, hdmi1, hdmi2, or 1 through 255; hex with 0x)"
        case .invalidPowerValue(let value): return "invalid power value: \(value) (expected on or off; no raw values)"
        case .powerConsentRequired: return String(describing: DDCPowerError.consentRequired)
        case .missingAppCommand: return "missing app command (use 'panelctl help app' for usage)"
        case .missingRecoveryAction: return "missing recovery action (use 'panelctl help recovery' for usage)"
        case .invalidRecoveryTimeout: return "recovery watchdog timeout must be from 1 through 60 seconds"
        case .disableRequirements: return "disable requires exactly one --display or --index, --consent-disable, and --timeout (1–60 seconds)"
        case .mirrorRequirements: return "mirror requires --display, --source and --consent-mirror"
        case .unmirrorRequirements: return "unmirror requires --consent-unmirror (restores the journaled topology)"
        case .handoffRequirements(let command):
            return "\(command) requires --display and --consent-\(command)" + (command == "away" ? " and --source" : "")
        case .snoozeDurationTooLong: return "snooze duration must not exceed 30 days"
        }
    }
}

public enum CLIParser {
    private static let maximumSnoozeDuration: TimeInterval = 30 * 24 * 60 * 60
    private static let commands = ["list", "probe", "recovery", "mirror", "unmirror", "away", "back", "blackout", "ddc-luminance", "ddc-input", "ddc-power", "sleep-displays", "wake-displays", "app"]

    public static func parse(_ args: [String]) throws -> PanelCommand {
        guard let command = args.first else { throw CLIParseError.missingCommand }
        let rest = Array(args.dropFirst())

        if command == "--version" { guard rest.isEmpty else { throw CLIParseError.unknownOption(rest[0]) }; return .version }
        if command == "--help" || command == "-h" { guard rest.isEmpty else { throw CLIParseError.unknownOption(rest[0]) }; return .help(command: nil) }
        if command == "help" {
            guard rest.count <= 1 else { throw CLIParseError.unknownOption(rest[1]) }
            guard let requested = rest.first else { return .help(command: nil) }
            if requested == "-h" || requested == "--help" { return .help(command: nil) }
            guard commands.contains(requested) else { throw CLIParseError.unknownCommand(requested) }
            return .help(command: requested)
        }

        // A command-specific help flag is a zero-exit parse command. Keep it
        // deliberately strict so typos in a command's other options are not
        // hidden by help handling.
        if rest.count == 1 && (rest[0] == "--help" || rest[0] == "-h") {
            guard commands.contains(command) else { throw CLIParseError.unknownCommand(command) }
            return .help(command: command)
        }

        switch command {
        case "list":
            return try parseJSONFlagCommand(rest, builder: { .list(json: $0) })
        case "probe":
            return try parseJSONFlagCommand(rest, builder: { .probe(json: $0) })
        case "recovery":
            return try parseRecovery(rest)
        case "mirror", "unmirror":
            return try parseMirror(rest, restore: command == "unmirror")
        case "away", "back":
            return try parseHandoff(rest, command: command)
        case "_recovery-helper":
            guard rest.count == 4, rest[0] == "--journal", !rest[1].isEmpty,
                  rest[2] == "--id", let id = UUID(uuidString: rest[3]) else {
                throw CLIParseError.unknownCommand("invalid internal recovery-helper invocation")
            }
            return .recoveryHelper(journalPath: rest[1], id: id)
        case "blackout":
            return try parseBlackout(rest)
        case "ddc-luminance":
            return try parseDDCLuminance(rest)
        case "ddc-input":
            return try parseDDCInput(rest)
        case "ddc-power":
            return try parseDDCPower(rest)
        case "sleep-displays":
            return try parseSleepDisplays(rest)
        case "wake-displays":
            guard rest.isEmpty else { throw CLIParseError.unknownOption(rest[0]) }
            return .wakeDisplays
        case "app":
            return try parseApp(rest)
        default:
            throw CLIParseError.unknownCommand(command)
        }
    }

    private static func parseHandoff(_ args: [String], command: String) throws -> PanelCommand {
        var values: [String: String] = [:]
        var consent = false
        let valueFlags = ["--display", "--journal", "--input"] + (command == "away" ? ["--source"] : [])
        var i = 0
        while i < args.count {
            let option = args[i]
            if option == "--consent-\(command)" {
                guard !consent else { throw CLIParseError.duplicateOption(option) }
                consent = true
            } else if valueFlags.contains(option) {
                guard values[option] == nil else { throw CLIParseError.duplicateOption(option) }
                i += 1
                guard i < args.count, !args[i].isEmpty, !args[i].hasPrefix("--") else {
                    throw CLIParseError.missingValue(option)
                }
                values[option] = args[i]
            } else {
                throw CLIParseError.unknownOption(option)
            }
            i += 1
        }
        guard consent, let selector = values["--display"] else { throw CLIParseError.handoffRequirements(command) }
        var input: UInt8?
        if let raw = values["--input"] {
            guard let parsed = DDCInput.parseValue(raw) else { throw CLIParseError.invalidInputValue(raw) }
            input = parsed
        }
        if command == "back" { return .back(selector: selector, input: input, journalPath: values["--journal"]) }
        guard let source = values["--source"] else { throw CLIParseError.handoffRequirements(command) }
        return .away(selector: selector, source: source, input: input, journalPath: values["--journal"])
    }

    private static func parseMirror(_ args: [String], restore: Bool) throws -> PanelCommand {
        var values: [String: String] = [:]
        var consent = false
        let consentFlag = restore ? "--consent-unmirror" : "--consent-mirror"
        let valueFlags = restore ? ["--journal", "--display"] : ["--display", "--source", "--journal"]
        var i = 0
        while i < args.count {
            let option = args[i]
            if option == consentFlag {
                guard !consent else { throw CLIParseError.duplicateOption(option) }
                consent = true
            } else if valueFlags.contains(option) {
                guard values[option] == nil else { throw CLIParseError.duplicateOption(option) }
                i += 1
                guard i < args.count, !args[i].isEmpty, !args[i].hasPrefix("--") else {
                    throw CLIParseError.missingValue(option)
                }
                values[option] = args[i]
            } else {
                throw CLIParseError.unknownOption(option)
            }
            i += 1
        }
        if restore {
            guard consent else { throw CLIParseError.unmirrorRequirements }
            if let selector = values["--display"] {
                return .unmirrorTarget(selector: selector, journalPath: values["--journal"])
            }
            return .unmirror(journalPath: values["--journal"])
        }
        guard consent, let target = values["--display"], let source = values["--source"] else {
            throw CLIParseError.mirrorRequirements
        }
        return .mirror(selector: target, source: source, journalPath: values["--journal"])
    }

    private static func parseRecovery(_ args: [String]) throws -> PanelCommand {
        guard let raw = args.first else { throw CLIParseError.missingRecoveryAction }
        if raw == "disable" { return try parseDisable(Array(args.dropFirst())) }
        guard let action = RecoveryAction(rawValue: raw) else { throw CLIParseError.unknownCommand(raw) }
        var timeout: TimeInterval?
        var journal: String?
        var selector: String?
        var i = 1
        while i < args.count {
            switch args[i] {
            case "--timeout":
                guard action == .rehearse || action == .guard else { throw CLIParseError.unknownOption(args[i]) }
                guard timeout == nil else { throw CLIParseError.duplicateOption(args[i]) }
                timeout = try duration(option: "--timeout", args: args, index: &i)
                guard (1...60).contains(timeout!) else { throw CLIParseError.invalidRecoveryTimeout }
            case "--journal":
                guard journal == nil else { throw CLIParseError.duplicateOption(args[i]) }
                i += 1
                guard i < args.count, !args[i].hasPrefix("--"), !args[i].isEmpty else {
                    throw CLIParseError.missingValue("--journal")
                }
                journal = args[i]
            case "--display":
                guard action == .verify || action == .restore else { throw CLIParseError.unknownOption(args[i]) }
                guard selector == nil else { throw CLIParseError.duplicateOption(args[i]) }
                i += 1
                guard i < args.count, !args[i].hasPrefix("--"), !args[i].isEmpty else {
                    throw CLIParseError.missingValue("--display")
                }
                selector = args[i]
            default: throw CLIParseError.unknownOption(args[i])
            }
            i += 1
        }
        if let selector {
            return .recoverySelected(action: action, timeout: timeout, selector: selector, journalPath: journal)
        }
        return .recovery(action: action, timeout: timeout, journalPath: journal)
    }

    private static func parseDisable(_ args: [String]) throws -> PanelCommand {
        var selector: String?
        var timeout: TimeInterval?
        var journal: String?
        var consent = false
        var i = 0
        while i < args.count {
            let option = args[i]
            switch option {
            case "--display", "--index":
                guard selector == nil else { throw CLIParseError.disableRequirements }
                i += 1
                guard i < args.count, !args[i].hasPrefix("-"), !args[i].isEmpty else {
                    throw CLIParseError.missingValue(option)
                }
                if option == "--index" {
                    guard let index = Int(args[i]), index > 0 else { throw CLIParseError.invalidIndex }
                    selector = "index:\(index)"
                } else { selector = args[i] }
            case "--consent-disable":
                guard !consent else { throw CLIParseError.duplicateOption(option) }
                consent = true
            case "--timeout":
                guard timeout == nil else { throw CLIParseError.duplicateOption(option) }
                timeout = try duration(option: option, args: args, index: &i)
                guard let timeout, (1...60).contains(timeout) else { throw CLIParseError.invalidRecoveryTimeout }
            case "--journal":
                guard journal == nil else { throw CLIParseError.duplicateOption(option) }
                i += 1
                guard i < args.count, !args[i].hasPrefix("-"), !args[i].isEmpty else {
                    throw CLIParseError.missingValue(option)
                }
                journal = args[i]
            default: throw CLIParseError.unknownOption(option)
            }
            i += 1
        }
        guard consent, let selector, let timeout else { throw CLIParseError.disableRequirements }
        return .recoveryDisable(selector: selector, timeout: timeout, journalPath: journal)
    }

    private static func parseJSONFlagCommand(
        _ args: [String],
        builder: (Bool) -> PanelCommand
    ) throws -> PanelCommand {
        var json = false
        for option in args {
            guard option == "--json" else { throw CLIParseError.unknownOption(option) }
            guard !json else { throw CLIParseError.duplicateOption("--json") }
            json = true
        }
        return builder(json)
    }

    private static func parseApp(_ args: [String]) throws -> PanelCommand {
        guard let rawCommand = args.first else { throw CLIParseError.missingAppCommand }
        guard let command = AppControlCommand(rawValue: rawCommand) else {
            throw CLIParseError.unknownCommand(rawCommand)
        }
        var json = false
        var durationSeconds: TimeInterval?
        var targetUUID: String?
        var i = 1
        while i < args.count {
            switch args[i] {
            case "--json":
                guard !json else {
                    throw CLIParseError.duplicateOption("--json")
                }
                json = true
            case "--display":
                guard command.isDisplayCommand else {
                    throw CLIParseError.unknownOption("--display")
                }
                guard targetUUID == nil else { throw CLIParseError.duplicateOption("--display") }
                i += 1
                guard i < args.count, UUID(uuidString: args[i]) != nil else {
                    throw CLIParseError.missingValue("--display (UUID)")
                }
                targetUUID = args[i]
            case "--for":
                guard command == .snooze else {
                    throw CLIParseError.unknownOption("--for")
                }
                guard durationSeconds == nil else {
                    throw CLIParseError.duplicateOption("--for")
                }
                let value = try duration(
                    option: "--for",
                    args: args,
                    index: &i
                )
                guard value <= maximumSnoozeDuration else {
                    throw CLIParseError.snoozeDurationTooLong
                }
                durationSeconds = value
            default:
                throw CLIParseError.unknownOption(args[i])
            }
            i += 1
        }
        if command == .snooze, durationSeconds == nil {
            throw CLIParseError.missingValue("--for")
        }
        if command.isDisplayCommand, targetUUID == nil {
            throw CLIParseError.missingValue("--display")
        }
        return .app(
            command: command,
            durationSeconds: durationSeconds,
            targetUUID: targetUUID,
            json: json
        )
    }

    private static func parseBlackout(_ args: [String]) throws -> PanelCommand {
        var selectors: [String] = []
        var all = false
        var idleAfter: TimeInterval?
        var timeout: TimeInterval?
        var sleepAfter: TimeInterval?
        var caffeinate = false
        var keepDisplaysAwake = false
        var watch = false
        var blackoutEmptyDisplays = false
        var keepBlackoutOnInput = false
        var mode: BlackoutMode = .blocking
        var modeSupplied = false
        var overlayOpacityPercent: Int? = 100
        var overlayOpacitySupplied = false
        var noOverlay = false
        var hardwareBrightnessPercent: Int?
        var deferPlayback = true
        var deferCamera = false
        var hiddenMirrorSourceUUIDs: [String] = []
        var hiddenDisplayUUIDs: [String] = []
        var i = 0
        while i < args.count {
            switch args[i] {
            case "--display":
                i += 1
                guard i < args.count, !args[i].hasPrefix("--"), !args[i].isEmpty else { throw CLIParseError.missingValue("--display") }
                selectors.append(args[i])
            case "--index":
                i += 1
                guard i < args.count, !args[i].hasPrefix("--") else { throw CLIParseError.missingValue("--index") }
                guard let index = Int(args[i]), index > 0 else { throw CLIParseError.invalidIndex }
                selectors.append("index:\(index)")
            case "--all":
                guard !all else { throw CLIParseError.duplicateOption("--all") }
                all = true
            case "--idle-after":
                guard idleAfter == nil else { throw CLIParseError.duplicateOption("--idle-after") }
                idleAfter = try duration(option: "--idle-after", args: args, index: &i)
            case "--timeout":
                guard timeout == nil else { throw CLIParseError.duplicateOption("--timeout") }
                timeout = try duration(option: "--timeout", args: args, index: &i)
            case "--sleep-after":
                guard sleepAfter == nil else { throw CLIParseError.duplicateOption("--sleep-after") }
                sleepAfter = try duration(option: "--sleep-after", args: args, index: &i)
            case "--caffeinate":
                guard !caffeinate else { throw CLIParseError.duplicateOption("--caffeinate") }
                caffeinate = true
            case "--keep-displays-awake":
                guard !keepDisplaysAwake else { throw CLIParseError.duplicateOption("--keep-displays-awake") }
                keepDisplaysAwake = true
            case "--watch":
                guard !watch else { throw CLIParseError.duplicateOption("--watch") }
                watch = true
            case "--blackout-empty-displays":
                guard !blackoutEmptyDisplays else {
                    throw CLIParseError.duplicateOption("--blackout-empty-displays")
                }
                blackoutEmptyDisplays = true
            case "--keep-blackout-on-input":
                guard !keepBlackoutOnInput else {
                    throw CLIParseError.duplicateOption("--keep-blackout-on-input")
                }
                keepBlackoutOnInput = true
            case "--mode":
                guard !modeSupplied else { throw CLIParseError.duplicateOption("--mode") }
                modeSupplied = true
                i += 1
                guard i < args.count, !args[i].hasPrefix("--") else {
                    throw CLIParseError.missingValue("--mode")
                }
                guard let parsed = BlackoutMode(rawValue: args[i]) else {
                    throw CLIParseError.invalidBlackoutMode(args[i])
                }
                mode = parsed
            case "--overlay-opacity":
                guard !overlayOpacitySupplied else {
                    throw CLIParseError.duplicateOption("--overlay-opacity")
                }
                overlayOpacitySupplied = true
                overlayOpacityPercent = try percentage(
                    option: "--overlay-opacity",
                    args: args,
                    index: &i,
                    range: 1...100
                ) { CLIParseError.invalidOverlayOpacity($0) }
            case "--no-overlay":
                guard !noOverlay else { throw CLIParseError.duplicateOption("--no-overlay") }
                noOverlay = true
                overlayOpacityPercent = nil
            case "--dim-to":
                guard hardwareBrightnessPercent == nil else {
                    throw CLIParseError.duplicateOption("--dim-to")
                }
                hardwareBrightnessPercent = try percentage(
                    option: "--dim-to",
                    args: args,
                    index: &i,
                    range: 0...100
                ) { CLIParseError.invalidHardwareBrightness($0) }
            case "--ignore-playback":
                guard deferPlayback else { throw CLIParseError.duplicateOption("--ignore-playback") }
                deferPlayback = false
            case "--defer-camera":
                guard !deferCamera else { throw CLIParseError.duplicateOption("--defer-camera") }
                deferCamera = true
            case "--panelctl-hidden-mirror-source":
                i += 1
                guard i < args.count, !args[i].hasPrefix("--") else {
                    throw CLIParseError.missingValue("--panelctl-hidden-mirror-source")
                }
                hiddenMirrorSourceUUIDs.append(args[i])
            case "--panelctl-hidden-display":
                i += 1
                guard i < args.count, !args[i].hasPrefix("--") else {
                    throw CLIParseError.missingValue("--panelctl-hidden-display")
                }
                hiddenDisplayUUIDs.append(args[i])
            default:
                throw CLIParseError.unknownOption(args[i])
            }
            i += 1
        }
        if blackoutEmptyDisplays && !watch {
            throw CLIParseError.emptyDisplayBlackoutRequiresWatch
        }
        if noOverlay && overlayOpacitySupplied { throw CLIParseError.conflictingOverlayOptions }
        if mode == .blocking && overlayOpacityPercent != 100 {
            throw CLIParseError.workingOverlayRequired
        }
        if mode == .blocking && keepBlackoutOnInput && hardwareBrightnessPercent != nil {
            throw CLIParseError.persistentDimming
        }
        if watch && idleAfter == nil { throw CLIParseError.watchRequiresIdleAfter }
        if all && !selectors.isEmpty { throw CLIParseError.conflictingTargets }
        if !all && selectors.isEmpty { throw CLIParseError.noDisplays }
        if timeout != nil && sleepAfter != nil { throw CLIParseError.conflictingBlackoutLimits }
        if keepDisplaysAwake && sleepAfter == nil { throw CLIParseError.keepDisplaysAwakeRequiresSleepAfter }
        if all && timeout == nil && sleepAfter == nil { throw CLIParseError.allRequiresLimit }
        if !hiddenMirrorSourceUUIDs.isEmpty {
            let sourceKeys = hiddenMirrorSourceUUIDs.map { $0.lowercased() }
            guard sourceKeys.allSatisfy({ UUID(uuidString: $0) != nil }),
                  Set(sourceKeys).count == sourceKeys.count,
                  !all, selectors.count == sourceKeys.count,
                  selectors.allSatisfy({ selector in sourceKeys.contains(where: { selector.caseInsensitiveCompare($0) == .orderedSame }) }),
                  watch, idleAfter != nil, timeout != nil, sleepAfter == nil,
                  !caffeinate, !keepDisplaysAwake, !blackoutEmptyDisplays,
                  mode == .blocking, overlayOpacityPercent == 100,
                  hardwareBrightnessPercent == nil else {
                throw CLIParseError.invalidHiddenMirrorSourceOverlay
            }
        }
        let options = BlackoutOptions(
            selectors: selectors,
            all: all,
            idleAfter: idleAfter,
            timeout: timeout,
            sleepAfter: sleepAfter,
            caffeinate: caffeinate,
            keepDisplaysAwake: keepDisplaysAwake,
            watch: watch,
            blackoutEmptyDisplays: blackoutEmptyDisplays,
            keepBlackoutOnInput: keepBlackoutOnInput,
            mode: mode,
            overlayOpacityPercent: overlayOpacityPercent,
            hardwareBrightnessPercent: hardwareBrightnessPercent,
            deferPlayback: deferPlayback,
            deferCamera: deferCamera,
            hiddenMirrorSourceUUIDs: hiddenMirrorSourceUUIDs,
            hiddenDisplayUUIDs: hiddenDisplayUUIDs
        )
        guard options.hiddenDisplaysAreValid else { throw CLIParseError.invalidHiddenDisplay }
        return .blackout(options)
    }

    private static func parseDDCLuminance(_ args: [String]) throws -> PanelCommand {
        var selector: String?
        var setValue: UInt16?
        var json = false
        var i = 0
        while i < args.count {
            switch args[i] {
            case "--display":
                guard selector == nil else { throw CLIParseError.duplicateOption("--display") }
                i += 1
                guard i < args.count, !args[i].hasPrefix("--"), !args[i].isEmpty else { throw CLIParseError.missingValue("--display") }
                selector = args[i]
            case "--set":
                guard setValue == nil else { throw CLIParseError.duplicateOption("--set") }
                i += 1
                guard i < args.count, !args[i].hasPrefix("--") else { throw CLIParseError.missingValue("--set") }
                guard let value = UInt16(args[i]) else { throw CLIParseError.invalidLuminance }
                setValue = value
            case "--json":
                guard !json else { throw CLIParseError.duplicateOption("--json") }
                json = true
            default:
                throw CLIParseError.unknownOption(args[i])
            }
            i += 1
        }
        guard let selector else { throw CLIParseError.missingValue("--display") }
        return .ddcLuminance(selector: selector, setValue: setValue, json: json)
    }

    private static func parseDDCInput(_ args: [String]) throws -> PanelCommand {
        var selector: String?
        var setValue: UInt8?
        var json = false
        var i = 0
        while i < args.count {
            switch args[i] {
            case "--display":
                guard selector == nil else { throw CLIParseError.duplicateOption("--display") }
                i += 1
                guard i < args.count, !args[i].hasPrefix("--"), !args[i].isEmpty else { throw CLIParseError.missingValue("--display") }
                selector = args[i]
            case "--set":
                guard setValue == nil else { throw CLIParseError.duplicateOption("--set") }
                i += 1
                guard i < args.count, !args[i].hasPrefix("--") else { throw CLIParseError.missingValue("--set") }
                guard let value = DDCInput.parseValue(args[i]) else { throw CLIParseError.invalidInputValue(args[i]) }
                setValue = value
            case "--json":
                guard !json else { throw CLIParseError.duplicateOption("--json") }
                json = true
            default:
                throw CLIParseError.unknownOption(args[i])
            }
            i += 1
        }
        guard let selector else { throw CLIParseError.missingValue("--display") }
        return .ddcInput(selector: selector, setValue: setValue, json: json)
    }

    private static func parseDDCPower(_ args: [String]) throws -> PanelCommand {
        var selector: String?
        var value: DDCPowerValue?
        var acceptedRisk = false
        var json = false
        var i = 0
        while i < args.count {
            switch args[i] {
            case "--display":
                guard selector == nil else { throw CLIParseError.duplicateOption("--display") }
                i += 1
                guard i < args.count, !args[i].hasPrefix("--"), !args[i].isEmpty else { throw CLIParseError.missingValue("--display") }
                selector = args[i]
            case "--set":
                guard value == nil else { throw CLIParseError.duplicateOption("--set") }
                i += 1
                guard i < args.count, !args[i].hasPrefix("--") else { throw CLIParseError.missingValue("--set") }
                guard let parsed = DDCPowerValue(rawValue: args[i].lowercased()) else { throw CLIParseError.invalidPowerValue(args[i]) }
                value = parsed
            case "--accept-power-risk":
                guard !acceptedRisk else { throw CLIParseError.duplicateOption("--accept-power-risk") }
                acceptedRisk = true
            case "--json":
                guard !json else { throw CLIParseError.duplicateOption("--json") }
                json = true
            default:
                throw CLIParseError.unknownOption(args[i])
            }
            i += 1
        }
        guard let selector else { throw CLIParseError.missingValue("--display") }
        guard value != .off || acceptedRisk else { throw CLIParseError.powerConsentRequired }
        return .ddcPower(selector: selector, value: value, acceptedRisk: acceptedRisk, json: json)
    }

    private static func parseSleepDisplays(_ args: [String]) throws -> PanelCommand {
        var keepSystemAwake = false
        var timeout: TimeInterval?
        var i = 0
        while i < args.count {
            switch args[i] {
            case "--keep-system-awake":
                guard !keepSystemAwake else { throw CLIParseError.duplicateOption("--keep-system-awake") }
                keepSystemAwake = true
            case "--timeout":
                guard timeout == nil else { throw CLIParseError.duplicateOption("--timeout") }
                timeout = try duration(option: "--timeout", args: args, index: &i)
            default:
                throw CLIParseError.unknownOption(args[i])
            }
            i += 1
        }
        if timeout != nil && !keepSystemAwake { throw CLIParseError.timeoutRequiresKeepAwake }
        return .sleepDisplays(keepSystemAwake: keepSystemAwake, timeout: timeout)
    }

    private static func percentage(
        option: String,
        args: [String],
        index: inout Int,
        range: ClosedRange<Int>,
        error: (String) -> CLIParseError
    ) throws -> Int {
        index += 1
        guard index < args.count, !args[index].hasPrefix("--") else {
            throw CLIParseError.missingValue(option)
        }
        let raw = args[index]
        guard raw.range(of: "^[0-9]+$", options: .regularExpression) != nil,
              let value = Int(raw),
              range.contains(value) else {
            throw error(raw)
        }
        return value
    }

    private static func duration(option: String, args: [String], index: inout Int) throws -> TimeInterval {
        index += 1
        guard index < args.count, !args[index].hasPrefix("--") else { throw CLIParseError.missingValue(option) }
        let raw = args[index]
        guard raw.range(
            of: "^[0-9]+(?:\\.[0-9]+)?(?:[sSmMhH])?$",
            options: .regularExpression
        ) != nil else {
            throw CLIParseError.invalidDuration(option: option, value: raw)
        }
        let last = raw.last.map { String($0).lowercased() }
        let suffix = last.flatMap { ["s", "m", "h"].contains($0) ? $0 : nil }
        let number = suffix == nil ? raw : String(raw.dropLast())
        guard let base = Double(number), base > 0, base.isFinite else {
            throw CLIParseError.invalidDuration(option: option, value: raw)
        }
        let multiplier: Double
        switch suffix {
        case "m": multiplier = 60
        case "h": multiplier = 3600
        default: multiplier = 1
        }
        let value = base * multiplier
        guard value > 0, value.isFinite else {
            throw CLIParseError.invalidDuration(option: option, value: raw)
        }
        return value
    }
}
