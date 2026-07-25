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
    var caffeinate = true
    var allDisplays = false
    var selectedDisplayUUIDs: Set<String> = []
    var didChooseDisplays = false

    func commandArguments(for displays: [DisplayRecord]) throws -> [String] {
        guard Self.isValidDuration(idleSeconds) else {
            throw ProtectionConfigurationError.invalidIdleDuration
        }
        if followUpAction != .untilActivity {
            guard Self.isValidDuration(followUpSeconds) else {
                throw ProtectionConfigurationError.invalidFollowUpDuration
            }
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
            guard selected.count == selectedDisplayUUIDs.count else {
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
        if !allDisplays, Set(selected.map(\.id)) == Set(drawable.map(\.id)) {
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
        switch followUpAction {
        case .untilActivity:
            break
        case .restore:
            arguments += ["--timeout", Self.durationArgument(followUpSeconds)]
        case .sleepDisplays:
            arguments += ["--sleep-after", Self.durationArgument(followUpSeconds)]
        }
        if caffeinate {
            arguments.append("--caffeinate")
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
        seconds.isFinite && seconds > 0 && seconds <= 30 * 24 * 60 * 60
    }
}
