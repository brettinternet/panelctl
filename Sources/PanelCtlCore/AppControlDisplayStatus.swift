import Foundation

public enum AppControlOutcome: String, Codable, Sendable {
    /// The display reached the requested state.
    case done
    case noOp = "no-op"
    /// PanelCtl didn't start the Hide or Show.
    case refused
    case busy
    /// The Hide or Show started but the display didn't reach the requested state.
    case failed
    case partial
    case recoveryNeeded = "recovery-needed"
    case responseLost = "response-lost"

    public var exitCode: Int32 {
        switch self {
        case .done, .noOp: return 0
        case .refused, .busy, .failed, .responseLost: return 1
        case .partial: return 5
        case .recoveryNeeded: return 6
        }
    }
}

/// Observations and session-only operation evidence, never inferred from input preferences.
public struct AppControlDisplayStatus: Codable, Equatable, Sendable {
    public let targetUUID: String
    public let observedState: String
    public let operation: String
    public let recoveryNeeded: Bool
    public let lastInputOutcome: DisplayInputOutcome?

    public init(targetUUID: String, observedState: String, operation: String,
                recoveryNeeded: Bool, lastInputOutcome: DisplayInputOutcome?) {
        self.targetUUID = targetUUID
        self.observedState = observedState
        self.operation = operation
        self.recoveryNeeded = recoveryNeeded
        self.lastInputOutcome = lastInputOutcome
    }
}
