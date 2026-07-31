import Foundation
import PanelCtlCore
import Darwin

private let maximumStatusBufferBytes = 8 * 1024
private let maximumErrorBufferBytes = 16 * 1024

enum ProtectionRuntimeState: Equatable {
    case disabled
    case snoozed(Date)
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
        case .disabled: return "Disabled"
        case .snoozed: return "Protection snoozed"
        case .starting: return "Starting…"
        case .waiting: return "Watching for inactivity"
        case .waitingForInput: return "Waiting for activity"
        case .waitingForPlayback: return "Playback detected — automatic blackout paused"
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
        case .snoozed: return "pause.circle.fill"
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
        case .waitingForPlayback: return "An active display-sleep prevention assertion was detected. The idle countdown restarts when playback ends."
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

    private(set) var state: ProtectionRuntimeState = .disabled {
        didSet {
            if oldValue != state {
                onStateChange?(state)
            }
        }
    }

    private var process: Process?
    private var currentArguments: [String]?
    private var pendingArguments: [String]?
    private var pendingControlIntent: ControlIntent?
    private var pendingControlSourceProcess: Process?
    private var inFlightControlIntent: ControlIntent?
    private var stateAfterTermination: ProtectionRuntimeState?
    private var statusBuffer = Data()
    private var errorBuffer = Data()
    private var lifetimeWriteHandle: FileHandle?
    private var forceTerminationWorkItem: DispatchWorkItem?
    private var shutdownCompletion: (() -> Void)?

    init(
        displaysAreAsleep: @escaping () -> Bool = {
            DisplayInventory.records().contains {
                $0.online && $0.asleep
            }
        }
    ) {
        self.displaysAreAsleep = displaysAreAsleep
    }

    var hasManagedProcess: Bool {
        process != nil
    }

    var canReceiveControl: Bool {
        pendingArguments != nil || (
            process?.isRunning == true &&
            lifetimeWriteHandle != nil &&
            state != .stopping
        )
    }

    func run(arguments: [String]) {
        if let process {
            if currentArguments == arguments,
               pendingArguments == nil,
               stateAfterTermination == nil,
               process.isRunning {
                return
            }
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
        launch(arguments: arguments)
    }

    func disable() {
        stop(then: .disabled)
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
        pendingArguments = nil
        pendingControlIntent = nil
        pendingControlSourceProcess = nil
        inFlightControlIntent = nil
        stateAfterTermination = .disabled
        shutdownCompletion = completion
        guard let process else {
            shutdownCompletion = nil
            completion()
            return
        }
        state = .stopping
        requestTermination(of: process)
    }

    private func stop(then finalState: ProtectionRuntimeState) {
        pendingArguments = nil
        pendingControlIntent = nil
        pendingControlSourceProcess = nil
        inFlightControlIntent = nil
        stateAfterTermination = finalState
        guard let process else {
            self.process = nil
            currentArguments = nil
            state = finalState
            return
        }
        state = .stopping
        requestTermination(of: process)
    }

    private func launch(arguments: [String]) {
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
            pendingArguments = nil
            stateAfterTermination = nil
            state = .starting
            try process.run()
            lifetimePipe.fileHandleForReading.closeFile()
            lifetimeWriteHandle = lifetimePipe.fileHandleForWriting
        } catch {
            statusPipe.fileHandleForReading.readabilityHandler = nil
            errorPipe.fileHandleForReading.readabilityHandler = nil
            lifetimePipe.fileHandleForReading.closeFile()
            lifetimePipe.fileHandleForWriting.closeFile()
            process = nil
            currentArguments = nil
            state = .failed("Could not start the watcher: \(error.localizedDescription)")
        }
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
            guard let event = try? JSONDecoder().decode(StatusEvent.self, from: Data(line)),
                  let runtimeState = BlackoutRuntimeState(rawValue: event.state) else {
                continue
            }
            if state == .stopping {
                updateInheritedControlIntent(
                    for: runtimeState,
                    from: sourceProcess
                )
                continue
            }
            updateControlIntent(for: runtimeState)
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
        for runtimeState: BlackoutRuntimeState,
        from sourceProcess: Process
    ) {
        guard pendingControlSourceProcess === sourceProcess,
              let intent = pendingControlIntent else {
            return
        }
        pendingControlIntent = Self.transition(
            intent,
            for: runtimeState
        )
        if pendingControlIntent == nil {
            pendingControlSourceProcess = nil
        }
    }

    private func updateControlIntent(for runtimeState: BlackoutRuntimeState) {
        guard let intent = inFlightControlIntent else { return }
        inFlightControlIntent = Self.transition(intent, for: runtimeState)
    }

    private static func transition(
        _ currentIntent: ControlIntent,
        for runtimeState: BlackoutRuntimeState
    ) -> ControlIntent? {
        var intent = currentIntent
        switch intent.command {
        case .blackoutNow:
            switch runtimeState {
            case .blackedOut, .sleeping:
                intent.isApplied = true
            case .waiting where intent.isApplied:
                return nil
            default:
                break
            }
        case .restore:
            switch runtimeState {
            case .waiting:
                intent.isApplied = true
            case .blackedOut where intent.isApplied:
                return nil
            default:
                break
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
            Darwin.kill(runningProcess.processIdentifier, SIGKILL)
        }
        forceTerminationWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
    }

    private func processDidTerminate(_ finished: Process) {
        guard process === finished else { return }
        let terminatedArguments = currentArguments
        forceTerminationWorkItem?.cancel()
        forceTerminationWorkItem = nil
        lifetimeWriteHandle?.closeFile()
        lifetimeWriteHandle = nil
        process = nil
        currentArguments = nil
        statusBuffer.removeAll(keepingCapacity: true)

        if let pendingArguments {
            self.pendingArguments = nil
            pendingControlSourceProcess = nil
            launch(arguments: pendingArguments)
            return
        }
        if let finalState = stateAfterTermination {
            pendingControlSourceProcess = nil
            inFlightControlIntent = nil
            stateAfterTermination = nil
            state = finalState
            let completion = shutdownCompletion
            shutdownCompletion = nil
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

    private static func helperExecutableURL() throws -> URL {
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

private struct StatusEvent: Decodable {
    let state: String
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
