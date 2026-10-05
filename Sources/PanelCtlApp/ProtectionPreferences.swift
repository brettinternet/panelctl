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

    func hiddenMirrorOverlayArguments(for source: DisplayRecord) throws -> [String]? {
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
        var arguments = [
            "blackout", "--display", uuid,
            "--panelctl-hidden-mirror-source", uuid,
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
        hiddenDisplayUUIDs: Set<String> = []
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
        let shown = drawable.filter { !matches($0, hiddenDisplayUUIDs) }

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
        if !allDisplays,
           followUpAction == .untilActivity,
           Set(selected.map(\.id)) == Set(shown.map(\.id)) {
            throw hidden.isEmpty
                ? ProtectionConfigurationError.selectionWouldCoverAllDisplays
                : ProtectionConfigurationError.selectionWouldCoverEveryShownDisplay
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
