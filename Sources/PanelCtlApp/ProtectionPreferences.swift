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
    case persistentDimming
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
            return "When every display is selected, choose Restore or Sleep as a safety limit."
        case .selectionWouldCoverAllDisplays:
            return "To protect every display, choose All connected displays and a safety limit."
        case .persistentDimming:
            return "Turn off hardware dimming to keep blackout active during input."
        case .invalidIdleDuration:
            return "Choose a valid inactivity delay."
        case .invalidFollowUpDuration:
            return "Choose a valid Restore or Sleep delay."
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
    var dimDisplaysDuringBlackout = false
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
        dimDisplaysDuringBlackout = try values.decodeIfPresent(Bool.self, forKey: .dimDisplaysDuringBlackout) ?? false
        keepBlackoutOnInput = try values.decodeIfPresent(Bool.self, forKey: .keepBlackoutOnInput) ?? false
        deferBlackoutDuringPlayback = try values.decodeIfPresent(Bool.self, forKey: .deferBlackoutDuringPlayback) ?? true
        deferBlackoutWhileCameraInUse = try values.decodeIfPresent(
            Bool.self,
            forKey: .deferBlackoutWhileCameraInUse
        ) ?? false
    }

    func commandArguments(for displays: [DisplayRecord]) throws -> [String] {
        guard Self.isValidDuration(idleSeconds) else {
            throw ProtectionConfigurationError.invalidIdleDuration
        }
        if followUpAction != .untilActivity {
            guard Self.isValidDuration(followUpSeconds) else {
                throw ProtectionConfigurationError.invalidFollowUpDuration
            }
        }
        if keepBlackoutOnInput && dimDisplaysDuringBlackout {
            throw ProtectionConfigurationError.persistentDimming
        }

        let drawable = displays.filter {
            $0.active &&
            $0.online &&
            $0.bounds.width > 0 &&
            $0.bounds.height > 0
        }
        guard !drawable.isEmpty else { throw ProtectionConfigurationError.noDisplays }

        let selected: [DisplayRecord]
        if allDisplays {
            selected = drawable
        } else {
            guard !selectedDisplayUUIDs.isEmpty else {
                throw ProtectionConfigurationError.noSelection
            }
            selected = drawable.filter { record in
                guard let uuid = record.uuid else { return false }
                return selectedDisplayUUIDs.contains {
                    $0.caseInsensitiveCompare(uuid) == .orderedSame
                }
            }
            guard !selected.isEmpty else {
                let missing = selectedDisplayUUIDs.first { uuid in
                    !selected.contains {
                        $0.uuid?.caseInsensitiveCompare(uuid) == .orderedSame
                    }
                } ?? "unknown"
                throw ProtectionConfigurationError.selectedDisplayUnavailable(
                    String(missing.prefix(8))
                )
            }
        }

        if allDisplays && followUpAction == .untilActivity {
            throw ProtectionConfigurationError.allDisplaysRequireLimit
        }
        if !allDisplays,
           followUpAction == .untilActivity,
           Set(selected.map(\.id)) == Set(drawable.map(\.id)) {
            throw ProtectionConfigurationError.selectionWouldCoverAllDisplays
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
        if dimDisplaysDuringBlackout {
            arguments.append("--dim")
        }
        if !deferBlackoutDuringPlayback {
            arguments.append("--ignore-playback")
        }
        if deferBlackoutWhileCameraInUse {
            arguments.append("--defer-camera")
        }
        return arguments
    }

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
