import Foundation
import PanelCtlCore

enum FollowUpAction: String, Codable, CaseIterable, Identifiable {
    case untilActivity
    case restore
    case sleepDisplays

    var id: Self { self }

    var title: String {
        switch self {
        case .untilActivity: return "Stay black until activity"
        case .restore: return "Restore the display"
        case .sleepDisplays: return "Sleep all displays"
        }
    }
}

enum ProtectionConfigurationError: Error, Equatable, LocalizedError {
    case noDisplays
    case noSelection
    case selectedDisplayUnavailable(String)
    case allDisplaysRequireLimit
    case selectionWouldCoverAllDisplays
    case selectedDisplaysHidden
    case selectionWouldCoverEveryShownDisplay
    case persistentDimming
    case invalidOverlayOpacityPercent
    case invalidHardwareBrightnessPercent
    case invalidIdleDuration
    case invalidFollowUpDuration
    case ruleConflict(String)
    case combinedCoverage(String)
    case duplicateRuleName(String)
    case invalidRuleName
    case duplicateRuleIdentity
    case noEnabledRules

    var errorDescription: String? {
        switch self {
        case .noDisplays:
            return "No active displays are available."
        case .noSelection:
            return "Select at least one display."
        case .selectedDisplayUnavailable(let identifier):
            return "Selected display \(identifier) is not currently available."
        case .allDisplaysRequireLimit:
            return "With All displays on, choose Restore or Sleep under Afterward as a safety limit."
        case .selectionWouldCoverAllDisplays:
            return "To cover every display, turn on All displays and choose Restore or Sleep under Afterward."
        case .selectedDisplaysHidden:
            return "The displays automation covers are hidden. Show one to resume."
        case .selectionWouldCoverEveryShownDisplay:
            return "Automation would cover every display that isn\u{2019}t hidden. Show a display, or choose Restore or Sleep under Afterward."
        case .persistentDimming:
            return "Use Dim, or turn off hardware brightness, to keep displays black during activity."
        case .invalidOverlayOpacityPercent:
            return "Choose an overlay darkness from 1% through 100%."
        case .invalidHardwareBrightnessPercent:
            return "Choose a hardware target brightness from 0% through 100%."
        case .invalidIdleDuration:
            return "Choose a valid inactivity delay."
        case .invalidFollowUpDuration:
            return "Choose a valid Restore or Sleep delay."
        case .ruleConflict(let message), .combinedCoverage(let message):
            return message
        case .duplicateRuleName(let name):
            return "Rule names must be unique. “\(name)” is already in use."
        case .invalidRuleName:
            return "Enter a non-empty rule name."
        case .duplicateRuleIdentity:
            return "This rule has a duplicate ID. Remove the duplicate before enabling protection."
        case .noEnabledRules:
            return "No rules are on. Turn one on in Settings → Automations."
        }
    }

    /// Automation waits instead of failing while displays are missing or hidden.
    var waitsForDisplays: Bool {
        switch self {
        case .noDisplays, .selectedDisplayUnavailable, .selectedDisplaysHidden,
             .selectionWouldCoverEveryShownDisplay:
            return true
        default:
            return false
        }
    }
}

struct ProtectionPreferences: Codable, Equatable {
    var isEnabled = false
    var idleSeconds: TimeInterval = 5 * 60
    var followUpAction: FollowUpAction = .sleepDisplays
    var followUpSeconds: TimeInterval = 30 * 60
    var keepDisplaysAwake = true
    var allDisplays = false
    var selectedDisplayUUIDs: Set<String> = []
    var didChooseDisplays = false
    var blackoutEmptyDisplays = false
    var mode: BlackoutMode = .blocking
    var workingOverlayEnabled = true
    var workingOverlayOpacityPercent = 60
    var hardwareDimmingEnabled = false
    var hardwareBrightnessPercent = 25
    var keepBlackoutOnInput = false
    var deferBlackoutDuringPlayback = true
    var deferBlackoutWhileCameraInUse = false

    private enum CodingKeys: String, CodingKey {
        case isEnabled
        case idleSeconds
        case followUpAction
        case followUpSeconds
        case keepDisplaysAwake
        case allDisplays
        case selectedDisplayUUIDs
        case didChooseDisplays
        case blackoutEmptyDisplays
        case mode
        case workingOverlayEnabled
        case workingOverlayOpacityPercent
        case hardwareDimmingEnabled
        case hardwareBrightnessPercent
        case dimDisplaysDuringBlackout
        case keepBlackoutOnInput
        case deferBlackoutDuringPlayback
        case deferBlackoutWhileCameraInUse
    }

    init() {}

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        isEnabled = try values.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? false
        idleSeconds = try values.decodeIfPresent(TimeInterval.self, forKey: .idleSeconds) ?? 5 * 60
        followUpAction = try values.decodeIfPresent(FollowUpAction.self, forKey: .followUpAction) ?? .sleepDisplays
        followUpSeconds = try values.decodeIfPresent(TimeInterval.self, forKey: .followUpSeconds) ?? 30 * 60
        keepDisplaysAwake = try values.decodeIfPresent(Bool.self, forKey: .keepDisplaysAwake) ?? true
        allDisplays = try values.decodeIfPresent(Bool.self, forKey: .allDisplays) ?? false
        selectedDisplayUUIDs = try values.decodeIfPresent(Set<String>.self, forKey: .selectedDisplayUUIDs) ?? []
        didChooseDisplays = try values.decodeIfPresent(Bool.self, forKey: .didChooseDisplays) ?? false
        blackoutEmptyDisplays = try values.decodeIfPresent(
            Bool.self,
            forKey: .blackoutEmptyDisplays
        ) ?? false
        mode = try values.decodeIfPresent(BlackoutMode.self, forKey: .mode) ?? .blocking
        workingOverlayEnabled = try values.decodeIfPresent(
            Bool.self,
            forKey: .workingOverlayEnabled
        ) ?? true
        workingOverlayOpacityPercent = try values.decodeIfPresent(
            Int.self,
            forKey: .workingOverlayOpacityPercent
        ) ?? 60
        let legacyDimming = try values.decodeIfPresent(
            Bool.self,
            forKey: .dimDisplaysDuringBlackout
        )
        hardwareDimmingEnabled = try values.decodeIfPresent(
            Bool.self,
            forKey: .hardwareDimmingEnabled
        ) ?? legacyDimming ?? false
        hardwareBrightnessPercent = try values.decodeIfPresent(
            Int.self,
            forKey: .hardwareBrightnessPercent
        ) ?? (legacyDimming == true ? 0 : 25)
        keepBlackoutOnInput = try values.decodeIfPresent(Bool.self, forKey: .keepBlackoutOnInput) ?? false
        deferBlackoutDuringPlayback = try values.decodeIfPresent(Bool.self, forKey: .deferBlackoutDuringPlayback) ?? true
        deferBlackoutWhileCameraInUse = try values.decodeIfPresent(
            Bool.self,
            forKey: .deferBlackoutWhileCameraInUse
        ) ?? false
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(isEnabled, forKey: .isEnabled)
        try values.encode(idleSeconds, forKey: .idleSeconds)
        try values.encode(followUpAction, forKey: .followUpAction)
        try values.encode(followUpSeconds, forKey: .followUpSeconds)
        try values.encode(keepDisplaysAwake, forKey: .keepDisplaysAwake)
        try values.encode(allDisplays, forKey: .allDisplays)
        try values.encode(selectedDisplayUUIDs, forKey: .selectedDisplayUUIDs)
        try values.encode(didChooseDisplays, forKey: .didChooseDisplays)
        try values.encode(blackoutEmptyDisplays, forKey: .blackoutEmptyDisplays)
        try values.encode(mode, forKey: .mode)
        try values.encode(workingOverlayEnabled, forKey: .workingOverlayEnabled)
        try values.encode(workingOverlayOpacityPercent, forKey: .workingOverlayOpacityPercent)
        try values.encode(hardwareDimmingEnabled, forKey: .hardwareDimmingEnabled)
        try values.encode(hardwareBrightnessPercent, forKey: .hardwareBrightnessPercent)
        try values.encode(keepBlackoutOnInput, forKey: .keepBlackoutOnInput)
        try values.encode(deferBlackoutDuringPlayback, forKey: .deferBlackoutDuringPlayback)
        try values.encode(deferBlackoutWhileCameraInUse, forKey: .deferBlackoutWhileCameraInUse)
    }

    /// Hidden displays count as covered, so input can't extend the timeout
    /// once the source and every hidden display are black.
    func hiddenMirrorOverlayArguments(
        for source: DisplayRecord,
        hiddenDisplays: [DisplayRecord] = [],
        otherRuleDisplays: [DisplayRecord] = []
    ) throws -> [String]? {
        try hiddenMirrorOverlayArguments(
            for: [source], hiddenDisplays: hiddenDisplays, otherRuleDisplays: otherRuleDisplays
        )
    }

    func hiddenMirrorOverlayArguments(
        for sources: [DisplayRecord],
        hiddenDisplays: [DisplayRecord] = [],
        otherRuleDisplays: [DisplayRecord] = []
    ) throws -> [String]? {
        guard !sources.isEmpty else { return nil }
        var sourceUUIDs: [String] = []
        var sourcesByUUID: [String: DisplayRecord] = [:]
        for source in sources {
            guard let uuid = source.uuid,
                  UUID(uuidString: uuid) != nil,
                  source.online, source.active, !source.asleep,
                  source.bounds.width > 0, source.bounds.height > 0 else {
                throw ProtectionConfigurationError.selectedDisplayUnavailable(source.name ?? String(source.id))
            }
            let selected = allDisplays || selectedDisplayUUIDs.contains {
                $0.caseInsensitiveCompare(uuid) == .orderedSame
            }
            guard selected else { return nil }
            let key = uuid.lowercased()
            if let existing = sourcesByUUID[key] {
                guard existing == source else {
                    throw ProtectionConfigurationError.selectedDisplayUnavailable("conflicting mirror source identities")
                }
                continue
            }
            sourcesByUUID[key] = source
            sourceUUIDs.append(uuid)
        }
        guard Self.isValidDuration(idleSeconds) else {
            throw ProtectionConfigurationError.invalidIdleDuration
        }
        if followUpAction != .untilActivity, !Self.isValidDuration(followUpSeconds) {
            throw ProtectionConfigurationError.invalidFollowUpDuration
        }

        let timeout = min(
            followUpAction == .untilActivity ? Self.hiddenMirrorOverlayMaximumDuration : followUpSeconds,
            Self.hiddenMirrorOverlayMaximumDuration
        )
        var arguments = ["blackout"]
        for uuid in sourceUUIDs.sorted() {
            arguments += ["--display", uuid, "--panelctl-hidden-mirror-source", uuid]
        }
        let sourceKeys = Set(sourceUUIDs.map { $0.lowercased() })
        var emittedHidden = Set<String>()
        let hidden = hiddenDisplays.compactMap(\.uuid).filter {
            !sourceKeys.contains($0.lowercased()) && emittedHidden.insert($0.lowercased()).inserted
        }
        let hiddenKeys = Set(hidden.map { $0.lowercased() })
        for hiddenUUID in hidden.sorted() {
            arguments += ["--panelctl-hidden-display", hiddenUUID]
        }
        var emittedSiblings = Set<String>()
        let siblings = otherRuleDisplays.compactMap(\.uuid).filter {
            let key = $0.lowercased()
            return !sourceKeys.contains(key) && !hiddenKeys.contains(key) && emittedSiblings.insert(key).inserted
        }
        for siblingUUID in siblings.sorted() {
            arguments += ["--panelctl-other-rule-display", siblingUUID]
        }
        arguments += [
            "--mode", "blocking", "--overlay-opacity", "100",
            "--idle-after", Self.durationArgument(idleSeconds), "--watch",
            "--timeout", Self.durationArgument(timeout)
        ]
        if mode == .working || keepBlackoutOnInput {
            arguments.append("--keep-blackout-on-input")
        }
        if !deferBlackoutDuringPlayback {
            arguments.append("--ignore-playback")
        }
        if deferBlackoutWhileCameraInUse {
            arguments.append("--defer-camera")
        }
        return arguments
    }

    /// Hidden displays are skipped but count as covered, so the safety
    /// rules treat them as already black.
    func commandArguments(
        for displays: [DisplayRecord],
        hiddenDisplayUUIDs: Set<String> = [],
        otherRuleDisplayUUIDs: Set<String> = [],
        ruleID: UUID? = nil
    ) throws -> [String] {
        guard Self.isValidDuration(idleSeconds) else {
            throw ProtectionConfigurationError.invalidIdleDuration
        }
        if followUpAction != .untilActivity {
            guard Self.isValidDuration(followUpSeconds) else {
                throw ProtectionConfigurationError.invalidFollowUpDuration
            }
        }
        guard (1...100).contains(workingOverlayOpacityPercent) else {
            throw ProtectionConfigurationError.invalidOverlayOpacityPercent
        }
        guard (0...100).contains(hardwareBrightnessPercent) else {
            throw ProtectionConfigurationError.invalidHardwareBrightnessPercent
        }
        if mode == .blocking && keepBlackoutOnInput && hardwareDimmingEnabled {
            throw ProtectionConfigurationError.persistentDimming
        }

        let drawable = displays.filter {
            $0.active &&
            $0.online &&
            $0.bounds.width > 0 &&
            $0.bounds.height > 0
        }
        guard !drawable.isEmpty else { throw ProtectionConfigurationError.noDisplays }
        func matches(_ record: DisplayRecord, _ uuids: Set<String>) -> Bool {
            guard let uuid = record.uuid else { return false }
            return uuids.contains { $0.caseInsensitiveCompare(uuid) == .orderedSame }
        }
        let hidden = drawable.filter { matches($0, hiddenDisplayUUIDs) }
        let hiddenIDs = Set(hidden.map(\.id))
        let otherRuleDisplays = drawable.filter {
            matches($0, otherRuleDisplayUUIDs) && !hiddenIDs.contains($0.id)
        }
        let covered = Set((hidden + otherRuleDisplays).map(\.id))
        let shown = drawable.filter { !covered.contains($0.id) }

        let selected: [DisplayRecord]
        if allDisplays {
            if followUpAction == .untilActivity {
                throw ProtectionConfigurationError.allDisplaysRequireLimit
            }
            selected = shown
        } else {
            guard !selectedDisplayUUIDs.isEmpty else {
                throw ProtectionConfigurationError.noSelection
            }
            selected = shown.filter { matches($0, selectedDisplayUUIDs) }
            if selected.isEmpty, !hidden.contains(where: { matches($0, selectedDisplayUUIDs) }) {
                let missing = selectedDisplayUUIDs.first { uuid in
                    !drawable.contains {
                        $0.uuid?.caseInsensitiveCompare(uuid) == .orderedSame
                    }
                } ?? "unknown"
                throw ProtectionConfigurationError.selectedDisplayUnavailable(
                    String(missing.prefix(8))
                )
            }
        }
        guard !selected.isEmpty else { throw ProtectionConfigurationError.selectedDisplaysHidden }
        if followUpAction == .untilActivity {
            let totalCovered = Set(selected.map(\.id)).union(covered)
            if totalCovered.count == drawable.count {
                throw hidden.isEmpty && otherRuleDisplays.isEmpty
                    ? ProtectionConfigurationError.selectionWouldCoverAllDisplays
                    : ProtectionConfigurationError.selectionWouldCoverEveryShownDisplay
            }
        }

        var arguments = ["blackout"]
        if allDisplays {
            arguments.append("--all")
        } else {
            for record in selected {
                guard let uuid = record.uuid else {
                    throw ProtectionConfigurationError.selectedDisplayUnavailable(
                        record.name ?? String(record.id)
                    )
                }
                arguments += ["--display", uuid]
            }
        }
        for uuid in hidden.compactMap(\.uuid).sorted() {
            arguments += ["--panelctl-hidden-display", uuid]
        }
        for uuid in otherRuleDisplays.compactMap(\.uuid).sorted() {
            arguments += ["--panelctl-other-rule-display", uuid]
        }
        if let ruleID {
            arguments += ["--panelctl-rule", ruleID.uuidString]
        }
        arguments += ["--mode", mode.rawValue]
        if mode == .working {
            if workingOverlayEnabled {
                arguments += ["--overlay-opacity", String(workingOverlayOpacityPercent)]
            } else {
                arguments.append("--no-overlay")
            }
        } else {
            arguments += ["--overlay-opacity", "100"]
        }
        arguments += ["--idle-after", Self.durationArgument(idleSeconds), "--watch"]
        if blackoutEmptyDisplays {
            arguments.append("--blackout-empty-displays")
        }
        switch followUpAction {
        case .untilActivity:
            break
        case .restore:
            arguments += ["--timeout", Self.durationArgument(followUpSeconds)]
        case .sleepDisplays:
            arguments += ["--sleep-after", Self.durationArgument(followUpSeconds)]
        }
        if followUpAction == .sleepDisplays && keepDisplaysAwake {
            arguments.append("--keep-displays-awake")
        }
        if keepBlackoutOnInput {
            arguments.append("--keep-blackout-on-input")
        }
        if hardwareDimmingEnabled {
            arguments += ["--dim-to", String(hardwareBrightnessPercent)]
        }
        if !deferBlackoutDuringPlayback {
            arguments.append("--ignore-playback")
        }
        if deferBlackoutWhileCameraInUse {
            arguments.append("--defer-camera")
        }
        return arguments
    }

    private static let hiddenMirrorOverlayMaximumDuration: TimeInterval = 24 * 60 * 60

    private static func durationArgument(_ seconds: TimeInterval) -> String {
        if seconds.rounded() == seconds {
            return String(Int(seconds))
        }
        return String(seconds)
    }

    private static func isValidDuration(_ seconds: TimeInterval) -> Bool {
        seconds.isFinite && seconds >= 1 && seconds <= 30 * 24 * 60 * 60
    }
}

struct ProtectionRule: Codable, Equatable, Identifiable {
    var id: UUID
    var name: String
    var isEnabled: Bool
    var settings: ProtectionPreferences

    init(
        id: UUID = UUID(),
        name: String = "Display protection",
        isEnabled: Bool = true,
        settings: ProtectionPreferences = ProtectionPreferences()
    ) {
        self.id = id
        self.name = name
        self.isEnabled = isEnabled
        self.settings = settings
        self.settings.isEnabled = false
    }
}

struct AutomationPreferences: Codable, Equatable {
    static let currentVersion = 1

    var version: Int = currentVersion
    var isEnabled = false
    var keepDisplaysAwake = true
    var rules: [ProtectionRule]

    init(
        isEnabled: Bool = false,
        keepDisplaysAwake: Bool = true,
        rules: [ProtectionRule]
    ) {
        self.version = Self.currentVersion
        self.isEnabled = isEnabled
        self.keepDisplaysAwake = keepDisplaysAwake
        self.rules = rules
    }

    private enum CodingKeys: String, CodingKey {
        case version, isEnabled, keepDisplaysAwake, rules
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = try values.decode(Int.self, forKey: .version)
        guard version == Self.currentVersion else {
            throw DecodingError.dataCorruptedError(
                forKey: .version, in: values,
                debugDescription: "Unsupported automation rule-set version."
            )
        }
        isEnabled = try values.decode(Bool.self, forKey: .isEnabled)
        keepDisplaysAwake = try values.decode(Bool.self, forKey: .keepDisplaysAwake)
        rules = try values.decode([ProtectionRule].self, forKey: .rules)
    }

    static func migrate(legacyData: Data?, displays: [DisplayRecord]) -> Self {
        var legacy = legacyData.flatMap { try? JSONDecoder().decode(ProtectionPreferences.self, from: $0) }
            ?? ProtectionPreferences()
        legacy.selectedDisplayUUIDs = Set(legacy.selectedDisplayUUIDs.map { $0.uppercased() })
        if !legacy.didChooseDisplays {
            let drawable = displays.filter {
                $0.active && $0.online && $0.bounds.width > 0 && $0.bounds.height > 0
            }
            let selectable = drawable.filter { $0.uuid != nil }
            let preferred = selectable.filter { !$0.builtin }
            let initial = preferred.first ?? selectable.first
            legacy.allDisplays = false
            legacy.selectedDisplayUUIDs = initial?.uuid.map { Set([$0.uppercased()]) } ?? []
            legacy.didChooseDisplays = true
        }
        let masterEnabled = legacy.isEnabled
        let keepAwake = legacy.keepDisplaysAwake
        legacy.isEnabled = false
        return Self(
            isEnabled: masterEnabled,
            keepDisplaysAwake: keepAwake,
            rules: [ProtectionRule(name: "Display protection", isEnabled: true, settings: legacy)]
        )
    }

    var firstRule: ProtectionRule? { rules.first }

    func rule(namedID id: UUID) -> ProtectionRule? {
        rules.first { $0.id == id }
    }

    mutating func renameRule(id: UUID, to proposedName: String) throws {
        let name = proposedName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw ProtectionConfigurationError.invalidRuleName }
        guard !rules.contains(where: {
            $0.id != id && $0.name.trimmingCharacters(in: .whitespacesAndNewlines)
                .caseInsensitiveCompare(name) == .orderedSame
        }) else {
            throw ProtectionConfigurationError.duplicateRuleName(name)
        }
        guard let index = rules.firstIndex(where: { $0.id == id }) else {
            throw ProtectionConfigurationError.duplicateRuleIdentity
        }
        rules[index].name = name
    }
}

struct ProtectionRuleValidation {
    let blockingReason: String?
    let waitingReason: String?
    let arguments: [String]?

    var isRunnable: Bool { blockingReason == nil && waitingReason == nil && arguments != nil }
}

enum ProtectionRuleValidator {
    static func validate(
        _ rule: ProtectionRule,
        in ruleSet: AutomationPreferences,
        displays: [DisplayRecord],
        hiddenUUIDs: Set<String> = []
    ) -> ProtectionRuleValidation {
        guard ruleSet.rules.filter({ $0.id == rule.id }).count == 1 else {
            return .init(
                blockingReason: ProtectionConfigurationError.duplicateRuleIdentity.localizedDescription,
                waitingReason: nil,
                arguments: nil
            )
        }
        let trimmedName = rule.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty, trimmedName == rule.name else {
            return .init(
                blockingReason: ProtectionConfigurationError.invalidRuleName.localizedDescription,
                waitingReason: nil,
                arguments: nil
            )
        }
        let duplicateName = ruleSet.rules.first {
            $0.id != rule.id && $0.name.trimmingCharacters(in: .whitespacesAndNewlines)
                .caseInsensitiveCompare(rule.name.trimmingCharacters(in: .whitespacesAndNewlines)) == .orderedSame
        }
        if let duplicateName {
            return .init(
                blockingReason: ProtectionConfigurationError.duplicateRuleName(duplicateName.name).localizedDescription,
                waitingReason: nil,
                arguments: nil
            )
        }
        let otherEnabled = ruleSet.rules.filter { $0.id != rule.id && $0.isEnabled }
        if rule.isEnabled {
            for other in otherEnabled {
                let sharedUUID = !rule.settings.allDisplays && !other.settings.allDisplays
                    ? rule.settings.selectedDisplayUUIDs.first { left in
                        other.settings.selectedDisplayUUIDs.contains {
                            $0.caseInsensitiveCompare(left) == .orderedSame
                        }
                    }
                    : nil
                if rule.settings.allDisplays || other.settings.allDisplays || sharedUUID != nil {
                    let sharedName = sharedUUID.flatMap { uuid in
                        displays.first { $0.uuid?.caseInsensitiveCompare(uuid) == .orderedSame }?.name
                    } ?? (sharedUUID.map { String($0.prefix(8)) } ?? "All displays")
                    let message = "\(sharedName) is also in “\(other.name)”. Remove it from one rule, or turn one off."
                    return .init(
                        blockingReason: ProtectionConfigurationError.ruleConflict(message).localizedDescription,
                        waitingReason: nil,
                        arguments: nil
                    )
                }
            }
        }
        let siblingUUIDs = Set(otherEnabled.flatMap { sibling in
            sibling.settings.allDisplays ? [] : Array(sibling.settings.selectedDisplayUUIDs)
        })
        let drawable = displays.filter {
            $0.active && $0.online && $0.bounds.width > 0 && $0.bounds.height > 0
        }
        let ownUUIDs = rule.settings.allDisplays ? [] : rule.settings.selectedDisplayUUIDs
        func contains(_ set: Set<String>, _ uuid: String?) -> Bool {
            guard let uuid else { return false }
            return set.contains { $0.caseInsensitiveCompare(uuid) == .orderedSame }
        }
        if rule.settings.followUpAction == .untilActivity {
            let targets = drawable.filter { display in
                rule.settings.allDisplays || contains(ownUUIDs, display.uuid)
            }
            let siblingDisplayIDs = Set(drawable.compactMap { display -> UInt32? in
                contains(siblingUUIDs, display.uuid) ? display.id : nil
            })
            let hiddenDisplayIDs = Set(drawable.compactMap { display -> UInt32? in
                contains(hiddenUUIDs, display.uuid) ? display.id : nil
            })
            let covered = Set(targets.map(\.id)).union(siblingDisplayIDs).union(hiddenDisplayIDs)
            if !drawable.isEmpty && covered.count == drawable.count {
                let siblingNames = otherEnabled.filter { sibling in
                    sibling.settings.allDisplays || !sibling.settings.selectedDisplayUUIDs.isEmpty
                }.map { "“\($0.name)”" }
                let companion = siblingNames.isEmpty ? "" : "With \(siblingNames.joined(separator: ", ")), "
                let message = "\(companion)this covers every display. Choose Restore or Sleep under Afterward."
                return .init(
                    blockingReason: ProtectionConfigurationError.combinedCoverage(message).localizedDescription,
                    waitingReason: nil,
                    arguments: nil
                )
            }
        }
        do {
            var settings = rule.settings
            settings.keepDisplaysAwake = ruleSet.keepDisplaysAwake
            settings.isEnabled = false
            let arguments = try settings.commandArguments(
                for: displays,
                hiddenDisplayUUIDs: hiddenUUIDs,
                otherRuleDisplayUUIDs: siblingUUIDs,
                ruleID: rule.id
            )
            return .init(blockingReason: nil, waitingReason: nil, arguments: arguments)
        } catch let error as ProtectionConfigurationError where error.waitsForDisplays {
            return .init(blockingReason: nil, waitingReason: error.localizedDescription, arguments: nil)
        } catch {
            return .init(blockingReason: error.localizedDescription, waitingReason: nil, arguments: nil)
        }
    }
}
