import XCTest
import CoreGraphics
import Darwin
@testable import PanelCtlCore

final class DisplayHideTests: XCTestCase {
    private var directory: URL!
    private var store: RecoveryStore!
    private var operationStore: RecoveryStore!
    private var topology: FakeTopology!
    private var writerCount = 0

    private let sourceUUID = "00000000-0000-0000-0000-000000000001"
    private let targetUUID = "00000000-0000-0000-0000-000000000002"
    private let otherUUID = "00000000-0000-0000-0000-000000000003"
    private let sourceID: UInt32 = 7
    private let targetID: UInt32 = 8

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("panelctl-display-hide-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        store = RecoveryStore(url: directory.appendingPathComponent("current.json"))
        operationStore = RecoveryStore(url: directory.appendingPathComponent("operation"))
        topology = FakeTopology(snapshot: try snapshot())
        writerCount = 0
    }

    override func tearDownWithError() throws {
        store.unlock()
        operationStore.unlock()
        try FileManager.default.removeItem(at: directory)
    }

    func testStatusReportsEveryRemovalAndAvoidsGuessingForSessionRecovery() throws {
        let baseline = topology.snapshot
        let firstHidden = try snapshot { displays in
            displays[1]["mirrorUUID"] = self.sourceUUID
            displays[1]["active"] = false
        }
        let bothHidden = try snapshot { displays in
            displays[1]["mirrorUUID"] = self.sourceUUID
            displays[1]["active"] = false
            displays[2]["mirrorUUID"] = self.sourceUUID
            displays[2]["active"] = false
        }
        let removals = [
            PublicMirrorRemoval(target: baseline.displays[1], source: baseline.displays[0],
                                beforeOperation: baseline, state: .mirrored),
            PublicMirrorRemoval(target: baseline.displays[2], source: baseline.displays[0],
                                beforeOperation: firstHidden, state: .mirrored)
        ]
        var journal = RecoveryJournal(snapshot: baseline,
                                      publicMirrorSession: PublicMirrorSession(baseline: baseline, removals: removals))
        journal.state = .mirrored
        try save(journal)
        topology.snapshot = bothHidden

        let inspected = try controller().inspect()
        XCTAssertEqual(inspected.removals.count, 2)
        XCTAssertEqual(Set(inspected.removals.map(\.target.uuid)), Set([targetUUID, otherUUID]))
        XCTAssertTrue(inspected.removals.allSatisfy { $0.isUnresolved && $0.canShow && $0.topologyVerified })
        XCTAssertEqual(inspected.observations.filter(\.isJournalTarget).count, 2)
        let status = DisplayHandoff.handoffStatus(from: inspected)
        XCTAssertEqual(status.removals.count, 2)
        XCTAssertEqual(Set(status.removals.map { $0.target.uuid }), Set([targetUUID, otherUUID]))
        XCTAssertTrue(status.removals.allSatisfy(\.canShow))
        XCTAssertNotNil(status.baselineIdentity, "sleep recovery can compare the exact retained session baseline")
        XCTAssertTrue(status.recoveryCommand?.contains("recovery status") == true,
                      "session-level guidance inspects the journal instead of guessing a target")
    }

    func testStableTopologyIdentityIgnoresFreshCaptureAndDiagnosticFields() throws {
        let saved = try timestampedSnapshot(Date(timeIntervalSince1970: 1_700_000_000))
        let rawObserved = try timestampedSnapshot(Date(timeIntervalSince1970: 1_800_000_000))
        let observedDisplays = rawObserved.displays.map { display in
            var evidence = display.identityEvidence!
            evidence.transport = "changed diagnostic transport"
            evidence.transportLocation = "changed diagnostic port"
            evidence.framebufferLocation = "changed diagnostic framebuffer"
            evidence.hpd = "changed diagnostic HPD"
            return RecoveryDisplay(
                uuid: display.uuid, id: display.id, name: "Localized name changed",
                vendor: display.vendor, model: display.model, serial: display.serial,
                builtin: display.builtin, main: display.main, active: display.active,
                x: display.x, y: display.y, rotation: display.rotation, mirrorUUID: display.mirrorUUID,
                mode: display.mode, colorSpace: display.colorSpace,
                colorProfileDigest: display.colorProfileDigest,
                colorProfileDateIndependentDigest: display.colorProfileDateIndependentDigest,
                connector: display.connector, identityEvidence: evidence
            )
        }
        let observed = RecoverySnapshot(bootSession: rawObserved.bootSession, osBuild: rawObserved.osBuild,
                                        userID: rawObserved.userID, displays: observedDisplays,
                                        hostModel: "changed diagnostic host label")

        XCTAssertNoThrow(try saved.verify(observed))
        XCTAssertEqual(saved.stableTopologyIdentity(), observed.stableTopologyIdentity())

        let changedLayout = try timestampedSnapshot(Date(timeIntervalSince1970: 1_800_000_000)) { displays in
            displays[1]["x"] = 1930
        }
        XCTAssertNotEqual(saved.stableTopologyIdentity(), changedLayout.stableTopologyIdentity())
        XCTAssertThrowsError(try saved.verify(changedLayout), "the stable token keeps exact layout checks")
        let changedMode = try timestampedSnapshot(Date(timeIntervalSince1970: 1_800_000_000)) { displays in
            var mode = displays[1]["mode"] as! [String: Any]
            mode["width"] = 1920
            displays[1]["mode"] = mode
        }
        XCTAssertNotEqual(saved.stableTopologyIdentity(), changedMode.stableTopologyIdentity())
        XCTAssertThrowsError(try saved.verify(changedMode), "the stable token keeps exact mode checks")
    }

    func testTwoDisplayWakeResetOffersGuardedRestoreOfTheCapturedBaseline() throws {
        let baseline = topology.snapshot
        let firstHidden = try snapshot { displays in
            displays[1]["mirrorUUID"] = self.sourceUUID
            displays[1]["active"] = false
        }
        let bothHidden = try snapshot { displays in
            displays[1]["mirrorUUID"] = self.sourceUUID
            displays[1]["active"] = false
            displays[2]["mirrorUUID"] = self.sourceUUID
            displays[2]["active"] = false
        }
        let removals = [
            PublicMirrorRemoval(target: baseline.displays[1], source: baseline.displays[0],
                                beforeOperation: baseline, state: .mirrored),
            PublicMirrorRemoval(target: baseline.displays[2], source: baseline.displays[0],
                                beforeOperation: firstHidden, state: .mirrored)
        ]
        var journal = RecoveryJournal(snapshot: baseline,
                                      publicMirrorSession: PublicMirrorSession(baseline: baseline, removals: removals))
        journal.state = .mirrored
        try save(journal)
        topology.snapshot = bothHidden
        XCTAssertEqual(try controller().inspect().removals.filter(\.isUnresolved).count, 2)

        // Simulate macOS clearing both mirrors but leaving the layout shifted.
        topology.snapshot = try snapshot { displays in
            displays[1]["x"] = 120
            displays[2]["x"] = 2040
        }
        let recovery = try controller().inspect()
        XCTAssertEqual(recovery.removals.filter(\.isUnresolved).count, 2)
        XCTAssertTrue(recovery.removals.allSatisfy { $0.state == PublicMirrorRemovalState.needsAttention.rawValue })
        XCTAssertEqual(DisplayHandoff.handoffStatus(from: recovery).state, .recovery)
        XCTAssertEqual(writerCount, 0, "inspection leaves the shifted wake layout untouched")

        XCTAssertNoThrow(try controller().show(expectedJournalID: journal.id.uuidString, targetUUID: targetUUID))
        XCTAssertEqual(writerCount, 1, "the explicit guarded Restore uses one public configuration transaction")
        XCTAssertEqual(try store.load().publicMirrorSession?.removals.filter { !$0.state.resolved }.count, 0)
        XCTAssertNoThrow(try baseline.verify(topology.snapshot))
    }

    func testWakeLayoutRepairRetainsBaselineAndRefusesChangedWriterEvidence() throws {
        // A new automatic write path must not act on a changed identity, an
        // unrelated mirror/mode, or a journal/topology changed after inspection.
        for scenario in ["success", "identity", "external-mirror", "visible-mode", "journal-before",
                         "journal-after-begin", "topology-after-stage", "commit-failure", "wrong-visible-mode",
                         "wrong-visible-origin"] {
            store = RecoveryStore(url: directory.appendingPathComponent("wake-\(scenario).json"))
            let status = try prepareWakeResetStatus(layoutDrift: true)
            let original = try store.load()
            var expectation = try wakeExpectation(status, targetUUID: targetUUID, resumeSession: true)
            if ["identity", "external-mirror", "visible-mode"].contains(scenario) {
                let raw = try JSONEncoder().encode(topology.snapshot)
                var payload = try JSONSerialization.jsonObject(with: raw) as! [String: Any]
                var displays = payload["displays"] as! [[String: Any]]
                if scenario == "identity" { displays[1]["serial"] = 999 }
                if scenario == "external-mirror" { displays[1]["mirrorUUID"] = otherUUID }
                if scenario == "visible-mode" {
                    var mode = displays[0]["mode"] as! [String: Any]
                    mode["refreshRate"] = 30
                    displays[0]["mode"] = mode
                }
                payload["displays"] = displays
                topology.snapshot = try JSONDecoder().decode(RecoverySnapshot.self,
                    from: JSONSerialization.data(withJSONObject: payload))
                // Even a fresh inspection token cannot authorize those changes.
                expectation = DisplayHideWakeExpectation(
                    journalID: expectation.journalID, journalIdentity: expectation.journalIdentity,
                    baselineIdentity: expectation.baselineIdentity,
                    observedTopologyIdentity: try XCTUnwrap(topology.snapshot.stableTopologyIdentity()),
                    target: expectation.target, source: expectation.source, resumeRemovalIDs: expectation.resumeRemovalIDs
                )
            }
            func changeJournal() throws {
                var changed = try store.load()
                changed.failure = "another operation changed the journal"
                try store.save(changed)
            }
            if scenario == "journal-before" {
                try store.lock()
                try changeJournal()
                store.unlock()
            }
            var staged: [UInt32] = []
            var origins: [UInt32: [Int32]] = [:]
            var commits = 0
            var cancels = 0
            let transaction = MirrorTransaction(
                begin: {
                    if scenario == "journal-after-begin" { try changeJournal() }
                    return OpaquePointer(bitPattern: 1)!
                },
                stage: { _, target, source in
                    XCTAssertEqual(source, self.sourceID)
                    staged.append(target)
                    if scenario == "topology-after-stage" {
                        self.topology.snapshot = try self.snapshot { $0[0]["x"] = 999 }
                    }
                },
                complete: { _, scope in
                    commits += 1
                    XCTAssertEqual(scope, .forSession)
                    if scenario == "commit-failure" { throw RecoveryError.unsafe("commit failed") }
                    self.topology.snapshot = try self.snapshot { displays in
                        for index in displays.indices {
                            let id = (displays[index]["id"] as! NSNumber).uint32Value
                            if staged.contains(id) {
                                displays[index]["mirrorUUID"] = self.sourceUUID
                                displays[index]["active"] = false
                            }
                            if let origin = origins[id] {
                                displays[index]["x"] = origin[0]
                                displays[index]["y"] = origin[1]
                            }
                        }
                        if scenario == "wrong-visible-mode" {
                            var mode = displays[0]["mode"] as! [String: Any]
                            mode["refreshRate"] = 30
                            displays[0]["mode"] = mode
                        }
                        if scenario == "wrong-visible-origin" { displays[0]["x"] = 10 }
                    }
                },
                cancel: { _ in cancels += 1 },
                stageOrigin: { _, id, x, y in origins[id] = [x, y] }
            )
            let core = controller(transaction: transaction)
            if scenario == "success" {
                XCTAssertNoThrow(try core.hide(target: expectation.target, source: expectation.source,
                                               awayInput: nil, wakeExpectation: expectation))
                XCTAssertEqual(Set(staged), Set([targetID, 9]))
                XCTAssertEqual(origins, [sourceID: [0, 0]])
                XCTAssertEqual(commits, 1)
                XCTAssertTrue(try core.inspect().removals.allSatisfy { $0.topologyVerified && $0.state == "mirrored" })
            } else {
                XCTAssertThrowsError(try core.hide(target: expectation.target, source: expectation.source,
                                                   awayInput: nil, wakeExpectation: expectation), scenario)
                let committed = scenario == "commit-failure" || scenario.hasPrefix("wrong-visible-")
                XCTAssertEqual(commits, committed ? 1 : 0, scenario)
                if scenario != "topology-after-stage" && !committed {
                    XCTAssertTrue(staged.isEmpty, scenario)
                }
                XCTAssertEqual(cancels, ["journal-after-begin", "topology-after-stage"].contains(scenario) ? 1 : 0)
            }
            let retained = try store.load()
            XCTAssertEqual(retained.id, original.id)
            XCTAssertEqual(retained.publicMirrorSession?.baseline, original.publicMirrorSession?.baseline)
            XCTAssertEqual(retained.publicMirrorSession?.removals.map(\.id), original.publicMirrorSession?.removals.map(\.id))
            if scenario.hasPrefix("journal-") {
                XCTAssertEqual(retained.failure, "another operation changed the journal")
            }
            if scenario == "commit-failure" || scenario == "topology-after-stage" || scenario.hasPrefix("wrong-visible-") {
                XCTAssertEqual(retained.state, .needsAttention)
                XCTAssertEqual(try core.inspect().journal?.state, "needsAttention",
                               "inspection cannot replace the stronger wake postcondition with mirror-only verification")
                if scenario.hasPrefix("wrong-visible-") {
                    var interrupted = retained
                    interrupted.state = .captured
                    try store.lock()
                    try store.save(interrupted)
                    store.unlock()
                    XCTAssertEqual(try core.inspect().journal?.state, "captured", "an interrupted commit also retains recovery")
                }
            }
        }
    }

    func testExplicitShowRecoversMissingModeAfterInputReturnWithoutTreatingOnlineAsIntent() throws {
        for scenario in ["mirrors-return", "separate", "unverified", "late-mode", "failed", "no-ddc", "no-input",
                         "timeout", "unstable", "identity-before", "identity-after", "journal-after", "other-mode"] {
            store = RecoveryStore(url: directory.appendingPathComponent("\(scenario).json"))
            let baseline = try snapshot { displays in
                var mode = displays[1]["mode"] as! [String: Any]
                mode["refreshRate"] = 240
                displays[1]["mode"] = mode
                displays[1]["x"] = 0
                displays[1]["y"] = 1080
            }
            let bothHidden = RecoverySnapshot(bootSession: baseline.bootSession, osBuild: baseline.osBuild,
                userID: baseline.userID, displays: try snapshot { displays in
                    for index in [1, 2] {
                        displays[index]["mirrorUUID"] = self.sourceUUID
                        displays[index]["active"] = false
                    }
                }.displays)
            let firstHidden = RecoverySnapshot(bootSession: baseline.bootSession, osBuild: baseline.osBuild,
                userID: baseline.userID, displays: bothHidden.displays.map {
                    $0.uuid == self.otherUUID ? baseline.displays[2] : $0
                })
            var journal = RecoveryJournal(snapshot: baseline, publicMirrorSession: PublicMirrorSession(
                baseline: baseline, removals: [
                    PublicMirrorRemoval(target: baseline.displays[1], source: baseline.displays[0],
                                        beforeOperation: baseline, state: .mirrored),
                    PublicMirrorRemoval(target: baseline.displays[2], source: baseline.displays[0],
                                        beforeOperation: firstHidden, state: .mirrored)
                ]))
            journal.state = .mirrored
            try save(journal)
            topology.snapshot = try snapshot { displays in
                displays[1]["main"] = true
                displays[0]["main"] = false
                if scenario == "identity-before" { displays[0]["serial"] = 999 }
            }
            var modeAvailable = false
            var pauses = 0
            var inputs = 0
            var restores = 0
            var mirror = MirrorController(
                records: { self.topology.records }, operationLock: { self.operationStore },
                engine: RecoveryEngine(capture: { self.topology.snapshot }, apply: { saved in
                    XCTAssertTrue(modeAvailable)
                    restores += 1
                    self.topology.snapshot = saved
                }, convergencePause: {
                    pauses += 1
                    if scenario == "unstable", inputs > 0 {
                        modeAvailable = true
                        self.topology.snapshot = try! self.snapshot { $0[1]["x"] = pauses % 2 }
                    }
                    if inputs > 0, pauses == (scenario == "late-mode" ? 12 : 2),
                       !["timeout", "failed", "unstable"].contains(scenario) {
                        modeAvailable = true
                        self.topology.snapshot = scenario == "separate" ? baseline : bothHidden
                        if scenario == "identity-after" {
                            self.topology.snapshot = try! self.snapshot { $0[1]["id"] = 88 }
                        }
                    }
                }), preflightModes: { _ in
                    if !modeAvailable {
                        let missing = baseline.displays[scenario == "other-mode" ? 2 : 1]
                        throw RecoveryError.modeUnavailable(displayUUID: missing.uuid, mode: missing.mode.description)
                    }
                })
            mirror.restoreTarget = { saved, uuid, revalidate, _ in
                XCTAssertEqual(uuid, self.targetUUID)
                XCTAssertTrue(modeAvailable)
                try revalidate()
                restores += 1
                self.topology.snapshot = RecoverySnapshot(bootSession: saved.bootSession, osBuild: saved.osBuild,
                    userID: saved.userID, displays: bothHidden.displays.map {
                        $0.uuid == uuid ? saved.displays[1] : $0
                    })
            }
            var handoff = HandoffController(mirror: mirror, report: { _ in })
            handoff.open = { uuid, _ in
                if scenario == "no-ddc" { throw RecoveryError.unsafe("fake DDC unavailable") }
                return (DDC.DisplayTarget(id: self.targetID, uuid: uuid), DDCChannel(
                    getVCP: { _ in (17, 0) }, setVCP: { _, _ in XCTFail("fake selector only") }))
            }
            handoff.select = { requested, _, id, uuid, original in
                XCTAssertEqual(restores, 0, "input must precede restoration of the unavailable mode")
                inputs += 1
                if scenario == "failed" { throw RecoveryError.unsafe("fake input failure") }
                if scenario == "journal-after" {
                    var changed = try self.store.load()
                    changed.trigger = "external-change"
                    try self.store.save(changed)
                }
                return DDCInputSelection(displayID: id, uuid: uuid, original: original, requested: requested,
                    observed: scenario == "unverified" ? nil : requested,
                    outcome: scenario == "unverified" ? .unverified : .verified, detail: nil)
            }
            let backend = DisplayHideController(store: store, mirror: mirror,
                operationLock: { self.operationStore }, handoff: handoff)
            let status = try backend.inspect()
            XCTAssertEqual(restores, 0, "online inspection cannot unmirror, even with an unresolved journal")
            XCTAssertEqual(inputs, 0, "inspection cannot switch away from another computer")
            let reason = try XCTUnwrap(status.journal?.showRefusal)
            XCTAssertTrue(reason.contains(scenario == "identity-before" ? "identity" : "original mode unavailable"), reason)
            if scenario != "identity-before" && scenario != "other-mode" {
                XCTAssertTrue(reason.contains("240.0 Hz"), reason)
                XCTAssertTrue(status.observations.first { $0.identity.uuid == self.targetUUID }?.detail?.contains("240.0 Hz") == true)
            }
            let success = ["mirrors-return", "separate", "unverified", "late-mode"].contains(scenario)
            do {
                let result = try backend.show(expectedJournalID: journal.id.uuidString, targetUUID: targetUUID,
                                              returnInput: scenario == "no-input" ? nil : 15)
                XCTAssertTrue(success, scenario)
                XCTAssertEqual(inputs, 1, "input return is never retried or replayed after Show")
                XCTAssertEqual(result.state, scenario == "unverified" ? .unverified : .verified)
                if scenario == "separate" {
                    XCTAssertEqual(restores, 0, "input return itself restored the exact baseline")
                    XCTAssertFalse(try backend.inspect().hasUnresolvedRecovery)
                } else {
                    XCTAssertEqual(restores, 1, "mirror reappearance is not successful Show: explicitly unmirror the target")
                    let shown = try XCTUnwrap(self.topology.snapshot.displays.first { $0.uuid == self.targetUUID })
                    XCTAssertNil(shown.mirrorUUID)
                    XCTAssertEqual(shown.mode, baseline.displays[1].mode)
                    XCTAssertEqual(try backend.inspect().removals.filter(\.isUnresolved).map(\.target.uuid), [otherUUID])
                    _ = try backend.show(expectedJournalID: journal.id.uuidString, targetUUID: otherUUID)
                    XCTAssertNoThrow(try baseline.verify(self.topology.snapshot), "last Show restores the exact stacked layout")
                    XCTAssertFalse(try backend.inspect().hasUnresolvedRecovery)
                    XCTAssertEqual(inputs, 1)
                }
            } catch {
                XCTAssertFalse(success, "\(scenario): \(error)")
                XCTAssertEqual(restores, 0, scenario)
                XCTAssertFalse(try store.load().state.resolved, scenario)
                XCTAssertEqual(try store.load().id, journal.id)
                if scenario == "journal-after" {
                    XCTAssertEqual(try store.load().trigger, "external-change", "never overwrite a changed journal")
                }
                let expected: String = switch scenario {
                case "failed": "fake input failure"
                case "no-ddc": "input button"
                case "identity-before", "identity-after": "identity"
                case "journal-after": "journal changed"
                case "unstable": "did not settle"
                default: "original mode unavailable"
                }
                XCTAssertTrue(error.localizedDescription.contains(expected), "\(scenario): \(error)")
                if ["identity-before", "no-input", "other-mode", "no-ddc"].contains(scenario) {
                    XCTAssertEqual(inputs, 0, "do not switch an unrelated or unverified monitor")
                } else { XCTAssertEqual(inputs, 1) }
            }
            XCTAssertLessThanOrEqual(pauses, 25, "mode/identity settlement is bounded; writers are not retried")
        }
    }

    func testWakeResumeRejectsJournalMutationBeforeAnyMirrorStage() throws {
        let status = try prepareWakeResetStatus()
        let expected = try wakeExpectation(status, targetUUID: targetUUID)
        try store.lock()
        var altered = try store.load()
        altered.trigger = "unexpected-external-change"
        try store.save(altered)
        store.unlock()

        var stages = 0
        var commits = 0
        let sut = controller(transaction: MirrorTransaction(
            begin: { OpaquePointer(bitPattern: 1)! },
            stage: { _, _, _ in stages += 1 },
            complete: { _, _ in commits += 1 },
            cancel: { _ in }
        ))
        XCTAssertThrowsError(try sut.hide(target: expected.target, source: expected.source, wakeExpectation: expected))
        XCTAssertEqual(stages, 0)
        XCTAssertEqual(commits, 0)
    }

    func testWakeResumeRejectsTopologyMutationAfterInspectionBeforeWriter() throws {
        let status = try prepareWakeResetStatus()
        let expected = try wakeExpectation(status, targetUUID: targetUUID)
        topology.snapshot = try timestampedSnapshot(Date(timeIntervalSince1970: 1_900_000_000)) { displays in
            displays[1]["x"] = 1900
        }

        var stages = 0
        var commits = 0
        let sut = controller(transaction: MirrorTransaction(
            begin: { OpaquePointer(bitPattern: 1)! },
            stage: { _, _, _ in stages += 1 },
            complete: { _, _ in commits += 1 },
            cancel: { _ in }
        ))
        XCTAssertThrowsError(try sut.hide(target: expected.target, source: expected.source, wakeExpectation: expected))
        XCTAssertEqual(stages, 0)
        XCTAssertEqual(commits, 0)
    }

    func testWakeResumeRevalidatesJournalAfterBeginBeforeAnyMirrorStage() throws {
        let status = try prepareWakeResetStatus()
        let expected = try wakeExpectation(status, targetUUID: targetUUID)
        var stages = 0
        var commits = 0
        var cancels = 0
        let sut = controller(transaction: MirrorTransaction(
            begin: {
                var altered = try self.store.load()
                altered.trigger = "changed-after-preflight"
                try self.store.save(altered)
                return OpaquePointer(bitPattern: 1)!
            },
            stage: { _, _, _ in stages += 1 },
            complete: { _, _ in commits += 1 },
            cancel: { _ in cancels += 1 }
        ))
        XCTAssertThrowsError(try sut.hide(target: expected.target, source: expected.source, wakeExpectation: expected))
        XCTAssertEqual(stages, 0, "journal is revalidated after begin and before mirror staging")
        XCTAssertEqual(commits, 0)
        XCTAssertEqual(cancels, 1)
    }

    func testWakeResumeRevalidatesTopologyAfterStageBeforeCommit() throws {
        let status = try prepareWakeResetStatus()
        let expected = try wakeExpectation(status, targetUUID: targetUUID)
        var stages = 0
        var commits = 0
        var cancels = 0
        let sut = controller(transaction: MirrorTransaction(
            begin: { OpaquePointer(bitPattern: 1)! },
            stage: { _, _, _ in
                stages += 1
                self.topology.snapshot = try self.timestampedSnapshot(Date(timeIntervalSince1970: 1_900_000_000)) { displays in
                    displays[1]["x"] = 1900
                }
            },
            complete: { _, _ in commits += 1 },
            cancel: { _ in cancels += 1 }
        ))
        XCTAssertThrowsError(try sut.hide(target: expected.target, source: expected.source, wakeExpectation: expected))
        XCTAssertEqual(stages, 1, "the staged fake transaction is cancelled on the post-stage topology mismatch")
        XCTAssertEqual(commits, 0, "the changed topology is refused before commit")
        XCTAssertEqual(cancels, 1)
    }

    func testWakeResumeRevalidatesTopologyAfterBeginBeforeAnyMirrorStage() throws {
        let status = try prepareWakeResetStatus()
        let expected = try wakeExpectation(status, targetUUID: targetUUID)
        var stages = 0
        var commits = 0
        var cancels = 0
        let sut = controller(transaction: MirrorTransaction(
            begin: {
                self.topology.snapshot = try self.timestampedSnapshot(Date(timeIntervalSince1970: 1_900_000_000)) { displays in
                    displays[1]["x"] = 1900
                }
                return OpaquePointer(bitPattern: 1)!
            },
            stage: { _, _, _ in stages += 1 },
            complete: { _, _ in commits += 1 },
            cancel: { _ in cancels += 1 }
        ))
        XCTAssertThrowsError(try sut.hide(target: expected.target, source: expected.source, wakeExpectation: expected))
        XCTAssertEqual(stages, 0, "topology is revalidated after begin and before mirror staging")
        XCTAssertEqual(commits, 0)
        XCTAssertEqual(cancels, 1)
    }

    func testHideAndShowUseSharedJournalAndFakePublicWriter() throws {
        let original = topology.snapshot
        let mirrored = try snapshot { displays in
            displays[1]["mirrorUUID"] = self.sourceUUID
            displays[1]["active"] = false
        }
        let sut = controller(transaction: MirrorTransaction(
            begin: { OpaquePointer(bitPattern: 1)! },
            stage: { _, target, source in
                XCTAssertEqual(target, self.targetID)
                XCTAssertEqual(source, self.sourceID)
            },
            complete: { _, scope in
                XCTAssertEqual(scope, .forSession)
                self.writerCount += 1
                self.topology.snapshot = mirrored
            },
            cancel: { _ in XCTFail("successful fake hide must consume its transaction") }
        ))

        XCTAssertNoThrow(try sut.hide(target: identity(targetUUID), source: identity(sourceUUID)))
        let journal = try store.load()
        XCTAssertEqual(journal.state, .mirrored)
        XCTAssertEqual(journal.snapshot, original)
        XCTAssertEqual(journal.mirrorTargetID, targetID)
        XCTAssertEqual(journal.mirrorSourceID, sourceID)
        XCTAssertEqual(writerCount, 1)

        let hidden = try sut.inspect()
        XCTAssertTrue(hidden.hasUnresolvedMirror)
        XCTAssertTrue(hidden.showAvailable)
        XCTAssertEqual(hidden.journal?.id, journal.id.uuidString)
        XCTAssertEqual(
            hidden.observations.first(where: { $0.isJournalTarget })?.state,
            .hiddenByPanelCtl
        )

        XCTAssertThrowsError(try sut.hide(target: identity(targetUUID), source: identity(sourceUUID)))
        XCTAssertEqual(writerCount, 1, "duplicate Hide cannot replace an unresolved journal")

        XCTAssertNoThrow(try sut.show(expectedJournalID: journal.id.uuidString))
        XCTAssertEqual(writerCount, 2)
        XCTAssertEqual(try store.load().state, .restored)
        XCTAssertNoThrow(try original.verify(topology.snapshot))
        XCTAssertFalse(try sut.inspect().hasUnresolvedRecovery)
        XCTAssertNoThrow(try sut.show(expectedJournalID: journal.id.uuidString))
        XCTAssertEqual(writerCount, 2, "resolved Show must not write topology again")
    }

    func testInspectedHiddenMirrorAuthorizationRefusesChangedMainDisplay() throws {
        var journal = RecoveryJournal(snapshot: topology.snapshot)
        journal.mirrorTargetID = targetID
        journal.mirrorSourceID = sourceID
        journal.state = .mirrored
        try save(journal)

        topology.snapshot = try snapshot { displays in
            displays[1]["mirrorUUID"] = self.sourceUUID
            displays[1]["active"] = false
        }
        var inspected = try controller().inspect()
        XCTAssertEqual(inspected.journal?.state, RecoveryState.mirrored.rawValue)
        XCTAssertTrue(inspected.showAvailable)
        XCTAssertTrue(inspected.journal?.mirrorTopologyVerified == true)
        var handoff = DisplayHandoff.handoffStatus(from: inspected)
        XCTAssertNil(HiddenMirrorSourceOverlayAuthorization.refusal(
            sourceUUID: sourceUUID,
            sourceDisplayID: sourceID,
            isMirrored: true,
            status: handoff
        ))

        topology.snapshot = try snapshot { displays in
            displays[0]["main"] = false
            displays[1]["main"] = true
            displays[1]["mirrorUUID"] = self.sourceUUID
            displays[1]["active"] = false
        }
        inspected = try controller().inspect()
        XCTAssertTrue(inspected.showAvailable, "Show can still restore a changed main-display setting")
        XCTAssertFalse(inspected.journal?.mirrorTopologyVerified ?? true)
        handoff = DisplayHandoff.handoffStatus(from: inspected)
        XCTAssertEqual(handoff.state, .recovery, "a non-main target keeps the captured main-display check strict")
        let refusal = HiddenMirrorSourceOverlayAuthorization.refusal(
            sourceUUID: sourceUUID,
            sourceDisplayID: sourceID,
            isMirrored: true,
            status: handoff
        )
        XCTAssertTrue(refusal?.contains("mirror topology") == true,
                      "a changed main display fails the exact hidden-topology authorization")
        XCTAssertEqual(writerCount, 0, "inspection and authorization never invoke the fake writer")
    }

    func testMainTargetStaysHiddenAcrossMainChangesAndShowRestoresOriginalMain() throws {
        let original = try snapshot { displays in
            displays[0]["main"] = false
            displays[1]["main"] = true
        }
        topology.snapshot = original
        var journal = RecoveryJournal(snapshot: original)
        journal.mirrorTargetID = targetID
        journal.mirrorSourceID = sourceID
        journal.state = .mirrored
        try save(journal)

        let sut = controller()
        for currentMainID in [sourceID, targetID, UInt32(9), sourceID] {
            topology.snapshot = try snapshot { displays in
                displays[0]["main"] = currentMainID == self.sourceID
                displays[1]["main"] = currentMainID == self.targetID
                displays[2]["main"] = currentMainID == 9
                displays[1]["mirrorUUID"] = self.sourceUUID
                displays[1]["active"] = false
            }
            let inspected = try sut.inspect()
            XCTAssertTrue(inspected.showAvailable)
            XCTAssertTrue(inspected.journal?.mirrorTopologyVerified == true, "main ID \(currentMainID)")
            XCTAssertEqual(inspected.observations.first(where: { $0.isJournalTarget })?.state, .hiddenByPanelCtl)
            let handoff = DisplayHandoff.handoffStatus(from: inspected)
            XCTAssertEqual(handoff.state, .hidden)
            XCTAssertNil(HiddenMirrorSourceOverlayAuthorization.refusal(
                sourceUUID: sourceUUID, sourceDisplayID: sourceID, isMirrored: true, status: handoff
            ))
        }

        XCTAssertNoThrow(try sut.show(expectedJournalID: journal.id.uuidString))
        XCTAssertEqual(try store.load().state, .restored)
        XCTAssertNoThrow(try original.verify(topology.snapshot))
        XCTAssertEqual(topology.snapshot.displays.first(where: { $0.id == targetID })?.main, true)
        XCTAssertEqual(writerCount, 1)
    }

    func testMainTargetShowMismatchKeepsRecoveryAndManualGuidance() throws {
        let original = try snapshot { displays in
            displays[0]["main"] = false
            displays[1]["main"] = true
        }
        topology.snapshot = try snapshot { displays in
            displays[0]["main"] = true
            displays[1]["main"] = false
            displays[1]["mirrorUUID"] = self.sourceUUID
            displays[1]["active"] = false
        }
        var journal = RecoveryJournal(snapshot: original)
        journal.mirrorTargetID = targetID
        journal.mirrorSourceID = sourceID
        journal.state = .mirrored
        try save(journal)

        let sut = controller(restore: { _ in })
        XCTAssertThrowsError(try sut.show(expectedJournalID: journal.id.uuidString)) { error in
            XCTAssertTrue(error.localizedDescription.contains("turn off mirroring"), error.localizedDescription)
            XCTAssertTrue(error.localizedDescription.contains("drag the menu bar"), error.localizedDescription)
        }
        let failed = try store.load()
        XCTAssertEqual(failed.state, .needsAttention)
        XCTAssertEqual(failed.snapshot, original)
        XCTAssertTrue(failed.failure?.contains("turn off mirroring") == true)
        XCTAssertTrue(failed.failure?.contains("drag the menu bar") == true)
        XCTAssertEqual(writerCount, 1, "a failed restore is not reported as success or retried")
    }

    func testImportedAwayJournalWithSuccessfulInputSwitchReportsUnknownAndManualFallback() throws {
        let mirrored = try snapshot { displays in
            displays[1]["mirrorUUID"] = self.sourceUUID
            displays[1]["active"] = false
        }
        let mirror = MirrorController(
            records: { self.topology.records },
            operationLock: { self.operationStore },
            engine: RecoveryEngine(
                capture: { self.topology.snapshot },
                apply: { self.topology.snapshot = $0 },
                convergencePause: {}
            ),
            preflightModes: { _ in },
            transaction: MirrorTransaction(
                begin: { OpaquePointer(bitPattern: 1)! },
                stage: { _, _, _ in },
                complete: { _, _ in
                    self.writerCount += 1
                    self.topology.snapshot = mirrored
                },
                cancel: { _ in XCTFail("successful fake Away must consume its transaction") }
            )
        )
        let handoff = HandoffController(
            mirror: mirror,
            open: { uuid, _ in
                (display: DDC.DisplayTarget(id: self.targetID, uuid: uuid), channel: DDCChannel(
                    getVCP: { _ in (current: 0x11, maximum: 0x12) },
                    setVCP: { _, _ in XCTFail("input write must stay fake") }
                ))
            },
            select: { requested, _, id, uuid, original in
                DDCInputSelection(
                    displayID: id, uuid: uuid, original: original, requested: requested,
                    observed: requested, outcome: .verified, detail: nil
                )
            },
            report: { _ in }
        )

        try handoff.away(selector: targetUUID, source: sourceUUID, input: 0x0F, store: store)
        let status = try DisplayHideController(
            store: store,
            mirror: mirror,
            operationLock: { self.operationStore }
        ).inspect()
        let observation = try XCTUnwrap(status.observations.first { $0.isJournalTarget })
        XCTAssertEqual(observation.state, .hiddenByPanelCtl)
        XCTAssertTrue(observation.detail?.contains("input is unknown") == true)
        XCTAssertTrue(observation.detail?.contains("input buttons") == true)
        XCTAssertFalse(observation.detail?.localizedCaseInsensitiveContains("unchanged") == true)
        XCTAssertEqual(writerCount, 1)
    }

    func testStatusRecognizesExternalMirrorWithoutClaimingPanelCtlOwnership() throws {
        topology.snapshot = try snapshot { displays in
            displays[1]["mirrorUUID"] = self.sourceUUID
            displays[1]["active"] = false
        }
        let status = try controller().inspect()
        XCTAssertNil(status.journal)
        XCTAssertFalse(status.hasUnresolvedRecovery)
        XCTAssertEqual(
            status.observations.first(where: { $0.identity.uuid == targetUUID })?.state,
            .mirroredExternally
        )
    }

    func testCapturedMirrorJournalAfterSystemRestorationResolvesByVerificationOnly() throws {
        var journal = RecoveryJournal(snapshot: topology.snapshot)
        journal.mirrorTargetID = targetID
        journal.mirrorSourceID = sourceID
        journal.state = .mirrored
        try save(journal)

        let status = try controller().inspect()

        XCTAssertFalse(status.hasUnresolvedRecovery)
        XCTAssertEqual(status.journal?.baselineIdentity, status.journal?.observedTopologyIdentity)
        XCTAssertEqual(try store.load().state, .verified)
        XCTAssertEqual(writerCount, 0, "observing macOS restoration must never replay Hide or Show")
    }

    func testMissingOrChangedJournalIdentityRefusesShowAndRetainsEvidence() throws {
        var journal = RecoveryJournal(snapshot: topology.snapshot)
        journal.mirrorTargetID = targetID
        journal.mirrorSourceID = sourceID
        journal.state = .mirrored
        try save(journal)

        topology.snapshot = try snapshot { displays in
            displays.removeAll { ($0["id"] as? NSNumber)?.uint32Value == self.targetID }
        }
        var status = try controller().inspect()
        XCTAssertTrue(status.hasUnresolvedMirror)
        XCTAssertFalse(status.showAvailable)
        XCTAssertEqual(
            status.observations.first(where: { $0.isJournalTarget })?.state,
            .unavailable
        )
        XCTAssertThrowsError(try controller().show(expectedJournalID: journal.id.uuidString))
        XCTAssertEqual(try store.load().id, journal.id)
        XCTAssertEqual(writerCount, 0)

        topology.snapshot = try snapshot { displays in
            displays[1]["serial"] = 999
            displays[1]["mirrorUUID"] = self.sourceUUID
            displays[1]["active"] = false
        }
        status = try controller().inspect()
        XCTAssertTrue(status.hasUnresolvedMirror)
        XCTAssertFalse(status.showAvailable)
        XCTAssertTrue(status.journal?.showRefusal?.contains("identity") == true)
        XCTAssertEqual(try store.load().id, journal.id)
        XCTAssertEqual(writerCount, 0)
    }

    func testHideRevalidatesConfirmedTargetAndSourceIdentityUnderTheLock() throws {
        let confirmedTarget = try identity(targetUUID)
        let confirmedSource = try identity(sourceUUID)

        topology.snapshot = try snapshot { displays in
            displays[1]["id"] = 80
        }
        XCTAssertThrowsError(try controller().hide(target: confirmedTarget, source: confirmedSource)) {
            XCTAssertTrue($0.localizedDescription.contains("target identity changed"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.url.path))
        XCTAssertEqual(writerCount, 0)

        topology.snapshot = try snapshot { displays in
            displays[0]["serial"] = 999
        }
        XCTAssertThrowsError(try controller().hide(target: confirmedTarget, source: confirmedSource)) {
            XCTAssertTrue($0.localizedDescription.contains("source identity changed"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.url.path))
        XCTAssertEqual(writerCount, 0)
    }

    func testShowRefusesSleepingTargetOrSourceWithoutCallingWriter() throws {
        var journal = RecoveryJournal(snapshot: topology.snapshot)
        journal.mirrorTargetID = targetID
        journal.mirrorSourceID = sourceID
        journal.state = .mirrored
        try save(journal)
        topology.snapshot = try snapshot { displays in
            displays[1]["mirrorUUID"] = self.sourceUUID
            displays[1]["active"] = false
        }

        topology.asleepDisplayIDs = [targetID]
        var status = try controller().inspect()
        XCTAssertFalse(status.showAvailable)
        XCTAssertTrue(status.journal?.showRefusal?.contains("asleep") == true)
        XCTAssertThrowsError(try controller().show(expectedJournalID: journal.id.uuidString))
        XCTAssertEqual(writerCount, 0)
        XCTAssertEqual(try store.load().state, .mirrored)

        topology.asleepDisplayIDs = [sourceID]
        status = try controller().inspect()
        XCTAssertFalse(status.showAvailable)
        XCTAssertTrue(status.journal?.showRefusal?.contains("asleep") == true)
        XCTAssertThrowsError(try controller().show(expectedJournalID: journal.id.uuidString))
        XCTAssertEqual(writerCount, 0)
        XCTAssertEqual(try store.load().state, .mirrored)
    }

    func testUnknownUnresolvedJournalIsVisibleButNeverRoutedThroughShow() throws {
        let journal = RecoveryJournal(snapshot: topology.snapshot)
        try save(journal)

        let status = try controller().inspect()

        XCTAssertTrue(status.hasUnresolvedRecovery)
        XCTAssertFalse(status.hasUnresolvedMirror)
        XCTAssertFalse(status.showAvailable)
        XCTAssertEqual(status.journal?.isMirrorJournal, false)
        XCTAssertNotNil(status.journal?.showRefusal)
        XCTAssertThrowsError(try controller().show(expectedJournalID: journal.id.uuidString))
        XCTAssertEqual(try store.load().id, journal.id)
        XCTAssertEqual(writerCount, 0)
    }

    func testShowConfirmationJournalIdentityIsCheckedUnderTheSharedLock() throws {
        var journal = RecoveryJournal(snapshot: topology.snapshot)
        journal.mirrorTargetID = targetID
        journal.mirrorSourceID = sourceID
        journal.state = .mirrored
        try save(journal)
        let mirrored = try snapshot { displays in
            displays[1]["mirrorUUID"] = self.sourceUUID
            displays[1]["active"] = false
        }
        topology.snapshot = mirrored

        XCTAssertThrowsError(try controller().show(expectedJournalID: UUID().uuidString))
        XCTAssertEqual(try store.load().id, journal.id)
        XCTAssertEqual(try store.load().state, .mirrored)
        XCTAssertEqual(writerCount, 0)
    }

    private func prepareWakeResetStatus(layoutDrift: Bool = false) throws -> DisplayHideStatus {
        let baseline = try timestampedSnapshot(Date(timeIntervalSince1970: 1_700_000_000))
        let firstHidden = try timestampedSnapshot(Date(timeIntervalSince1970: 1_700_000_001)) { displays in
            displays[1]["mirrorUUID"] = self.sourceUUID
            displays[1]["active"] = false
        }
        let bothHidden = try timestampedSnapshot(Date(timeIntervalSince1970: 1_700_000_002)) { displays in
            displays[1]["mirrorUUID"] = self.sourceUUID
            displays[1]["active"] = false
            displays[2]["mirrorUUID"] = self.sourceUUID
            displays[2]["active"] = false
        }
        let removals = [
            PublicMirrorRemoval(target: baseline.displays[1], source: baseline.displays[0],
                                beforeOperation: baseline, state: .mirrored),
            PublicMirrorRemoval(target: baseline.displays[2], source: baseline.displays[0],
                                beforeOperation: firstHidden, state: .mirrored)
        ]
        var journal = RecoveryJournal(snapshot: baseline,
                                      publicMirrorSession: PublicMirrorSession(baseline: baseline, removals: removals))
        journal.state = .mirrored
        try save(journal)
        topology.snapshot = bothHidden
        XCTAssertEqual(try controller().inspect().removals.filter(\.isUnresolved).count, 2)

        // New capture timestamps model macOS restoring the saved baseline after wake.
        topology.snapshot = try timestampedSnapshot(Date(timeIntervalSince1970: 1_800_000_000)) { displays in
            if layoutDrift {
                displays[0]["main"] = false
                displays[0]["x"] = 2560
                displays[1]["main"] = true
                displays[1]["x"] = 0
                displays[2]["x"] = 6400
            }
        }
        let status = try controller().inspect()
        if layoutDrift {
            XCTAssertTrue(status.removals.allSatisfy { $0.isUnresolved && $0.state == "needsAttention" })
        } else {
            XCTAssertEqual(status.journal?.state, RecoveryState.verified.rawValue)
            XCTAssertTrue(status.removals.allSatisfy { !$0.isUnresolved && $0.state == "restored" })
            XCTAssertEqual(status.journal?.baselineIdentity, status.journal?.observedTopologyIdentity)
        }
        return status
    }

    private func wakeExpectation(_ status: DisplayHideStatus, targetUUID: String,
                                 resumeSession: Bool = false) throws -> DisplayHideWakeExpectation {
        let journal = try XCTUnwrap(status.journal)
        let removal = try XCTUnwrap(status.removals.first {
            $0.target.uuid.caseInsensitiveCompare(targetUUID) == .orderedSame
        })
        return DisplayHideWakeExpectation(
            journalID: journal.id,
            journalIdentity: try XCTUnwrap(journal.journalIdentity),
            baselineIdentity: try XCTUnwrap(journal.baselineIdentity),
            observedTopologyIdentity: try XCTUnwrap(journal.observedTopologyIdentity),
            target: removal.target, source: removal.source,
            resumeRemovalIDs: resumeSession ? status.removals.filter(\.isUnresolved).map(\.id) : []
        )
    }

    private func controller(transaction: MirrorTransaction = MirrorTransaction(),
                             restore: ((RecoverySnapshot) throws -> Void)? = nil) -> DisplayHideController {
        let mirror = MirrorController(
            records: { self.topology.records },
            operationLock: { self.operationStore },
            engine: RecoveryEngine(
                capture: { self.topology.snapshot },
                apply: { snapshot in
                    self.writerCount += 1
                    if let restore { try restore(snapshot) }
                    else { self.topology.snapshot = snapshot }
                },
                convergencePause: {}
            ),
            preflightModes: { _ in },
            transaction: transaction
        )
        return DisplayHideController(
            store: store,
            mirror: mirror,
            operationLock: { self.operationStore }
        )
    }

    private func identity(_ uuid: String) throws -> DisplayHideIdentity {
        let record = try XCTUnwrap(topology.records.first { $0.uuid?.caseInsensitiveCompare(uuid) == .orderedSame })
        return DisplayHideIdentity(
            uuid: uuid,
            displayID: record.id,
            name: record.name,
            vendor: record.vendor,
            model: record.model,
            serial: record.serial
        )
    }

    private func save(_ journal: RecoveryJournal) throws {
        try store.lock()
        defer { store.unlock() }
        try store.create(journal)
    }

    private func timestampedSnapshot(
        _ capturedAt: Date,
        _ modify: (inout [[String: Any]]) -> Void = { _ in }
    ) throws -> RecoverySnapshot {
        let base = try snapshot(modify)
        let displays = base.displays.map { display in
            RecoveryDisplay(
                uuid: display.uuid, id: display.id, name: display.name,
                vendor: display.vendor, model: display.model, serial: display.serial,
                builtin: display.builtin, main: display.main, active: display.active,
                x: display.x, y: display.y, rotation: display.rotation, mirrorUUID: display.mirrorUUID,
                mode: display.mode, colorSpace: display.colorSpace,
                colorProfileDigest: display.colorProfileDigest,
                colorProfileDateIndependentDigest: display.colorProfileDateIndependentDigest,
                connector: display.connector,
                identityEvidence: RecoveryIdentityEvidence(source: .syntheticFixture, capturedAt: capturedAt)
            )
        }
        return RecoverySnapshot(bootSession: base.bootSession, osBuild: base.osBuild,
                                userID: base.userID, displays: displays, hostModel: base.hostModel)
    }

    private func snapshot(
        _ modify: (inout [[String: Any]]) -> Void = { _ in }
    ) throws -> RecoverySnapshot {
        var displays: [[String: Any]] = [
            ["uuid": sourceUUID, "id": sourceID, "name": "Source", "vendor": 1, "model": 1, "serial": 1,
             "builtin": false, "main": true, "active": true, "x": 0, "y": 0, "rotation": 0,
             "mode": ["id": 1, "width": 1920, "height": 1080, "pixelWidth": 1920,
                      "pixelHeight": 1080, "refreshRate": 60, "flags": 0]],
            ["uuid": targetUUID, "id": targetID, "name": "Target", "vendor": 2, "model": 2, "serial": 2,
             "builtin": false, "main": false, "active": true, "x": 1920, "y": 0, "rotation": 0,
             "mode": ["id": 2, "width": 2560, "height": 1440, "pixelWidth": 2560,
                      "pixelHeight": 1440, "refreshRate": 60, "flags": 0]],
            ["uuid": otherUUID, "id": 9, "name": "Other", "vendor": 3, "model": 3, "serial": 3,
             "builtin": false, "main": false, "active": true, "x": 4480, "y": 0, "rotation": 0,
             "mode": ["id": 3, "width": 1920, "height": 1080, "pixelWidth": 1920,
                      "pixelHeight": 1080, "refreshRate": 60, "flags": 0]]
        ]
        modify(&displays)
        let value: [String: Any] = [
            "bootSession": "test-boot",
            "osBuild": "test-build",
            "userID": getuid(),
            "displays": displays
        ]
        return try JSONDecoder().decode(
            RecoverySnapshot.self,
            from: JSONSerialization.data(withJSONObject: value)
        )
    }

    private final class FakeTopology {
        var snapshot: RecoverySnapshot
        var asleepDisplayIDs = Set<UInt32>()

        init(snapshot: RecoverySnapshot) {
            self.snapshot = snapshot
        }

        var records: [DisplayRecord] {
            snapshot.displays.enumerated().map { index, display in
                DisplayRecord(
                    index: index + 1,
                    id: display.id,
                    uuid: display.uuid,
                    name: display.name,
                    active: display.active,
                    online: true,
                    asleep: asleepDisplayIDs.contains(display.id),
                    builtin: display.builtin,
                    main: display.main,
                    vendor: display.vendor,
                    model: display.model,
                    serial: display.serial,
                    bounds: DisplayBounds(CGRect(x: Int(display.x), y: Int(display.y), width: 1920, height: 1080)),
                    pixelWidth: display.mode.pixelWidth,
                    pixelHeight: display.mode.pixelHeight
                )
            }
        }
    }
}
