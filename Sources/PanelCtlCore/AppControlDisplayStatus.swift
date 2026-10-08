import Foundation

public enum AppControlOutcome: String, Codable, Sendable {
    /// The display reached the requested state.
    case done
    case noOp = "no-op"
    /// A safely unavailable Action target was skipped; remaining steps may run.
    case skipped
    /// PanelCtl refused to start a requested display or window action.
    case refused
    case busy
    /// The operation started but did not complete successfully.
    case failed
    /// Some part of the operation completed before a later failure or gate refusal.
    case partial
    case recoveryNeeded = "recovery-needed"
    case responseLost = "response-lost"
    /// A later step was skipped after the workflow stopped.
    case notRun = "not-run"

    public var exitCode: Int32 {
        switch self {
        case .done, .noOp, .skipped: return 0
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

/// Session-only progress for an explicitly running one-shot Automation rule.
public struct AppControlRunningRule: Codable, Equatable, Sendable {
    public let id: UUID
    public let name: String

    public init(id: UUID, name: String) {
        self.id = id
        self.name = name
    }
}

/// Stable, privacy-safe reasons used by one-shot window relocation results.
public enum AppControlWindowMoveReason: String, Codable, CaseIterable, Error, Sendable {
    case noWindows = "no-windows"
    case sourceUnavailable = "source-unavailable"
    case noDestination = "no-destination"
    case destinationUnavailable = "destination-unavailable"
    case identityAmbiguous = "identity-ambiguous"
    case recoveryRequired = "recovery-required"
    case permissionMissing = "permission-missing"
    case permissionStale = "permission-stale"
    case topologyChanged = "topology-changed"
    case fullscreen
    case minimized
    case visibilityUnverified = "visibility-unverified"
    case vanished
    case nonmovable
    case unattributed
    case appTimeout = "app-timeout"
    case enumerationFailed = "enumeration-failed"
    case moveFailed = "move-failed"
    case moveUnverified = "move-unverified"
    case cancelled
}

/// Counts are separated for window-level and app-level failures; app enumeration failures do not invent windows.
public struct AppControlWindowMoveReasonCount: Codable, Equatable, Sendable {
    public let reason: AppControlWindowMoveReason
    public let count: Int

    public init(reason: AppControlWindowMoveReason, count: Int) {
        self.reason = reason
        self.count = max(0, count)
    }
}

/// Privacy-safe one-shot window move counts. No titles or persistent window identifiers are retained.
public struct AppControlWindowMoveResult: Codable, Equatable, Sendable {
    public let moved: Int
    public let skipped: Int
    public let failed: Int
    public let reasons: [AppControlWindowMoveReasonCount]
    public let appFailures: Int
    public let appFailureReasons: [AppControlWindowMoveReasonCount]
    public let refusalReason: AppControlWindowMoveReason?

    public init(moved: Int = 0, skipped: Int = 0, failed: Int = 0,
                reasons: [AppControlWindowMoveReasonCount] = [], appFailures: Int = 0,
                appFailureReasons: [AppControlWindowMoveReasonCount] = [],
                refusalReason: AppControlWindowMoveReason? = nil) {
        self.moved = max(0, moved)
        self.skipped = max(0, skipped)
        self.failed = max(0, failed)
        self.reasons = Array(reasons.prefix(4))
        self.appFailures = max(0, appFailures)
        self.appFailureReasons = Array(appFailureReasons.prefix(4))
        self.refusalReason = refusalReason
    }
}

/// Most recently completed saved Action, exposed by status and the status stream.
public struct AppControlActionStatus: Codable, Equatable, Sendable {
    public let id: UUID
    public let name: String
    public let outcome: AppControlOutcome
    public let summary: String
    public let steps: [AppControlActionStepResult]

    public init(id: UUID, name: String, outcome: AppControlOutcome, summary: String,
                steps: [AppControlActionStepResult]) {
        self.id = id
        self.name = name
        self.outcome = outcome
        self.summary = summary
        self.steps = steps
    }
}

/// One ordered step's honest desktop, input and optional window-move result; these are not atomic.
public struct AppControlActionStepResult: Codable, Equatable, Sendable {
    public let index: Int
    public let targetUUID: String
    public let effect: String
    public let outcome: AppControlOutcome
    public let desktopSummary: String
    public let inputOutcome: DisplayInputOutcome.State?
    public let inputDetail: String?
    public let windowMove: AppControlWindowMoveResult?

    public init(index: Int, targetUUID: String, effect: String, outcome: AppControlOutcome,
                desktopSummary: String, inputOutcome: DisplayInputOutcome.State? = nil,
                inputDetail: String? = nil, windowMove: AppControlWindowMoveResult? = nil) {
        self.index = index
        self.targetUUID = targetUUID
        self.effect = effect
        self.outcome = outcome
        self.desktopSummary = desktopSummary
        self.inputOutcome = inputOutcome
        self.inputDetail = inputDetail
        self.windowMove = windowMove
    }
}
