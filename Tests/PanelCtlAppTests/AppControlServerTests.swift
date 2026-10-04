import XCTest
import Darwin
@testable import PanelCtlApp
@testable import PanelCtlCore

final class AppControlServerTests: XCTestCase {
    @MainActor
    func testSameUserClientReceivesBoundedServerResponse() async throws {
        let directory = try AppControlSocket.userTemporaryDirectory()
        let path = "\(directory)/panelctl-test-\(UUID().uuidString.prefix(8)).sock"
        var receivedCommand: AppControlCommand?
        let server = AppControlServer(socketPath: path) { request in
            receivedCommand = request.command
            return AppControlResponse(
                ok: true,
                running: true,
                enabled: true,
                state: "waiting",
                summary: "Watching for inactivity · 5 minutes",
                detail: String(repeating: "x", count: 16 * 1024)
            )
        }
        try server.start()
        defer { server.stop() }

        try connectAndClose(path)
        try await Task.sleep(nanoseconds: 20_000_000)

        let response = try await Task.detached {
            let client = try AppControlClient(
                socketPath: path,
                launch: { XCTFail("status must not launch the app") }
            )
            return try client.execute(.status)
        }.value

        XCTAssertEqual(receivedCommand, .status)
        XCTAssertTrue(response.ok)
        XCTAssertTrue(response.running)
        XCTAssertTrue(response.enabled)
        XCTAssertEqual(response.state, "waiting")
        XCTAssertEqual(response.summary, "Watching for inactivity · 5 minutes")
        XCTAssertNil(response.detail)
    }

    @MainActor
    func testStatusRejectsAnUnsupportedResponseFromALiveServer() async throws {
        let directory = try AppControlSocket.userTemporaryDirectory()
        let path = "\(directory)/panelctl-test-\(UUID().uuidString.prefix(8)).sock"
        let server = AppControlServer(socketPath: path) { _ in
            AppControlResponse(
                protocolVersion: AppControlRequest.currentProtocol + 1,
                ok: true,
                running: true,
                enabled: false,
                state: "disabled",
                summary: "Disabled"
            )
        }
        try server.start()
        defer { server.stop() }

        do {
            _ = try await Task.detached {
                let client = try AppControlClient(
                    socketPath: path,
                    launch: { XCTFail("status must not launch the app") }
                )
                return try client.execute(.status)
            }.value
            XCTFail("unsupported protocol should fail")
        } catch {
            XCTAssertEqual(
                error as? AppControlError,
                .invalidMessage("unsupported protocol 2")
            )
        }
    }

    @MainActor
    func testStatusRejectsUnavailableResponseFromALiveServer() async throws {
        let directory = try AppControlSocket.userTemporaryDirectory()
        let path = "\(directory)/panelctl-test-\(UUID().uuidString.prefix(8)).sock"
        let server = AppControlServer(socketPath: path) { _ in
            .unavailable()
        }
        try server.start()
        defer { server.stop() }

        do {
            _ = try await Task.detached {
                let client = try AppControlClient(
                    socketPath: path,
                    launch: { XCTFail("status must not launch the app") }
                )
                return try client.execute(.status)
            }.value
            XCTFail("a live endpoint cannot report itself unavailable")
        } catch {
            XCTAssertEqual(
                error as? AppControlError,
                .invalidMessage("live endpoint reported running=false")
            )
        }
    }

    @MainActor
    func testHideShowLostResponseNeverLaunchesOrRetries() async throws {
        for command in [AppControlCommand.hide, .show] {
            let path = "\(try AppControlSocket.userTemporaryDirectory())/panelctl-test-\(UUID().uuidString.prefix(8)).sock"
            let listener = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
            XCTAssertGreaterThanOrEqual(listener, 0)
            defer { Darwin.close(listener); _ = unlink(path) }
            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)
            withUnsafeMutableBytes(of: &address.sun_path) { destination in
                destination.copyBytes(from: Array(path.utf8))
                destination[path.utf8.count] = 0
            }
            let result = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            XCTAssertEqual(result, 0)
            XCTAssertEqual(Darwin.listen(listener, 2), 0)
            let consumed = Task.detached { () throws -> AppControlRequest in
                let connection = Darwin.accept(listener, nil, nil)
                guard connection >= 0 else { throw AppControlError.transport("accept failed") }
                defer { Darwin.close(connection) }
                var bytes = Data()
                var byte: UInt8 = 0
                while Darwin.read(connection, &byte, 1) == 1 {
                    if byte == 10 { break }
                    bytes.append(byte)
                }
                // Close after consuming the request, without returning a response.
                return try JSONDecoder().decode(AppControlRequest.self, from: bytes)
            }
            do {
                _ = try await Task.detached {
                    let client = try AppControlClient(socketPath: path,
                        launch: { XCTFail("lost response must not launch") },
                        isAppRunning: { XCTFail("lost response must not retry or poll"); return true })
                    return try client.execute(command, targetUUID: "00000000-0000-0000-0000-000000000002")
                }.value
                XCTFail("lost response must throw")
            } catch {
                XCTAssertTrue(error is AppControlError)
            }
            let request = try await consumed.value
            XCTAssertEqual(request.command, command)
            XCTAssertNotNil(request.targetUUID)
        }
    }

    @MainActor
    func testOversizedDisplayStatusDoesNotSilentlyReportSuccess() async throws {
        let path = "\(try AppControlSocket.userTemporaryDirectory())/panelctl-test-\(UUID().uuidString.prefix(8)).sock"
        let server = AppControlServer(socketPath: path) { _ in
            AppControlResponse(ok: true, running: true, enabled: false, state: "disabled", summary: "fixture",
                displays: [AppControlDisplayStatus(targetUUID: "target", observedState: "separate", operation: "idle",
                    recoveryNeeded: false, lastInputOutcome: DisplayInputOutcome(state: .failed, detail: String(repeating: "x", count: 8192)))])
        }
        try server.start()
        defer { server.stop() }
        let response = try await Task.detached {
            try AppControlClient(socketPath: path, launch: {}).execute(.status)
        }.value
        XCTAssertFalse(response.ok)
        XCTAssertEqual(response.outcome, .refused)
        XCTAssertEqual(response.exitCode, 1)
    }

    private func connectAndClose(_ path: String) throws {
        let socket = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(socket, 0)
        defer { Darwin.close(socket) }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8)
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            destination.copyBytes(from: pathBytes)
            destination[pathBytes.count] = 0
        }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(
                    socket,
                    $0,
                    socklen_t(MemoryLayout<sockaddr_un>.size)
                )
            }
        }
        XCTAssertEqual(result, 0)
    }
}
