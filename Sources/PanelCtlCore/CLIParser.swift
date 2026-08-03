import Foundation

public struct BlackoutOptions: Equatable {
    public let selectors: [String]
    public let all: Bool
    public let idleAfter: TimeInterval?
    public let timeout: TimeInterval?
    public let sleepAfter: TimeInterval?
    public let caffeinate: Bool
    public let keepDisplaysAwake: Bool
    public let watch: Bool
    public let dimDisplays: Bool
    public let deferPlayback: Bool
    public let deferCamera: Bool

    public init(
        selectors: [String],
        all: Bool,
        idleAfter: TimeInterval?,
        timeout: TimeInterval?,
        sleepAfter: TimeInterval?,
        caffeinate: Bool,
        keepDisplaysAwake: Bool = false,
        watch: Bool = false,
        dimDisplays: Bool = false,
        deferPlayback: Bool = true,
        deferCamera: Bool = false
    ) {
        self.selectors = selectors
        self.all = all
        self.idleAfter = idleAfter
        self.timeout = timeout
        self.sleepAfter = sleepAfter
        self.caffeinate = caffeinate
        self.keepDisplaysAwake = keepDisplaysAwake
        self.watch = watch
        self.dimDisplays = dimDisplays
        self.deferPlayback = deferPlayback
        self.deferCamera = deferCamera
    }
}

public enum PanelCommand: Equatable {
    case list(json: Bool)
    case probe(json: Bool)
    case blackout(BlackoutOptions)
    case ddcLuminance(selector: String, setValue: UInt16?, json: Bool)
    case sleepDisplays(keepSystemAwake: Bool, timeout: TimeInterval?)
    case wakeDisplays
    case app(
        command: AppControlCommand,
        durationSeconds: TimeInterval?,
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
    case invalidLuminance
    case missingAppCommand
    case snoozeDurationTooLong

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
        case .invalidLuminance: return "luminance must be an integer from 0 through 65535"
        case .missingAppCommand: return "missing app command (use 'panelctl help app' for usage)"
        case .snoozeDurationTooLong: return "snooze duration must not exceed 30 days"
        }
    }
}

public enum CLIParser {
    private static let maximumSnoozeDuration: TimeInterval = 30 * 24 * 60 * 60
    private static let commands = ["list", "probe", "blackout", "ddc-luminance", "sleep-displays", "wake-displays", "app"]

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
            var json = false
            for option in rest {
                guard option == "--json" else { throw CLIParseError.unknownOption(option) }
                guard !json else { throw CLIParseError.duplicateOption("--json") }
                json = true
            }
            return .list(json: json)
        case "probe":
            var json = false
            for option in rest {
                guard option == "--json" else { throw CLIParseError.unknownOption(option) }
                guard !json else { throw CLIParseError.duplicateOption("--json") }
                json = true
            }
            return .probe(json: json)
        case "blackout":
            return try parseBlackout(rest)
        case "ddc-luminance":
            return try parseDDCLuminance(rest)
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

    private static func parseApp(_ args: [String]) throws -> PanelCommand {
        guard let rawCommand = args.first else { throw CLIParseError.missingAppCommand }
        guard let command = AppControlCommand(rawValue: rawCommand) else {
            throw CLIParseError.unknownCommand(rawCommand)
        }
        var json = false
        var durationSeconds: TimeInterval?
        var i = 1
        while i < args.count {
            switch args[i] {
            case "--json":
                guard !json else {
                    throw CLIParseError.duplicateOption("--json")
                }
                json = true
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
        return .app(
            command: command,
            durationSeconds: durationSeconds,
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
        var dimDisplays = false
        var deferPlayback = true
        var deferCamera = false
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
            case "--dim":
                guard !dimDisplays else { throw CLIParseError.duplicateOption("--dim") }
                dimDisplays = true
            case "--ignore-playback":
                guard deferPlayback else { throw CLIParseError.duplicateOption("--ignore-playback") }
                deferPlayback = false
            case "--defer-camera":
                guard !deferCamera else { throw CLIParseError.duplicateOption("--defer-camera") }
                deferCamera = true
            default:
                throw CLIParseError.unknownOption(args[i])
            }
            i += 1
        }
        if watch && idleAfter == nil { throw CLIParseError.watchRequiresIdleAfter }
        if all && !selectors.isEmpty { throw CLIParseError.conflictingTargets }
        if !all && selectors.isEmpty { throw CLIParseError.noDisplays }
        if timeout != nil && sleepAfter != nil { throw CLIParseError.conflictingBlackoutLimits }
        if keepDisplaysAwake && sleepAfter == nil { throw CLIParseError.keepDisplaysAwakeRequiresSleepAfter }
        if all && timeout == nil && sleepAfter == nil { throw CLIParseError.allRequiresLimit }
        return .blackout(BlackoutOptions(selectors: selectors, all: all, idleAfter: idleAfter, timeout: timeout, sleepAfter: sleepAfter, caffeinate: caffeinate, keepDisplaysAwake: keepDisplaysAwake, watch: watch, dimDisplays: dimDisplays, deferPlayback: deferPlayback, deferCamera: deferCamera))
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
