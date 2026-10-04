import Foundation
import PanelCtlCore

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

    init(target: DisplayIdentitySnapshot, enabled: Bool = false, source: DisplayIdentitySnapshot? = nil) {
        self.target = target
        self.enabled = enabled
        self.source = source
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

struct DisplayHideRequest: Equatable, Identifiable {
    let target: DisplayIdentitySnapshot
    let source: DisplayIdentitySnapshot

    var id: String { target.uuid.lowercased() }
}

enum DisplayHideOperation: Equatable {
    case idle
    case hiding(String)
    case showing(String)

    var isBusy: Bool {
        if case .idle = self { return false }
        return true
    }
}

enum DisplayHideError: Error, LocalizedError, Equatable {
    case unavailable(String)
    case identityChanged(String)
    case recoveryBlocksHide(String)
    case recoveryBlocksAction(String)
    case actionInProgress
    case acknowledgementRequired
    case protectionCleanup(String)
    case sleeping

    var errorDescription: String? {
        switch self {
        case .unavailable(let message), .identityChanged(let message),
             .recoveryBlocksHide(let message), .recoveryBlocksAction(let message),
             .protectionCleanup(let message):
            return message
        case .actionInProgress:
            return "A display hide/show operation is already in progress. Wait for it to finish."
        case .acknowledgementRequired:
            return "Confirm that you have another usable display and a manual recovery option before continuing."
        case .sleeping:
            return "Hide and Show are unavailable during sleep or display transitions. Wait for the displays to wake, then Refresh."
        }
    }
}
