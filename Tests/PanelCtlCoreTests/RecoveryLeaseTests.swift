import XCTest
import CoreGraphics
import Darwin
@testable import PanelCtlCore

final class RecoveryLeaseTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("panelctl-lease-tests-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
    }

    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }

    private func snapshot() throws -> RecoverySnapshot {
        let value: [String: Any] = ["bootSession": "boot", "osBuild": "build", "userID": getuid(),
            "displays": (1...2).map { id -> [String: Any] in
                ["uuid": "00000000-0000-0000-0000-00000000000\(id)", "id": id,
                 "vendor": 1, "model": 2, "serial": id, "builtin": false,
                 "main": id == 1, "active": true, "x": (id - 1) * 1920, "y": 0, "rotation": 0,
                 "connector": "port-\(id)", "colorSpace": "color",
                 "identityEvidence": ["source": "syntheticFixture", "capturedAt": 0],
                 "mode": ["id": 1, "width": 1920, "height": 1080, "pixelWidth": 1920,
                          "pixelHeight": 1080, "refreshRate": 60, "flags": 0]]
            }]
        return try JSONDecoder().decode(RecoverySnapshot.self, from: JSONSerialization.data(withJSONObject: value))
    }

    private func absent(_ original: RecoverySnapshot) -> RecoverySnapshot {
        RecoverySnapshot(bootSession: original.bootSession, osBuild: original.osBuild, userID: original.userID,
                         displays: Array(original.displays.prefix(1)))
    }

    private func inventory(_ original: RecoverySnapshot, online: Set<UInt32>) -> RecoveryEnableInventory {
        RecoveryEnableInventory(bootSession: original.bootSession, osBuild: original.osBuild,
            userID: original.userID, identities: original.displays.map(RecoveryEnableIdentity.init),
            onlineIDs: online, binding: .syntheticPhysicalFixture)
    }

    private func store() throws -> RecoveryStore {
        let store = RecoveryStore(url: directory.appendingPathComponent("\(UUID()).json"))
        try store.lock()
        return store
    }

    func testDisableWriteAheadOrderingAndFreshLeaseAtEveryTransactionBoundary() throws {
        let baseline = try snapshot(), store = try store()
        var journal = RecoveryJournal(snapshot: baseline, timeout: 30)
        journal.state = .armed
        try store.create(journal)
        var events: [String] = []
        let transaction = RecoveryEnableTransaction(begin: {
            XCTAssertEqual(try store.load().state, .disabling)
            XCTAssertEqual(try store.load().disabledByUsID, 2)
            XCTAssertEqual(try store.load().disableAttempted, true)
            XCTAssertNil(try store.load().disableStaged)
            events.append("begin"); return CGDisplayConfigRef(bitPattern: 1)!
        }, setEnabled: { _, id, enabled in
            XCTAssertEqual(id, 2); XCTAssertFalse(enabled); events.append("set")
        }, commit: { _, scope in
            XCTAssertEqual(scope, .forSession)
            XCTAssertEqual(try store.load().disableStaged, true)
            XCTAssertEqual(try store.load().disableCommitStarted, true)
            events.append("commit")
        }, cancel: { _ in XCTFail("unexpected cancel") })
        let disable = RecoveryDisable(transaction: transaction,
            inventory: { self.inventory(baseline, online: [1, 2]) }, preflight: { _, _ in events.append("preflight") })
        try disable.perform(&journal, store: store, targetID: 2,
                            capture: { events.append("capture"); return baseline }, lease: { events.append("lease") })
        XCTAssertEqual(events, ["lease", "capture", "preflight", "lease", "capture", "preflight", "begin",
                                "lease", "capture", "preflight", "set", "lease", "capture", "preflight", "commit"])
        XCTAssertEqual(try store.load().state, .disabled)
        XCTAssertThrowsError(try disable.perform(&journal, store: store, targetID: 2, capture: { baseline }, lease: {}))
    }

    func testUnreadyExpiredDeadLeaseTopologyAndPersistenceRefuseDisable() throws {
        let baseline = try snapshot()
        for fault in ["unready", "expired", "lease", "topology", "persistence", "preflight", "verifyOnly"] {
            let store = try store()
            var journal = RecoveryJournal(snapshot: baseline, verifyOnly: fault == "verifyOnly", timeout: 30)
            journal.state = fault == "unready" ? .captured : .armed
            if fault == "expired" {
                var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(journal)) as! [String: Any]
                json["createdAt"] = Date().addingTimeInterval(-60).timeIntervalSinceReferenceDate
                json["deadline"] = Date().addingTimeInterval(-30).timeIntervalSinceReferenceDate
                journal = try JSONDecoder().decode(RecoveryJournal.self, from: JSONSerialization.data(withJSONObject: json))
            }
            try store.create(journal)
            if fault == "persistence" { store.unlock() }
            let transaction = RecoveryEnableTransaction(begin: {
                XCTFail("began despite \(fault)"); return CGDisplayConfigRef(bitPattern: 1)!
            }, setEnabled: { _, _, _ in XCTFail("setter") }, commit: { _, _ in XCTFail("commit") }, cancel: { _ in })
            let disable = RecoveryDisable(transaction: transaction,
                inventory: { self.inventory(baseline, online: [1, 2]) }, preflight: { _, _ in
                    if fault == "preflight" { throw RecoveryError.unsafe(fault) }
                })
            XCTAssertThrowsError(try disable.perform(&journal, store: store, targetID: 2,
                capture: { fault == "topology" ? self.absent(baseline) : baseline }, lease: {
                    if fault == "lease" { throw RecoveryError.unsafe(fault) }
                }), fault)
            XCTAssertEqual(try store.load().snapshot, baseline)
        }
    }

    func testLeaseLossAtEveryDisableBoundaryPreventsCompletion() throws {
        let baseline = try snapshot()
        // Before intent, before begin, before setter, and before completion.
        for revokedAt in 1...4 {
            let store = try store()
            var journal = RecoveryJournal(snapshot: baseline, timeout: 30); journal.state = .armed
            try store.create(journal)
            var checks = 0, begins = 0, setters = 0, cancellations = 0
            let transaction = RecoveryEnableTransaction(begin: {
                begins += 1; return CGDisplayConfigRef(bitPattern: 1)!
            }, setEnabled: { _, id, enabled in
                XCTAssertEqual(id, 2); XCTAssertFalse(enabled); setters += 1
            }, commit: { _, _ in XCTFail("completion after revoked lease") }, cancel: { _ in cancellations += 1 })
            let disable = RecoveryDisable(transaction: transaction,
                inventory: { self.inventory(baseline, online: [1, 2]) }, preflight: { _, _ in })
            XCTAssertThrowsError(try disable.perform(&journal, store: store, targetID: 2, capture: { baseline }, lease: {
                checks += 1
                if checks == revokedAt { throw RecoveryError.unsafe("parent died") }
            }))
            XCTAssertEqual(checks, revokedAt)
            XCTAssertEqual(begins, revokedAt >= 3 ? 1 : 0)
            XCTAssertEqual(setters, revokedAt == 4 ? 1 : 0)
            XCTAssertEqual(cancellations, begins)
            let saved = try store.load()
            XCTAssertEqual(saved.snapshot, baseline)
            XCTAssertEqual(saved.disabledByUsID, revokedAt == 1 ? nil : 2)
            XCTAssertEqual(saved.disableAttempted, revokedAt == 1 ? nil : true)
            XCTAssertEqual(saved.disableStaged, revokedAt == 4 ? true : nil)
            XCTAssertNil(saved.disableCommitStarted)
            XCTAssertNil(saved.disableCompleted)
            XCTAssertEqual(saved.state, revokedAt == 1 ? .armed : .disabling)
            store.unlock()
            let engine = RecoveryEngine(capture: { self.absent(baseline) }, apply: { _ in XCTFail("public write") },
                reenable: RecoveryReenable(inventory: { self.inventory(baseline, online: [1]) }, enable: { _, _ in
                    XCTFail("cancelled disable authorized a later private enable")
                }), convergencePause: {})
            XCTAssertThrowsError(try engine.recover(store: store, trigger: "startup"))
            XCTAssertNil(try store.load().reenableAttempted)
        }
    }

    func testCrashWindowsRetainTargetAndStartupUsesSameOneShotRecovery() throws {
        let baseline = try snapshot()
        for fault in ["begin", "setter", "staging-save", "commit", "ack", "none"] {
            let store = try store()
            var journal = RecoveryJournal(snapshot: baseline, timeout: 30); journal.state = .armed
            try store.create(journal)
            var current = baseline, cancellations = 0, enables = 0
            let transaction = RecoveryEnableTransaction(begin: {
                if fault == "begin" { throw RecoveryError.unsafe("crash before setter") }
                return CGDisplayConfigRef(bitPattern: 1)!
            }, setEnabled: { _, _, _ in
                if fault == "setter" { throw RecoveryError.unsafe("crash in setter") }
                if fault == "staging-save" { store.unlock() }
            }, commit: { _, _ in
                current = self.absent(baseline)
                if fault == "commit" { throw RecoveryError.unsafe("uncertain commit") }
                if fault == "ack" { store.unlock() }
            }, cancel: { _ in cancellations += 1 })
            let disable = RecoveryDisable(transaction: transaction,
                inventory: { self.inventory(baseline, online: [1, 2]) }, preflight: { _, _ in })
            if fault == "none" {
                try disable.perform(&journal, store: store, targetID: 2, capture: { current }, lease: {})
            } else {
                XCTAssertThrowsError(try disable.perform(&journal, store: store, targetID: 2, capture: { current }, lease: {}))
            }
            XCTAssertEqual(try store.load().disabledByUsID, 2)
            XCTAssertEqual(try store.load().disableAttempted, true)
            XCTAssertEqual(try store.load().state, fault == "none" ? .disabled : .disabling)
            XCTAssertEqual(cancellations, ["setter", "staging-save"].contains(fault) ? 1 : 0)
            XCTAssertEqual(try store.load().disableStaged, ["begin", "setter", "staging-save"].contains(fault) ? nil : true)
            store.unlock()
            let backend = RecoveryReenable(inventory: { self.inventory(baseline, online: [1]) }, enable: { id, validate in
                try validate(); XCTAssertEqual(id, 2); enables += 1; current = baseline
            })
            let engine = RecoveryEngine(capture: { current }, apply: { _ in XCTFail("public no-op") },
                                        reenable: backend, convergencePause: {})
            XCTAssertEqual(try engine.recover(store: store, trigger: "startup").state, .restored)
            XCTAssertEqual(try engine.recover(store: store, trigger: "shutdown").state, .restored)
            XCTAssertEqual(enables, ["begin", "setter", "staging-save"].contains(fault) ? 0 : 1)
        }
    }

    func testCommitIntentSaveFailureAndLegacyStagingCannotAuthorizeRecovery() throws {
        let baseline = try snapshot()
        for legacy in [false, true] {
            let store = try store()
            var journal = RecoveryJournal(snapshot: baseline, timeout: 30)
            journal.state = .armed
            if legacy { journal.disabledByUsID = 2; journal.disableStaged = true }
            try store.create(journal)
            if !legacy {
                var validations = 0, cancellations = 0
                let transaction = RecoveryEnableTransaction(begin: { OpaquePointer(bitPattern: 1)! },
                    setEnabled: { _, _, _ in }, commit: { _, _ in XCTFail("commit without durable intent") },
                    cancel: { _ in cancellations += 1 })
                let disable = RecoveryDisable(transaction: transaction,
                    inventory: { self.inventory(baseline, online: [1, 2]) }, preflight: { _, _ in
                        validations += 1
                        if validations == 4 { store.unlock() }
                    })
                XCTAssertThrowsError(try disable.perform(&journal, store: store, targetID: 2, capture: { baseline }, lease: {}))
                XCTAssertEqual(cancellations, 1)
            }
            XCTAssertEqual(try store.load().disableStaged, true)
            XCTAssertNil(try store.load().disableCommitStarted)
            store.unlock()
            let engine = RecoveryEngine(capture: { self.absent(baseline) }, apply: { _ in XCTFail("public write") },
                reenable: RecoveryReenable(inventory: { self.inventory(baseline, online: [1]) }, enable: { _, _ in
                    XCTFail("staging alone granted private authority")
                }), convergencePause: {})
            if !legacy {
                XCTAssertNil(journal.disableCommitStarted)
                XCTAssertEqual(journal.privateRecoveryClosed, true)
                try store.lock()
                XCTAssertThrowsError(try engine.finish(&journal, store: store, verifyOnly: false, trigger: "disable-error"))
                store.unlock()
            }
            XCTAssertThrowsError(try engine.recover(store: store, trigger: "startup"))
            XCTAssertNil(try store.load().reenableAttempted)
            XCTAssertEqual(try store.load().state, .needsAttention)
            XCTAssertEqual(try store.load().snapshot, baseline)
        }
    }

    func testManualSystemReenableRetiresAuthorityBeforeFailedVerification() throws {
        let baseline = try snapshot(), store = try store()
        var displays = baseline.displays; displays[1].x += 10
        var current = RecoverySnapshot(bootSession: baseline.bootSession, osBuild: baseline.osBuild,
                                       userID: baseline.userID, displays: displays)
        let journal = RecoveryJournal(snapshot: baseline, disabledByUsID: 2, disableStaged: true, disableCommitStarted: true)
        try store.create(journal); store.unlock()
        let engine = RecoveryEngine(capture: { current }, apply: { _ in
            XCTFail("must not repair layout after a system re-enable")
            throw RecoveryError.unsafe("layout repair failed")
        }, reenable: RecoveryReenable(inventory: { self.inventory(baseline, online: [1]) }, enable: { _, _ in
            XCTFail("system re-enable revived old private authority")
        }), convergencePause: {})
        XCTAssertThrowsError(try engine.recover(store: store, trigger: "manual-enable", ownedOnly: true))
        XCTAssertEqual(try store.load().privateRecoveryClosed, true)
        XCTAssertEqual(try store.load().state, .needsAttention)
        current = absent(baseline)
        XCTAssertThrowsError(try engine.recover(store: store, trigger: "startup", ownedOnly: true))
        XCTAssertNil(try store.load().reenableAttempted)
        XCTAssertEqual(try store.load().snapshot, baseline)
    }

    func testBoundedConvergenceAfterEnableAndPublicRestoreNeverRepeatsWrites() throws {
        let baseline = try snapshot(), store = try store()
        var current = absent(baseline), phase = 0, pauses = 0, enables = 0, publicWrites = 0
        var shifted = baseline.displays; shifted[1].x += 10
        let changed = RecoverySnapshot(bootSession: baseline.bootSession, osBuild: baseline.osBuild,
                                       userID: baseline.userID, displays: shifted)
        var journal = RecoveryJournal(snapshot: baseline, disabledByUsID: 2, disableStaged: true, disableCommitStarted: true)
        try store.create(journal)
        let backend = RecoveryReenable(inventory: { self.inventory(baseline, online: [1]) }, enable: { _, validate in
            try validate(); enables += 1; phase = 1
        })
        let engine = RecoveryEngine(capture: { current }, apply: { _ in publicWrites += 1; phase = 2 },
            reenable: backend, convergencePause: {
                pauses += 1
                if phase == 1 && pauses == 2 { current = changed }
                if phase == 2 && pauses == 4 { current = baseline }
            })
        try engine.finish(&journal, store: store, verifyOnly: false, trigger: "deadline")
        XCTAssertEqual(enables, 1); XCTAssertEqual(publicWrites, 1); XCTAssertEqual(pauses, 4)
        XCTAssertEqual(try store.load().state, .restored)
    }

    func testStoredVerifyOnlyAndResolvedIntentNeverGrantPrivateAuthority() throws {
        let baseline = try snapshot()
        for resolved in [false, true] {
            let store = try store()
            var journal = RecoveryJournal(snapshot: baseline, verifyOnly: !resolved, disabledByUsID: 2, disableStaged: true, disableCommitStarted: true)
            if resolved { journal.state = .verified }
            try store.create(journal)
            let backend = RecoveryReenable(inventory: { self.inventory(baseline, online: [1]) },
                                           enable: { _, _ in XCTFail("private write") })
            let engine = RecoveryEngine(capture: { self.absent(baseline) }, apply: { _ in XCTFail("public write") },
                                        reenable: backend, convergencePause: {})
            for _ in 0..<2 {
                XCTAssertThrowsError(try engine.finish(&journal, store: store, verifyOnly: false, trigger: "restore"))
                journal = try store.load()
                XCTAssertEqual(journal.state, .needsAttention)
            }
        }
    }

    func testExhaustedConvergencePreservesEvidenceAndAttemptBudget() throws {
        let baseline = try snapshot(), store = try store()
        var journal = RecoveryJournal(snapshot: baseline, disabledByUsID: 2, disableStaged: true, disableCommitStarted: true)
        try store.create(journal)
        var writes = 0, pauses = 0
        let engine = RecoveryEngine(capture: { self.absent(baseline) }, apply: { _ in XCTFail("public write") },
            reenable: RecoveryReenable(inventory: { self.inventory(baseline, online: [1]) }, enable: { _, validate in
                try validate(); writes += 1
            }), convergencePause: { pauses += 1 })
        XCTAssertThrowsError(try engine.finish(&journal, store: store, verifyOnly: false, trigger: "deadline"))
        XCTAssertEqual(pauses, 5); XCTAssertEqual(writes, 1)
        journal = try store.load()
        XCTAssertEqual(journal.state, .needsAttention); XCTAssertEqual(journal.snapshot, baseline)
        XCTAssertThrowsError(try engine.finish(&journal, store: store, verifyOnly: false, trigger: "startup"))
        XCTAssertEqual(writes, 1)
    }

    func testRecoveryEntryPointHonorsBothLocksAcrossCustomJournals() throws {
        let baseline = try snapshot(), store = try store()
        try store.create(RecoveryJournal(snapshot: baseline))
        let engine = RecoveryEngine(capture: { baseline }, apply: { _ in XCTFail("writer") })
        XCTAssertThrowsError(try engine.recover(store: RecoveryStore(url: store.url), trigger: "startup"))
        store.unlock()
        let operation = RecoveryStore.operationLock(); try operation.lock()
        let other = try self.store(); try other.create(RecoveryJournal(snapshot: baseline)); other.unlock()
        XCTAssertThrowsError(try engine.recover(store: store, trigger: "shutdown"))
        XCTAssertThrowsError(try engine.recover(store: other, trigger: "startup"))
        operation.unlock()
        XCTAssertEqual(try engine.recover(store: store, trigger: "startup").state, .restored)
    }

    // Launched only by the test below, not by production or environment flags
    // in PanelCtlCore. Every writer and every observation is synthetic.
    func testHelperSubprocess() throws {
        guard let path = ProcessInfo.processInfo.environment["PANELCTL_FAKE_HELPER_JOURNAL"] else { return }
        let fault = ProcessInfo.processInfo.environment["PANELCTL_FAKE_HELPER_FAULT"] ?? "none"
        let store = RecoveryStore(url: URL(fileURLWithPath: path))
        let journal = try store.load(), baseline = journal.snapshot
        let displayURL = store.url.appendingPathExtension("display")
        var current = baseline
        var pendingEnabled = false
        var runtime: RecoveryPrivateSession?
        func crash(_ point: String) {
            if fault == point { _ = kill(getpid(), SIGKILL) }
        }
        let transaction = RecoveryEnableTransaction(begin: {
            crash("begin"); return CGDisplayConfigRef(bitPattern: 1)!
        }, setEnabled: { _, _, enabled in pendingEnabled = enabled; crash("setter") }, commit: { _, _ in
            crash("before-commit")
            current = pendingEnabled ? baseline : self.absent(baseline)
            try JSONEncoder().encode(current).write(to: displayURL, options: .atomic)
            if !pendingEnabled {
                if fault == "runtime-system-enable" { current = baseline }
                if fault == "runtime-system-layout" || fault == "runtime-system-layout-EOF" {
                    var displays = baseline.displays
                    displays[1].x += 10
                    current = RecoverySnapshot(bootSession: baseline.bootSession, osBuild: baseline.osBuild,
                                               userID: baseline.userID, displays: displays)
                }
                if fault == "runtime-sleep" || fault == "runtime-sleep-expired" {
                    DispatchQueue.main.async {
                        runtime?.receive(.suspend(.system))
                        if fault == "runtime-sleep" {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { runtime?.receive(.resume(.system)) }
                        }
                    }
                }
            }
            crash("after-commit")
        }, cancel: { _ in })
        let disable = RecoveryDisable(transaction: transaction,
            inventory: { self.inventory(baseline, online: [1, 2]) }, preflight: { _, _ in })
        let backend = RecoveryReenable(inventory: { self.inventory(baseline, online: [1]) }, enable: { _, validate in
            try validate(); current = baseline
            try JSONEncoder().encode(current).write(to: displayURL, options: .atomic)
        })
        let engine = RecoveryEngine(capture: { current }, apply: { _ in XCTFail("unexpected public write") },
                                    reenable: backend, convergencePause: {})
        if fault.hasPrefix("runtime-") {
            runtime = RecoveryPrivateSession(snapshot: baseline, capture: { current }, inventory: {
                self.inventory(baseline, online: Set(current.displays.map(\.id)))
            }, environment: {
                RecoveryEligibilityEnvironment(architecture: .appleSilicon, drivers: .nativeOnly,
                    lid: .notApplicable, mirrored: false, screens: Dictionary(uniqueKeysWithValues: current.displays.map {
                        ($0.id, .init(kind: .physical, online: true, active: true,
                                      awake: fault != "runtime-collapse" || current.displays.count == 2))
                    }))
            }, transaction: { transaction }, apply: { _, _ in
                try Data("public-write".utf8).write(to: store.url.appendingPathExtension("public-write"))
                XCTFail("unexpected public write")
            }, initiallyAwake: true)
        }
        try RecoveryWatchdog.runHelper(store: store, id: journal.id, engine: engine, disable: disable,
                                       session: runtime, resolveModes: { _ in crash("before-ready") })
    }

    private func awaitState(_ state: RecoveryState, store: RecoveryStore, action: () throws -> Void = {}) throws {
        // Atomic rename notifications can precede the final journal replacement.
        // A bounded test-only observer avoids depending on vnode coalescing.
        let source = DispatchSource.makeTimerSource(queue: .global())
        let done = DispatchSemaphore(value: 0)
        source.schedule(deadline: .now(), repeating: .milliseconds(10))
        source.setEventHandler { if (try? store.load().state) == state { done.signal() } }
        source.resume()
        defer { source.cancel() }
        try action()
        guard done.wait(timeout: .now() + 8) == .success else {
            throw RecoveryError.unsafe("missing state \(state); journal is \(try store.load().state)")
        }
    }

    func testRealHelperIPCDeathCrashAndRecoveryWithFakeWriters() throws {
        let baseline = try snapshot()
        for fault in ["before-ready", "after-ready", "begin", "setter", "before-commit", "after-commit",
                      "shutdown", "deadline", "SIGINT", "SIGTERM", "runtime-deadline", "runtime-collapse",
                      "runtime-system-enable", "runtime-system-layout", "runtime-system-layout-EOF",
                      "runtime-sleep", "runtime-sleep-expired", "runtime-SIGTERM"] {
            let store = try store()
            let journal = RecoveryJournal(snapshot: baseline, timeout: fault == "deadline" || fault == "runtime-deadline" ? 2 : 30)
            try store.create(journal); store.unlock()
            let process = Process(), pipe = Pipe(), output = Pipe(), exited = DispatchSemaphore(value: 0)
            process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
            process.arguments = ["xctest", "-XCTest", "PanelCtlCoreTests.RecoveryLeaseTests/testHelperSubprocess",
                                 Bundle(for: Self.self).bundlePath]
            var environment = ProcessInfo.processInfo.environment
            environment["PANELCTL_FAKE_HELPER_JOURNAL"] = store.url.path
            environment["PANELCTL_FAKE_HELPER_FAULT"] = fault
            process.environment = environment
            process.standardInput = pipe
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { _ in exited.signal() }
            try process.run()
            try pipe.fileHandleForReading.close()
            try output.fileHandleForWriting.close()
            defer {
                try? pipe.fileHandleForWriting.close()
                try? output.fileHandleForReading.close()
                if process.isRunning { process.terminate() }
            }
            if fault != "before-ready" {
                // Consume the actual READY, not just the earlier armed save.
                // XCTest emits its own preamble on this test-only pipe.
                var response = ""
                let expires = ProcessInfo.processInfo.systemUptime + 5
                while !response.contains("READY \(journal.id.uuidString)\n") {
                    let remaining = expires - ProcessInfo.processInfo.systemUptime
                    var descriptor = pollfd(fd: output.fileHandleForReading.fileDescriptor, events: Int16(POLLIN), revents: 0)
                    guard remaining > 0, poll(&descriptor, 1, Int32(remaining * 1000)) > 0 else {
                        throw RecoveryError.unsafe("fake helper READY timeout")
                    }
                    var bytes = [UInt8](repeating: 0, count: 4096)
                    let count = Darwin.read(descriptor.fd, &bytes, bytes.count)
                    guard count > 0 else { throw RecoveryError.unsafe("fake helper exited before READY") }
                    response += String(decoding: bytes.prefix(count), as: UTF8.self)
                }
                XCTAssertEqual(try store.load().state, .armed)
                if fault == "after-ready" {
                    XCTAssertEqual(kill(process.processIdentifier, SIGKILL), 0)
                } else {
                    try pipe.fileHandleForWriting.write(contentsOf: Data("DISABLE \(journal.id.uuidString) 2\n".utf8))
                    if ["shutdown", "deadline", "SIGINT", "SIGTERM"].contains(fault) || fault.hasPrefix("runtime-") {
                        if !["runtime-collapse", "runtime-system-enable", "runtime-system-layout"].contains(fault) {
                            try awaitState(.disabled, store: store)
                        }
                        // Even a different custom journal cannot compete while
                        // this helper owns the user's operation lock.
                        if !["runtime-collapse", "runtime-system-enable", "runtime-system-layout"].contains(fault) {
                            let operation = RecoveryStore.operationLock()
                            XCTAssertThrowsError(try operation.lock())
                        }
                        if ["shutdown", "runtime-sleep", "runtime-sleep-expired", "runtime-system-layout-EOF"].contains(fault) { try pipe.fileHandleForWriting.close() }
                        if fault == "SIGINT" { XCTAssertEqual(kill(process.processIdentifier, SIGINT), 0) }
                        if fault == "SIGTERM" || fault == "runtime-SIGTERM" { XCTAssertEqual(kill(process.processIdentifier, SIGTERM), 0) }
                    }
                }
            }
            XCTAssertEqual(exited.wait(timeout: .now() + 8), .success, fault)
            let saved = try store.load()
            XCTAssertFalse(FileManager.default.fileExists(atPath: store.url.appendingPathExtension("public-write").path), fault)
            XCTAssertEqual(saved.id, journal.id); XCTAssertEqual(saved.snapshot, baseline)
            if fault == "runtime-system-layout" || fault == "runtime-system-layout-EOF" {
                XCTAssertNotEqual(process.terminationStatus, 0)
                XCTAssertEqual(saved.state, .needsAttention)
                XCTAssertEqual(saved.privateRecoveryClosed, true, "system re-enable must durably retire authority even if layout verification fails")
                XCTAssertNil(saved.reenableAttempted)
            } else if fault == "runtime-sleep-expired" {
                XCTAssertNotEqual(process.terminationStatus, 0)
                XCTAssertEqual(saved.state, .needsAttention)
                XCTAssertNil(saved.reenableAttempted, "exhausted sleep gate must not enable")
            } else if ["shutdown", "deadline", "SIGINT", "SIGTERM"].contains(fault) || fault.hasPrefix("runtime-") {
                XCTAssertEqual(process.terminationStatus, 0, fault)
                XCTAssertEqual(saved.state, fault == "runtime-system-enable" ? .verified : .restored, fault)
                XCTAssertEqual(saved.reenableAttempted, fault == "runtime-system-enable" ? nil : true, fault)
                if fault == "runtime-system-enable" { XCTAssertEqual(saved.trigger, "system-reenable") }
                if fault == "runtime-collapse" { XCTAssertTrue(saved.trigger?.hasPrefix("eligibility:") == true) }
            } else {
                XCTAssertEqual(process.terminationReason, .uncaughtSignal, fault)
                XCTAssertEqual(process.terminationStatus, SIGKILL, fault)
                XCTAssertFalse(saved.state.resolved, fault)
                if !["before-ready", "after-ready"].contains(fault) {
                    XCTAssertEqual(saved.disabledByUsID, 2, fault)
                    XCTAssertEqual(saved.state, .disabling, fault)
                } else { XCTAssertNil(saved.disabledByUsID, fault) }
                // Same-boot startup adopts evidence after helper death. A
                // successful commit without its acknowledgment is recoverable.
                var current = baseline, enables = 0
                if let data = try? Data(contentsOf: store.url.appendingPathExtension("display")) {
                    current = try JSONDecoder().decode(RecoverySnapshot.self, from: data)
                }
                let backend = RecoveryReenable(inventory: { self.inventory(baseline, online: [1]) }, enable: { _, validate in
                    try validate(); enables += 1; current = baseline
                })
                let engine = RecoveryEngine(capture: { current }, apply: { _ in XCTFail("public write") },
                                            reenable: backend, convergencePause: {})
                if ["before-ready", "after-ready", "begin", "setter"].contains(fault) {
                    // A later unrelated disappearance must not turn selected
                    // intent into authority when no setter staged successfully.
                    current = absent(baseline)
                    XCTAssertNil(saved.disableStaged, fault)
                    XCTAssertThrowsError(try engine.recover(store: store, trigger: "startup"), fault)
                    XCTAssertEqual(try store.load().state, .needsAttention, fault)
                } else {
                    XCTAssertEqual(saved.disableStaged, true, fault)
                    XCTAssertEqual(saved.disableCommitStarted, true, fault)
                    XCTAssertEqual(try engine.recover(store: store, trigger: "startup").state,
                                   fault == "before-commit" ? .verified : .restored)
                }
                XCTAssertEqual(enables, fault == "after-commit" ? 1 : 0, fault)
            }
        }
    }
}
