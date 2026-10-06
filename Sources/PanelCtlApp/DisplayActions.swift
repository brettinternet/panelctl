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
        case .blackOut: return "Hide (black out)"
        case .removeFromDesktop: return "Hide (remove from desktop)"
        case .show: return "Show"
        }
    }
}

/// The Displays configuration reviewed when a Remove from desktop step is saved.
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

struct DisplayActionStep: Codable, Equatable, Identifiable {
    var target: DisplayIdentitySnapshot?
    var effect: DisplayActionEffect
    var reviewedRemoval: ReviewedRemovalSetup?

    var id: String { target?.uuid.lowercased() ?? "step-\(effect.rawValue)" }

    init(target: DisplayIdentitySnapshot? = nil, effect: DisplayActionEffect = .blackOut,
         reviewedRemoval: ReviewedRemovalSetup? = nil) {
        self.target = target
        self.effect = effect
        self.reviewedRemoval = reviewedRemoval
    }
}

struct DisplayAction: Codable, Equatable, Identifiable {
    var id: UUID
    var name: String
    var steps: [DisplayActionStep]

    /// Compatibility initializer for old one-display Actions and callers that edit their first step.
    init(
        id: UUID = UUID(),
        name: String = "",
        target: DisplayIdentitySnapshot? = nil,
        effect: DisplayActionEffect = .blackOut,
        reviewedRemoval: ReviewedRemovalSetup? = nil
    ) {
        self.id = id
        self.name = name
        self.steps = [DisplayActionStep(target: target, effect: effect, reviewedRemoval: reviewedRemoval)]
    }

    init(id: UUID = UUID(), name: String = "", steps: [DisplayActionStep]) {
        self.id = id
        self.name = name
        self.steps = steps
    }

    /// Compatibility facade for one-step call sites. New workflows use `steps` directly.
    var target: DisplayIdentitySnapshot? {
        get { steps.first?.target }
        set {
            if steps.isEmpty { steps = [DisplayActionStep(target: newValue)] }
            else { steps[0].target = newValue }
        }
    }

    var effect: DisplayActionEffect {
        get { steps.first?.effect ?? .blackOut }
        set {
            if steps.isEmpty { steps = [DisplayActionStep(effect: newValue)] }
            else { steps[0].effect = newValue }
        }
    }

    var reviewedRemoval: ReviewedRemovalSetup? {
        get { steps.first?.reviewedRemoval }
        set {
            if steps.isEmpty { steps = [DisplayActionStep(effect: .removeFromDesktop, reviewedRemoval: newValue)] }
            else { steps[0].reviewedRemoval = newValue }
        }
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, steps, target, effect, reviewedRemoval
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        if values.contains(.steps) {
            steps = try values.decode([DisplayActionStep].self, forKey: .steps)
        } else {
            // TASK-36 stored a single target/effect directly on the Action.
            steps = [DisplayActionStep(
                target: try values.decodeIfPresent(DisplayIdentitySnapshot.self, forKey: .target),
                effect: try values.decode(DisplayActionEffect.self, forKey: .effect),
                reviewedRemoval: try values.decodeIfPresent(ReviewedRemovalSetup.self, forKey: .reviewedRemoval)
            )]
        }
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(name, forKey: .name)
        try values.encode(steps, forKey: .steps)
    }
}

struct DisplayActionSet: Codable, Equatable {
    static let currentVersion = 2

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
        let storedVersion = try values.decode(Int.self, forKey: .version)
        guard storedVersion == 1 || storedVersion == Self.currentVersion else {
            throw DecodingError.dataCorruptedError(
                forKey: .version, in: values,
                debugDescription: "Unsupported display action version \(storedVersion)."
            )
        }
        version = Self.currentVersion
        actions = try values.decode([DisplayAction].self, forKey: .actions)
    }
}

enum DisplayActionValidationError: Error, Equatable, LocalizedError {
    case invalidName
    case duplicateName(String)
    case duplicateIdentity
    case invalidStepCount
    case duplicateDisplay(String)
    case missingTarget(Int)
    case invalidTarget(Int)
    case removalSetupUnavailable(Int, String)
    case experimentalFeaturesRequired(Int)
    case staticConflict(Int, String)
    case actionInProgress(String)
    case storedActionsUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .invalidName:
            return "Enter a non-empty action name."
        case .duplicateName(let name):
            return "Action names must be unique. “\(name)” is already in use."
        case .duplicateIdentity:
            return "This action no longer exists. Close the editor and try again."
        case .invalidStepCount:
            return "An Action needs 1–8 steps."
        case .duplicateDisplay(let name):
            return "“\(name)” can appear only once in an Action."
        case .missingTarget(let index):
            return "Step \(index): Choose a display."
        case .invalidTarget(let index):
            return "Step \(index): Choose a display with a stable UUID."
        case .removalSetupUnavailable(let index, let reason):
            return "Step \(index): \(reason)"
        case .experimentalFeaturesRequired(let index):
            return "Step \(index): Turn on Experimental features in General to review Remove from desktop."
        case .staticConflict(let index, let reason):
            return "Step \(index): \(reason)"
        case .actionInProgress(let name):
            return "“\(name)” is running. Wait for it to finish before editing it."
        case .storedActionsUnavailable(let reason):
            return reason
        }
    }
}

struct DisplayActionReviewChange: Equatable {
    let current: ReviewedRemovalSetup
    let message: String
}

enum DisplayActionPresentation {
    static func stepNeedsAttention(_ step: AppControlActionStepResult) -> Bool {
        [.refused, .busy, .failed, .partial, .recoveryNeeded].contains(step.outcome) ||
            step.inputOutcome.map { [.failed, .skipped, .unverified, .notAttempted].contains($0) } == true ||
            ((step.inputOutcome == nil || step.inputOutcome == .notRequested) && step.inputDetail != nil)
    }

    static func summary(for action: DisplayAction, displays: [DisplayRecord]) -> String {
        let summaries = action.steps.enumerated().map { index, step in
            let text = summary(for: step, displays: displays)
            return action.steps.count == 1 ? text : "\(index + 1). \(text)"
        }
        return summaries.joined(separator: "  ·  ")
    }

    static func summary(for step: DisplayActionStep, displays: [DisplayRecord]) -> String {
        let targetName = step.target.map { displayName(for: $0, displays: displays) } ?? "Choose a display"
        switch step.effect {
        case .blackOut:
            return "Hide \(targetName) (black out)"
        case .show:
            return "Show \(targetName)"
        case .removeFromDesktop:
            let source: String
            if let uuid = step.reviewedRemoval?.sourceUUID, !uuid.isEmpty {
                let name = displays.first(where: { $0.uuid?.caseInsensitiveCompare(uuid) == .orderedSame })?.settingsName
                    ?? "\(uuid.prefix(8))… (unavailable)"
                source = "mirror onto \(name)"
            } else {
                source = "no mirror source"
            }
            let input = step.reviewedRemoval?.awayInput.map { "switch to \(MonitorInput.name($0))" } ?? "don’t switch input"
            return "Hide \(targetName) (remove from desktop) · \(source) · \(input)"
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
