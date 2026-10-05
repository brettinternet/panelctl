import XCTest
import CoreGraphics
import AppKit
import Darwin
@testable import PanelCtlCore

final class RecoveryCLITests: XCTestCase {
    private var directory: URL!
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("panelctl-cli-tests-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }

    private final class Fixture {
        let baseline: RecoverySnapshot
        var current: RecoverySnapshot
        var fault = ""
        var writes: [Bool] = []
        var begins = 0
        var clock: TimeInterval = 100
        var pending = false
        var leaseAlive = true
        var environment = RecoveryEligibilityEnvironment(architecture: .appleSilicon, drivers: .nativeOnly,
            lid: .notApplicable, mirrored: false, screens: [1: .init(kind: .physical, online: true, active: true, awake: true),
                                                         2: .init(kind: .physical, online: true, active: true, awake: true)])
        init() throws {
            let data: [String: Any] = ["bootSession": "boot", "osBuild": "build", "userID": getuid(), "hostModel": "synthetic-model",
                "displays": (1...2).map { id -> [String: Any] in
                    ["uuid": "00000000-0000-0000-0000-00000000000\(id)", "id": id,
                     "vendor": 1, "model": id, "serial": id, "builtin": false,
                     "main": id == 1, "active": true, "x": (id - 1) * 1920, "y": 0, "rotation": 0,
                     "connector": "port-\(id)", "identityEvidence": ["source": "syntheticFixture", "capturedAt": 0, "transport": "DisplayPort", "framebufferLocation": "frame-\(id)"],
                     "mode": ["id": 1, "width": 1920, "height": 1080, "pixelWidth": 1920,
                              "pixelHeight": 1080, "refreshRate": 60, "flags": 0]]
                }]
            baseline = try JSONDecoder().decode(RecoverySnapshot.self, from: JSONSerialization.data(withJSONObject: data))
            current = baseline
        }
        var absent: RecoverySnapshot {
            RecoverySnapshot(bootSession: baseline.bootSession, osBuild: baseline.osBuild, userID: baseline.userID,
                             displays: [baseline.displays[0]])
        }
        var records: [DisplayRecord] {
            baseline.displays.enumerated().map { index, d in
                DisplayRecord(index: index + 1, id: d.id, uuid: d.uuid, name: nil, active: true, online: true,
                    asleep: false, builtin: false, main: d.main, vendor: d.vendor, model: d.model, serial: d.serial,
                    bounds: DisplayBounds(CGRect(x: Int(d.x), y: 0, width: 1920, height: 1080)), pixelWidth: 1920, pixelHeight: 1080)
            }
        }
        lazy var session = RecoveryPrivateSession(snapshot: baseline, capture: { self.current }, inventory: {
            RecoveryEnableInventory(bootSession: self.baseline.bootSession, osBuild: self.baseline.osBuild,
                userID: self.baseline.userID, identities: self.baseline.displays.map(RecoveryEnableIdentity.init),
                onlineIDs: Set(self.current.displays.map(\.id)), hostModel: self.baseline.hostModel, architecture: "synthetic",
                binding: self.fault == "identity" ? .unqualified : .syntheticPhysicalFixture)
        }, environment: {
            var observed = self.environment
            let online = Set(self.current.displays.map(\.id))
            observed.screens = observed.screens.filter { online.contains($0.key) }
            return observed
        }, transaction: {
            if self.fault == "api" { throw RecoveryError.unsafe("private display backend unavailable") }
            return RecoveryEnableTransaction(begin: {
                self.begins += 1
                return CGDisplayConfigRef(bitPattern: 1)!
            }, setEnabled: { _, id, enabled in
                XCTAssertEqual(id, 2)
                self.pending = enabled; self.writes.append(enabled)
            }, commit: { _, scope in
                XCTAssertEqual(scope, .forSession)
                if self.fault == "recovery" && self.pending || self.fault == "disable-commit" && !self.pending {
                    throw RecoveryError.unsafe("injected commit failure")
                }
                self.current = self.pending ? self.baseline : self.absent
            }, cancel: { _ in })
        }, apply: { _, validate in try validate(); XCTFail("unexpected public mutation") }, now: { self.clock }, initiallyAwake: true)
    }

    private let arguments = ["recovery", "disable", "--display", "2", "--consent-disable", "--timeout", "5s"]

    private func execute(_ args: [String], cli: RecoveryCLI, store: RecoveryStore) throws -> RecoveryJournal {
        switch try CLIParser.parse(args) {
        case .recoveryDisable(let selector, let timeout, _):
            return try cli.disable(selector: selector, timeout: timeout, store: store, executable: URL(fileURLWithPath: "/unused"))
        case .recovery(let action, _, _) where action == .enable || action == .panic:
            return try cli.recoverOwned(store: store, trigger: "manual-\(action.rawValue)")
        case .recovery(let action, _, _) where action == .status: return try store.load()
        default: throw RecoveryError.unsafe("unexpected test command")
        }
    }

    private func cli(_ f: Fixture) -> RecoveryCLI {
        RecoveryCLI(records: { f.records }, capture: { f.current }, preflight: { snapshot, id in
            XCTAssertEqual(snapshot, f.baseline)
            _ = try f.session.prepareDisable(targetID: id)
        }, recover: { store, trigger in
            try f.session.engine.recover(store: store, trigger: trigger, ownedOnly: true)
        }, arm: { store, _, timeout, snapshot in
            if f.fault == "helper" { throw RecoveryError.unsafe("watchdog unavailable") }
            let operation = RecoveryStore.operationLock(); try operation.lock()
            try store.lock()
            var journal = RecoveryJournal(snapshot: snapshot, timeout: timeout)
            journal.privateLease = true; journal.state = .armed
            try store.create(journal)
            func finish() throws {
                defer { store.unlock(); operation.unlock() }
                try f.session.engine.finish(&journal, store: store, verifyOnly: false, trigger: "deadline")
            }
            let journalID = journal.id
            return RecoveryCLI.Lease(id: journalID, requestDisable: { id in
                if f.fault == "lost-helper" { f.leaseAlive = false }
                let disable = try f.session.prepareDisable(targetID: id)
                try disable.perform(&journal, store: store, targetID: id, capture: { f.current }, lease: {
                    guard f.leaseAlive else { throw RecoveryError.unsafe("lease lost") }
                    XCTAssertEqual(try store.load().id, journalID)
                })
                XCTAssertEqual(try store.load().disableCompleted, true)
                f.session.didDisable(id)
            }, wait: { try? finish() }, shutdown: finish)
        })
    }

    func testStrictParserAndHelp() throws {
        XCTAssertEqual(try CLIParser.parse(arguments), .recoveryDisable(selector: "2", timeout: 5, journalPath: nil))
        XCTAssertEqual(try CLIParser.parse(["recovery", "disable", "--index", "2", "--consent-disable", "--timeout", "1m", "--journal", "/x"]),
                       .recoveryDisable(selector: "index:2", timeout: 60, journalPath: "/x"))
        let invalidArguments: [[String]] = [Array(arguments.dropLast(2)), Array(arguments.dropLast(3)),
                     ["recovery", "disable", "--timeout", "5", "--consent-disable"],
                     arguments + ["--display", "1"], arguments + ["--index", "2"], arguments + ["--all"],
                     arguments + ["--consent-disable"], arguments + ["--timeout", "2"],
                     arguments + ["--force"], arguments + ["--journal", ""],
                     ["recovery", "enable", "--display", "2"], ["recovery", "panic", "--global-reset"],
                     ["recovery", "status", "--consent-disable"]]
        for args in invalidArguments {
            XCTAssertThrowsError(try CLIParser.parse(args), args.joined(separator: " "))
        }
        for value in ["0", "0.5", "61", "nan", "inf", "-1"] {
            XCTAssertThrowsError(try CLIParser.parse(Array(arguments.dropLast()) + [value]))
        }
        let help = CLIHelp.text(for: "recovery")
        for text in ["--consent-disable", "1s...60s", "enable", "panic", "unqualified", "unverified", "no-write"] {
            XCTAssertTrue(help.contains(text), text)
        }
    }

    func testParsedDisableRoundTripAndJournalOnlyStatus() throws {
        let f = try Fixture(), store = RecoveryStore(url: directory.appendingPathComponent("current.json"))
        let journal = try execute(arguments, cli: cli(f), store: store)
        XCTAssertEqual(journal.state, .restored); XCTAssertEqual(journal.disabledByUsID, 2)
        XCTAssertEqual(f.writes, [false, true]); XCTAssertEqual(journal.reenableAttempted, true)
        var noInventory = cli(f)
        noInventory.records = { XCTFail("status enumerated"); return [] }
        noInventory.capture = { XCTFail("status captured"); return f.absent }
        XCTAssertEqual(try execute(["recovery", "status"], cli: noInventory, store: store).id, journal.id)
        XCTAssertEqual(try execute(["recovery", "enable"], cli: noInventory, store: store).state, .restored)
        XCTAssertEqual(f.writes, [false, true], "resolved intent must not replay")
    }

    func testParsedFailuresNeverBypassPreflightOrReportSuccess() throws {
        for fault in ["identity", "api", "helper", "lost-helper", "recovery", "disable-commit", "missing", "ambiguous", "physical"] {
            let f = try Fixture(); f.fault = fault
            let store = RecoveryStore(url: directory.appendingPathComponent("\(fault).json"))
            var runner = cli(f)
            if fault == "missing" { runner.records = { [] } }
            if fault == "ambiguous" { runner.records = { f.records + [f.records[1]] } }
            if fault == "physical" { f.environment.screens[1]?.kind = .headless }
            XCTAssertThrowsError(try execute(arguments, cli: runner, store: store), fault)
            if !["recovery", "disable-commit"].contains(fault) { XCTAssertEqual(f.begins, 0, fault) }
            if fault == "recovery" {
                XCTAssertEqual(try store.load().state, .needsAttention)
                XCTAssertEqual(try store.load().reenableAttempted, true)
                XCTAssertThrowsError(try execute(["recovery", "panic"], cli: runner, store: store))
                XCTAssertEqual(f.writes, [false, true], "failed enable must not replay")
            }
        }
    }

    private func stranded(_ f: Fixture, store: RecoveryStore) throws {
        try store.lock()
        var journal = RecoveryJournal(snapshot: f.baseline, disabledByUsID: 2, disableStaged: true, disableCommitStarted: true)
        journal.state = .disabled; journal.disableCompleted = true
        try store.create(journal); store.unlock()
        f.current = f.absent
    }

    func testOfflineEnablePanicAndStartupRecoverOnlyOwnedIntent() throws {
        for action in ["enable", "panic", "startup"] {
            let f = try Fixture(), store = RecoveryStore(url: directory.appendingPathComponent("\(action).json"))
            try stranded(f, store: store)
            var runner = cli(f)
            runner.records = { XCTFail("recovery must not select online targets"); return [] }
            if action == "startup" {
                XCTAssertThrowsError(try execute(arguments, cli: runner, store: store)) { error in
                    XCTAssertTrue(String(describing: error).contains("explicitly select again"))
                }
            } else { XCTAssertEqual(try execute(["recovery", action], cli: runner, store: store).state, .restored) }
            XCTAssertEqual(f.writes, [true]); XCTAssertEqual(try store.load().trigger, action == "startup" ? "startup" : "manual-\(action)")
        }
        let f = try Fixture(), store = RecoveryStore(url: directory.appendingPathComponent("public.json"))
        try store.lock(); try store.create(RecoveryJournal(snapshot: f.baseline)); store.unlock()
        for action in ["enable", "panic"] { XCTAssertThrowsError(try execute(["recovery", action], cli: cli(f), store: store)) }
        XCTAssertEqual(f.begins, 0)
    }

    func testExecutableExitCodesAndOfflineStatusWithoutHardwareCalls() throws {
        let executable = Bundle(for: Self.self).bundleURL.deletingLastPathComponent().appendingPathComponent("panelctl")
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw XCTSkip("build the panelctl product to test exit codes")
        }
        func run(_ args: [String]) throws -> (Int32, String) {
            let process = Process(), output = Pipe()
            process.executableURL = executable; process.arguments = args
            process.standardOutput = output; process.standardError = output
            try process.run(); try output.fileHandleForWriting.close()
            let text = String(decoding: try output.fileHandleForReading.readToEnd() ?? Data(), as: UTF8.self)
            process.waitUntilExit()
            return (process.terminationStatus, text)
        }
        XCTAssertEqual(try run(["recovery", "--help"]).0, 0)
        XCTAssertEqual(try run(["recovery", "disable"]).0, 2)
        XCTAssertEqual(try run(arguments + ["--force"]).0, 2)
        XCTAssertEqual(try run(["recovery", "enable", "--journal", directory.appendingPathComponent("missing.json").path]).0, 1)
        let f = try Fixture(), store = RecoveryStore(url: directory.appendingPathComponent("status.json"))
        try stranded(f, store: store)
        let result = try run(["recovery", "status", "--journal", store.url.path])
        XCTAssertEqual(result.0, 0)
        let journal = try JSONDecoder().decode(RecoveryJournal.self, from: Data(result.1.utf8))
        XCTAssertEqual(journal.disabledByUsID, 2); XCTAssertEqual(journal.snapshot.displays.count, 2)
        XCTAssertEqual(journal.state, .disabled)
    }

    func testJournalSelectionIsRecheckedUnderRecoveryLock() throws {
        let f = try Fixture(), store = RecoveryStore(url: directory.appendingPathComponent("replacement.json"))
        try stranded(f, store: store)
        let saved = try store.load()
        let engine = RecoveryEngine(capture: { XCTFail("replacement must refuse before capture"); return f.current },
                                    apply: { _ in XCTFail("replacement must never write") })
        XCTAssertThrowsError(try engine.recover(store: store, trigger: "manual-restore", expectedID: UUID()))
        XCTAssertEqual(try store.load().id, saved.id)
        XCTAssertEqual(try store.load().state, saved.state)
        XCTAssertNil(try store.load().reenableAttempted)
    }

    func testProductionProviderRefusesBeforeConstructingAnyWriter() throws {
        let f = try Fixture()
        let session = RecoveryPrivateSession(snapshot: f.baseline, transaction: {
            XCTFail("production provider constructed writer")
            throw RecoveryError.unsafe("must not run")
        }, initiallyAwake: true)
        XCTAssertThrowsError(try session.prepareDisable(targetID: 2)) { error in
            XCTAssertFalse(String(describing: error).isEmpty)
        }
    }

    func testUnqualifiedEnvironmentAndInitialLifecycleRefuseBeforeWriterConstruction() throws {
        let f = try Fixture()
        var constructions = 0
        let writer: () throws -> RecoveryEnableTransaction = {
            constructions += 1
            throw RecoveryError.unsafe("must not construct writer")
        }
        // Isolate each production default from the other refusal gates.
        let unknownEnvironment = RecoveryPrivateSession(snapshot: f.baseline,
            inventory: f.session.inventory, environment: {
                var value = f.environment; value.drivers = .unknown; return value
            }, transaction: writer, initiallyAwake: true)
        XCTAssertThrowsError(try unknownEnvironment.prepareDisable(targetID: 2)) { error in
            XCTAssertFalse(String(describing: error).isEmpty)
        }
        let unknownLifecycle = RecoveryPrivateSession(snapshot: f.baseline,
            inventory: f.session.inventory, environment: { f.environment }, transaction: writer,
            lifecycleObservation: { .init(awake: nil, lid: .unknown, diagnostic: "unknown") }, now: { f.clock })
        for event: RecoveryLifecycle.Event in [.resume(.system), .resume(.screens), .resume(.session)] {
            unknownLifecycle.receive(event)
        }
        f.clock += 2
        XCTAssertEqual(unknownLifecycle.gate, .needsAttention)
        XCTAssertThrowsError(try unknownLifecycle.prepareDisable(targetID: 2)) { error in
            XCTAssertTrue(String(describing: error).localizedCaseInsensitiveContains("observation"))
        }
        XCTAssertEqual(constructions, 0)
    }

    func testProductionProvenanceCannotUseSyntheticBindingEvenWithFreshTimestamp() throws {
        let f = try Fixture()
        var displays = f.baseline.displays
        for index in displays.indices {
            displays[index].identityEvidence = RecoveryIdentityEvidence(source: .cgAndCoreDisplay,
                capturedAt: Date(), transport: "DisplayPort", hpd: "High", framebufferLocation: "port-\(index + 1)")
        }
        let baseline = RecoverySnapshot(bootSession: f.baseline.bootSession, osBuild: f.baseline.osBuild,
            userID: f.baseline.userID, displays: displays)
        let session = RecoveryPrivateSession(snapshot: baseline, inventory: f.session.inventory,
            environment: { f.environment }, transaction: {
                XCTFail("cached production provenance constructed writer")
                throw RecoveryError.unsafe("must not run")
            }, initiallyAwake: true)
        XCTAssertThrowsError(try session.prepareDisable(targetID: 2)) { error in
            XCTAssertFalse(String(describing: error).isEmpty)
        }
    }

    func testRuntimeNotificationDeliverySleepAndSystemReenable() throws {
        let f = try Fixture()
        f.session.observeNotifications()
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.screensDidSleepNotification, object: nil)
        XCTAssertEqual(f.session.gate, .deferred)
        XCTAssertThrowsError(try f.session.prepareDisable(targetID: 2)); XCTAssertEqual(f.begins, 0)
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.screensDidWakeNotification, object: nil)
        f.clock += 1
        XCTAssertEqual(f.session.gate, .ready)
        f.session.didDisable(2); f.current = f.absent
        f.environment.screens[2] = nil
        XCTAssertEqual(try f.session.check(), .none)
        f.environment.screens[1]?.awake = false
        guard case .requestGuardedRecovery = try f.session.check() else { return XCTFail("no survivor recovery") }
        f.current = f.baseline
        f.environment.screens[1]?.awake = true
        f.environment.screens[2] = .init(kind: .physical, online: true, active: true, awake: true)
        XCTAssertEqual(try f.session.check(), .reconcileSystemReenable(2))
        XCTAssertThrowsError(try f.session.prepareDisable(targetID: 2), "system enable never permits automatic redisconnect")
    }

    func testRecoveryBoundaryRefreshRefusesLostSurvivorBeforeWriterConstruction() throws {
        let f = try Fixture(), store = RecoveryStore(url: directory.appendingPathComponent("boundary.json"))
        try stranded(f, store: store)
        var environment = f.environment
        var inventoryReads = 0, writerConstructions = 0, setterCalls = 0
        let session = RecoveryPrivateSession(snapshot: f.baseline, capture: { f.current }, inventory: {
            inventoryReads += 1
            if inventoryReads == 2 { environment.screens[1]?.awake = false }
            return try f.session.inventory()
        }, environment: {
            var observed = environment
            let online = Set(f.current.displays.map(\.id))
            observed.screens = observed.screens.filter { online.contains($0.key) }
            return observed
        }, transaction: {
            writerConstructions += 1
            return RecoveryEnableTransaction(begin: { CGDisplayConfigRef(bitPattern: 1)! },
                setEnabled: { _, _, _ in setterCalls += 1 }, commit: { _, _ in }, cancel: { _ in })
        }, initiallyAwake: true)
        XCTAssertThrowsError(try session.engine.recover(store: store, trigger: "boundary", ownedOnly: true))
        XCTAssertEqual(writerConstructions, 0)
        XCTAssertEqual(setterCalls, 0)
        XCTAssertNil(try store.load().reenableAttempted)
        XCTAssertEqual(try store.load().state, .needsAttention)
    }

    func testPublicRestoreRefreshesEnvironmentImmediatelyBeforeFakeWriter() throws {
        let f = try Fixture(), store = RecoveryStore(url: directory.appendingPathComponent("public-boundary.json"))
        var changed = f.baseline.displays
        changed[1].x += 10
        f.current = RecoverySnapshot(bootSession: f.baseline.bootSession, osBuild: f.baseline.osBuild,
            userID: f.baseline.userID, displays: changed, hostModel: f.baseline.hostModel)
        var environment = f.environment
        var publicWrites = 0
        let session = RecoveryPrivateSession(snapshot: f.baseline, capture: { f.current },
            inventory: f.session.inventory, environment: { environment },
            transaction: { XCTFail("private writer is not used"); throw RecoveryError.unsafe("unexpected") },
            apply: { _, validate in
                environment.drivers = .unknown
                try validate()
                publicWrites += 1
            }, initiallyAwake: true)
        try store.lock()
        var journal = RecoveryJournal(snapshot: f.baseline)
        try store.create(journal)
        XCTAssertThrowsError(try session.engine.finish(&journal, store: store, verifyOnly: false, trigger: "public-boundary"))
        XCTAssertEqual(publicWrites, 0)
        XCTAssertEqual(try store.load().state, .needsAttention)
    }

    func testPublicRecoveryBoundaryRefusesFreshAsleepScreenWithoutPrivateGates() throws {
        let f = try Fixture()
        var observed = f.environment
        var fakeWrites = 0
        let session = RecoveryPrivateSession(snapshot: f.baseline, capture: { f.current },
            inventory: f.session.inventory, environment: { observed },
            apply: { _, validate in
                observed.screens[1]?.awake = false
                try validate()
                fakeWrites += 1
            }, initiallyAwake: true)
        XCTAssertThrowsError(try session.makeEngine(requiresPrivateIdentity: false).apply(f.baseline))
        XCTAssertEqual(fakeWrites, 0)
    }

    func testSleepGateProtectsManualPrivateAndPublicRecoveryWrites() throws {
        let f = try Fixture(), store = RecoveryStore(url: directory.appendingPathComponent("sleep.json"))
        try stranded(f, store: store)
        f.session.receive(.suspend(.system))
        XCTAssertThrowsError(try execute(["recovery", "enable"], cli: cli(f), store: store))
        XCTAssertNil(try store.load().reenableAttempted); XCTAssertEqual(f.begins, 0)
        f.clock += 5
        XCTAssertEqual(f.session.gate, .needsAttention)
        XCTAssertThrowsError(try execute(["recovery", "panic"], cli: cli(f), store: store))
        XCTAssertEqual(f.begins, 0)
        // A now-online target must not bypass the gate via public layout repair.
        var displays = f.baseline.displays
        displays[1].x += 10
        f.current = RecoverySnapshot(bootSession: f.baseline.bootSession, osBuild: f.baseline.osBuild,
            userID: f.baseline.userID, displays: displays)
        XCTAssertThrowsError(try execute(["recovery", "enable"], cli: cli(f), store: store))
        XCTAssertEqual(try store.load().state, .needsAttention)
        XCTAssertNil(try store.load().reenableAttempted)
        XCTAssertEqual(f.begins, 0)
    }
}

