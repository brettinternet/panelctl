import Foundation
import PanelCtlCore

/// Session result of reading, read-only over DDC, the input this Mac uses.
enum MacInputDetection: Equatable {
    /// The monitor's input when read, taken as this Mac's.
    case detected(UInt8)
    /// The monitor was on the input Hide switches to, so it may have been
    /// showing the other computer; the reading says nothing about this Mac.
    case onSwitchInput(UInt8)
    case unavailable(String)
}

/// Display names for the common MCCS input codes.
enum MonitorInput {
    static let common: [(value: UInt8, name: String)] = [
        (0x11, "HDMI 1"), (0x12, "HDMI 2"), (0x0F, "DisplayPort 1"), (0x10, "DisplayPort 2")
    ]

    static func name(_ value: UInt8) -> String {
        common.first { $0.value == value }?.name ?? String(format: "Input 0x%02X", value)
    }
}

struct DisplayIdentitySnapshot: Codable, Equatable {
    let uuid: String
    let id: UInt32
    let name: String?
    let vendor: UInt32
    let model: UInt32
    let serial: UInt32

    var identityDetail: String {
        "Display ID \(id) · UUID \(uuid) · \(vendor):\(model):\(serial)"
    }

    init(_ display: DisplayRecord) {
        uuid = display.uuid ?? ""
        id = display.id
        name = display.name
        vendor = display.vendor
        model = display.model
        serial = display.serial
    }

    init(uuid: String, id: UInt32, name: String?, vendor: UInt32, model: UInt32, serial: UInt32) {
        self.uuid = uuid
        self.id = id
        self.name = name
        self.vendor = vendor
        self.model = model
        self.serial = serial
    }

    var listID: String { uuid.lowercased() }
}

struct DisplayHideConfiguration: Codable, Equatable {
    var target: DisplayIdentitySnapshot
    var enabled: Bool
    var source: DisplayIdentitySnapshot?
    var awayInput: UInt8?
    var returnInput: UInt8?

    init(target: DisplayIdentitySnapshot, enabled: Bool = false, source: DisplayIdentitySnapshot? = nil,
         awayInput: UInt8? = nil, returnInput: UInt8? = nil) {
        self.target = target
        self.enabled = enabled
        self.source = source
        self.awayInput = awayInput
        self.returnInput = returnInput
    }
}

struct DisplayHidePreferences: Codable, Equatable {
    var configurations: [String: DisplayHideConfiguration] = [:]

    private enum CodingKeys: String, CodingKey {
        case configurations
    }

    init() {}

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        configurations = try values.decodeIfPresent(
            [String: DisplayHideConfiguration].self,
            forKey: .configurations
        ) ?? [:]
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(configurations, forKey: .configurations)
    }

    subscript(uuid: String) -> DisplayHideConfiguration? {
        get { configurations[Self.key(uuid)] }
        set { configurations[Self.key(uuid)] = newValue }
    }

    mutating func remove(uuid: String) {
        configurations.removeValue(forKey: Self.key(uuid))
    }

    private static func key(_ uuid: String) -> String {
        uuid.lowercased()
    }
}

struct DisplayHideRequest: Equatable {
    let target: DisplayIdentitySnapshot
    let source: DisplayIdentitySnapshot
    let awayInput: UInt8?
    let awayInputWarning: String?
}

struct DisplayShowRequest: Equatable {
    let status: DisplayHandoffStatus
    let targetUUID: String
    let returnInput: UInt8?
    let returnInputWarning: String?
}

/// The last Hide or Show outcome for one display, shown inline instead of in alerts.
struct DisplayOperationResult: Equatable {
    enum Action: Equatable {
        case hide
        case show
    }

    let action: Action
    /// Whether the desktop reached the requested state.
    let succeeded: Bool
    /// One line about the desktop.
    let message: String
    /// One line about the monitor input, when one was involved.
    let inputMessage: String?
    /// Input evidence, also reported to scripts.
    let inputOutcome: DisplayInputOutcome?
    let inputNeedsAttention: Bool

    var needsAttention: Bool { !succeeded || inputNeedsAttention }

    /// A short line for the menu: the failure, or else the input outcome.
    var menuLine: String? { succeeded ? inputMessage : message }

    /// The command that puts the monitor back on the input it had before
    /// PanelCtl switched it, offered when the result needs attention.
    var undoInputCommand: String? { needsAttention ? inputOutcome?.recoveryCommand : nil }
}

/// One display in the Displays tab, in arrangement order.
struct DisplayTile: Identifiable, Equatable {
    enum Status: Equatable {
        case on
        case hidden
        case hiding
        case showing
        case blackedOut
        case asleep
        case mirrored
        case busy
        case unavailable
        case needsRecovery

        var label: String {
            switch self {
            case .on: return "On"
            case .hidden: return "Hidden"
            case .hiding: return "Hiding…"
            case .showing: return "Showing…"
            case .blackedOut: return "Blacked out"
            case .asleep: return "Asleep"
            case .mirrored: return "Mirrored"
            case .busy: return "Busy"
            case .unavailable: return "Unavailable"
            case .needsRecovery: return "Needs recovery"
            }
        }
    }

    enum Action: Equatable {
        case hide
        case show
    }

    /// Lowercased UUID, or a display-ID key for a display without one.
    let id: String
    let uuid: String?
    let name: String
    let status: Status
    /// Nil for a journaled display that is no longer connected.
    let display: DisplayRecord?
    /// The Hide or Show this display offers, shared by Settings and the menu.
    var action: Action?
    /// Why the action can't run now; nil when it can.
    var actionBlocker: String?

    var isMain: Bool { display?.main == true }

    /// Width over height, clamped to a drawable range.
    var aspectRatio: Double {
        guard let display, display.pixelWidth > 0, display.pixelHeight > 0 else { return 16.0 / 9.0 }
        return min(max(Double(display.pixelWidth) / Double(display.pixelHeight), 0.5), 3.6)
    }
}

enum DisplayHideOperation: Equatable {
    case idle
    case hiding(String)
    case showing(String)

    var isBusy: Bool {
        if case .idle = self { return false }
        return true
    }

    var targetUUID: String? {
        switch self {
        case .idle: return nil
        case .hiding(let uuid), .showing(let uuid): return uuid
        }
    }
}

enum DisplayHideError: Error, LocalizedError, Equatable {
    case unavailable(String)
    case identityChanged(String)
    case recoveryBlocksHide(String)
    case recoveryBlocksAction(String)
    case actionInProgress
    case protectionCleanup(String)
    case sleeping

    var errorDescription: String? {
        switch self {
        case .unavailable(let message), .identityChanged(let message),
             .recoveryBlocksHide(let message), .recoveryBlocksAction(let message),
             .protectionCleanup(let message):
            return message
        case .actionInProgress:
            return "Another Hide or Show is still running. Try again when it finishes."
        case .sleeping:
            return "Displays are sleeping or changing. Try again once they’re awake."
        }
    }
}
