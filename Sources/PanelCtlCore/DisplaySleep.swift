import Foundation

public enum DisplaySleepError: Error, CustomStringConvertible {
    case commandFailed(String, Int32, String)

    public var description: String {
        switch self {
        case .commandFailed(let command, let status, let stderr):
            let detail = stderr.isEmpty ? "" : ": \(stderr)"
            return "\(command) failed with status \(status)\(detail)"
        }
    }
}

public final class DisplaySleepController {
    private var assertion: CaffeinateAssertion?
    private var signalSources: [DispatchSourceSignal] = []
    private var timer: DispatchWorkItem?

    public init() {}

    public func start(keepSystemAwake: Bool, timeout: TimeInterval?) throws {
        if keepSystemAwake {
            assertion = try CaffeinateAssertion()
            installSignals()
            if let timeout {
                let work = DispatchWorkItem { [weak self] in self?.stop() }
                timer = work
                DispatchQueue.main.asyncAfter(deadline: .now() + timeout, execute: work)
            }
        }

        do {
            try Self.run("/usr/bin/pmset", arguments: ["displaysleepnow"])
        } catch {
            stop()
            throw error
        }
    }

    public func runUntilTermination() {
        while assertion?.isRunning == true {
            _ = RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.25))
        }
    }

    public func stop() {
        timer?.cancel()
        timer = nil
        signalSources.forEach { $0.cancel() }
        signalSources.removeAll()
        for number in [SIGINT, SIGTERM, SIGHUP] {
            signal(number, SIG_DFL)
        }
        assertion?.stop()
        assertion = nil
    }

    public static func wake() throws {
        try run("/usr/bin/caffeinate", arguments: ["-u", "-t", "1"])
    }

    private func installSignals() {
        for number in [SIGINT, SIGTERM, SIGHUP] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler { [weak self] in self?.stop() }
            source.resume()
            signalSources.append(source)
        }
    }

    public static func sleep() throws {
        try run("/usr/bin/pmset", arguments: ["displaysleepnow"])
    }

    private static func run(_ executable: String, arguments: [String]) throws {
        let process = Process()
        let stderr = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let data = stderr.fileHandleForReading.readDataToEndOfFile()
            let message = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw DisplaySleepError.commandFailed(executable, process.terminationStatus, message)
        }
    }
}

final class CaffeinateAssertion {
    private let process: Process

    var isRunning: Bool { process.isRunning }

    init() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")
        process.arguments = ["-i", "-w", String(ProcessInfo.processInfo.processIdentifier)]
        try process.run()
        self.process = process
    }

    func stop() {
        guard process.isRunning else { return }
        process.terminate()
        process.waitUntilExit()
    }
}
