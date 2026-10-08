import Darwin
import XCTest
@testable import PanelCtlApp
@testable import PanelCtlCore

final class AppStatusStreamTests: XCTestCase {
    private static func status(_ state: String) -> AppControlResponse {
        AppControlResponse(ok: true, running: true, enabled: true, state: state, summary: state)
    }

    @MainActor
    func testInitialChangesCoalescingDeduplicationConcurrentWatchersAndShutdown() async throws {
        let path = "\(try AppControlSocket.userTemporaryDirectory())/panelctl-test-\(UUID().uuidString.prefix(8)).sock"
        var snapshot = Self.status("waiting")
        var commands: [AppControlCommand] = []
        let server = AppControlServer(socketPath: path, statusSnapshot: { snapshot }) { request, _ in
            commands.append(request.command)
            return snapshot
        }
        try server.start()
        defer { server.stop() }
        let initial = expectation(description: "both initial snapshots")
        initial.expectedFulfillmentCount = 2
        let changed = expectation(description: "both changed snapshots")
        changed.expectedFulfillmentCount = 2
        let clients = (0..<2).map { _ in
            Task {
                try await Self.blockingClient {
                    var frames: [AppControlResponse] = []
                    let client = try AppControlClient(socketPath: path, launch: { XCTFail("watch must never launch") })
                    let code = try client.watchStatus { response in
                        frames.append(response)
                        if response.state == "waiting" { initial.fulfill() }
                        if response.state == "hidden" { changed.fulfill() }
                    }
                    return (frames, code)
                }
            }
        }
        await fulfillment(of: [initial], timeout: 2)
        for index in 0..<100 {
            snapshot = Self.status("intermediate-\(index)")
            server.statusDidChange()
        }
        snapshot = Self.status("hidden")
        server.statusDidChange()
        await fulfillment(of: [changed], timeout: 2)
        // Unchanged invalidations do not produce another document.
        for _ in 0..<100 { server.statusDidChange() }
        try await Task.sleep(nanoseconds: 200_000_000)
        let legacy = try await Self.blockingClient {
            try AppControlClient(socketPath: path, launch: {}).execute(.status)
        }
        XCTAssertEqual(legacy, snapshot)
        XCTAssertEqual(commands, [.status], "subscriptions bypass command dispatch")
        server.stop()
        for client in clients {
            let (frames, code) = try await client.value
            XCTAssertEqual(frames.map(\.state), ["waiting", "hidden", "unavailable"])
            XCTAssertEqual(frames.map(\.sequence), [1, 2, 3])
            XCTAssertFalse(try XCTUnwrap(frames.last).running)
            XCTAssertEqual(code, 3)
        }
    }

    @MainActor
    func testConsumerDisconnectAndAdditionalCommandsRemoveWatcher() async throws {
        var snapshots = 0
        let stream = AppStatusStream {
            snapshots += 1
            return Self.status("waiting")
        }
        defer { stream.stop() }
        let first = try socketPair()
        stream.subscribe(first[0])
        XCTAssertEqual(try Self.readFrame(first[1]).sequence, 1)
        Darwin.close(first[1])
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(stream.watcherCount, 0)

        let second = try socketPair()
        defer { Darwin.close(second[1]) }
        stream.subscribe(second[0])
        _ = try Self.readFrame(second[1])
        let command = Data("{\"protocol\":1,\"command\":\"enable\"}\n".utf8)
        _ = command.withUnsafeBytes { Darwin.send(second[1], $0.baseAddress, $0.count, MSG_NOSIGNAL) }
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(stream.watcherCount, 0)
        stream.statusDidChange()
        XCTAssertEqual(snapshots, 2, "no snapshot work without subscribers")
    }

    @MainActor
    func testStalledConsumerIsDisconnectedWithoutBlockingHealthyWatcher() async throws {
        var snapshot = Self.status("waiting")
        let stream = AppStatusStream(coalescingNanoseconds: 20_000_000) { snapshot }
        defer { stream.stop() }
        let slow = try socketPair()
        let fast = try socketPair()
        defer { Darwin.close(slow[1]); Darwin.close(fast[1]) }
        stream.subscribe(slow[0])
        stream.subscribe(fast[0])
        _ = try Self.readFrame(fast[1])
        // Each frame is valid, but an unread backlog soon exceeds the
        // one-frame send buffer and must disconnect only the stalled consumer.
        for index in 0..<100 {
            snapshot = Self.status("\(index)-" + String(repeating: "x", count: 100_000))
            stream.statusDidChange()
            // Wait off the main actor so the coalesced publisher can run even
            // when the runner takes longer than its nominal timer interval.
            let response = try await Self.blockingClient { try Self.readFrame(fast[1]) }
            XCTAssertEqual(response.state, snapshot.state)
            if stream.watcherCount == 1 { break }
        }
        XCTAssertEqual(stream.watcherCount, 1)
    }

    @MainActor
    func testValidFrameLargerThanDefaultSocketBufferReachesWatcherBeforeItReads() throws {
        let pair = try socketPair()
        defer { Darwin.close(pair[1]) }
        var defaultSize: Int32 = 0
        var length = socklen_t(MemoryLayout<Int32>.size)
        XCTAssertEqual(getsockopt(pair[0], SOL_SOCKET, SO_SNDBUF, &defaultSize, &length), 0)
        // Leave room for the JSON envelope, sequence and newline.
        let state = String(repeating: "x", count: AppControlSocket.streamMessageLimit - 512)
        XCTAssertGreaterThan(state.utf8.count, Int(defaultSize))
        let stream = AppStatusStream {
            AppControlResponse(ok: true, running: true, enabled: true, state: state, summary: "large")
        }
        defer { stream.stop() }
        stream.subscribe(pair[0])
        XCTAssertEqual(stream.watcherCount, 1, "a healthy watcher that has not read yet stays subscribed")
        let frame = try Self.readFrame(pair[1])
        XCTAssertEqual(frame.state, state)
        XCTAssertEqual(frame.sequence, 1)
    }

    @MainActor
    func testOversizedSnapshotDisconnectsRatherThanTruncatingEvidence() throws {
        let pair = try socketPair()
        defer { Darwin.close(pair[1]) }
        let stream = AppStatusStream { Self.status(String(repeating: "x", count: AppControlSocket.streamMessageLimit)) }
        stream.subscribe(pair[0])
        XCTAssertEqual(stream.watcherCount, 0)
        stream.stop()
    }

    @MainActor
    func testAbruptDropAfterInitialFrameEmitsNextSequenceAndNeverReconnects() async throws {
        let path = "\(try AppControlSocket.userTemporaryDirectory())/panelctl-test-\(UUID().uuidString.prefix(8)).sock"
        var requests = 0
        let server = AppControlServer(socketPath: path) { _, _ in
            requests += 1
            var response = Self.status("waiting")
            response.sequence = 1
            return response // One frame, then an abrupt EOF instead of a terminal frame.
        }
        try server.start()
        defer { server.stop() }
        let (frames, code) = try await Self.blockingClient {
            var frames: [AppControlResponse] = []
            let code = try AppControlClient(socketPath: path, launch: { XCTFail("must not launch") })
                .watchStatus { frames.append($0) }
            return (frames, code)
        }
        XCTAssertEqual(frames.map(\.state), ["waiting", "unavailable"])
        XCTAssertEqual(frames.map(\.sequence), [1, 2])
        XCTAssertEqual(code, 3)
        XCTAssertEqual(requests, 1)
    }

    @MainActor
    func testLegacyServerDropProducesFinalDisconnectedDocument() async throws {
        let path = "\(try AppControlSocket.userTemporaryDirectory())/panelctl-test-\(UUID().uuidString.prefix(8)).sock"
        let server = AppControlServer(socketPath: path) { _, _ in Self.status("waiting") }
        try server.start()
        defer { server.stop() }
        let (frames, code) = try await Self.blockingClient {
            var frames: [AppControlResponse] = []
            let code = try AppControlClient(socketPath: path, launch: { XCTFail("must not launch") })
                .watchStatus { frames.append($0) }
            return (frames, code)
        }
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames.first?.sequence, 1)
        XCTAssertEqual(frames.first?.running, false)
        XCTAssertEqual(code, 3)
    }

    // Socket reads block indefinitely while a stream is unchanged. Task.detached
    // still uses Swift's cooperative pool and can starve the server on small runners.
    private static func blockingClient<T: Sendable>(
        _ operation: @escaping @Sendable () throws -> T
    ) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result(catching: operation))
            }
        }
    }

    private func socketPair() throws -> [Int32] {
        var pair: [Int32] = [-1, -1]
        guard Darwin.socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0 else { throw POSIXError(.EIO) }
        var timeout = timeval(tv_sec: 1, tv_usec: 0)
        _ = setsockopt(pair[1], SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        return pair
    }

    // Tests read each frame before another is published, so a chunk never
    // spans two frames.
    private static func readFrame(_ fd: Int32) throws -> AppControlResponse {
        var data = Data()
        var chunk = [UInt8](repeating: 0, count: 65_536)
        while true {
            let count = Darwin.read(fd, &chunk, chunk.count)
            guard count > 0 else { throw POSIXError(.EIO) }
            data.append(contentsOf: chunk[..<count])
            if let newline = data.firstIndex(of: 0x0A) {
                return try JSONDecoder().decode(AppControlResponse.self, from: data[..<newline])
            }
        }
    }
}
