import Foundation
import PanelCtlCore
import Darwin
import OSLog

private let maximumStatusBufferBytes = 8 * 1024
private let maximumErrorBufferBytes = 16 * 1024
private let shutdownLogger = Logger(
    subsystem: "com.brettinternet.panelctl",
    category: "shutdown"
)

enum ProtectionRuntimeState: Equatable {
    case disabled
    case snoozed(Date)
    case disconnectPaused
    case starting
    case waiting
    case waitingForInput
    case waitingForPlayback
    case blackedOut
    case sleeping
    case stopping
    case waitingForDisplays(String)
    case failed(String)

    var label: String {
        switch self {
        case .disabled: return "Automation off"
        case .snoozed: return "Automation paused"
        case .disconnectPaused: return "Paused for Full disconnect"
        case .starting: return "Starting…"
        case .waiting: return "Watching for inactivity"
        case .waitingForInput: return "Waiting for activity"
        case .waitingForPlayback: return "Paused for media or camera"
        case .blackedOut: return "Blackout active"
        case .sleeping: return "Displays sleeping"
        case .stopping: return "Stopping…"
        case .waitingForDisplays: return "Waiting for selected displays"
        case .failed: return "Needs attention"
        }
    }

    var systemImage: String {
        switch self {
        case .disabled: return "shield"
        case .snoozed, .disconnectPaused: return "pause.circle.fill"
        case .starting, .waiting, .waitingForInput, .waitingForPlayback: return "shield.fill"
        case .blackedOut: return "rectangle.fill"
        case .sleeping: return "moon.fill"
        case .stopping: return "shield"
        case .waitingForDisplays: return "shield"
        case .failed: return "exclamationmark.triangle.fill"
        }
    }

    var errorMessage: String? {
        if case .failed(let message) = self { return message }
        return nil
    }

    var detailMessage: String? {
        switch self {
        case .waitingForDisplays(let message), .failed(let message): return message
        case .waitingForPlayback: return "The idle countdown restarts when it ends."
        case .disconnectPaused: return "Automation resumes with a fresh countdown only after cancellation or verified recovery. Preferences and snooze stay unchanged."
        case .snoozed(let until):
            return "Resumes \(until.formatted(date: .abbreviated, time: .shortened))"
        default: return nil
        }
    }
}

@MainActor
final class ProtectionService {
    private struct ControlIntent {
        let command: BlackoutControlCommand
        var isApplied = false
        var didRetryAfterCleanExit = false

        var replayed: Self {
            Self(
                command: command,
                didRetryAfterCleanExit: didRetryAfterCleanExit
            )
        }

        var retryingAfterCleanExit: Self {
            Self(
                command: command,
                didRetryAfterCleanExit: true
            )
        }
    }

    private let displaysAreAsleep: () -> Bool
    var onStateChange: ((ProtectionRuntimeState) -> Void)?
    var onMembershipChange: ((Set<UInt32>) -> Void)?

    private(set) var state: ProtectionRuntimeState = .disabled {
        didSet {
            if oldValue != state {
                onStateChange?(state)
            }
        }
    }
    private(set) var blackedOutDisplayIDs: Set<UInt32> = [] {
        didSet {
            if oldValue != blackedOutDisplayIDs {
                onMembershipChange?(blackedOutDisplayIDs)
            }
        }
    }

    private var process: Process?
    private var currentArguments: [String]?
    private var currentRunIsOneShot = false
    private var pendingArguments: [String]?
    private var pendingRunIsOneShot = false
    private var oneShotLifecycleActive = false
    private var oneShotInstallationReported = false
    private var oneShotInstalledCompletion: ((Bool, String?) -> Void)?
    private var oneShotFinishedCompletion: ((Bool, String?) -> Void)?
    private var pendingControlIntent: ControlIntent?
    private var pendingControlSourceProcess: Process?
    private var pendingDisplayRearm = false
    private var inFlightControlIntent: ControlIntent?
    private var stateAfterTermination: ProtectionRuntimeState?
    private var statusBuffer = Data()
    private var errorBuffer = Data()
    private var lifetimeWriteHandle: FileHandle?
    private var forceTerminationWorkItem: DispatchWorkItem?
    private var shutdownCompletion: (() -> Void)?
    private var stopCompletions: [((Bool, String?) -> Void)] = []
    private var cleanupResultObserved: Bool?
    private(set) var unresolvedCleanupFailure: String?
    private let cleanupIsVerified: () -> Bool
    private let cleanupRuleID: UUID?
    private var cleanupRetryCompletion: ((Bool, String?) -> Void)?
    private var cleanupOnly = false
    private static let unknownCleanup = "Automation cleanup couldn\u{2019}t confirm brightness was restored."
    private var shutdownStartedAt: TimeInterval?

    init(
        initialCleanupFailure: String? = nil,
        cleanupRuleID: UUID? = nil,
        cleanupIsVerified: (() -> Bool)? = nil,
        displaysAreAsleep: @escaping () -> Bool = {
            DisplayInventory.records().contains {
                $0.online && $0.asleep
            }
        }
    ) {
        self.displaysAreAsleep = displaysAreAsleep
        self.cleanupRuleID = cleanupRuleID
        let verify = cleanupIsVerified ?? { BlackoutController.brightnessCleanupIsVerified(ruleID: cleanupRuleID) }
        self.cleanupIsVerified = verify
        self.unresolvedCleanupFailure = initialCleanupFailure ??
            (verify() ? nil : Self.unknownCleanup)
    }

    var hasManagedProcess: Bool {
        process != nil
    }

    var isRunningOneShot: Bool { oneShotLifecycleActive }

    var hasActiveEffect: Bool {
        state == .starting || state == .blackedOut || state == .sleeping || state == .stopping ||
            !blackedOutDisplayIDs.isEmpty
    }

    var canStartOneShot: Bool {
        guard !oneShotLifecycleActive, cleanupRetryCompletion == nil, shutdownCompletion == nil,
              unresolvedCleanupFailure == nil else { return false }
        guard let process else { return true }
        return process.isRunning && pendingArguments == nil && stateAfterTermination == nil &&
            ![.starting, .stopping, .blackedOut, .sleeping].contains(state) && blackedOutDisplayIDs.isEmpty
    }

    var canReceiveControl: Bool {
        pendingArguments != nil || (
            process?.isRunning == true &&
            lifetimeWriteHandle != nil &&
            state != .stopping
        )
    }

    func run(arguments: [String], restartForDisplayChange: Bool = false) {
        guard cleanupRetryCompletion == nil, shutdownCompletion == nil, !oneShotLifecycleActive else { return }
        if restartForDisplayChange {
            pendingDisplayRearm = true
        }
        if let process {
            if !restartForDisplayChange,
               currentArguments == arguments,
               pendingArguments == nil,
               stateAfterTermination == nil,
               process.isRunning {
                return
            }
            blackedOutDisplayIDs = []
            pendingArguments = arguments
            if pendingControlIntent == nil {
                pendingControlIntent = inFlightControlIntent
                if pendingControlIntent != nil {
                    pendingControlSourceProcess = process
                }
            }
            inFlightControlIntent = nil
            stateAfterTermination = nil
            state = .stopping
            requestTermination(of: process)
            return
        }
        blackedOutDisplayIDs = []
        launch(arguments: arguments)
    }

    func disable() {
        guard cleanupRetryCompletion == nil else { return }
        stop(then: .disabled)
    }

    @discardableResult
    func runOneShot(
        arguments: [String],
        onInstalled: @escaping (Bool, String?) -> Void,
        onFinished: @escaping (Bool, String?) -> Void
    ) -> Bool {
        guard canStartOneShot else { return false }
        oneShotLifecycleActive = true
        oneShotInstallationReported = false
        oneShotInstalledCompletion = onInstalled
        oneShotFinishedCompletion = onFinished
        if let process {
            blackedOutDisplayIDs = []
            pendingArguments = arguments
            pendingRunIsOneShot = true
            pendingControlIntent = nil
            pendingControlSourceProcess = nil
            inFlightControlIntent = nil
            stateAfterTermination = nil
            state = .stopping
            requestTermination(of: process)
        } else {
            blackedOutDisplayIDs = []
            _ = launch(arguments: arguments, oneShot: true)
        }
        return true
    }

    @discardableResult
    func stopOneShot() -> Bool {
        guard oneShotLifecycleActive else { return false }
        stop(then: .disabled)
        return true
    }

    func retryCleanup(completion: @escaping (Bool, String?) -> Void) {
        guard cleanupRetryCompletion == nil, shutdownCompletion == nil else { return }
        cleanupRetryCompletion = completion
        stop(then: .disabled) { [weak self] _, _ in
            guard let self else { return }
            guard self.shutdownCompletion == nil else {
                self.finishCleanupRetry(succeeded: false, message: "Automation cleanup was cancelled by shutdown.")
                return
            }
            self.launch(arguments: [], cleanupOnly: true)
        }
    }

    private func finishCleanupRetry(succeeded: Bool, message: String?) {
        let completion = cleanupRetryCompletion
        cleanupRetryCompletion = nil
        cleanupOnly = false
        completion?(succeeded, message)
    }

    func disableForDisplayHide(completion: @escaping (Bool, String?) -> Void) {
        if let retryCompletion = cleanupRetryCompletion {
            // External journal discovery can request quiescence during retry.
            // Join that cleanup rather than kill it or acknowledge too early.
            cleanupRetryCompletion = { succeeded, message in
                retryCompletion(succeeded, message)
                completion(succeeded, message)
            }
            return
        }
        stop(then: .disabled, completion: completion)
    }

    func fail(_ message: String) {
        stop(then: .failed(message))
    }

    func waitForDisplays(_ message: String) {
        stop(then: .waitingForDisplays(message))
    }

    @discardableResult
    func sendControl(_ command: BlackoutControlCommand) throws -> Bool {
        let existingIntent = pendingControlIntent ?? inFlightControlIntent
        if command == .restore {
            let hasActiveBlackout = state == .blackedOut ||
                state == .sleeping ||
                !blackedOutDisplayIDs.isEmpty ||
                displaysAreAsleep() ||
                existingIntent?.command == .blackoutNow ||
                existingIntent?.command == .restore
            guard hasActiveBlackout else { return false }
        }
        if existingIntent?.command == command {
            if pendingControlSourceProcess != nil {
                pendingControlIntent = existingIntent?.replayed
                pendingControlSourceProcess = nil
                return true
            }
            if command != .restore ||
                state != .sleeping ||
                existingIntent?.isApplied == true {
                return true
            }
        }
        let intent = ControlIntent(command: command)
        if pendingArguments != nil || state == .starting {
            pendingControlIntent = intent
            pendingControlSourceProcess = nil
            inFlightControlIntent = nil
            return true
        }
        guard state != .stopping else { throw HelperError.notRunning }
        if let process,
           process.isRunning,
           let lifetimeWriteHandle {
            try Self.writeControl(command, to: lifetimeWriteHandle)
            inFlightControlIntent = intent
            return true
        }
        throw HelperError.notRunning
    }

    func shutdown(completion: @escaping () -> Void) {
        shutdownStartedAt = ProcessInfo.processInfo.systemUptime
        shutdownLogger.info("Blackout helper shutdown requested")
        pendingArguments = nil
        pendingRunIsOneShot = false
        pendingControlIntent = nil
        pendingControlSourceProcess = nil
        pendingDisplayRearm = false
        inFlightControlIntent = nil
        stateAfterTermination = .disabled
        shutdownCompletion = completion
        blackedOutDisplayIDs = []
        guard let process else {
            shutdownLogger.info("Blackout helper was not running")
            shutdownStartedAt = nil
            shutdownCompletion = nil
            completion()
            return
        }
        state = .stopping
        requestTermination(of: process)
    }

    private func stop(
        then finalState: ProtectionRuntimeState,
        completion: ((Bool, String?) -> Void)? = nil
    ) {
        if let completion {
            stopCompletions.append(completion)
        }
        pendingArguments = nil
        pendingRunIsOneShot = false
        pendingControlIntent = nil
        pendingControlSourceProcess = nil
        pendingDisplayRearm = false
        inFlightControlIntent = nil
        stateAfterTermination = finalState
        blackedOutDisplayIDs = []
        guard let process else {
            self.process = nil
            currentArguments = nil
            if let unresolvedCleanupFailure {
                state = .failed(unresolvedCleanupFailure)
                finishStopCompletions(succeeded: false, message: unresolvedCleanupFailure)
            } else {
                state = finalState
                finishStopCompletions(succeeded: true)
            }
            if oneShotLifecycleActive {
                finishOneShot(succeeded: unresolvedCleanupFailure == nil, message: unresolvedCleanupFailure)
            }
            return
        }
        state = .stopping
        requestTermination(of: process)
    }

    private func finishStopCompletions(succeeded: Bool, message: String? = nil) {
        let completions = stopCompletions
        stopCompletions.removeAll()
        completions.forEach { $0(succeeded, message) }
    }

    @discardableResult
    private func launch(arguments: [String], cleanupOnly: Bool = false, oneShot: Bool = false) -> Bool {
        self.cleanupOnly = cleanupOnly
        currentRunIsOneShot = oneShot
        let statusPipe = Pipe()
        let errorPipe = Pipe()
        let lifetimePipe = Pipe()
        do {
            let helperURL = try Self.helperExecutableURL()
            let process = Process()
            process.executableURL = helperURL
            process.arguments = arguments
            process.standardInput = lifetimePipe
            process.standardOutput = statusPipe
            process.standardError = errorPipe
            var environment = ProcessInfo.processInfo.environment
            environment["PANELCTL_EMIT_STATUS"] = "1"
            environment["PANELCTL_PARENT_PIPE"] = "1"
            environment["PANELCTL_CLEANUP_ONLY"] = cleanupOnly ? "1" : nil
            environment["PANELCTL_CLEANUP_RULE_ID"] = cleanupOnly ? cleanupRuleID?.uuidString : nil
            if pendingDisplayRearm {
                environment["PANELCTL_REARM_ON_START"] = "1"
            }
            pendingDisplayRearm = false
            process.environment = environment
            guard fcntl(
                lifetimePipe.fileHandleForWriting.fileDescriptor,
                F_SETNOSIGPIPE,
                1
            ) == 0 else {
                throw HelperError.controlPipe(String(cString: strerror(errno)))
            }

            statusBuffer.removeAll(keepingCapacity: true)
            errorBuffer.removeAll(keepingCapacity: true)
            cleanupResultObserved = nil
            statusPipe.fileHandleForReading.readabilityHandler = { [weak self, weak process] handle in
                let data = handle.availableData
                guard !data.isEmpty, let process else {
                    handle.readabilityHandler = nil
                    return
                }
                DispatchQueue.main.async {
                    self?.consumeStatus(data, from: process)
                }
            }
            errorPipe.fileHandleForReading.readabilityHandler = { [weak self, weak process] handle in
                let data = handle.availableData
                guard !data.isEmpty, let process else {
                    handle.readabilityHandler = nil
                    return
                }
                DispatchQueue.main.async {
                    self?.consumeError(data, from: process)
                }
            }
            process.terminationHandler = { [weak self] finished in
                statusPipe.fileHandleForReading.readabilityHandler = nil
                errorPipe.fileHandleForReading.readabilityHandler = nil
                let remainingStatus = readImmediatelyAvailableData(
                    from: statusPipe.fileHandleForReading,
                    maximumBytes: maximumStatusBufferBytes
                )
                let remainingError = readImmediatelyAvailableData(
                    from: errorPipe.fileHandleForReading,
                    maximumBytes: maximumErrorBufferBytes
                )
                try? statusPipe.fileHandleForReading.close()
                try? errorPipe.fileHandleForReading.close()
                DispatchQueue.main.async {
                    self?.consumeStatus(remainingStatus, from: finished)
                    self?.consumeError(remainingError, from: finished)
                    self?.processDidTerminate(finished)
                }
            }

            self.process = process
            currentArguments = arguments
            currentRunIsOneShot = oneShot
            pendingArguments = nil
            pendingRunIsOneShot = false
            stateAfterTermination = nil
            state = .starting
            try process.run()
            lifetimePipe.fileHandleForReading.closeFile()
            lifetimeWriteHandle = lifetimePipe.fileHandleForWriting
            if cleanupOnly {
                let timeout = DispatchWorkItem { [weak self, weak process] in
                    guard let self, let process, self.process === process else { return }
                    self.requestTermination(of: process)
                }
                forceTerminationWorkItem = timeout
                DispatchQueue.main.asyncAfter(deadline: .now() + 30, execute: timeout)
            }
            return true
        } catch {
            statusPipe.fileHandleForReading.readabilityHandler = nil
            errorPipe.fileHandleForReading.readabilityHandler = nil
            lifetimePipe.fileHandleForReading.closeFile()
            lifetimePipe.fileHandleForWriting.closeFile()
            process = nil
            currentArguments = nil
            currentRunIsOneShot = false
            let message = "Could not start the helper: \(error.localizedDescription)"
            state = .failed(message)
            if cleanupOnly {
                finishCleanupRetry(succeeded: false, message: message)
            }
            if oneShot { finishOneShot(succeeded: false, message: message) }
            return false
        }
    }

    private func reportOneShotInstalled(_ succeeded: Bool, message: String? = nil) {
        guard oneShotLifecycleActive, !oneShotInstallationReported else { return }
        oneShotInstallationReported = true
        let completion = oneShotInstalledCompletion
        oneShotInstalledCompletion = nil
        completion?(succeeded, message)
    }

    private func finishOneShot(succeeded: Bool, message: String? = nil) {
        guard oneShotLifecycleActive else { return }
        if !oneShotInstallationReported {
            reportOneShotInstalled(false, message: message ?? "The one-shot rule ended before its effect was installed.")
        }
        oneShotLifecycleActive = false
        oneShotInstallationReported = false
        oneShotInstalledCompletion = nil
        let completion = oneShotFinishedCompletion
        oneShotFinishedCompletion = nil
        completion?(succeeded, message)
    }

    private func consumeStatus(_ data: Data, from sourceProcess: Process) {
        guard !data.isEmpty,
              process === sourceProcess else {
            return
        }
        statusBuffer.append(data)
        if statusBuffer.count > maximumStatusBufferBytes {
            statusBuffer.removeAll(keepingCapacity: true)
            return
        }
        while let newline = statusBuffer.firstIndex(of: 0x0A) {
            let line = statusBuffer[..<newline]
            statusBuffer.removeSubrange(...newline)
            guard let status = try? JSONDecoder().decode(
                BlackoutRuntimeStatus.self,
                from: Data(line)
            ) else {
                continue
            }
            let runtimeState = status.state
            if runtimeState == .stopped {
                cleanupResultObserved = status.cleanupSucceeded
            }
            if state == .stopping {
                updateInheritedControlIntent(for: status, from: sourceProcess)
                continue
            }
            blackedOutDisplayIDs = Set(status.blackedOutDisplayIDs)
            updateControlIntent(for: status)
            if currentRunIsOneShot && (runtimeState == .blackedOut || runtimeState == .sleeping) {
                reportOneShotInstalled(true)
            }
            switch runtimeState {
            case .waiting: self.state = .waiting
            case .waitingForInput: self.state = .waitingForInput
            case .waitingForPlayback: self.state = .waitingForPlayback
            case .blackedOut: self.state = .blackedOut
            case .sleeping: self.state = .sleeping
            case .stopped:
                if self.state != .stopping {
                    self.state = .stopping
                }
            }
            if runtimeState == .waiting || runtimeState == .waitingForPlayback {
                deliverPendingControl(to: sourceProcess)
            }
        }
    }

    private func deliverPendingControl(to sourceProcess: Process) {
        guard process === sourceProcess,
              sourceProcess.isRunning,
              let intent = pendingControlIntent,
              let lifetimeWriteHandle else {
            return
        }
        pendingControlIntent = nil
        pendingControlSourceProcess = nil
        do {
            try Self.writeControl(intent.command, to: lifetimeWriteHandle)
            inFlightControlIntent = intent.replayed
        } catch {
            inFlightControlIntent = nil
            stateAfterTermination = .failed(
                "Could not control the watcher: \(error.localizedDescription)"
            )
            state = .stopping
            requestTermination(of: sourceProcess)
        }
    }

    private func updateInheritedControlIntent(
        for status: BlackoutRuntimeStatus,
        from sourceProcess: Process
    ) {
        guard pendingControlSourceProcess === sourceProcess,
              let intent = pendingControlIntent else {
            return
        }
        pendingControlIntent = Self.transition(intent, for: status)
        if pendingControlIntent == nil {
            pendingControlSourceProcess = nil
        }
    }

    private func updateControlIntent(for status: BlackoutRuntimeStatus) {
        guard let intent = inFlightControlIntent else { return }
        inFlightControlIntent = Self.transition(intent, for: status)
    }

    private static func transition(
        _ currentIntent: ControlIntent,
        for status: BlackoutRuntimeStatus
    ) -> ControlIntent? {
        var intent = currentIntent
        switch intent.command {
        case .blackoutNow:
            switch status.state {
            case .blackedOut, .sleeping:
                intent.isApplied = true
            case .waiting where intent.isApplied:
                return nil
            default:
                break
            }
        case .restore:
            if status.state == .waiting && status.blackedOutDisplayIDs.isEmpty {
                intent.isApplied = true
            } else if !status.blackedOutDisplayIDs.isEmpty && intent.isApplied {
                return nil
            }
        }
        return intent
    }

    private func consumeError(_ data: Data, from sourceProcess: Process) {
        guard !data.isEmpty, process === sourceProcess else { return }
        errorBuffer.append(data)
        if errorBuffer.count > maximumErrorBufferBytes {
            errorBuffer.removeFirst(errorBuffer.count - maximumErrorBufferBytes)
        }
    }

    private func requestTermination(of runningProcess: Process) {
        lifetimeWriteHandle?.closeFile()
        lifetimeWriteHandle = nil
        guard runningProcess.isRunning else { return }
        runningProcess.terminate()

        forceTerminationWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self, weak runningProcess] in
            guard let self,
                  let runningProcess,
                  self.process === runningProcess,
                  runningProcess.isRunning else {
                return
            }
            shutdownLogger.error(
                "Blackout helper did not exit within 2 seconds; sending SIGKILL"
            )
            Darwin.kill(runningProcess.processIdentifier, SIGKILL)
        }
        forceTerminationWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
    }

    private func processDidTerminate(_ finished: Process) {
        guard process === finished else { return }
        let terminatedArguments = currentArguments
        let terminatedWasOneShot = currentRunIsOneShot
        currentRunIsOneShot = false
        forceTerminationWorkItem?.cancel()
        forceTerminationWorkItem = nil
        lifetimeWriteHandle?.closeFile()
        lifetimeWriteHandle = nil
        process = nil
        currentArguments = nil
        statusBuffer.removeAll(keepingCapacity: true)
        blackedOutDisplayIDs = []
        let windowOnlyOverlay = Self.isHardwareFreeHiddenMirrorOverlay(arguments: terminatedArguments)
        if cleanupOnly {
            let succeeded = cleanupResultObserved == true &&
                finished.terminationReason == .exit && finished.terminationStatus == 0
            unresolvedCleanupFailure = succeeded ? nil : (unresolvedCleanupFailure ?? Self.unknownCleanup)
            stateAfterTermination = nil
            state = succeeded ? .disabled : .failed(unresolvedCleanupFailure!)
            finishStopCompletions(succeeded: succeeded, message: unresolvedCleanupFailure)
            finishCleanupRetry(succeeded: succeeded, message: unresolvedCleanupFailure)
            let completion = shutdownCompletion
            shutdownCompletion = nil
            shutdownStartedAt = nil
            completion?()
            return
        }
        if !windowOnlyOverlay {
            if cleanupResultObserved == false {
                unresolvedCleanupFailure = "Hardware brightness cleanup failed."
            } else if !cleanupIsVerified() {
                // A clean stop from a non-dimming watcher cannot certify a
                // brightness journal left by a previous process.
                unresolvedCleanupFailure = unresolvedCleanupFailure ?? Self.unknownCleanup
            }
        }

        if let pendingArguments {
            let pendingIsOneShot = pendingRunIsOneShot
            self.pendingArguments = nil
            pendingRunIsOneShot = false
            pendingControlSourceProcess = nil
            if let unresolvedCleanupFailure {
                state = .failed(unresolvedCleanupFailure)
                if pendingIsOneShot { finishOneShot(succeeded: false, message: unresolvedCleanupFailure) }
                return
            }
            _ = launch(arguments: pendingArguments, oneShot: pendingIsOneShot)
            return
        }
        if terminatedWasOneShot {
            let intentionalStop = stateAfterTermination != nil
            let finalState = stateAfterTermination ?? .disabled
            stateAfterTermination = nil
            pendingControlIntent = nil
            pendingControlSourceProcess = nil
            inFlightControlIntent = nil
            let exitWasClean = finished.terminationReason == .exit && finished.terminationStatus == 0
            let cleanupVerified = cleanupResultObserved == true && cleanupIsVerified() && unresolvedCleanupFailure == nil
            let succeeded = cleanupVerified && (intentionalStop || exitWasClean)
            let errorText = String(data: errorBuffer, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let failure = succeeded ? nil : unresolvedCleanupFailure ??
                (errorText?.isEmpty == false ? errorText : nil) ??
                "The one-shot helper exited before cleanup was verified."
            errorBuffer.removeAll(keepingCapacity: true)
            if let failure {
                state = .failed(failure)
            } else {
                state = finalState
            }
            finishStopCompletions(succeeded: succeeded, message: failure)
            finishOneShot(succeeded: succeeded, message: failure)
            let completion = shutdownCompletion
            shutdownCompletion = nil
            shutdownStartedAt = nil
            completion?()
            return
        }
        if let finalState = stateAfterTermination {
            pendingControlSourceProcess = nil
            inFlightControlIntent = nil
            stateAfterTermination = nil
            // Process death removes windows. Exit status alone is not a
            // cleanup failure when the locked luminance journal is empty.
            let stopFailure = unresolvedCleanupFailure
            cleanupResultObserved = nil
            if let stopFailure {
                state = .failed(stopFailure)
                finishStopCompletions(succeeded: false, message: stopFailure)
            } else {
                state = finalState
                finishStopCompletions(succeeded: true)
            }
            if oneShotLifecycleActive {
                finishOneShot(succeeded: stopFailure == nil, message: stopFailure)
            }
            let completion = shutdownCompletion
            shutdownCompletion = nil
            if let startedAt = shutdownStartedAt {
                let elapsed = ProcessInfo.processInfo.systemUptime - startedAt
                let duration = String(format: "%.3f", elapsed)
                shutdownLogger.info(
                    "Blackout helper exited in \(duration, privacy: .public)s (reason: \(String(describing: finished.terminationReason), privacy: .public), status: \(finished.terminationStatus))"
                )
            }
            shutdownStartedAt = nil
            completion?()
            return
        }
        if finished.terminationReason == .exit,
           finished.terminationStatus == 0,
           let terminatedArguments,
           let interruptedIntent = pendingControlIntent ?? inFlightControlIntent,
           !interruptedIntent.didRetryAfterCleanExit {
            pendingControlIntent = interruptedIntent.retryingAfterCleanExit
            pendingControlSourceProcess = nil
            inFlightControlIntent = nil
            launch(arguments: terminatedArguments)
            return
        }

        let errorText = String(data: errorBuffer, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        pendingControlIntent = nil
        pendingControlSourceProcess = nil
        inFlightControlIntent = nil
        errorBuffer.removeAll(keepingCapacity: true)
        if let errorText, !errorText.isEmpty {
            state = .failed(errorText)
        } else {
            state = .failed("The watcher exited unexpectedly (status \(finished.terminationStatus)).")
        }
    }

    static func isHardwareFreeHiddenMirrorOverlay(arguments: [String]?) -> Bool {
        guard let arguments,
              let command = try? CLIParser.parse(arguments),
              case .blackout(let options) = command else { return false }
        let sources = options.hiddenMirrorSourceUUIDs.map { $0.lowercased() }
        let targets = options.selectors.map { $0.lowercased() }
        guard options.removalSessionOverlay,
              sources.allSatisfy({ UUID(uuidString: $0) != nil }),
              Set(sources).count == sources.count,
              targets.allSatisfy({ UUID(uuidString: $0) != nil }),
              Set(targets).count == targets.count,
              Set(sources).isSubset(of: Set(targets)),
              options.watch,
              options.idleAfter?.isFinite == true,
              options.timeout?.isFinite == true,
              options.sleepAfter == nil,
              !options.caffeinate,
              !options.keepDisplaysAwake,
              !options.blackoutEmptyDisplays,
              options.mode == .blocking,
              options.overlayOpacityPercent == 100,
              options.hardwareBrightnessPercent == nil else {
            return false
        }
        return true
    }

    /// The CLI bundled in the app, which also runs the blackout helper.
    static func helperExecutableURL() throws -> URL {
        let fileManager = FileManager.default
        var candidates = [
            Bundle.main.bundleURL
                .appendingPathComponent("Contents", isDirectory: true)
                .appendingPathComponent("Helpers", isDirectory: true)
                .appendingPathComponent("panelctl")
        ]
#if DEBUG
        if let override = ProcessInfo.processInfo.environment["PANELCTL_HELPER"] {
            candidates.insert(URL(fileURLWithPath: override), at: 0)
        }
        let currentExecutable = URL(fileURLWithPath: CommandLine.arguments[0])
            .standardizedFileURL
        candidates.append(
            currentExecutable.deletingLastPathComponent().appendingPathComponent("panelctl")
        )
#endif

        if let executable = candidates.first(where: {
            fileManager.isExecutableFile(atPath: $0.path)
        }) {
            return executable
        }
        throw HelperError.notFound
    }

    private static func writeControl(
        _ command: BlackoutControlCommand,
        to handle: FileHandle
    ) throws {
        let data = Data((command.rawValue + "\n").utf8)
        let descriptor = handle.fileDescriptor
        guard descriptor >= 0 else { throw HelperError.notRunning }

        var written = 0
        while written < data.count {
            let count = data.withUnsafeBytes {
                Darwin.write(
                    descriptor,
                    $0.baseAddress?.advanced(by: written),
                    data.count - written
                )
            }
            if count > 0 {
                written += count
                continue
            }
            if count < 0, errno == EINTR { continue }
            throw HelperError.controlPipe(
                count == 0
                    ? "the watcher closed its control pipe"
                    : String(cString: strerror(errno))
            )
        }
    }
}


private enum HelperError: Error, LocalizedError {
    case notFound
    case notRunning
    case controlPipe(String)

    var errorDescription: String? {
        switch self {
        case .notFound:
            return "The bundled panelctl helper could not be found."
        case .notRunning:
            return "The managed watcher is not running."
        case .controlPipe(let message):
            return "Could not send a watcher command: \(message)"
        }
    }
}

private func readImmediatelyAvailableData(
    from handle: FileHandle,
    maximumBytes: Int
) -> Data {
    let descriptor = handle.fileDescriptor
    let flags = fcntl(descriptor, F_GETFL)
    guard flags >= 0,
          fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) >= 0 else {
        return Data()
    }

    var buffer = [UInt8](repeating: 0, count: maximumBytes)
    let byteCount = buffer.withUnsafeMutableBytes { bytes in
        Darwin.read(descriptor, bytes.baseAddress, bytes.count)
    }
    guard byteCount > 0 else { return Data() }
    return Data(buffer.prefix(byteCount))
}
