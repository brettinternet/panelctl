import Foundation
import PanelCtlCore

/// The fixed, deliberately invoked effects available to a named display action.
enum DisplayActionEffect: String, Codable, CaseIterable, Identifiable {
    case blackOut
    case removeFromDesktop
    case show
    case moveWindows

    var id: Self { self }

    var title: String {
        switch self {
        case .blackOut: return "Hide (black out)"
        case .removeFromDesktop: return "Hide (remove from desktop)"
        case .show: return "Show"
        case .moveWindows: return "Move windows"
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

enum MoveWindowsDestination: Codable, Equatable {
    case automatic
    case display(DisplayIdentityReference)

    private enum CodingKeys: String, CodingKey { case kind, display }
    private enum Kind: String, Codable { case automatic, display }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        switch try values.decode(Kind.self, forKey: .kind) {
        case .automatic: self = .automatic
        case .display: self = .display(try values.decode(DisplayIdentityReference.self, forKey: .display))
        }
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .automatic:
            try values.encode(Kind.automatic, forKey: .kind)
        case .display(let identity):
            try values.encode(Kind.display, forKey: .kind)
            try values.encode(identity, forKey: .display)
        }
    }
}

struct MoveWindowsConfiguration: Codable, Equatable {
    var destination: MoveWindowsDestination

    init(destination: MoveWindowsDestination = .automatic) {
        self.destination = destination
    }
}

struct DisplayActionStep: Codable, Equatable, Identifiable {
    var id: UUID
    var target: DisplayIdentityReference?
    var effect: DisplayActionEffect
    var reviewedRemoval: ReviewedRemovalSetup?
    var moveWindows: MoveWindowsConfiguration?
    /// Black-out steps only: keep windows off the display for as long as this Hide lasts.
    var keepWindowsOff: MoveWindowsConfiguration?

    init(id: UUID = UUID(), target: DisplayIdentityReference? = nil, effect: DisplayActionEffect = .blackOut,
         reviewedRemoval: ReviewedRemovalSetup? = nil, moveWindows: MoveWindowsConfiguration? = nil,
         keepWindowsOff: MoveWindowsConfiguration? = nil) {
        self.id = id
        self.target = target
        self.effect = effect
        self.reviewedRemoval = reviewedRemoval
        self.moveWindows = moveWindows
        self.keepWindowsOff = keepWindowsOff
    }

    init(id: UUID = UUID(), target: DisplayIdentitySnapshot, effect: DisplayActionEffect = .blackOut,
         reviewedRemoval: ReviewedRemovalSetup? = nil, moveWindows: MoveWindowsConfiguration? = nil,
         keepWindowsOff: MoveWindowsConfiguration? = nil) {
        self.init(id: id, target: DisplayIdentityReference(target), effect: effect,
                  reviewedRemoval: reviewedRemoval, moveWindows: moveWindows, keepWindowsOff: keepWindowsOff)
    }

    private enum CodingKeys: String, CodingKey { case id, target, effect, reviewedRemoval, moveWindows, keepWindowsOff }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        target = try values.decodeIfPresent(DisplayIdentityReference.self, forKey: .target)
        effect = try values.decode(DisplayActionEffect.self, forKey: .effect)
        reviewedRemoval = try values.decodeIfPresent(ReviewedRemovalSetup.self, forKey: .reviewedRemoval)
        moveWindows = try values.decodeIfPresent(MoveWindowsConfiguration.self, forKey: .moveWindows)
        guard (effect == .moveWindows) == (moveWindows != nil) else {
            throw DecodingError.dataCorruptedError(forKey: .moveWindows, in: values,
                debugDescription: "Move windows steps require a destination; other effects cannot have one.")
        }
        keepWindowsOff = try values.decodeIfPresent(MoveWindowsConfiguration.self, forKey: .keepWindowsOff)
        guard keepWindowsOff == nil || effect == .blackOut else {
            throw DecodingError.dataCorruptedError(forKey: .keepWindowsOff, in: values,
                debugDescription: "Only black-out steps can keep windows off.")
        }
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encodeIfPresent(target, forKey: .target)
        try values.encode(effect, forKey: .effect)
        try values.encodeIfPresent(reviewedRemoval, forKey: .reviewedRemoval)
        try values.encodeIfPresent(moveWindows, forKey: .moveWindows)
        try values.encodeIfPresent(keepWindowsOff, forKey: .keepWindowsOff)
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
        self.steps = [DisplayActionStep(target: target.map(DisplayIdentityReference.init), effect: effect, reviewedRemoval: reviewedRemoval)]
    }

    init(
        id: UUID = UUID(),
        name: String = "",
        target: DisplayIdentityReference?,
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
    var target: DisplayIdentityReference? {
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
                target: try values.decodeIfPresent(DisplayIdentityReference.self, forKey: .target),
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

struct UnsupportedDisplayAction: Equatable, Identifiable {
    let id: String
    let name: String
    let reason: String
    let raw: ActionStorageJSON
}

/// A small Codable JSON tree keeps unsupported saved Actions losslessly editable alongside valid siblings.
indirect enum ActionStorageJSON: Codable, Equatable {
    case object([String: ActionStorageJSON])
    case array([ActionStorageJSON])
    case string(String)
    case integer(Int64)
    case unsignedInteger(UInt64)
    case number(Double)
    case bool(Bool)
    case null

    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() { self = .null; return }
        if let bool = try? value.decode(Bool.self) { self = .bool(bool); return }
        // Decode integers before floating point so unknown payload IDs/counters survive sibling edits.
        if let integer = try? value.decode(Int64.self) { self = .integer(integer); return }
        if let integer = try? value.decode(UInt64.self) { self = .unsignedInteger(integer); return }
        if let number = try? value.decode(Double.self) { self = .number(number); return }
        if let string = try? value.decode(String.self) { self = .string(string); return }
        if let object = try? value.decode([String: ActionStorageJSON].self) { self = .object(object); return }
        if let array = try? value.decode([ActionStorageJSON].self) { self = .array(array); return }
        throw DecodingError.dataCorruptedError(in: value, debugDescription: "Invalid JSON value.")
    }

    func encode(to encoder: Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self {
        case .object(let object): try value.encode(object)
        case .array(let array): try value.encode(array)
        case .string(let string): try value.encode(string)
        case .integer(let integer): try value.encode(integer)
        case .unsignedInteger(let integer): try value.encode(integer)
        case .number(let number): try value.encode(number)
        case .bool(let bool): try value.encode(bool)
        case .null: try value.encodeNil()
        }
    }

    var object: [String: ActionStorageJSON]? { if case .object(let object) = self { object } else { nil } }
    var string: String? { if case .string(let string) = self { string } else { nil } }
}

private struct StoredDisplayActionRow: Equatable {
    let id: UUID?
    let raw: ActionStorageJSON
    let reason: String?
}

struct DisplayActionSet: Codable, Equatable {
    static let currentVersion = 3

    var version = currentVersion
    var actions: [DisplayAction] = []
    var unsupportedActions: [UnsupportedDisplayAction] = []
    private var storedRows: [StoredDisplayActionRow] = []

    init(actions: [DisplayAction] = []) {
        version = Self.currentVersion
        self.actions = actions
    }

    private enum CodingKeys: String, CodingKey { case version, actions }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let storedVersion = try values.decode(Int.self, forKey: .version)
        guard (1...Self.currentVersion).contains(storedVersion) else {
            throw DecodingError.dataCorruptedError(forKey: .version, in: values,
                debugDescription: "Unsupported display action version \(storedVersion).")
        }
        version = Self.currentVersion
        actions = []
        unsupportedActions = []
        storedRows = []
        let rows = try values.decode([ActionStorageJSON].self, forKey: .actions)
        for (offset, raw) in rows.enumerated() {
            do {
                if storedVersion == Self.currentVersion { try Self.validateV3Shape(raw) }
                let rowData = try JSONEncoder().encode(raw)
                let action = try JSONDecoder().decode(DisplayAction.self, from: rowData)
                guard Set(action.steps.map(\.id)).count == action.steps.count else {
                    throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                        debugDescription: "Action contains duplicate step UUIDs."))
                }
                actions.append(action)
                storedRows.append(StoredDisplayActionRow(id: action.id, raw: raw, reason: nil))
            } catch {
                let fields = raw.object ?? [:]
                let parsedID = fields["id"]?.string.flatMap(UUID.init(uuidString:))?.uuidString ?? "unsupported-\(offset + 1)"
                let name = fields["name"]?.string ?? "Unsupported Action \(offset + 1)"
                let reason = "This Action uses an unsupported effect or invalid saved data and is preserved but unavailable. (\(error.localizedDescription))"
                unsupportedActions.append(UnsupportedDisplayAction(id: parsedID, name: name, reason: reason, raw: raw))
                storedRows.append(StoredDisplayActionRow(id: nil, raw: raw, reason: reason))
            }
        }
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(Self.currentVersion, forKey: .version)
        var encodedActions: [ActionStorageJSON] = []
        var emitted = Set<UUID>()
        for row in storedRows {
            guard let id = row.id else {
                encodedActions.append(row.raw)
                continue
            }
            guard let action = actions.first(where: { $0.id == id }) else { continue }
            encodedActions.append(try Self.merging(try Self.json(action), over: row.raw))
            emitted.insert(id)
        }
        for action in actions where !emitted.contains(action.id) {
            encodedActions.append(try Self.json(action))
        }
        try values.encode(encodedActions, forKey: .actions)
    }

    private static func validateV3Shape(_ raw: ActionStorageJSON) throws {
        guard let fields = raw.object, case .array(let steps)? = fields["steps"] else {
            throw DisplayActionStorageShapeError.invalid
        }
        for step in steps {
            guard let stepFields = step.object, stepFields["id"]?.string.flatMap(UUID.init(uuidString:)) != nil else {
                throw DisplayActionStorageShapeError.invalid
            }
        }
    }

    private static func json<T: Encodable>(_ value: T) throws -> ActionStorageJSON {
        try JSONDecoder().decode(ActionStorageJSON.self, from: JSONEncoder().encode(value))
    }

    private static func merging(_ current: ActionStorageJSON, over original: ActionStorageJSON) throws -> ActionStorageJSON {
        guard case .object(var fields) = original, case .object(let updated) = current else { return current }
        fields.merge(updated) { _, new in new }
        return .object(fields)
    }
}

private enum DisplayActionStorageShapeError: Error, LocalizedError {
    case invalid
    var errorDescription: String? { "This saved Action is missing stable step identity or has an invalid shape." }
}

enum DisplayActionValidationError: Error, Equatable, LocalizedError {
    case invalidName
    case duplicateName(String)
    case duplicateIdentity
    case invalidStepCount
    case duplicateDisplay(String)
    case duplicateStepIdentity
    case invalidMoveConfiguration(Int)
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
            return "“\(name)” can appear only once in the same Action effect class."
        case .duplicateStepIdentity:
            return "Every Action step must have a unique stable identity."
        case .invalidMoveConfiguration(let index):
            return "Step \(index): Choose the required Move windows destination."
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

    /// One step as the Automations row shows it: what happens to which display, then how.
    static func stepParts(for step: DisplayActionStep, displays: [DisplayRecord]) -> (title: String, detail: String?) {
        let targetName = step.target.map { displayName(for: $0, displays: displays) } ?? "Choose a display"
        switch step.effect {
        case .blackOut:
            return ("Hide \(targetName)", "Black out")
        case .show:
            return ("Show \(targetName)", nil)
        case .removeFromDesktop:
            let source: String
            if let uuid = step.reviewedRemoval?.sourceUUID, !uuid.isEmpty {
                let name = displays.first(where: { $0.uuid?.caseInsensitiveCompare(uuid) == .orderedSame })?.settingsName
                    ?? "\(uuid.prefix(8))… (unavailable)"
                source = "Mirror onto \(name)"
            } else {
                source = "No mirror source"
            }
            let input = step.reviewedRemoval?.awayInput.map { "Switch to \(MonitorInput.name($0))" } ?? "Don’t switch input"
            return ("Hide \(targetName)", "Remove from desktop · \(source) · \(input)")
        case .moveWindows:
            let destination: String
            switch step.moveWindows?.destination {
            case .automatic: destination = "Automatic destination"
            case .display(let identity): destination = "Move to \(displayName(for: identity, displays: displays))"
            case nil: destination = "Choose a destination"
            }
            return ("Move windows from \(targetName)", destination)
        }
    }

    /// The last run's step results in the Action's current step order, or nil when the Action changed since.
    static func alignedStepResults(
        for action: DisplayAction,
        steps results: [AppControlActionStepResult]?
    ) -> [AppControlActionStepResult]? {
        guard let results, results.count == action.steps.count else { return nil }
        for (offset, pair) in zip(action.steps, results).enumerated() {
            let (step, result) = pair
            guard result.index == offset + 1, result.effect == step.effect.rawValue,
                  let uuid = step.target?.uuid,
                  uuid.caseInsensitiveCompare(result.targetUUID) == .orderedSame else { return nil }
        }
        return results
    }

    static func displayName(for identity: DisplayIdentityReference, displays: [DisplayRecord]) -> String {
        if let display = displays.first(where: { $0.uuid?.caseInsensitiveCompare(identity.uuid) == .orderedSame }) {
            return display.settingsName
        }
        return "\(identity.presentationName) (unavailable)"
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
