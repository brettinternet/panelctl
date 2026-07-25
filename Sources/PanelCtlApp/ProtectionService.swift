import Foundation
import PanelCtlCore
import Darwin

private let maximumStatusBufferBytes = 8 * 1024
private let maximumErrorBufferBytes = 16 * 1024

enum ProtectionRuntimeState: Equatable {
    case disabled
    case starting
    case waiting
    case blackedOut
    case sleeping
    case stopping
    case waitingForDisplays(String)
    case failed(String)

    var label: String {
        switch self {
        case .disabled: return "Disabled"
        case .starting: return "Starting…"
        case .waiting: return "Watching for inactivity"
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
        case .starting, .waiting: return "shield.fill"
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
        default: return nil
        }
    }
}

@MainActor
final class ProtectionService {
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
    private var stateAfterTermination: ProtectionRuntimeState?
    private var statusBuffer = Data()
    private var errorBuffer = Data()
    private var lifetimeWriteHandle: FileHandle?
    private var forceTerminationWorkItem: DispatchWorkItem?
    private var shutdownCompletion: (() -> Void)?

    func run(arguments: [String]) {
        if let process {
            if currentArguments == arguments,
               pendingArguments == nil,
               stateAfterTermination == nil {
                return
            }
            pendingArguments = arguments
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

    func shutdown(completion: @escaping () -> Void) {
        pendingArguments = nil
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
        guard !data.isEmpty, process === sourceProcess else { return }
        statusBuffer.append(data)
        if statusBuffer.count > maximumStatusBufferBytes {
            statusBuffer.removeAll(keepingCapacity: true)
            return
        }
        while let newline = statusBuffer.firstIndex(of: 0x0A) {
            let line = statusBuffer[..<newline]
            statusBuffer.removeSubrange(...newline)
            guard let event = try? JSONDecoder().decode(StatusEvent.self, from: Data(line)),
                  let state = BlackoutRuntimeState(rawValue: event.state) else {
                continue
            }
            switch state {
            case .waiting: self.state = .waiting
            case .blackedOut: self.state = .blackedOut
            case .sleeping: self.state = .sleeping
            case .stopped:
                if self.state != .stopping {
                    self.state = .stopping
                }
            }
        }
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
        forceTerminationWorkItem?.cancel()
        forceTerminationWorkItem = nil
        lifetimeWriteHandle?.closeFile()
        lifetimeWriteHandle = nil
        process = nil
        currentArguments = nil
        statusBuffer.removeAll(keepingCapacity: true)

        if let pendingArguments {
            self.pendingArguments = nil
            launch(arguments: pendingArguments)
            return
        }
        if let finalState = stateAfterTermination {
            stateAfterTermination = nil
            state = finalState
            let completion = shutdownCompletion
            shutdownCompletion = nil
            completion?()
            return
        }

        let errorText = String(data: errorBuffer, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
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
}

private struct StatusEvent: Decodable {
    let state: String
}

private enum HelperError: Error, LocalizedError {
    case notFound

    var errorDescription: String? {
        "The bundled panelctl helper could not be found."
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
