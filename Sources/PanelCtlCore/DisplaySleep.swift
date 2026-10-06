import Foundation
import IOKit.pwr_mgt
import Darwin

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

final class AutomationSleepGate {
    private let markerURL: URL
    private let lockURL: URL
    private var leaseFD: Int32?

    init(markerURL: URL = BlackoutController.automationSleepMarkerURL) {
        self.markerURL = markerURL
        self.lockURL = markerURL.appendingPathExtension("lock")
    }

    deinit {
        releaseLease(clearMarker: false)
    }

    @discardableResult
    func sleepOnce(_ sleep: () throws -> Void) throws -> Bool {
        guard leaseFD == nil else { return false }
        let directory = markerURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fd = open(lockURL.path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw DisplaySleepError.commandFailed("open", errno, String(cString: strerror(errno))) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            return false
        }
        var leaseAdopted = false
        do {
            try removeMarkerWhileLocked()
            let markerFD = open(
                markerURL.path,
                O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC | O_NOFOLLOW,
                S_IRUSR | S_IWUSR
            )
            guard markerFD >= 0 else {
                throw DisplaySleepError.commandFailed("create sleep marker", errno, String(cString: strerror(errno)))
            }
            close(markerFD)
            leaseFD = fd
            leaseAdopted = true
            try sleep()
            return true
        } catch {
            if leaseAdopted {
                if leaseFD == fd { releaseLease(clearMarker: true) }
            } else {
                _ = flock(fd, LOCK_UN)
                close(fd)
            }
            throw error
        }
    }

    func wakeObserved() {
        if leaseFD != nil {
            releaseLease(clearMarker: true)
            return
        }
        let fd = open(lockURL.path, O_RDWR | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else { return }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            return
        }
        defer {
            _ = flock(fd, LOCK_UN)
            close(fd)
        }
        try? removeMarkerWhileLocked()
    }

    private func removeMarkerWhileLocked() throws {
        var info = stat()
        guard lstat(markerURL.path, &info) == 0 else {
            if errno == ENOENT { return }
            throw DisplaySleepError.commandFailed("inspect sleep marker", errno, String(cString: strerror(errno)))
        }
        guard info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFREG else {
            throw DisplaySleepError.commandFailed("inspect sleep marker", EPERM, "unsafe marker type or owner")
        }
        guard unlink(markerURL.path) == 0 else {
            throw DisplaySleepError.commandFailed("remove stale sleep marker", errno, String(cString: strerror(errno)))
        }
    }

    private func releaseLease(clearMarker: Bool) {
        guard let fd = leaseFD else { return }
        if clearMarker { try? removeMarkerWhileLocked() }
        leaseFD = nil
        _ = flock(fd, LOCK_UN)
        close(fd)
    }
}

public final class DisplaySleepController {
    private var assertion: CaffeinateAssertion?
    private var signalSources: [DispatchSourceSignal] = []
    private var timer: DispatchWorkItem?

    public init() {}

    public func start(keepSystemAwake: Bool, timeout: TimeInterval?) throws {
        if keepSystemAwake {
            assertion = try CaffeinateAssertion(kind: .system)
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

    @discardableResult
    static func sleepForAutomation(gate: AutomationSleepGate) throws -> Bool {
        try gate.sleepOnce { try sleep() }
    }

    public static func automationScreensDidWake() {
        AutomationSleepGate().wakeObserved()
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

enum CaffeinateAssertionKind {
    case system
    case display
}

final class CaffeinateAssertion {
    private let process: Process?
    private var nativeID: IOPMAssertionID?

    var isRunning: Bool { nativeID != nil || process?.isRunning == true }

    init(kind: CaffeinateAssertionKind = .system) throws {
        if case .display = kind {
            var assertionID: IOPMAssertionID = 0
            let status = IOPMAssertionCreateWithDescription(
                kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                "PanelCtl display sleep timer" as CFString,
                "Keep displays awake until the configured timeout while unlocked" as CFString,
                nil,
                nil,
                0,
                nil,
                &assertionID
            )
            guard status == kIOReturnSuccess else {
                throw DisplaySleepError.commandFailed(
                    "IOPMAssertionCreateWithDescription",
                    Int32(status),
                    ""
                )
            }
            nativeID = assertionID
            process = nil
            return
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")
        process.arguments = ["-i", "-w", String(ProcessInfo.processInfo.processIdentifier)]
        try process.run()
        self.process = process
    }

    func stop() {
        if let nativeID {
            _ = IOPMAssertionRelease(nativeID)
            self.nativeID = nil
        }
        guard let process, process.isRunning else { return }
        process.terminate()
        process.waitUntilExit()
    }
}
