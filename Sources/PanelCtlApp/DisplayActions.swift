import Foundation
import PanelCtlCore

/// The fixed, deliberately invoked effects available to a named display action.
enum DisplayActionEffect: String, Codable, CaseIterable, Identifiable {
    case blackOut
    case removeFromDesktop
    case show

    var id: Self { self }

    var title: String {
        switch self {
        case .blackOut: return "Black out"
        case .removeFromDesktop: return "Remove from desktop"
        case .show: return "Show"
        }
    }
}

/// The Displays configuration reviewed when a Remove from desktop action is saved.
/// Return-input detection is intentionally excluded because it is read-only and dynamic.
struct ReviewedRemovalSetup: Codable, Equatable {
    let removeEnabled: Bool
    let sourceUUID: String?
    let awayInput: UInt8?

    init(removeEnabled: Bool, sourceUUID: String?, awayInput: UInt8?) {
        self.removeEnabled = removeEnabled
        self.sourceUUID = sourceUUID?.lowercased()
        self.awayInput = awayInput
    }
}

struct DisplayAction: Codable, Equatable, Identifiable {
    var id: UUID
    var name: String
    var target: DisplayIdentitySnapshot?
    var effect: DisplayActionEffect
    var reviewedRemoval: ReviewedRemovalSetup?

    init(
        id: UUID = UUID(),
        name: String = "",
        target: DisplayIdentitySnapshot? = nil,
        effect: DisplayActionEffect = .blackOut,
        reviewedRemoval: ReviewedRemovalSetup? = nil
    ) {
        self.id = id
        self.name = name
        self.target = target
        self.effect = effect
        self.reviewedRemoval = reviewedRemoval
    }
}

struct DisplayActionSet: Codable, Equatable {
    static let currentVersion = 1

    var version = currentVersion
    var actions: [DisplayAction] = []

    init(actions: [DisplayAction] = []) {
        version = Self.currentVersion
        self.actions = actions
    }

    private enum CodingKeys: String, CodingKey {
        case version, actions
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = try values.decode(Int.self, forKey: .version)
        guard version == Self.currentVersion else {
            throw DecodingError.dataCorruptedError(
                forKey: .version, in: values,
                debugDescription: "Unsupported display action version."
            )
        }
        actions = try values.decode([DisplayAction].self, forKey: .actions)
    }
}

enum DisplayActionValidationError: Error, Equatable, LocalizedError {
    case invalidName
    case duplicateName(String)
    case duplicateIdentity
    case missingTarget
    case invalidTarget
    case removalSetupUnavailable(String)
    case experimentalFeaturesRequired

    var errorDescription: String? {
        switch self {
        case .invalidName:
            return "Enter a non-empty action name."
        case .duplicateName(let name):
            return "Action names must be unique. “\(name)” is already in use."
        case .duplicateIdentity:
            return "This action no longer exists. Close the editor and try again."
        case .missingTarget:
            return "Choose a display."
        case .invalidTarget:
            return "Choose a display with a stable UUID."
        case .removalSetupUnavailable(let reason):
            return reason
        case .experimentalFeaturesRequired:
            return "Turn on Experimental features in General to review Remove from desktop."
        }
    }
}

struct DisplayActionReviewChange: Equatable {
    let current: ReviewedRemovalSetup
    let message: String
}

enum DisplayActionPresentation {
    static let runsDescription = "Only when you choose Run or run its command"

    static func summary(for action: DisplayAction, displays: [DisplayRecord]) -> String {
        let targetName = action.target.map { displayName(for: $0, displays: displays) } ?? "Choose a display"
        switch action.effect {
        case .blackOut:
            return "Black out \(targetName)"
        case .show:
            return "Show \(targetName)"
        case .removeFromDesktop:
            let source: String
            if let uuid = action.reviewedRemoval?.sourceUUID, !uuid.isEmpty {
                source = displays.first(where: { $0.uuid?.caseInsensitiveCompare(uuid) == .orderedSame })?.settingsName
                    ?? "\(uuid.prefix(8))… (unavailable)"
            } else {
                source = "no mirror source"
            }
            let input = action.reviewedRemoval?.awayInput.map(MonitorInput.name) ?? "Don’t switch input"
            return "Remove \(targetName) from desktop onto \(source) · \(input == "Don’t switch input" ? input.lowercased() : "switch to \(input)")"
        }
    }

    static func displayName(for identity: DisplayIdentitySnapshot, displays: [DisplayRecord]) -> String {
        if let display = displays.first(where: { $0.uuid?.caseInsensitiveCompare(identity.uuid) == .orderedSame }) {
            return display.settingsName
        }
        return identity.name ?? "\(identity.uuid.prefix(8))… (unavailable)"
    }

    static func setupChange(
        from reviewed: ReviewedRemovalSetup,
        to current: ReviewedRemovalSetup,
        displays: [DisplayRecord]
    ) -> DisplayActionReviewChange? {
        var changes: [String] = []
        if reviewed.removeEnabled != current.removeEnabled {
            changes.append("Remove from desktop \(reviewed.removeEnabled ? "On" : "Off") → \(current.removeEnabled ? "On" : "Off")")
        }
        if reviewed.sourceUUID != current.sourceUUID {
            changes.append("Mirror onto \(sourceName(reviewed.sourceUUID, displays: displays)) → \(sourceName(current.sourceUUID, displays: displays))")
        }
        if reviewed.awayInput != current.awayInput {
            changes.append("Switch monitor to \(inputName(reviewed.awayInput)) → \(inputName(current.awayInput))")
        }
        guard !changes.isEmpty else { return nil }
        return DisplayActionReviewChange(current: current, message: "Displays setup changed since review: \(changes.joined(separator: "; ")).")
    }

    private static func sourceName(_ uuid: String?, displays: [DisplayRecord]) -> String {
        guard let uuid else { return "None" }
        return displays.first(where: { $0.uuid?.caseInsensitiveCompare(uuid) == .orderedSame })?.settingsName
            ?? "\(uuid.prefix(8))… (unavailable)"
    }

    private static func inputName(_ input: UInt8?) -> String {
        input.map(MonitorInput.name) ?? "Don’t switch"
    }
}

enum DisplayHideStyle: Equatable {
    case configured
    case blackOut
    case removeFromDesktop
}
