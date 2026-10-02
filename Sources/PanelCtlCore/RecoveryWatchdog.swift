import Foundation
import Darwin

public enum RecoveryAction: String, Equatable {
    case capture, status, verify, restore, rehearse
}

public enum DisplayRecovery {
    public static func run(action: RecoveryAction, timeout: TimeInterval?, journalPath: String?, executable: URL) throws {
        let store = RecoveryStore(url: journalPath.map { URL(fileURLWithPath: $0) } ?? RecoveryStore.defaultURL)
        if action == .status {
            try printJournal(store.load())
            return
        }
        if action == .rehearse {
            let session = try RecoveryWatchdog.start(store: store, executable: executable, timeout: timeout ?? 5)
            print("Rehearsal armed; no display writes. Journal: \(store.url.path)")
            fflush(stdout)
            session.wait()
            let journal = try store.load()
            try printJournal(journal)
            guard journal.id == session.id, journal.state == .verified else {
                throw RecoveryError.unsafe(journal.failure ?? "watchdog did not verify the snapshot")
            }
            return
        }
        try store.lock()
        defer { store.unlock() }
        if action == .capture {
            let snapshot = try RecoverySnapshot.capture()
            // Catch topology changes during collection rather than journaling
            // an internally inconsistent baseline.
            try snapshot.verify(.capture())
            let journal = RecoveryJournal(snapshot: snapshot)
            try store.create(journal)
            try printJournal(journal)
        } else {
            var journal = try store.load()
            try RecoveryEngine().finish(&journal, store: store, verifyOnly: action == .verify, trigger: "manual-\(action.rawValue)")
            try printJournal(journal)
        }
    }

    public static func runHelper(journalPath: String, id: UUID) throws {
        let store = RecoveryStore(url: URL(fileURLWithPath: journalPath))
        do {
            try RecoveryWatchdog.runHelper(store: store, id: id)
        } catch {
            // Include startup failures in durable evidence, but never alter a
            // different journal or one owned by another active helper.
            if (try? store.lock()) != nil {
                defer { store.unlock() }
                if var journal = try? store.load(), journal.id == id, !journal.state.resolved {
                    journal.state = .needsAttention
                    journal.failure = String(describing: error)
                    journal.trigger = "helper-error"
                    try? store.save(journal)
                }
            }
            throw error
        }
    }

    private static func printJournal(_ journal: RecoveryJournal) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        FileHandle.standardOutput.write(try encoder.encode(journal))
        print()
    }
}

/// The CLI exposes only a no-write rehearsal. A future control operation must
/// not mutate anything until start() has returned (READY handshake). There is
/// intentionally no arbitrary command hook and no private disable API here.
final class RecoveryWatchdog {
    let id: UUID
    private let process: Process
    private let lease: FileHandle

    private init(id: UUID, process: Process, lease: FileHandle) {
        self.id = id; self.process = process; self.lease = lease
    }

    deinit {
        // EOF requests early verification, including on ordinary parent exit.
        // Do not terminate the independent helper.
        try? lease.close()
    }

    func wait() { process.waitUntilExit() }

    static func start(store: RecoveryStore, executable: URL, timeout: TimeInterval) throws -> RecoveryWatchdog {
        guard timeout.isFinite, (1...60).contains(timeout) else {
            throw RecoveryError.unsafe("rehearsal timeout must be 1–60 seconds")
        }
        try store.lock()
        let journal: RecoveryJournal
        do {
            let snapshot = try RecoverySnapshot.capture()
            try snapshot.verify(.capture())
            journal = RecoveryJournal(snapshot: snapshot, verifyOnly: true, timeout: timeout)
            try store.create(journal)
        } catch {
            store.unlock()
            throw error
        }
        store.unlock()
        let input = Pipe(), output = Pipe()
        let process = Process()
        process.executableURL = executable
        process.arguments = ["_recovery-helper", "--journal", store.url.path, "--id", journal.id.uuidString]
        process.standardInput = input
        process.standardOutput = output
        // Do not inherit the terminal's stderr: a dead terminal must not kill
        // the helper with SIGPIPE while it is recording a recovery failure.
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            try? input.fileHandleForReading.close()
            try? output.fileHandleForWriting.close()
            defer { try? output.fileHandleForReading.close() }
            // Bounded startup wait. poll is a single IPC wait, not a shell loop.
            var descriptor = pollfd(fd: output.fileHandleForReading.fileDescriptor, events: Int16(POLLIN), revents: 0)
            let ready = poll(&descriptor, 1, 5_000)
            guard ready > 0 else { throw RecoveryError.unsafe("watchdog readiness timed out; no mutation allowed") }
            // One POSIX read consumes the helper's atomic (< PIPE_BUF) write.
            // FileHandle.read(upToCount:) may wait to fill the requested count
            // until EOF, which would postpone READY until the helper exits.
            var bytes = [UInt8](repeating: 0, count: 128)
            let count = Darwin.read(descriptor.fd, &bytes, bytes.count)
            let response = count > 0 ? Data(bytes.prefix(count)) : Data()
            guard String(data: response, encoding: .utf8) == "READY \(journal.id.uuidString)\n" else {
                let detail = (try? store.load().failure) ?? "no diagnostic available"
                throw RecoveryError.unsafe("watchdog did not acknowledge readiness; no mutation allowed (\(detail))")
            }
            let armed = try store.load()
            guard armed.id == journal.id, armed.state == .armed,
                  process.isRunning, let deadline = armed.deadline, deadline > Date() else {
                throw RecoveryError.unsafe("watchdog is not armed; no mutation allowed")
            }
            return RecoveryWatchdog(id: journal.id, process: process, lease: input.fileHandleForWriting)
        } catch {
            // A started helper will see EOF and perform its check. If launch
            // failed, captured state remains unresolved for manual verification.
            try? input.fileHandleForWriting.close()
            throw error
        }
    }

    static func runHelper(store: RecoveryStore, id: UUID) throws {
        var inputInfo = stat()
        guard fstat(STDIN_FILENO, &inputInfo) == 0, inputInfo.st_mode & S_IFMT == S_IFIFO else {
            throw RecoveryError.unsafe("watchdog requires a parent lease pipe")
        }
        // Foundation.Process already makes the child a process-group leader
        // on macOS, so setsid() would fail with EPERM. A separate group is what
        // we need to avoid the parent's terminal interrupt/kill-group signals.
        guard getpgrp() == getpid() || setpgid(0, 0) == 0 else {
            throw RecoveryError.unsafe("cannot isolate watchdog process group")
        }
        // Survive a parent closing the readiness pipe before startup completes.
        signal(SIGPIPE, SIG_IGN)
        try store.lock()
        defer { store.unlock() }
        var journal = try store.load()
        guard journal.id == id, journal.state == .captured,
              journal.verifyOnly, let deadline = journal.deadline else {
            throw RecoveryError.unsafe("watchdog journal identity/state mismatch")
        }
        try journal.snapshot.verify(.capture())
        let remaining = deadline.timeIntervalSinceNow
        guard remaining > 0, remaining <= 60 else {
            throw RecoveryError.unsafe("watchdog deadline expired or invalid; no mutation allowed")
        }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        let input = DispatchSource.makeReadSource(fileDescriptor: STDIN_FILENO, queue: .main)
        var signals: [DispatchSourceSignal] = []
        var finished = false
        var result: Error?
        func finish(_ trigger: String) {
            guard !finished else { return }
            finished = true
            do {
                try RecoveryEngine().finish(&journal, store: store, verifyOnly: true, trigger: trigger)
            } catch { result = error }
            timer.cancel(); input.cancel()
            signals.forEach { $0.cancel() }
        }
        timer.schedule(deadline: .now() + remaining)
        timer.setEventHandler { finish("deadline") }
        input.setEventHandler {
            var buffer = [UInt8](repeating: 0, count: 64)
            let count = Darwin.read(STDIN_FILENO, &buffer, buffer.count)
            if count == 0 { finish("parent-exit") }
            else if count > 0 { finish("parent-request") }
            else if errno != EINTR && errno != EAGAIN { finish("parent-pipe-error") }
        }
        for number in [SIGTERM, SIGINT, SIGHUP] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler { finish("signal-\(number)") }
            source.resume(); signals.append(source)
        }
        timer.resume(); input.resume()
        journal.state = .armed
        try store.save(journal)
        let ready = Data("READY \(id.uuidString)\n".utf8)
        let written = ready.withUnsafeBytes { Darwin.write(STDOUT_FILENO, $0.baseAddress, $0.count) }
        if written != ready.count { finish("parent-exit-before-ready") }
        // Process-local run loop; timers and EOF are event-driven. No detached
        // service survives logout, reboot, SIGKILL of the helper, or OS failure.
        while !finished { RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1)) }
        if let result { throw result }
    }
}
