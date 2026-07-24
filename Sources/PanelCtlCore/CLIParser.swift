import Foundation

public struct BlackoutOptions: Equatable {
    public let selectors: [String]
    public let all: Bool
    public let idleAfter: TimeInterval?
    public let timeout: TimeInterval?
    public let sleepAfter: TimeInterval?
    public let caffeinate: Bool
}

public enum PanelCommand: Equatable {
    case list(json: Bool)
    case probe(json: Bool)
    case blackout(BlackoutOptions)
    case ddcLuminance(selector: String, setValue: UInt16?, json: Bool)
    case sleepDisplays(keepSystemAwake: Bool, timeout: TimeInterval?)
    case wakeDisplays
}

public enum CLIParseError: Error, Equatable, CustomStringConvertible {
    case missingCommand
    case unknownCommand(String)
    case unknownOption(String)
    case missingValue(String)
    case invalidTimeout
    case noDisplays
    case timeoutRequiresKeepAwake
    case duplicateOption(String)
    case invalidIndex
    case conflictingTargets
    case conflictingBlackoutLimits
    case allRequiresLimit
    case invalidLuminance

    public var description: String {
        switch self {
        case .missingCommand: return "missing command (list, probe, blackout, ddc-luminance, sleep-displays, or wake-displays)"
        case .unknownCommand(let s): return "unknown command: \(s)"
        case .unknownOption(let s): return "unknown option: \(s)"
        case .missingValue(let s): return "missing value for \(s)"
        case .invalidTimeout: return "timeout must be a positive number of seconds"
        case .noDisplays: return "blackout requires at least one --display selector"
        case .timeoutRequiresKeepAwake: return "--timeout requires --keep-system-awake"
        case .duplicateOption(let option): return "option may only be supplied once: \(option)"
        case .invalidIndex: return "display index must be a positive integer"
        case .conflictingTargets: return "--all cannot be combined with --display or --index"
        case .conflictingBlackoutLimits: return "--timeout and --sleep-after are mutually exclusive"
        case .allRequiresLimit: return "--all requires --timeout or --sleep-after"
        case .invalidLuminance: return "luminance must be an integer from 0 through 65535"
        }
    }
}

public enum CLIParser {
    public static func parse(_ args: [String]) throws -> PanelCommand {
        guard let command = args.first else { throw CLIParseError.missingCommand }
        let rest = Array(args.dropFirst())
        switch command {
        case "list":
            guard rest.allSatisfy({ $0 == "--json" }) else {
                throw CLIParseError.unknownOption(rest.first(where: { $0 != "--json" })!)
            }
            return .list(json: rest.contains("--json"))
        case "probe":
            guard rest.allSatisfy({ $0 == "--json" }) else {
                throw CLIParseError.unknownOption(rest.first(where: { $0 != "--json" })!)
            }
            return .probe(json: rest.contains("--json"))
        case "blackout":
            var selectors: [String] = []
            var all = false
            var idleAfter: TimeInterval?
            var timeout: TimeInterval?
            var sleepAfter: TimeInterval?
            var caffeinate = false
            var i = 0
            while i < rest.count {
                switch rest[i] {
                case "--display":
                    i += 1
                    guard i < rest.count, !rest[i].hasPrefix("--"), !rest[i].isEmpty else { throw CLIParseError.missingValue("--display") }
                    selectors.append(rest[i])
                case "--index":
                    i += 1
                    guard i < rest.count, !rest[i].hasPrefix("--") else { throw CLIParseError.missingValue("--index") }
                    guard let index = Int(rest[i]), index > 0 else { throw CLIParseError.invalidIndex }
                    selectors.append("index:\(index)")
                case "--all":
                    guard !all else { throw CLIParseError.duplicateOption("--all") }
                    all = true
                case "--idle-after":
                    guard idleAfter == nil else { throw CLIParseError.duplicateOption("--idle-after") }
                    i += 1
                    guard i < rest.count, !rest[i].hasPrefix("--") else { throw CLIParseError.missingValue("--idle-after") }
                    guard let value = TimeInterval(rest[i]), value > 0, value.isFinite else { throw CLIParseError.invalidTimeout }
                    idleAfter = value
                case "--timeout":
                    guard timeout == nil else { throw CLIParseError.duplicateOption("--timeout") }
                    i += 1
                    guard i < rest.count, !rest[i].hasPrefix("--") else { throw CLIParseError.missingValue("--timeout") }
                    guard let value = TimeInterval(rest[i]), value > 0, value.isFinite else { throw CLIParseError.invalidTimeout }
                    timeout = value
                case "--sleep-after":
                    guard sleepAfter == nil else { throw CLIParseError.duplicateOption("--sleep-after") }
                    i += 1
                    guard i < rest.count, !rest[i].hasPrefix("--") else { throw CLIParseError.missingValue("--sleep-after") }
                    guard let value = TimeInterval(rest[i]), value > 0, value.isFinite else { throw CLIParseError.invalidTimeout }
                    sleepAfter = value
                case "--caffeinate":
                    guard !caffeinate else { throw CLIParseError.duplicateOption("--caffeinate") }
                    caffeinate = true
                default: throw CLIParseError.unknownOption(rest[i])
                }
                i += 1
            }
            if all && !selectors.isEmpty { throw CLIParseError.conflictingTargets }
            if !all && selectors.isEmpty { throw CLIParseError.noDisplays }
            if timeout != nil && sleepAfter != nil { throw CLIParseError.conflictingBlackoutLimits }
            if all && timeout == nil && sleepAfter == nil { throw CLIParseError.allRequiresLimit }
            return .blackout(BlackoutOptions(selectors: selectors, all: all, idleAfter: idleAfter, timeout: timeout, sleepAfter: sleepAfter, caffeinate: caffeinate))
        case "ddc-luminance":
            var selector: String?
            var setValue: UInt16?
            var json = false
            var i = 0
            while i < rest.count {
                switch rest[i] {
                case "--display":
                    i += 1
                    guard i < rest.count, !rest[i].hasPrefix("--"), !rest[i].isEmpty else { throw CLIParseError.missingValue("--display") }
                    selector = rest[i]
                case "--set":
                    guard setValue == nil else { throw CLIParseError.duplicateOption("--set") }
                    i += 1
                    guard i < rest.count, !rest[i].hasPrefix("--") else { throw CLIParseError.missingValue("--set") }
                    guard let value = UInt16(rest[i]) else { throw CLIParseError.invalidLuminance }
                    setValue = value
                case "--json":
                    json = true
                default:
                    throw CLIParseError.unknownOption(rest[i])
                }
                i += 1
            }
            guard let selector else { throw CLIParseError.missingValue("--display") }
            return .ddcLuminance(selector: selector, setValue: setValue, json: json)
        case "sleep-displays":
            var keepSystemAwake = false
            var timeout: TimeInterval?
            var i = 0
            while i < rest.count {
                switch rest[i] {
                case "--keep-system-awake":
                    keepSystemAwake = true
                case "--timeout":
                    i += 1
                    guard i < rest.count, !rest[i].hasPrefix("--") else { throw CLIParseError.missingValue("--timeout") }
                    guard let value = TimeInterval(rest[i]), value > 0, value.isFinite else { throw CLIParseError.invalidTimeout }
                    timeout = value
                default:
                    throw CLIParseError.unknownOption(rest[i])
                }
                i += 1
            }
            if timeout != nil && !keepSystemAwake { throw CLIParseError.timeoutRequiresKeepAwake }
            return .sleepDisplays(keepSystemAwake: keepSystemAwake, timeout: timeout)
        case "wake-displays":
            guard rest.isEmpty else { throw CLIParseError.unknownOption(rest[0]) }
            return .wakeDisplays
        default: throw CLIParseError.unknownCommand(command)
        }
    }
}
