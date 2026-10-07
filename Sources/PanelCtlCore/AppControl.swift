import Foundation
import AppKit
import Darwin

/// Commands understood by the PanelCtl.app control socket.
public enum AppControlCommand: String, Codable, Equatable, Sendable {
    case hide
    case show
    case toggleHide = "toggle-hide"
    case runAction = "run-action"
    case runRule = "run-rule"
    case enable
    case disable
    case toggle
    case status
    case blackoutNow = "blackout-now"
    case restore
    case sleepNow = "sleep-now"
    case snooze
    case resume
    case openSettings = "open-settings"

    public static let blackoutNowMigrationGuidance =
        "app blackout-now is retired. Use `panelctl app hide --display <UUID>` to hide one display, `panelctl app run-action --action <UUID>` to run a saved Action, or `panelctl app run-rule --rule <UUID>` to run one saved Automation rule."

    /// Hide, Show and Toggle Hide act on the one display named by `--display`.
    public var isDisplayCommand: Bool {
        self == .hide || self == .show || self == .toggleHide
    }

    /// Manually invoked display operations and one-shot rules never launch or resend the app request.
    public var isManualDisplayCommand: Bool {
        isDisplayCommand || self == .runAction || self == .runRule
    }

    /// A shell command line that runs this display command with the CLI at
    /// `executable`, for pasting into a script.
    public func commandLine(executable: String, displayUUID: String) -> String {
        "\(Self.shellSafeExecutable(executable)) app \(rawValue) --display \(displayUUID)"
    }

    public func commandLine(executable: String, actionID: UUID) -> String {
        "\(Self.shellSafeExecutable(executable)) app \(rawValue) --action \(actionID.uuidString)"
    }

    public func commandLine(executable: String, ruleID: UUID) -> String {
        "\(Self.shellSafeExecutable(executable)) app \(rawValue) --rule \(ruleID.uuidString)"
    }

    private static func shellSafeExecutable(_ executable: String) -> String {
        let safe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789@%+=:,./_-")
        return !executable.isEmpty && executable.unicodeScalars.allSatisfy(safe.contains)
            ? executable
            : "'" + executable.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

public enum AppControlHideStyle: String, Codable, Equatable, Sendable {
    case blackOut = "black-out"
}

/// Versioned, newline-delimited request sent to PanelCtl.app.
public struct AppControlRequest: Codable, Equatable, Sendable {
    public static let currentProtocol = 1
    // Older apps must reject style overrides rather than silently perform removal.
    public static let hideStyleProtocol = 2

    public static let watchProtocol = 3

    public var hasSupportedProtocol: Bool {
        if watch != nil {
            return protocolVersion == Self.watchProtocol && watch == true && command == .status &&
                durationSeconds == nil && targetUUID == nil && actionID == nil && ruleID == nil && hideStyle == nil
        }
        return protocolVersion == Self.currentProtocol && hideStyle == nil ||
            protocolVersion == Self.hideStyleProtocol
    }

    public let protocolVersion: Int
    public let command: AppControlCommand
    public let durationSeconds: TimeInterval?
    public let targetUUID: String?
    public let actionID: UUID?
    public let ruleID: UUID?
    public let hideStyle: AppControlHideStyle?
    public let watch: Bool?

    public init(
        command: AppControlCommand,
        durationSeconds: TimeInterval? = nil,
        targetUUID: String? = nil,
        actionID: UUID? = nil,
        ruleID: UUID? = nil,
        hideStyle: AppControlHideStyle? = nil,
        protocolVersion: Int? = nil,
        watch: Bool? = nil
    ) {
        self.watch = watch
        self.protocolVersion = protocolVersion ?? (watch == nil ? (hideStyle == nil ? Self.currentProtocol : Self.hideStyleProtocol) : Self.watchProtocol)
        self.command = command
        self.durationSeconds = durationSeconds
        self.targetUUID = targetUUID
        self.actionID = actionID
        self.ruleID = ruleID
        self.hideStyle = hideStyle
    }

    enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol"
        case command
        case durationSeconds, targetUUID, actionID, ruleID, hideStyle, watch
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(protocolVersion, forKey: .protocolVersion)
        try container.encode(command, forKey: .command)
        try container.encodeIfPresent(durationSeconds, forKey: .durationSeconds)
        try container.encodeIfPresent(targetUUID, forKey: .targetUUID)
        try container.encodeIfPresent(actionID, forKey: .actionID)
        try container.encodeIfPresent(ruleID, forKey: .ruleID)
        try container.encodeIfPresent(hideStyle, forKey: .hideStyle)
        try container.encodeIfPresent(watch, forKey: .watch)
    }
}

public struct AppControlRuleStatus: Codable, Equatable, Sendable {
    public let id: UUID
    public let name: String
    public let enabled: Bool
    public let state: String
    public let summary: String
    public let detail: String?
    public let displays: [String]
    public let nextAction: String?
    public let secondsRemaining: Int?

    public init(id: UUID, name: String, enabled: Bool, state: String, summary: String,
                detail: String? = nil, displays: [String], nextAction: String? = nil,
                secondsRemaining: Int? = nil) {
        self.id = id
        self.name = name
        self.enabled = enabled
        self.state = state
        self.summary = summary
        self.detail = detail
        self.displays = displays
        self.nextAction = nextAction
        self.secondsRemaining = secondsRemaining
    }
}

/// Versioned response returned by PanelCtl.app.  `detail` and `error` are
/// omitted from JSON when they are not present.
public struct AppControlResponse: Codable, Equatable, Sendable {
    public let protocolVersion: Int
    public let ok: Bool
    public let running: Bool
    public let enabled: Bool
    public let state: String
    public let summary: String
    public let detail: String?
    public let error: String?
    public let nextAction: String?
    public let secondsRemaining: Int?
    public let snoozedUntil: String?
    public let outcome: AppControlOutcome?
    public let displays: [AppControlDisplayStatus]?
    public let rules: [AppControlRuleStatus]?
    public let steps: [AppControlActionStepResult]?
    public let runningAction: AppControlRunningAction?
    public let runningRule: AppControlRunningRule?
    /// Present only on a status stream; scoped to that connection.
    public var sequence: UInt64?

    public var exitCode: Int32 {
        if !running { return 3 }
        if let outcome, outcome != .noOp { return outcome.exitCode }
        return ok ? 0 : 1
    }

    public init(
        protocolVersion: Int = AppControlRequest.currentProtocol,
        ok: Bool,
        running: Bool,
        enabled: Bool,
        state: String,
        summary: String,
        detail: String? = nil,
        error: String? = nil,
        nextAction: String? = nil,
        secondsRemaining: Int? = nil,
        snoozedUntil: String? = nil,
        outcome: AppControlOutcome? = nil,
        displays: [AppControlDisplayStatus]? = nil,
        rules: [AppControlRuleStatus]? = nil,
        steps: [AppControlActionStepResult]? = nil,
        runningAction: AppControlRunningAction? = nil,
        runningRule: AppControlRunningRule? = nil
    ) {
        self.protocolVersion = protocolVersion
        self.ok = ok
        self.running = running
        self.enabled = enabled
        self.state = state
        self.summary = summary
        self.detail = detail
        self.error = error
        self.nextAction = nextAction
        self.secondsRemaining = secondsRemaining
        self.snoozedUntil = snoozedUntil
        self.outcome = outcome
        self.displays = displays
        self.rules = rules
        self.steps = steps
        self.runningAction = runningAction
        self.runningRule = runningRule
    }

    public static func unavailable(_ message: String = "PanelCtl.app is not running") -> Self {
        Self(
            ok: false,
            running: false,
            enabled: false,
            state: "unavailable",
            summary: message,
            error: message
        )
    }

    enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol"
        case ok, running, enabled, state, summary, detail, error, sequence
        case nextAction, secondsRemaining, snoozedUntil, outcome, displays, rules, steps, runningAction, runningRule
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(protocolVersion, forKey: .protocolVersion)
        try container.encode(ok, forKey: .ok)
        try container.encode(running, forKey: .running)
        try container.encode(enabled, forKey: .enabled)
        try container.encode(state, forKey: .state)
        try container.encode(summary, forKey: .summary)
        try container.encodeIfPresent(detail, forKey: .detail)
        try container.encodeIfPresent(error, forKey: .error)
        try container.encodeIfPresent(nextAction, forKey: .nextAction)
        try container.encodeIfPresent(secondsRemaining, forKey: .secondsRemaining)
        try container.encodeIfPresent(snoozedUntil, forKey: .snoozedUntil)
        try container.encodeIfPresent(outcome, forKey: .outcome)
        try container.encodeIfPresent(displays, forKey: .displays)
        try container.encodeIfPresent(rules, forKey: .rules)
        try container.encodeIfPresent(steps, forKey: .steps)
        try container.encodeIfPresent(runningAction, forKey: .runningAction)
        try container.encodeIfPresent(runningRule, forKey: .runningRule)
        try container.encodeIfPresent(sequence, forKey: .sequence)
    }
}

public enum AppControlSocket {
    public static let messageLimit = 4 * 1024
    public static let streamMessageLimit = 1024 * 1024
    static let socketName = "panelctl-app-control.sock"
    static let socketPathCapacity = MemoryLayout.size(
        ofValue: sockaddr_un().sun_path
    )

    /// Returns a per-user Darwin temporary directory.  Deliberately does not
    /// consult TMPDIR: the app and CLI must derive the same path.
    static func userTemporaryDirectory() throws -> String {
        let required = confstr(_CS_DARWIN_USER_TEMP_DIR, nil, 0)
        guard required > 0 else { throw AppControlError.socketPathUnavailable }
        var buffer = [CChar](repeating: 0, count: Int(required))
        let actual = confstr(_CS_DARWIN_USER_TEMP_DIR, &buffer, buffer.count)
        guard actual > 0 else {
            throw AppControlError.socketPathUnavailable
        }
        let value = String(cString: buffer)
        return value.hasSuffix("/") ? String(value.dropLast()) : value
    }

    public static func path() throws -> String {
        try path(name: socketName)
    }

    static func path(name: String) throws -> String {
        let directory = try userTemporaryDirectory()
        guard !name.isEmpty, !name.contains("/") else {
            throw AppControlError.socketPathOutsideUserDirectory
        }
        let path = directory + "/" + name
        let byteCount = path.utf8.count
        // sockaddr_un.sun_path is 104 bytes on Darwin, including NUL.
        guard byteCount + 1 <= socketPathCapacity else {
            throw AppControlError.socketPathTooLong(path)
        }
        return path
    }
}

public enum AppControlError: Error, Equatable, CustomStringConvertible, LocalizedError {
    case socketPathUnavailable
    case socketPathOutsideUserDirectory
    case socketPathTooLong(String)
    case invalidMessage(String)
    case messageTooLarge
    case transport(String)
    case launchFailed(String)

    public var description: String {
        switch self {
        case .socketPathUnavailable: return "unable to determine the per-user socket directory"
        case .socketPathOutsideUserDirectory: return "PanelCtl.app control socket must be under the per-user socket directory"
        case .socketPathTooLong: return "PanelCtl.app control socket path is too long"
        case .invalidMessage(let message): return "invalid PanelCtl.app response: \(message)"
        case .messageTooLarge: return "PanelCtl.app control message exceeds 4096 bytes"
        case .transport(let message): return message
        case .launchFailed(let message): return message
        }
    }

    public var errorDescription: String? { description }
}

public struct AppControlClient {
    static let defaultDeadline: TimeInterval = 3
    static let pollInterval: TimeInterval = 0.05
    /// How long one display step may take; an eight-step Action gets this budget per step.
    static let displayResponseTimeout = 30
    static let actionResponseTimeout = displayResponseTimeout * 8

    private let socketPath: String
    private let launch: () throws -> Void
    private let sleep: (TimeInterval) -> Void
    private let now: () -> Date
    private let isAppRunning: () -> Bool

    public init() throws {
        socketPath = try AppControlSocket.path()
        launch = Self.launchInstalledApp
        sleep = { Thread.sleep(forTimeInterval: $0) }
        now = Date.init
        isAppRunning = { Self.isAppRunning }
    }

    init(
        socketPath: String,
        launch: @escaping () throws -> Void,
        sleep: @escaping (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) },
        now: @escaping () -> Date = Date.init,
        isAppRunning: @escaping () -> Bool = { Self.isAppRunning }
    ) throws {
        self.socketPath = socketPath
        self.launch = launch
        self.sleep = sleep
        self.now = now
        self.isAppRunning = isAppRunning
    }

    /// Sends one request. Status, Hide/Show, Actions and one-shot rules never
    /// start the app. Other mutating commands may launch it after an unavailable
    /// first attempt; manual commands are never retried after request bytes land.
    public func execute(
        _ command: AppControlCommand,
        durationSeconds: TimeInterval? = nil,
        targetUUID: String? = nil,
        actionID: UUID? = nil,
        ruleID: UUID? = nil,
        hideStyle: AppControlHideStyle? = nil
    ) throws -> AppControlResponse {
        try execute(
            command,
            durationSeconds: durationSeconds,
            targetUUID: targetUUID,
            actionID: actionID,
            ruleID: ruleID,
            hideStyle: hideStyle,
            deadline: Self.defaultDeadline
        )
    }

    func execute(
        _ command: AppControlCommand,
        durationSeconds: TimeInterval? = nil,
        targetUUID: String? = nil,
        actionID: UUID? = nil,
        ruleID: UUID? = nil,
        hideStyle: AppControlHideStyle? = nil,
        deadline: TimeInterval
    ) throws -> AppControlResponse {
        do {
            return try send(command, durationSeconds: durationSeconds, targetUUID: targetUUID, actionID: actionID, ruleID: ruleID, hideStyle: hideStyle)
        } catch let error as AppControlTransportError {
            if command == .status || command.isManualDisplayCommand {
                if !error.requestBytesWritten, !isAppRunning() {
                    return .unavailable(error.description)
                }
                throw AppControlError.transport(error.description)
            }
            if command == .toggle && error.requestBytesWritten {
                throw AppControlError.transport(error.description)
            }
            if isAppRunning() {
                guard waitForSocket(deadline: deadline) else {
                    throw AppControlError.transport(
                        "PanelCtl.app is running but its control endpoint is unavailable"
                    )
                }
                do {
                    return try send(command, durationSeconds: durationSeconds, targetUUID: targetUUID, actionID: actionID, ruleID: ruleID, hideStyle: hideStyle)
                } catch {
                    throw AppControlError.transport(error.localizedDescription)
                }
            }
            do {
                try launch()
            } catch let error as AppControlError {
                throw error
            } catch {
                throw AppControlError.launchFailed(error.localizedDescription)
            }
            _ = waitForSocket(deadline: deadline)
            do {
                return try send(command, durationSeconds: durationSeconds, targetUUID: targetUUID, actionID: actionID, ruleID: ruleID, hideStyle: hideStyle)
            } catch {
                throw AppControlError.transport(error.localizedDescription)
            }
        }
    }

    /// One read-only subscription. Never launches or reconnects. The callback is
    /// synchronous so the client cannot build an unbounded output queue.
    public func watchStatus(emit: (AppControlResponse) throws -> Void) throws -> Int32 {
        var sequence: UInt64 = 0
        do {
            let fd = try Self.connect(to: socketPath)
            defer { close(fd) }
            // An unchanged status can remain silent indefinitely.
            var timeout = timeval(tv_sec: 0, tv_usec: 0)
            _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            var request = try JSONEncoder().encode(AppControlRequest(command: .status, watch: true))
            request.append(0x0A)
            let sent = request.withUnsafeBytes { Darwin.send(fd, $0.baseAddress, $0.count, MSG_NOSIGNAL) }
            guard sent == request.count else { throw AppControlError.transport("Status subscription failed") }
            var pending = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while true {
                let count = Darwin.read(fd, &buffer, buffer.count)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw AppControlError.transport("PanelCtl.app status stream disconnected") }
                pending.append(contentsOf: buffer.prefix(count))
                while let newline = pending.firstIndex(of: 0x0A) {
                    guard pending.distance(from: pending.startIndex, to: newline) < AppControlSocket.streamMessageLimit else {
                        throw AppControlError.messageTooLarge
                    }
                    let response = try JSONDecoder().decode(AppControlResponse.self, from: pending[..<newline])
                    guard response.protocolVersion == AppControlRequest.currentProtocol,
                          let next = response.sequence, next > sequence, next < UInt64.max else {
                        throw AppControlError.invalidMessage("missing or invalid stream sequence (app may not support --watch)")
                    }
                    sequence = next
                    try emit(response)
                    if !response.running { return response.exitCode }
                    pending.removeSubrange(...newline)
                }
                guard pending.count < AppControlSocket.streamMessageLimit else { throw AppControlError.messageTooLarge }
            }
        } catch {
            var response = AppControlResponse.unavailable(error.localizedDescription)
            response.sequence = sequence + 1
            try emit(response)
            return response.exitCode
        }
    }

    private func waitForSocket(deadline: TimeInterval) -> Bool {
        let socketDeadline = now().addingTimeInterval(max(0, deadline))
        while now() < socketDeadline {
            if Self.canConnect(to: socketPath) { return true }
            sleep(Self.pollInterval)
        }
        return false
    }

    private func send(
        _ command: AppControlCommand,
        durationSeconds: TimeInterval?,
        targetUUID: String?,
        actionID: UUID?,
        ruleID: UUID?,
        hideStyle: AppControlHideStyle?
    ) throws -> AppControlResponse {
        let request = AppControlRequest(
            command: command,
            durationSeconds: durationSeconds,
            targetUUID: targetUUID,
            actionID: actionID,
            ruleID: ruleID,
            hideStyle: hideStyle
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var bytes = try encoder.encode(request)
        bytes.append(0x0A)
        guard bytes.count <= AppControlSocket.messageLimit else { throw AppControlError.messageTooLarge }

        let fd = try Self.connect(to: socketPath)
        defer { close(fd) }
        if command.isManualDisplayCommand {
            // A saved Action is sequential and gets the established per-display budget for each of its eight steps.
            let seconds = command == .runAction ? Self.actionResponseTimeout : Self.displayResponseTimeout
            var timeout = timeval(tv_sec: seconds, tv_usec: 0)
            _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        }
        var written = 0
        while written < bytes.count {
            let result = bytes.withUnsafeBytes { raw in
                Darwin.send(
                    fd,
                    raw.baseAddress!.advanced(by: written),
                    bytes.count - written,
                    MSG_NOSIGNAL
                )
            }
            if result > 0 {
                written += result
                continue
            }
            if result < 0, errno == EINTR { continue }
            throw AppControlTransportError("failed to write PanelCtl.app control request", requestBytesWritten: written > 0)
        }

        var response = Data()
        var buffer = [UInt8](repeating: 0, count: 512)
        while response.count < AppControlSocket.messageLimit {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count > 0 {
                response.append(contentsOf: buffer.prefix(count))
                if response.contains(0x0A) { break }
                continue
            }
            if count < 0, errno == EINTR { continue }
            if count == 0 { break }
            throw AppControlTransportError("failed to read PanelCtl.app control response", requestBytesWritten: true)
        }
        guard response.count <= AppControlSocket.messageLimit,
              let newline = response.firstIndex(of: 0x0A) else {
            throw AppControlError.invalidMessage("response was not newline terminated")
        }
        let payload = response[..<newline]
        do {
            let response = try JSONDecoder().decode(
                AppControlResponse.self,
                from: payload
            )
            guard response.protocolVersion == AppControlRequest.currentProtocol else {
                throw AppControlError.invalidMessage(
                    "unsupported protocol \(response.protocolVersion)"
                )
            }
            guard response.running else {
                throw AppControlError.invalidMessage(
                    "live endpoint reported running=false"
                )
            }
            return response
        } catch {
            if let error = error as? AppControlError { throw error }
            throw AppControlError.invalidMessage(error.localizedDescription)
        }
    }

    private static func connect(to path: String) throws -> Int32 {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw AppControlTransportError("unable to create PanelCtl.app control socket", requestBytesWritten: false)
        }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8)
        guard pathBytes.count + 1 <= AppControlSocket.socketPathCapacity else {
            close(fd)
            throw AppControlError.socketPathTooLong(path)
        }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: pathBytes)
            raw[pathBytes.count] = 0
        }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            let message = String(cString: strerror(errno))
            close(fd)
            throw AppControlTransportError("PanelCtl.app is unavailable: \(message)", requestBytesWritten: false)
        }
        var noSignal = Int32(1)
        withUnsafePointer(to: &noSignal) {
            _ = setsockopt(
                fd,
                SOL_SOCKET,
                SO_NOSIGPIPE,
                $0,
                socklen_t(MemoryLayout<Int32>.size)
            )
        }
        var timeout = timeval(tv_sec: 1, tv_usec: 0)
        withUnsafePointer(to: &timeout) {
            _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, $0, socklen_t(MemoryLayout<timeval>.size))
            _ = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, $0, socklen_t(MemoryLayout<timeval>.size))
        }
        return fd
    }

    private static func canConnect(to path: String) -> Bool {
        guard let fd = try? connect(to: path) else { return false }
        close(fd)
        return true
    }

    private static var isAppRunning: Bool {
        NSRunningApplication.runningApplications(
            withBundleIdentifier: "com.brettinternet.panelctl"
        ).contains { !$0.isTerminated }
    }

    static func launchInstalledApp() throws {
        let appURL: URL?
        if let enclosing = enclosingApplicationURL() {
            appURL = enclosing
        } else {
            appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.brettinternet.panelctl")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        if let appURL {
            process.arguments = ["--background", appURL.path, "--args", "--background"]
        } else {
            process.arguments = ["--background", "-b", "com.brettinternet.panelctl", "--args", "--background"]
        }
        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                throw AppControlError.launchFailed(
                    "unable to launch PanelCtl.app (open exited \(process.terminationStatus))"
                )
            }
        } catch let error as AppControlError {
            throw error
        } catch {
            throw AppControlError.launchFailed(
                "unable to launch PanelCtl.app: \(error.localizedDescription)"
            )
        }
    }

    private static func enclosingApplicationURL() -> URL? {
        var url = Bundle.main.bundleURL
        while url.path != "/" {
            if url.pathExtension == "app" { return url }
            url.deleteLastPathComponent()
        }
        return nil
    }
}

private struct AppControlTransportError: Error, CustomStringConvertible, LocalizedError {
    let message: String
    let requestBytesWritten: Bool

    init(_ message: String, requestBytesWritten: Bool) {
        self.message = message
        self.requestBytesWritten = requestBytesWritten
    }

    var description: String { message }
    var errorDescription: String? { message }
}
