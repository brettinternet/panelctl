import Foundation
import Darwin

public enum RecoveryAction: String, Equatable {
    case capture, status, verify, restore, rehearse, `guard`, enable, panic
}

public enum DisplayRecovery {
    public static func run(action: RecoveryAction, timeout: TimeInterval?, journalPath: String?, executable: URL) throws {
        let store = RecoveryStore(url: journalPath.map { URL(fileURLWithPath: $0) } ?? RecoveryStore.defaultURL)
        if action == .status {
            try printJournal(store.load())
            return
        }
        if action == .enable || action == .panic {
            try printJournal(RecoveryCLI().recoverOwned(store: store, trigger: "manual-\(action.rawValue)"))
            return
        }
        if action == .rehearse || action == .guard {
            let verifyOnly = action == .rehearse
            let session = try RecoveryWatchdog.start(store: store, executable: executable, timeout: timeout ?? 5, verifyOnly: verifyOnly)
            print("\(verifyOnly ? "Rehearsal armed; no display writes" : "Public-configuration recovery armed; private reconnection unavailable"). Journal: \(store.url.path)")
            fflush(stdout)
            session.wait()
            let journal = try store.load()
            try printJournal(journal)
            guard journal.id == session.id, journal.state == (verifyOnly ? .verified : .restored) else {
                throw RecoveryError.unsafe(journal.failure ?? "watchdog did not verify the snapshot")
            }
            return
        }
        if action != .capture {
            let saved = try store.load()
            let engine: RecoveryEngine
            if saved.mirrorTargetID != nil {
                engine = .publicMirror
            } else {
                let session = RecoveryPrivateSession(snapshot: saved.snapshot)
                session.observeNotifications()
                engine = session.makeEngine(requiresPrivateIdentity: saved.disabledByUsID != nil)
            }
            try printJournal(engine.recover(store: store, verifyOnly: action == .verify,
                                            trigger: "manual-\(action.rawValue)", expectedID: saved.id))
            return
        }
        let operationLock = RecoveryStore.operationLock()
        try operationLock.lock()
        defer { operationLock.unlock() }
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
        }
    }

    public static func disable(selector: String, timeout: TimeInterval, journalPath: String?, executable: URL) throws {
        let store = RecoveryStore(url: journalPath.map { URL(fileURLWithPath: $0) } ?? RecoveryStore.defaultURL)
        try printJournal(RecoveryCLI().disable(selector: selector, timeout: timeout, store: store, executable: executable))
    }

    public static func runHelper(journalPath: String, id: UUID) throws {
        let store = RecoveryStore(url: URL(fileURLWithPath: journalPath))
        do {
            try RecoveryWatchdog.runHelper(store: store, id: id)
        } catch {
            // Include startup failures in durable evidence, but never alter a
            // different journal or one owned by another active helper.
            let operationLock = RecoveryStore.operationLock()
            if (try? operationLock.lock()) != nil, (try? store.lock()) != nil {
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

/// The helper is the sole writer for the whole bounded lease. The parent may
/// request a disable, never execute one itself based on a stale READY. There is
/// no arbitrary command hook. Private sessions refuse unqualified providers.
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

    func requestDisable(targetID: UInt32) throws {
        guard process.isRunning,
              fcntl(lease.fileDescriptor, F_SETNOSIGPIPE, 1) == 0 else {
            throw RecoveryError.unsafe("watchdog unavailable; no disable request sent")
        }
        // A single sub-PIPE_BUF message. Delivery is not commit acknowledgment.
        try lease.write(contentsOf: Data("DISABLE \(id.uuidString) \(targetID)\n".utf8))
    }

    // The app must keep its run loop responsive while the independent helper
    // recovers. Closing the pipe requests recovery, not proof of completion.
    func releaseLease() throws { try lease.close() }

    func shutdown() throws {
        // EOF invokes the same recovery engine as deadline/startup/manual use.
        try releaseLease()
        wait()
    }

    static func start(store: RecoveryStore, executable: URL, timeout: TimeInterval, verifyOnly: Bool,
                      expectedSnapshot: RecoverySnapshot? = nil, privateLease: Bool = false,
                      capture: () throws -> RecoverySnapshot = { try .capture() }) throws -> RecoveryWatchdog {
        guard timeout.isFinite, (1...60).contains(timeout) else {
            throw RecoveryError.unsafe("watchdog timeout must be 1–60 seconds")
        }
        let operationLock = RecoveryStore.operationLock()
        try operationLock.lock()
        defer { operationLock.unlock() }
        try store.lock()
        var journal: RecoveryJournal
        do {
            let snapshot = try capture()
            try expectedSnapshot?.verify(snapshot)
            try snapshot.verify(capture())
            // Public topology verification does not compare private transport
            // evidence. Keep the selected baseline so the helper's private
            // identity checks refuse a changed connection rather than adopt it.
            journal = RecoveryJournal(snapshot: expectedSnapshot ?? snapshot, verifyOnly: verifyOnly, timeout: timeout)
            journal.privateLease = privateLease ? true : nil
            try store.create(journal)
        } catch {
            store.unlock()
            throw error
        }
        store.unlock()
        operationLock.unlock()
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

    static func runHelper(store: RecoveryStore, id: UUID,
                          engine injectedEngine: RecoveryEngine? = nil,
                          disable: RecoveryDisable? = nil,
                          session injectedSession: RecoveryPrivateSession? = nil,
                          resolveModes: (RecoverySnapshot) throws -> Void = { _ = try RecoveryConfiguration.resolveModes($0) }) throws {
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
        let operationLock = RecoveryStore.operationLock()
        try operationLock.lock()
        defer { operationLock.unlock() }
        try store.lock()
        defer { store.unlock() }
        var journal = try store.load()
        guard journal.id == id, journal.state == .captured,
              let deadline = journal.deadline else {
            throw RecoveryError.unsafe("watchdog journal identity/state mismatch")
        }
        let session = injectedSession ?? (injectedEngine == nil ? RecoveryPrivateSession(snapshot: journal.snapshot) : nil)
        session?.observeNotifications()
        let requiresPrivateIdentity = journal.privateLease == true || journal.disabledByUsID != nil || disable != nil
        let engine = session?.makeEngine(requiresPrivateIdentity: requiresPrivateIdentity) ?? injectedEngine ?? RecoveryEngine()
        try journal.snapshot.verify(engine.capture())
        try resolveModes(journal.snapshot)
        let remaining = deadline.timeIntervalSinceNow
        guard remaining > 0, remaining <= 60 else {
            throw RecoveryError.unsafe("watchdog deadline expired or invalid; no mutation allowed")
        }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        let input = DispatchSource.makeReadSource(fileDescriptor: STDIN_FILENO, queue: .main)
        var signals: [DispatchSourceSignal] = []
        var finished = false
        var readySent = false
        let monotonicDeadline = ProcessInfo.processInfo.systemUptime + remaining
        var result: Error?
        var pendingFinish: String?
        func validateLease() throws {
            guard readySent, ProcessInfo.processInfo.systemUptime < monotonicDeadline else {
                throw RecoveryError.unsafe("helper not ready or lease expired")
            }
            // The command has already been consumed. EOF/HUP or any further
            // input revokes disable authority, including a queued shutdown.
            var descriptor = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
            guard poll(&descriptor, 1, 0) == 0 else {
                throw RecoveryError.unsafe("parent lease closed or another request pending")
            }
        }
        func finish(_ trigger: String, verifyOnly: Bool = false) {
            guard !finished else { return }
            if session?.gate == .deferred {
                pendingFinish = pendingFinish ?? trigger
                input.cancel() // EOF stays readable; do not spin while deferring.
                return
            }
            finished = true
            do {
                var reconcileOnly = verifyOnly
                if let session {
                    try session.gate.requireReady()
                    // EOF, signals and the deadline can beat the observation
                    // timer. Accept a system re-enable on every finish path,
                    // not only when the periodic sampler happens to see it.
                    if journal.disableStaged == true,
                       case .reconcileSystemReenable = try session.check() {
                        reconcileOnly = true
                    }
                }
                if reconcileOnly {
                    // Retire authority before verification: layout mismatch or
                    // a later disappearance must never revive our old intent.
                    journal.privateRecoveryClosed = true
                    try store.save(journal)
                }
                try engine.finish(&journal, store: store, verifyOnly: journal.verifyOnly || reconcileOnly, trigger: trigger)
            } catch {
                result = error
                journal.state = .needsAttention; journal.trigger = trigger
                journal.failure = String(describing: error)
                try? store.save(journal)
            }
            timer.cancel(); input.cancel()
            signals.forEach { $0.cancel() }
        }
        if session != nil {
            timer.schedule(deadline: .now() + 0.1, repeating: .milliseconds(100))
        } else { timer.schedule(deadline: .now() + remaining) }
        timer.setEventHandler {
            if let pendingFinish { finish(pendingFinish); return }
            if ProcessInfo.processInfo.systemUptime >= monotonicDeadline { finish("deadline"); return }
            guard let session, journal.disableStaged == true else { return }
            do {
                switch try session.check() {
                case .none, .deferWrites: break
                case .needsAttention: finish("lifecycle-attention")
                case .requestGuardedRecovery(let reason): finish("eligibility: \(reason)")
                case .reconcileSystemReenable: finish("system-reenable", verifyOnly: true)
                }
            } catch { finish("observation-error: \(error)") }
        }
        input.setEventHandler {
            var buffer = [UInt8](repeating: 0, count: 64)
            let count = Darwin.read(STDIN_FILENO, &buffer, buffer.count)
            if count == 0 { finish("parent-exit") }
            else if count > 0 {
                let command = String(decoding: buffer.prefix(count), as: UTF8.self)
                let parts = command.split(separator: " ")
                do {
                    guard parts.count == 3, parts[0] == "DISABLE", parts[1] == id.uuidString,
                          command.hasSuffix("\n"), let target = UInt32(parts[2].dropLast()) else {
                        throw RecoveryError.unsafe("invalid private disable request")
                    }
                    guard pendingFinish == nil else { throw RecoveryError.unsafe("recovery already requested") }
                    guard let disable = try session?.prepareDisable(targetID: target) ?? disable else {
                        throw RecoveryError.unsafe("private disable unavailable")
                    }
                    try disable.perform(&journal, store: store, targetID: target,
                                        capture: engine.capture, lease: validateLease)
                    session?.didDisable(target)
                } catch {
                    // An uncertain commit still goes through journal-driven
                    // recovery. The write-ahead target survives a failed ack.
                    finish("disable-error: \(error)")
                }
            }
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
        journal.watchdogPID = getpid()
        try store.save(journal)
        let ready = Data("READY \(id.uuidString)\n".utf8)
        let written = ready.withUnsafeBytes { Darwin.write(STDOUT_FILENO, $0.baseAddress, $0.count) }
        if written == ready.count { readySent = true }
        else { finish("parent-exit-before-ready") }
        // Process-local run loop; timers and EOF are event-driven. No detached
        // service survives logout, reboot, SIGKILL of the helper, or OS failure.
        while !finished { RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1)) }
        if let result { throw result }
    }
}
