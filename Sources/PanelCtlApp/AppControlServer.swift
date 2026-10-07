import Darwin
import Foundation
import PanelCtlCore

final class AppControlServer {
    /// Answers one request, given when it was received; a display command
    /// answers when its operation finishes.
    typealias Handler = @MainActor (AppControlRequest, ContinuousClock.Instant) async -> AppControlResponse

    private let handler: Handler
    private let statusStream: AppStatusStream?
    private let configuredSocketPath: String?
    private let clientQueue = DispatchQueue(
        label: "com.brettinternet.panelctl.control",
        qos: .utility,
        attributes: .concurrent
    )
    private var listener: Int32 = -1
    private var listenerSource: DispatchSourceRead?
    private var socketPath: String?
    private var socketDevice: dev_t?
    private var socketInode: ino_t?

    @MainActor
    init(
        socketPath: String? = nil,
        statusSnapshot: (@MainActor () -> AppControlResponse)? = nil,
        handler: @escaping Handler
    ) {
        configuredSocketPath = socketPath
        self.handler = handler
        statusStream = statusSnapshot.map { AppStatusStream(snapshot: $0) }
    }

    func start() throws {
        guard listener < 0 else { return }
        let path = try configuredSocketPath ?? AppControlSocket.path()
        try removeStaleSocket(at: path)

        let socket = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard socket >= 0 else {
            throw AppControlServerError.systemCall("socket", errno)
        }

        do {
            var address = try socketAddress(path: path)
            let bindResult = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(
                        socket,
                        $0,
                        socklen_t(MemoryLayout<sockaddr_un>.size)
                    )
                }
            }
            guard bindResult == 0 else {
                throw AppControlServerError.systemCall("bind", errno)
            }

            var metadata = stat()
            guard lstat(path, &metadata) == 0 else {
                throw AppControlServerError.systemCall("lstat", errno)
            }
            socketPath = path
            socketDevice = metadata.st_dev
            socketInode = metadata.st_ino

            guard chmod(path, S_IRUSR | S_IWUSR) == 0 else {
                throw AppControlServerError.systemCall("chmod", errno)
            }
            guard Darwin.listen(socket, 8) == 0 else {
                throw AppControlServerError.systemCall("listen", errno)
            }

            listener = socket

            // Requests are received off the main thread, so their arrival is
            // known even while the app is busy.
            let source = DispatchSource.makeReadSource(
                fileDescriptor: socket,
                queue: clientQueue
            )
            source.setEventHandler { [weak self] in
                self?.acceptClient(from: socket)
            }
            source.setCancelHandler {
                Darwin.close(socket)
            }
            listenerSource = source
            source.resume()
        } catch {
            Darwin.close(socket)
            removeOwnedSocket()
            throw error
        }
    }

    @MainActor
    func statusDidChange() {
        statusStream?.statusDidChange()
    }

    @MainActor
    func stop() {
        statusStream?.stop()
        listenerSource?.cancel()
        listenerSource = nil
        listener = -1
        removeOwnedSocket()
    }

    private func acceptClient(from listener: Int32) {
        let client = Darwin.accept(listener, nil, nil)
        guard client >= 0 else { return }

        var peerUser = uid_t()
        var peerGroup = gid_t()
        guard getpeereid(client, &peerUser, &peerGroup) == 0,
              peerUser == geteuid() else {
            Darwin.close(client)
            return
        }

        var timeout = timeval(tv_sec: 1, tv_usec: 0)
        withUnsafePointer(to: &timeout) {
            _ = setsockopt(
                client,
                SOL_SOCKET,
                SO_RCVTIMEO,
                $0,
                socklen_t(MemoryLayout<timeval>.size)
            )
            _ = setsockopt(
                client,
                SOL_SOCKET,
                SO_SNDTIMEO,
                $0,
                socklen_t(MemoryLayout<timeval>.size)
            )
        }
        var noSignal = Int32(1)
        withUnsafePointer(to: &noSignal) {
            _ = setsockopt(
                client,
                SOL_SOCKET,
                SO_NOSIGPIPE,
                $0,
                socklen_t(MemoryLayout<Int32>.size)
            )
        }

        clientQueue.async { [weak self] in
            self?.readRequest(from: client)
        }
    }

    private func readRequest(from client: Int32) {
        do {
            guard let request = try Self.readRequestData(from: client) else {
                Darwin.close(client)
                return
            }
            let decoded = try JSONDecoder().decode(AppControlRequest.self, from: request)
            let receivedAt = ContinuousClock.now
            Task { @MainActor [weak self] in
                guard let self else {
                    Darwin.close(client)
                    return
                }
                if decoded.hasSupportedProtocol, decoded.watch == true, let statusStream {
                    statusStream.subscribe(client)
                    return
                }
                let response = await handler(decoded, receivedAt)
                clientQueue.async {
                    Self.write(response, for: decoded.command, to: client)
                }
            }
        } catch {
            let response = AppControlResponse(
                ok: false,
                running: true,
                enabled: false,
                state: "error",
                summary: "Invalid control request",
                error: error.localizedDescription
            )
            Self.write(response, for: nil, to: client)
        }
    }

    private static func readRequestData(from client: Int32) throws -> Data? {
        var request = Data()
        while request.count < AppControlSocket.messageLimit {
            let capacity = min(512, AppControlSocket.messageLimit - request.count)
            var buffer = [UInt8](repeating: 0, count: capacity)
            let count = Darwin.read(client, &buffer, buffer.count)
            if count > 0 {
                request.append(contentsOf: buffer.prefix(count))
                if let newline = request.firstIndex(of: 0x0A) {
                    return Data(request[..<newline])
                }
                continue
            }
            if count < 0, errno == EINTR { continue }
            if count == 0 {
                if request.isEmpty { return nil }
                throw AppControlServerError.invalidRequest(
                    "request ended before a newline"
                )
            }
            throw AppControlServerError.systemCall("read", errno)
        }
        throw AppControlError.messageTooLarge
    }

    private static func write(_ response: AppControlResponse, for command: AppControlCommand?, to client: Int32) {
        defer { Darwin.close(client) }
        guard var data = encodedResponse(response, for: command) else { return }
        data.append(0x0A)

        var written = 0
        while written < data.count {
            let count = data.withUnsafeBytes { bytes in
                Darwin.send(
                    client,
                    bytes.baseAddress?.advanced(by: written),
                    data.count - written,
                    MSG_NOSIGNAL
                )
            }
            if count > 0 {
                written += count
                continue
            }
            if count < 0, errno == EINTR { continue }
            return
        }
    }

    private static func encodedResponse(
        _ response: AppControlResponse,
        for command: AppControlCommand?
    ) -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        if let data = try? encoder.encode(response),
           data.count + 1 <= AppControlSocket.messageLimit {
            return data
        }

        // Status can't drop its display evidence, so an oversized status
        // fails. Any other response, such as a Hide's, keeps its result.
        let failsStatus = command == .status && (response.displays != nil || response.rules != nil)
        let requiredFieldsOnly = AppControlResponse(
            protocolVersion: response.protocolVersion,
            ok: failsStatus ? false : response.ok,
            running: response.running,
            enabled: response.enabled,
            state: String(response.state.prefix(64)),
            summary: failsStatus
                ? "Response exceeded the control message limit; no complete status is available."
                : String(response.summary.prefix(512)),
            error: failsStatus ? "Check PanelCtl Settings \u{2192} Displays; do not infer an operation result."
                : response.error.map { String($0.prefix(512)) },
            outcome: failsStatus ? .refused : response.outcome
        )
        guard let data = try? encoder.encode(requiredFieldsOnly),
              data.count + 1 <= AppControlSocket.messageLimit else {
            return nil
        }
        return data
    }

    private func removeStaleSocket(at path: String) throws {
        var metadata = stat()
        guard lstat(path, &metadata) == 0 else {
            if errno == ENOENT { return }
            throw AppControlServerError.systemCall("lstat", errno)
        }
        guard (metadata.st_mode & S_IFMT) == S_IFSOCK else {
            throw AppControlServerError.unsafeExistingPath
        }

        let probe = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard probe >= 0 else {
            throw AppControlServerError.systemCall("socket", errno)
        }
        defer { Darwin.close(probe) }
        var address = try socketAddress(path: path)
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(
                    probe,
                    $0,
                    socklen_t(MemoryLayout<sockaddr_un>.size)
                )
            }
        }
        if result == 0 {
            throw AppControlServerError.alreadyRunning
        }
        guard errno == ECONNREFUSED else {
            throw AppControlServerError.systemCall("connect", errno)
        }
        guard unlink(path) == 0 else {
            throw AppControlServerError.systemCall("unlink", errno)
        }
    }

    private func removeOwnedSocket() {
        guard let socketPath, let socketDevice, let socketInode else { return }
        var metadata = stat()
        guard lstat(socketPath, &metadata) == 0,
              (metadata.st_mode & S_IFMT) == S_IFSOCK,
              metadata.st_dev == socketDevice,
              metadata.st_ino == socketInode else {
            return
        }
        _ = unlink(socketPath)
        self.socketPath = nil
        self.socketDevice = nil
        self.socketInode = nil
    }

    private func socketAddress(path: String) throws -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count + 1 <= MemoryLayout.size(ofValue: address.sun_path) else {
            throw AppControlError.socketPathTooLong(path)
        }
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            destination.copyBytes(from: bytes)
            destination[bytes.count] = 0
        }
        return address
    }

}

private enum AppControlServerError: Error, LocalizedError {
    case alreadyRunning
    case unsafeExistingPath
    case invalidRequest(String)
    case systemCall(String, Int32)

    var errorDescription: String? {
        switch self {
        case .alreadyRunning:
            return "another PanelCtl control server is already running"
        case .unsafeExistingPath:
            return "refusing to replace a non-socket control endpoint"
        case .invalidRequest(let message):
            return message
        case .systemCall(let operation, let code):
            return "\(operation) failed: \(String(cString: strerror(code)))"
        }
    }
}
