import Darwin
import Foundation
import PanelCtlCore

/// Main-actor ownership serializes subscriptions, snapshots and descriptor use.
/// Writes never wait: a partial write or full kernel buffer ends the subscription.
@MainActor
final class AppStatusStream {
    private struct Watcher {
        let source: DispatchSourceRead
        var sequence: UInt64 = 0
        var previous: AppControlResponse?
    }

    private let snapshot: @MainActor () -> AppControlResponse
    private var watchers: [Int32: Watcher] = [:]
    private var pending: Task<Void, Never>?
    private var stopped = false
    private let coalescingNanoseconds: UInt64
    var watcherCount: Int { watchers.count }

    init(coalescingNanoseconds: UInt64 = 100_000_000,
         snapshot: @escaping @MainActor () -> AppControlResponse) {
        self.coalescingNanoseconds = coalescingNanoseconds
        self.snapshot = snapshot
    }

    func subscribe(_ fd: Int32) {
        guard !stopped, watchers.count < 64,
              fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) == 0 else {
            Darwin.close(fd)
            return
        }
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        source.setEventHandler { [weak self] in
            // EOF or any additional input closes the read-only subscription.
            MainActor.assumeIsolated { self?.remove(fd) }
        }
        source.setCancelHandler { Darwin.close(fd) }
        watchers[fd] = Watcher(source: source)
        source.resume()
        send(snapshot(), to: fd)
    }

    func statusDidChange() {
        guard !watchers.isEmpty, pending == nil, !stopped else { return }
        pending = Task { [weak self, coalescingNanoseconds] in
            do { try await Task.sleep(nanoseconds: coalescingNanoseconds) }
            catch { return }
            guard let self else { return }
            self.pending = nil
            self.publish()
        }
    }

    private func publish() {
        guard !watchers.isEmpty else { return }
        let response = snapshot()
        for fd in Array(watchers.keys) { send(response, to: fd) }
    }

    func stop() {
        stopped = true
        pending?.cancel()
        pending = nil
        for fd in Array(watchers.keys) {
            send(.unavailable("PanelCtl.app is shutting down"), to: fd)
            remove(fd)
        }
    }

    private func send(_ snapshot: AppControlResponse, to fd: Int32) {
        guard var watcher = watchers[fd] else { return }
        var response = snapshot
        response.sequence = nil
        guard watcher.previous != response else { return }
        watcher.previous = response
        watcher.sequence += 1
        response.sequence = watcher.sequence
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard var data = try? encoder.encode(response),
              data.count < AppControlSocket.streamMessageLimit else {
            remove(fd)
            return
        }
        data.append(0x0A)
        let sent = data.withUnsafeBytes {
            Darwin.send(fd, $0.baseAddress, $0.count, MSG_NOSIGNAL)
        }
        guard sent == data.count else {
            remove(fd)
            return
        }
        watchers[fd] = watcher
    }

    private func remove(_ fd: Int32) {
        watchers.removeValue(forKey: fd)?.source.cancel()
        if watchers.isEmpty {
            pending?.cancel()
            pending = nil
        }
    }
}
