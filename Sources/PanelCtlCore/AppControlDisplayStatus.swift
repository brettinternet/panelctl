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
    /// A later step was skipped after the workflow stopped.
    case notRun = "not-run"

    public var exitCode: Int32 {
        switch self {
        case .done, .noOp: return 0
        case .refused, .busy, .failed, .responseLost, .notRun: return 1
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

/// Session-only progress for an explicitly running saved Action.
public struct AppControlRunningAction: Codable, Equatable, Sendable {
    public let id: UUID
    public let name: String
    public let currentStep: Int
    public let totalSteps: Int

    public init(id: UUID, name: String, currentStep: Int, totalSteps: Int) {
        self.id = id
        self.name = name
        self.currentStep = currentStep
        self.totalSteps = totalSteps
    }
}

/// One ordered step's honest desktop and input result; these are not an atomic transaction.
public struct AppControlActionStepResult: Codable, Equatable, Sendable {
    public let index: Int
    public let targetUUID: String
    public let effect: String
    public let outcome: AppControlOutcome
    public let desktopSummary: String
    public let inputOutcome: DisplayInputOutcome.State?
    public let inputDetail: String?

    public init(index: Int, targetUUID: String, effect: String, outcome: AppControlOutcome,
                desktopSummary: String, inputOutcome: DisplayInputOutcome.State? = nil,
                inputDetail: String? = nil) {
        self.index = index
        self.targetUUID = targetUUID
        self.effect = effect
        self.outcome = outcome
        self.desktopSummary = desktopSummary
        self.inputOutcome = inputOutcome
        self.inputDetail = inputDetail
    }
}
