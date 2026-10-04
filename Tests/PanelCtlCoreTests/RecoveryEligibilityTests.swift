import XCTest
import AppKit
import CoreGraphics
@testable import PanelCtlCore

final class RecoveryEligibilityTests: XCTestCase {
    private func snapshot(ids: [Int] = [1, 2], builtin: Int? = nil, main: Int = 1,
                          mirrored: Bool = false, serialOffset: Int = 0) throws -> RecoverySnapshot {
        let value: [String: Any] = ["bootSession": "boot", "osBuild": "build", "userID": 501,
            "displays": ids.map { id -> [String: Any] in
                var display: [String: Any] = [
                    "uuid": "00000000-0000-0000-0000-00000000000\(id)", "id": id,
                    "vendor": 1, "model": 2, "serial": id + serialOffset, "builtin": id == builtin,
                    "main": id == main, "active": true, "x": (id - 1) * 1920, "y": 0, "rotation": 0,
                    "connector": "port-\(id)", "identityEvidence": ["source": "syntheticFixture", "capturedAt": 0],
                    "mode": ["id": 1, "width": 1920, "height": 1080, "pixelWidth": 1920,
                             "pixelHeight": 1080, "refreshRate": 60, "flags": 0]]
                if mirrored { display["mirrorUUID"] = "00000000-0000-0000-0000-000000000001" }
                return display
            }]
        return try JSONDecoder().decode(RecoverySnapshot.self, from: JSONSerialization.data(withJSONObject: value))
    }

    private func identity(_ snapshot: RecoverySnapshot, online: Set<UInt32> = [1, 2]) -> RecoveryEnableInventory {
        RecoveryEnableInventory(bootSession: snapshot.bootSession, osBuild: snapshot.osBuild,
            userID: snapshot.userID, identities: snapshot.displays.map(RecoveryEnableIdentity.init),
            onlineIDs: online, binding: .syntheticPhysicalFixture)
    }

    private func environment(ids: [UInt32] = [1, 2]) -> RecoveryEligibilityEnvironment {
        RecoveryEligibilityEnvironment(architecture: .appleSilicon, drivers: .nativeOnly,
            lid: .open, mirrored: false, screens: Dictionary(uniqueKeysWithValues: ids.map {
                ($0, .init(kind: .physical, online: true, active: true, awake: true))
            }))
    }

    func testEligibilityRequiresPositivePhysicalAndIdentityEvidence() throws {
        let baseline = try snapshot()
        func decision(_ env: RecoveryEligibilityEnvironment, _ evidence: RecoveryEnableInventory? = nil) -> RecoveryEligibilityDecision {
            RecoveryEligibilityPolicy.evaluate(snapshot: baseline, targetID: 2,
                identity: evidence ?? identity(baseline), environment: env)
        }
        XCTAssertTrue(decision(environment()).eligible)
        XCTAssertEqual(decision(environment()).usableSurvivors, [1])
        XCTAssertFalse(decision(RecoveryEligibilityEnvironment()).eligible)
        var evidence = identity(baseline); evidence.binding = .unqualified
        XCTAssertTrue(decision(environment(), evidence).refusals.joined().contains("unsupported"))
        evidence.binding = .stale
        XCTAssertFalse(decision(environment(), evidence).eligible)
        for kind: RecoveryEligibilityEnvironment.PhysicalKind in [.unknown, .virtual, .headless, .displayLink] {
            for id: UInt32 in [1, 2] {
                var env = environment(); env.screens[id]?.kind = kind
                let result = decision(env)
                XCTAssertFalse(result.eligible, "\(id) \(kind)")
                XCTAssertTrue(result.refusals.joined().contains(kind.rawValue))
            }
        }
        for drivers: RecoveryEligibilityEnvironment.Drivers in [.unknown, .displayLink, .virtual] {
            var env = environment(); env.drivers = drivers
            XCTAssertTrue(decision(env).refusals.joined().contains("driver"))
        }
        for arch: RecoveryEligibilityEnvironment.Architecture in [.intel, .unknown] {
            var env = environment(); env.architecture = arch
            XCTAssertTrue(decision(env).refusals.joined().contains("Apple Silicon"))
        }
        for mirror: Bool? in [true, nil] {
            var env = environment(); env.mirrored = mirror
            XCTAssertFalse(decision(env).eligible)
        }
        for keyPath in [\RecoveryEligibilityEnvironment.Screen.online, \.active, \.awake] {
            var env = environment(); env.screens[1]?[keyPath: keyPath] = false
            XCTAssertFalse(decision(env).eligible)
        }
        var env = environment(); env.screens[1] = nil
        XCTAssertFalse(decision(env).eligible)
        env = environment(ids: [1, 2, 3])
        XCTAssertFalse(decision(env).eligible)
        // Even with two known survivors, unknown physical state is not benign.
        let three = try snapshot(ids: [1, 2, 3]); env.screens[3]?.kind = .unknown
        XCTAssertFalse(RecoveryEligibilityPolicy.evaluate(snapshot: three, targetID: 2,
            identity: identity(three, online: [1, 2, 3]), environment: env).eligible)
    }

    func testLastMainBuiltinMirrorsAndClosedLidRefuse() throws {
        for baseline in [try snapshot(ids: [2]), try snapshot(main: 2),
                         try snapshot(builtin: 2), try snapshot(mirrored: true)] {
            let ids = baseline.displays.map(\.id)
            let decision = RecoveryEligibilityPolicy.evaluate(snapshot: baseline, targetID: 2,
                identity: identity(baseline, online: Set(ids)), environment: environment(ids: ids))
            XCTAssertFalse(decision.eligible)
            XCTAssertFalse(decision.refusals.isEmpty)
            XCTAssertThrowsError(try decision.requireEligible())
        }
        let baseline = try snapshot(builtin: 1)
        for lid: RecoveryEligibilityEnvironment.Lid in [.closed, .unknown] {
            var env = environment(); env.lid = lid
            let decision = RecoveryEligibilityPolicy.evaluate(snapshot: baseline, targetID: 2,
                identity: identity(baseline), environment: env)
            XCTAssertTrue(decision.refusals.joined().contains("lid"))
        }
        XCTAssertFalse(RecoveryEligibilityPolicy.evaluate(snapshot: baseline, targetID: 99,
            identity: identity(baseline), environment: environment()).eligible)
    }

    func testSelectionInvalidationAtRealDisableTransactionBoundaries() throws {
        let baseline = try snapshot()
        // A topology ABA, changed lid, sleep, or lost physical classification
        // after begin or staging must cancel; no commit can occur.
        for boundary in ["begin", "stage"] {
            for race in ["topology", "lid", "sleep", "physical"] {
                let directory = FileManager.default.temporaryDirectory.appendingPathComponent("panelctl-eligibility-tests-\(UUID())")
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                       attributes: [.posixPermissions: 0o700])
                defer { try? FileManager.default.removeItem(at: directory) }
                let store = RecoveryStore(url: directory.appendingPathComponent("journal.json"))
                try store.lock()
                defer { store.unlock() }
                var journal = RecoveryJournal(snapshot: baseline, timeout: 30); journal.state = .armed
                try store.create(journal)
                var lifecycle = RecoveryLifecycle(now: 0, initiallyAwake: true)
                var env = environment()
                let selection = try RecoveryEligibilitySelection(snapshot: baseline, targetID: 2,
                    identity: identity(baseline), environment: env, lifecycle: lifecycle, now: 0)
                func change() {
                    switch race {
                    case "topology": lifecycle.receive(.topologyChanged, now: 0)
                    case "lid": env.lid = .closed
                    case "sleep": lifecycle.receive(.suspend(.system), now: 0)
                    default: env.screens[1]?.kind = .unknown
                    }
                }
                var stages = 0, cancels = 0, commits = 0
                let transaction = RecoveryEnableTransaction(begin: {
                    if boundary == "begin" { change() }
                    return OpaquePointer(bitPattern: 1)!
                }, setEnabled: { _, id, enabled in
                    XCTAssertEqual(id, 2); XCTAssertFalse(enabled); stages += 1
                    if boundary == "stage" { change() }
                }, commit: { _, _ in commits += 1 }, cancel: { _ in cancels += 1 })
                let disable = RecoveryDisable(transaction: transaction, inventory: { self.identity(baseline) },
                    preflight: { current, target in
                        try selection.validate(current: current, targetID: target, identity: self.identity(baseline),
                            environment: env, lifecycle: lifecycle, now: 0)
                    })
                XCTAssertThrowsError(try disable.perform(&journal, store: store, targetID: 2,
                    capture: { baseline }, lease: {}), "\(boundary) \(race)")
                XCTAssertEqual(stages, boundary == "begin" ? 0 : 1)
                XCTAssertEqual(cancels, 1); XCTAssertEqual(commits, 0)
            }
        }
    }

    func testSleepNotificationsHaveMatchingResumesAndFixedBudget() throws {
        var lifecycle = RecoveryLifecycle(now: 0, initiallyAwake: true)
        func notify(_ name: Notification.Name, _ now: TimeInterval) {
            lifecycle.receive(RecoveryLifecycle.event(for: name)!, now: now)
        }
        notify(NSWorkspace.willSleepNotification, 0)
        notify(NSWorkspace.screensDidSleepNotification, 0.1)
        notify(NSWorkspace.didWakeNotification, 0.2)
        XCTAssertEqual(lifecycle.writeGate(now: 2), .deferred)
        notify(NSWorkspace.screensDidWakeNotification, 2)
        XCTAssertEqual(lifecycle.writeGate(now: 2.9), .deferred)
        XCTAssertEqual(lifecycle.writeGate(now: 3), .ready)
        notify(NSWorkspace.sessionDidResignActiveNotification, 4)
        notify(NSWorkspace.didWakeNotification, 4.1)
        XCTAssertEqual(lifecycle.writeGate(now: 6), .deferred)
        notify(NSWorkspace.sessionDidBecomeActiveNotification, 6)
        XCTAssertEqual(lifecycle.writeGate(now: 7), .ready)
        // Repeated notifications cannot extend a stuck transition forever.
        notify(NSWorkspace.willSleepNotification, 8)
        notify(NSWorkspace.willSleepNotification, 12)
        XCTAssertEqual(lifecycle.writeGate(now: 13), .needsAttention)
        notify(NSWorkspace.didWakeNotification, 14)
        XCTAssertEqual(lifecycle.writeGate(now: 15), .needsAttention)
        XCTAssertThrowsError(try lifecycle.writeGate(now: 15).requireReady())
        XCTAssertEqual(RecoveryLifecycle(now: 0).writeGate(now: 0), .needsAttention)
        XCTAssertEqual(lifecycle.writeGate(now: .nan), .needsAttention)
        XCTAssertEqual(lifecycle.writeGate(now: 0), .needsAttention)
        XCTAssertNil(RecoveryLifecycle.event(for: Notification.Name("unrelated")))
    }

    func testSurvivorLossRequestsRecoveryAndSystemReenableNeverRedisables() throws {
        let baseline = try snapshot(builtin: 1), absent = try snapshot(ids: [1], builtin: 1)
        var lifecycle = RecoveryLifecycle(now: 0, initiallyAwake: true)
        lifecycle.didDisable(2)
        func observe(_ current: RecoverySnapshot, _ env: RecoveryEligibilityEnvironment, now: TimeInterval = 0) -> RecoveryLifecycle.Action {
            lifecycle.observe(baseline: baseline, current: current,
                identity: identity(baseline, online: Set(current.displays.map(\.id))), environment: env, now: now)
        }
        XCTAssertEqual(observe(absent, environment(ids: [1])), .none)
        for kind: RecoveryEligibilityEnvironment.PhysicalKind in [.unknown, .virtual, .headless, .displayLink] {
            var env = environment(ids: [1]); env.screens[1]?.kind = kind
            guard case .requestGuardedRecovery = observe(absent, env) else { return XCTFail("\(kind)") }
        }
        var env = environment(ids: [1]); env.lid = .closed
        guard case .requestGuardedRecovery = observe(absent, env) else { return XCTFail("closed lid") }
        let noScreens = try snapshot(ids: [])
        guard case .requestGuardedRecovery = observe(noScreens, environment(ids: [])) else { return XCTFail("no screens") }
        lifecycle.receive(.suspend(.system), now: 0)
        XCTAssertEqual(observe(baseline, environment()), .deferWrites)
        lifecycle.receive(.resume(.system), now: 1)
        XCTAssertEqual(observe(baseline, environment(), now: 2), .reconcileSystemReenable(2))
        XCTAssertNil(lifecycle.disabledTargetID)
        XCTAssertThrowsError(try lifecycle.requireDisableReady(now: 2))
        XCTAssertEqual(observe(absent, environment(ids: [1]), now: 2), .none)
        // There is deliberately no lifecycle action that can request disable.
    }

    func testUnqualifiedOrAmbiguousReappearancePreservesIntentAndRequestsRecovery() throws {
        let baseline = try snapshot()
        let changes: [(inout RecoveryEligibilityEnvironment) -> Void] = [
            { $0.drivers = .unknown }, { $0.drivers = .displayLink }, { $0.drivers = .virtual },
            { $0.architecture = .intel }, { $0.architecture = .unknown },
            { $0.mirrored = true }, { $0.mirrored = nil },
            { $0.screens[1]?.kind = .unknown }, { $0.screens[2]?.kind = .unknown },
            { $0.screens[2]?.kind = .virtual }, { $0.screens[2]?.awake = false },
            { $0.screens[2]?.active = false }, { $0.screens[2]?.online = false }
        ]
        for change in changes {
            var lifecycle = RecoveryLifecycle(now: 0, initiallyAwake: true)
            lifecycle.didDisable(2)
            var env = environment(); change(&env)
            guard case .requestGuardedRecovery = lifecycle.observe(baseline: baseline, current: baseline,
                identity: identity(baseline), environment: env, now: 0) else { return XCTFail("unsafe reappearance ignored") }
            XCTAssertEqual(lifecycle.disabledTargetID, 2)
            XCTAssertThrowsError(try lifecycle.requireDisableReady(now: 0))
        }
        let wrongBoot = RecoverySnapshot(bootSession: "new boot", osBuild: baseline.osBuild,
            userID: baseline.userID, displays: baseline.displays)
        for current in [try snapshot(serialOffset: 10), wrongBoot, try snapshot(mirrored: true)] {
            var lifecycle = RecoveryLifecycle(now: 0, initiallyAwake: true)
            lifecycle.didDisable(2)
            guard case .requestGuardedRecovery = lifecycle.observe(baseline: baseline, current: current,
                identity: identity(baseline), environment: environment(), now: 0) else { return XCTFail("ambiguous reappearance ignored") }
            XCTAssertEqual(lifecycle.disabledTargetID, 2)
        }
    }

    func testFreshSelectionRejectsChangedSnapshotIdentityAndTarget() throws {
        let baseline = try snapshot(), env = environment()
        let lifecycle = RecoveryLifecycle(now: 0, initiallyAwake: true)
        let selection = try RecoveryEligibilitySelection(snapshot: baseline, targetID: 2,
            identity: identity(baseline), environment: env, lifecycle: lifecycle, now: 0)
        try selection.validate(current: baseline, targetID: 2, identity: identity(baseline),
            environment: env, lifecycle: lifecycle, now: 0)
        XCTAssertThrowsError(try selection.validate(current: snapshot(main: 2), targetID: 2,
            identity: identity(baseline), environment: env, lifecycle: lifecycle, now: 0))
        XCTAssertThrowsError(try selection.validate(current: baseline, targetID: 1,
            identity: identity(baseline), environment: env, lifecycle: lifecycle, now: 0))
        var evidence = identity(baseline); evidence.binding = .stale
        XCTAssertThrowsError(try selection.validate(current: baseline, targetID: 2,
            identity: evidence, environment: env, lifecycle: lifecycle, now: 0))
        var changed = lifecycle
        changed.receive(RecoveryLifecycle.event(for: NSApplication.didChangeScreenParametersNotification)!, now: 0)
        XCTAssertThrowsError(try selection.validate(current: baseline, targetID: 2,
            identity: identity(baseline), environment: env, lifecycle: changed, now: 0))
    }
}
