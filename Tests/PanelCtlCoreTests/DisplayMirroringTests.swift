import XCTest
import CoreGraphics
import Darwin
@testable import PanelCtlCore

final class DisplayMirroringTests: XCTestCase {
    private var directory: URL!
    private var store: RecoveryStore!
    private let targetID: UInt32 = 8
    private let sourceID: UInt32 = 7
    private let sourceUUID = "00000000-0000-0000-0000-000000000001"

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("panelctl-mirror-tests-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        store = RecoveryStore(url: directory.appendingPathComponent("current.json"))
    }

    override func tearDownWithError() throws {
        store.unlock()
        try FileManager.default.removeItem(at: directory)
    }

    private func snapshot(_ modify: (inout [[String: Any]]) -> Void = { _ in }) throws -> RecoverySnapshot {
        var displays: [[String: Any]] = (1...3).map { index in
            ["uuid": String(format: "00000000-0000-0000-0000-%012d", index), "id": index + 6,
             "vendor": 1, "model": index, "serial": index, "builtin": false,
             "main": index == 1, "active": true, "x": (index - 1) * 1920, "y": 0, "rotation": 0,
             "mode": ["id": index, "width": 1920, "height": 1080, "pixelWidth": 1920,
                      "pixelHeight": 1080, "refreshRate": 60, "flags": 0]]
        }
        modify(&displays)
        let value: [String: Any] = ["bootSession": "test-boot", "osBuild": "test-build",
                                     "userID": getuid(), "displays": displays]
        return try JSONDecoder().decode(RecoverySnapshot.self, from: JSONSerialization.data(withJSONObject: value))
    }

    private func snapshotUUID(_ index: Int) -> String {
        String(format: "00000000-0000-0000-0000-%012d", index)
    }

    private func changedSnapshot(_ snapshot: RecoverySnapshot,
                                 _ change: (inout [[String: Any]]) -> Void) throws -> RecoverySnapshot {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot)) as? [String: Any])
        var displays = try XCTUnwrap(object["displays"] as? [[String: Any]])
        change(&displays)
        object["displays"] = displays
        return try JSONDecoder().decode(RecoverySnapshot.self, from: JSONSerialization.data(withJSONObject: object))
    }

    private func withoutDisplay(_ snapshot: RecoverySnapshot, uuid: String) throws -> RecoverySnapshot {
        try changedSnapshot(snapshot) { displays in
            displays.removeAll { ($0["uuid"] as? String)?.caseInsensitiveCompare(uuid) == .orderedSame }
        }
    }

    private func sessionSnapshot(_ active: [Int: Int], includeFourth: Bool = false,
                                originalMain: Int = 1) throws -> RecoverySnapshot {
        try snapshot { displays in
            if includeFourth, displays.count == 3 {
                displays.append([
                    "uuid": self.snapshotUUID(4), "id": 10, "vendor": 1, "model": 4, "serial": 4,
                    "builtin": false, "main": false, "active": true, "x": 5760, "y": 0, "rotation": 0,
                    "mode": ["id": 4, "width": 1920, "height": 1080, "pixelWidth": 1920,
                             "pixelHeight": 1080, "refreshRate": 60, "flags": 0]
                ])
            }
            let currentMain = active[originalMain] ?? originalMain
            for index in displays.indices {
                let displayIndex = index + 1
                displays[index]["main"] = displayIndex == currentMain
                if let sourceIndex = active[displayIndex] {
                    displays[index]["mirrorUUID"] = self.snapshotUUID(sourceIndex)
                    displays[index]["active"] = false
                }
            }
        }
    }

    private func records(_ snapshot: RecoverySnapshot) -> [DisplayRecord] {
        snapshot.displays.enumerated().map { index, display in
            DisplayRecord(index: index + 1, id: display.id, uuid: display.uuid, name: "fake",
                          active: display.active, online: true, asleep: false, builtin: display.builtin,
                          main: display.main, vendor: display.vendor, model: display.model, serial: display.serial,
                          bounds: DisplayBounds(CGRect(x: Int(display.x), y: Int(display.y), width: 1920, height: 1080)),
                          pixelWidth: 1920, pixelHeight: 1080)
        }
    }

    private func controller(_ snapshot: RecoverySnapshot) -> MirrorController {
        MirrorController(records: { self.records(snapshot) },
            engine: RecoveryEngine(capture: { snapshot }, apply: { _ in XCTFail("unexpected restore") }, convergencePause: {}),
            preflightModes: { _ in }, transaction: MirrorTransaction(
                begin: { XCTFail("unexpected begin"); throw RecoveryError.unsafe("unexpected") },
                stage: { _, _, _ in XCTFail("unexpected stage") },
                complete: { _, _ in XCTFail("unexpected complete") }, cancel: { _ in XCTFail("unexpected cancel") }))
    }

    private func journal(_ snapshot: RecoverySnapshot) throws -> RecoveryJournal {
        try store.lock()
        defer { store.unlock() }
        var journal = RecoveryJournal(snapshot: snapshot)
        journal.mirrorTargetID = targetID; journal.mirrorSourceID = sourceID
        try store.create(journal)
        return journal
    }

    func testLegacyPublicAndMirrorConnectorsMatchFreshTransportEvidence() throws {
        let legacyPublic = try snapshot { displays in
            for index in displays.indices { displays[index]["connector"] = "CoreDisplay-\(index + 1)" }
        }
        let freshPublic = try snapshot { displays in
            for index in displays.indices {
                let location = "CoreDisplay-\(index + 1)"
                displays[index]["connector"] = location
                displays[index]["identityEvidence"] = ["source": "cgAndCoreDisplay", "capturedAt": 0,
                    "transport": "DisplayPort", "transportLocation": "IOKit-Port-\(index + 1)",
                    "framebufferLocation": location]
            }
        }
        XCTAssertNoThrow(try legacyPublic.validateRestoration(to: freshPublic))

        let legacyMirror = try snapshot()
        let freshMirror = try snapshot { displays in
            for index in displays.indices {
                displays[index]["identityEvidence"] = ["source": "cgAndIOKit", "capturedAt": 0,
                    "transport": "DisplayPort", "transportLocation": "IOKit-Port-\(index + 1)"]
            }
        }
        XCTAssertTrue(legacyMirror.displays.allSatisfy { $0.connector == nil })
        XCTAssertNoThrow(try legacyMirror.validateRestoration(to: freshMirror))

        let changedPublic = try snapshot { displays in displays[0]["connector"] = "different CoreDisplay location" }
        XCTAssertThrowsError(try legacyPublic.validateRestoration(to: changedPublic))
        let changedMirror = try snapshot { displays in displays[0]["connector"] = "new IOKit location" }
        XCTAssertThrowsError(try legacyMirror.validateRestoration(to: changedMirror))
    }

    func testMirrorJournalsBeforeBeginAndKeepsUnresolvedIntent() throws {
        let original = try snapshot()
        let mirrored = try snapshot { $0[1]["mirrorUUID"] = sourceUUID; $0[1]["active"] = false }
        var current = original
        var events: [String] = []
        var sut = controller(original)
        sut.engine.capture = { current }
        sut.transaction = MirrorTransaction(begin: {
            let saved = try self.store.load()
            XCTAssertEqual(saved.snapshot, original)
            XCTAssertEqual(saved.mirrorTargetID, self.targetID)
            XCTAssertEqual(saved.mirrorSourceID, self.sourceID)
            XCTAssertEqual(saved.state, .captured)
            events.append("begin")
            return OpaquePointer(bitPattern: 1)!
        }, stage: { _, target, source in
            XCTAssertEqual(target, self.targetID); XCTAssertEqual(source, self.sourceID)
            events.append("stage")
        }, complete: { _, scope in
            XCTAssertEqual(scope, .forSession)
            events.append("complete"); current = mirrored
        }, cancel: { _ in XCTFail("must not cancel") })
        let result = try sut.mirror(selector: "index:2", source: sourceUUID, store: store)
        XCTAssertEqual(events, ["begin", "stage", "complete"])
        XCTAssertEqual(result.state, .mirrored)
        XCTAssertFalse(result.state.resolved)
        XCTAssertNil(result.disabledByUsID)
        XCTAssertEqual(try store.load().snapshot, original)
        XCTAssertThrowsError(try sut.mirror(selector: "8", source: "7", store: store))
    }

    func testMultiRemovalSessionRestoresTwoAndThreeDisplaysInEveryShowOrder() throws {
        let baseline = try sessionSnapshot([:], includeFourth: true)
        let targetIndexes = [2, 3, 4]
        let orders = [[2, 3], [3, 2], [2, 3, 4], [2, 4, 3], [3, 2, 4], [3, 4, 2],
                      [4, 2, 3], [4, 3, 2]]
        for hideOrder in orders {
            for showOrder in orders where showOrder.count == hideOrder.count {
                let scenarioStore = RecoveryStore(url: directory.appendingPathComponent(
                    "session-\(hideOrder.map(String.init).joined())-\(showOrder.map(String.init).joined()).json"
                ))
                var active: [Int: Int] = [:]
                var current = baseline
                let operation = RecoveryStore(url: directory.appendingPathComponent("operation"))
                var stagedTarget: UInt32 = 0
                var stagedSource: UInt32 = 0
                let sut = MirrorController(
                    records: { self.records(current) }, operationLock: { operation },
                    engine: RecoveryEngine(
                        capture: { current },
                        apply: { _ in active.removeAll(); current = baseline },
                        convergencePause: {}
                    ),
                    preflightModes: { _ in },
                    transaction: MirrorTransaction(
                        begin: { OpaquePointer(bitPattern: 1)! },
                        stage: { _, target, source in stagedTarget = target; stagedSource = source },
                        complete: { _, _ in
                            active[Int(stagedTarget) - 6] = Int(stagedSource) - 6
                            current = try self.sessionSnapshot(active, includeFourth: true)
                        }, cancel: { _ in XCTFail("successful fake transaction must not cancel") }
                    ),
                    restoreTarget: { _, targetUUID, revalidate, _ in
                        try revalidate()
                        guard let target = targetIndexes.first(where: { self.snapshotUUID($0) == targetUUID }) else {
                            throw RecoveryError.unsafe("unknown fake target")
                        }
                        active.removeValue(forKey: target)
                        current = try self.sessionSnapshot(active, includeFourth: true)
                    }
                )
                for target in hideOrder {
                    _ = try sut.mirror(selector: self.snapshotUUID(target), source: self.snapshotUUID(1), store: scenarioStore)
                }
                var saved = try scenarioStore.load()
                XCTAssertEqual(saved.publicMirrorSession?.baseline, baseline)
                XCTAssertEqual(saved.publicMirrorSession?.removals.count, hideOrder.count)
                for (position, target) in hideOrder.enumerated() {
                    let removal = try XCTUnwrap(saved.publicMirrorSession?.removals.first(where: {
                        $0.targetUUID == self.snapshotUUID(target)
                    }))
                    XCTAssertEqual(removal.beforeOperation, try self.sessionSnapshot(
                        Dictionary(uniqueKeysWithValues: hideOrder.prefix(position).map { ($0, 1) }), includeFourth: true
                    ))
                    XCTAssertEqual(removal.state, .mirrored)
                }
                for target in showOrder {
                    saved = try sut.unmirror(store: scenarioStore, selector: self.snapshotUUID(target))
                    let entries = try XCTUnwrap(saved.publicMirrorSession?.removals)
                    XCTAssertEqual(entries.first(where: { $0.targetUUID == self.snapshotUUID(target) })?.state, .restored)
                    XCTAssertEqual(entries.filter { !$0.state.resolved }.count,
                                   showOrder.suffix(from: (showOrder.firstIndex(of: target) ?? 0) + 1).count)
                }
                XCTAssertEqual(current, baseline, "hide order \(hideOrder), Show order \(showOrder)")
                XCTAssertEqual(saved.state, .restored)
                XCTAssertTrue(saved.publicMirrorSession?.removals.allSatisfy { $0.state == .restored } == true)
            }
        }
    }

    func testSecondHideFailurePreservesFirstRemovalAndSelectedShowFailurePreservesOthers() throws {
        let baseline = try sessionSnapshot([:], includeFourth: true)
        var active: [Int: Int] = [:]
        var current = baseline
        let scenarioStore = RecoveryStore(url: directory.appendingPathComponent("multi-failure.json"))
        let operation = RecoveryStore(url: directory.appendingPathComponent("multi-operation"))
        var completionCount = 0
        var stagedTarget: UInt32 = 0
        var stagedSource: UInt32 = 0
        let sut = MirrorController(
            records: { self.records(current) }, operationLock: { operation },
            engine: RecoveryEngine(capture: { current }, apply: { _ in current = baseline }, convergencePause: {}),
            preflightModes: { _ in },
            transaction: MirrorTransaction(
                begin: { OpaquePointer(bitPattern: 1)! },
                stage: { _, targetID, sourceID in stagedTarget = targetID; stagedSource = sourceID },
                complete: { _, _ in
                    completionCount += 1
                    if completionCount == 2 { throw RecoveryError.unsafe("fake interrupted second Hide") }
                    active[Int(stagedTarget) - 6] = Int(stagedSource) - 6
                    current = try self.sessionSnapshot(active, includeFourth: true)
                }, cancel: { _ in XCTFail("fake public writer never has a private rollback") }
            ),
            restoreTarget: { _, targetUUID, revalidate, _ in
                try revalidate()
                guard let index = [2, 3, 4].first(where: { self.snapshotUUID($0) == targetUUID }) else {
                    throw RecoveryError.unsafe("unknown fake target")
                }
                active.removeValue(forKey: index)
                current = try self.sessionSnapshot(active, includeFourth: true)
                throw RecoveryError.unsafe("fake interrupted first Show")
            }
        )
        _ = try sut.mirror(selector: snapshotUUID(2), source: snapshotUUID(1), store: scenarioStore)
        XCTAssertThrowsError(try sut.mirror(selector: snapshotUUID(3), source: snapshotUUID(1), store: scenarioStore))
        var saved = try scenarioStore.load()
        XCTAssertEqual(saved.publicMirrorSession?.removals.first(where: { $0.targetUUID == snapshotUUID(2) })?.state, .mirrored)
        XCTAssertEqual(saved.publicMirrorSession?.removals.first(where: { $0.targetUUID == snapshotUUID(3) })?.state, .needsAttention)
        XCTAssertEqual(saved.publicMirrorSession?.baseline, baseline)

        // The second Hide left the exact pre-operation topology, so it can be
        // reconciled as untouched before a later independent Show failure.
        _ = try sut.unmirror(store: scenarioStore, selector: snapshotUUID(3))
        XCTAssertEqual(try scenarioStore.load().publicMirrorSession?.removals.last?.state, .cancelled)
        _ = try sut.mirror(selector: snapshotUUID(3), source: snapshotUUID(1), store: scenarioStore)
        XCTAssertThrowsError(try sut.unmirror(store: scenarioStore, selector: snapshotUUID(3)))
        saved = try scenarioStore.load()
        XCTAssertEqual(saved.publicMirrorSession?.removals.first(where: { $0.targetUUID == snapshotUUID(2) })?.state, .mirrored)
        XCTAssertEqual(saved.publicMirrorSession?.removals.last?.state, .needsAttention)
    }

    func testFailedFinalShowRetainsRecoveryUntilWholeBaselineVerifies() throws {
        for mismatch in ["origin", "mode"] {
            let baseline = try sessionSnapshot([:], includeFourth: true)
            var current = try sessionSnapshot([3: 1], includeFourth: true)
            var earlier = PublicMirrorRemoval(target: baseline.displays[1], source: baseline.displays[0],
                                              beforeOperation: baseline, state: .restored)
            earlier.failure = nil
            let last = PublicMirrorRemoval(target: baseline.displays[2], source: baseline.displays[0],
                                           beforeOperation: baseline, state: .mirrored)
            var journal = RecoveryJournal(snapshot: baseline, publicMirrorSession:
                PublicMirrorSession(baseline: baseline, removals: [earlier, last]))
            journal.state = .mirrored
            let scenarioStore = RecoveryStore(url: directory.appendingPathComponent("final-\(mismatch).json"))
            try scenarioStore.lock(); try scenarioStore.create(journal); scenarioStore.unlock()
            let operation = RecoveryStore(url: directory.appendingPathComponent("final-\(mismatch)-operation"))
            var repair = false
            var writes = 0
            let sut = MirrorController(
                records: { self.records(current) }, operationLock: { operation },
                engine: RecoveryEngine(capture: { current }, apply: { _ in
                    writes += 1
                    current = baseline
                    if !repair {
                        current = try self.changedSnapshot(current) { displays in
                            if mismatch == "origin" { displays[0]["y"] = 42 }
                            else {
                                var mode = displays[0]["mode"] as! [String: Any]
                                mode["refreshRate"] = 59
                                displays[0]["mode"] = mode
                            }
                        }
                    }
                }, convergencePause: {}), preflightModes: { _ in })
            XCTAssertThrowsError(try sut.unmirror(store: scenarioStore, selector: snapshotUUID(3)))
            let inspector = DisplayHideController(store: scenarioStore, mirror: sut, operationLock: { operation })
            let status = try inspector.inspect()
            XCTAssertTrue(status.hasUnresolvedRecovery)
            XCTAssertEqual(status.removals.filter(\.isUnresolved).map { $0.target.uuid }, [snapshotUUID(3)])
            XCTAssertTrue(try XCTUnwrap(status.removals.last).canShow, "final layout remains explicitly repairable")
            XCTAssertThrowsError(try sut.verifyRemoval(store: scenarioStore, selector: snapshotUUID(3)))
            XCTAssertThrowsError(try sut.verifyRemoval(store: scenarioStore, selector: snapshotUUID(2)))
            XCTAssertEqual(writes, 1, "inspection and verify never retry the writer")
            repair = true
            let repaired = try sut.unmirror(store: scenarioStore, selector: snapshotUUID(3))
            XCTAssertEqual(repaired.state, .restored)
            XCTAssertEqual(writes, 2)
            try baseline.verify(current)
            XCTAssertEqual(try sut.verifyRemoval(store: scenarioStore, selector: snapshotUUID(3)).state, .verified)
        }
    }

    func testFailedPartialShowAllowsOnlyExplicitTargetRepair() throws {
        let baseline = try changedSnapshot(sessionSnapshot([:], includeFourth: true)) { $0[1]["y"] = -4 }
        var current = try sessionSnapshot([2: 1, 3: 1], includeFourth: true)
        let removals = [2, 3].map { index in
            PublicMirrorRemoval(target: baseline.displays[index - 1], source: baseline.displays[0],
                                beforeOperation: baseline, state: .mirrored)
        }
        var journal = RecoveryJournal(snapshot: baseline, publicMirrorSession:
            PublicMirrorSession(baseline: baseline, removals: removals))
        journal.state = .mirrored
        let scenarioStore = RecoveryStore(url: directory.appendingPathComponent("partial-origin-repair.json"))
        try scenarioStore.lock(); try scenarioStore.create(journal); scenarioStore.unlock()
        let operation = RecoveryStore(url: directory.appendingPathComponent("partial-origin-operation"))
        var writes = 0
        var inputCalls = 0
        let sut = MirrorController(
            records: { self.records(current) }, operationLock: { operation },
            engine: RecoveryEngine(capture: { current }, apply: { _ in XCTFail("never restore siblings") }, convergencePause: {}),
            preflightModes: { _ in }, restoreTarget: { _, targetUUID, revalidate, _ in
                try revalidate()
                XCTAssertEqual(targetUUID, self.snapshotUUID(2))
                let siblingBefore = current.displays[2]
                writes += 1
                // macOS places the target at y=0 rather than its saved -4 both
                // times; that is accepted. The first write leaves the wrong
                // mode, which is not: do not report desktop success.
                if writes == 1 {
                    current = try self.changedSnapshot(self.sessionSnapshot([3: 1], includeFourth: true)) {
                        var mode = $0[1]["mode"] as! [String: Any]; mode["refreshRate"] = 30; $0[1]["mode"] = mode
                    }
                } else {
                    XCTAssertNil(current.displays[1].mirrorUUID)
                    current = try self.sessionSnapshot([3: 1], includeFourth: true)
                }
                XCTAssertEqual(current.displays[2], siblingBefore)
            })
        XCTAssertThrowsError(try sut.unmirror(store: scenarioStore, selector: snapshotUUID(2),
                                             returnInputBeforeRestore: { _ in inputCalls += 1 }))
        let inspector = DisplayHideController(store: scenarioStore, mirror: sut, operationLock: { operation })
        let status = try inspector.inspect()
        XCTAssertEqual(status.removals.first?.state, "needsAttention")
        XCTAssertEqual(status.removals.first?.canShow, true)
        XCTAssertThrowsError(try sut.verifyRemoval(store: scenarioStore, selector: snapshotUUID(2)))
        XCTAssertEqual(writes, 1)
        XCTAssertEqual(inputCalls, 1)
        let persisted = try XCTUnwrap(scenarioStore.load().publicMirrorSession)
        let wrongSibling = try changedSnapshot(current) { $0[2]["mirrorUUID"] = self.snapshotUUID(4) }
        XCTAssertFalse(MirrorSessionTopology.canRepairTargetLayout(
            baseline: baseline, removals: persisted.removals, targetUUID: snapshotUUID(2), current: wrongSibling))
        let wrongIdentity = try changedSnapshot(current) { $0[1]["serial"] = 999 }
        XCTAssertFalse(MirrorSessionTopology.canRepairTargetLayout(
            baseline: baseline, removals: persisted.removals, targetUUID: snapshotUUID(2), current: wrongIdentity))
        let repaired = try sut.unmirror(store: scenarioStore, selector: snapshotUUID(2),
                                        returnInputBeforeRestore: { _ in inputCalls += 1 })
        XCTAssertEqual(writes, 2, "only a separate explicit Show retries the failed target layout")
        XCTAssertEqual(inputCalls, 2, "each explicit request returns input before checking the desktop postcondition")
        XCTAssertEqual(repaired.publicMirrorSession?.removals.map(\.state), [.restored, .mirrored])
        XCTAssertEqual(current.displays[1].y, 0, "macOS placement is accepted until the last Show")
    }

    func testLastPhysicalShowRestoresBaselineWithEarlierLayoutRecoveryOutstanding() throws {
        let baseline = try changedSnapshot(sessionSnapshot([:], includeFourth: true)) { $0[1]["y"] = -4 }
        var current = try sessionSnapshot([3: 1], includeFourth: true)
        let removals = [
            PublicMirrorRemoval(target: baseline.displays[1], source: baseline.displays[0],
                                beforeOperation: baseline, state: .needsAttention),
            PublicMirrorRemoval(target: baseline.displays[2], source: baseline.displays[0],
                                beforeOperation: baseline, state: .mirrored)
        ]
        var journal = RecoveryJournal(snapshot: baseline, publicMirrorSession:
            PublicMirrorSession(baseline: baseline, removals: removals))
        journal.state = .needsAttention
        let scenarioStore = RecoveryStore(url: directory.appendingPathComponent("last-physical-show.json"))
        try scenarioStore.lock(); try scenarioStore.create(journal); scenarioStore.unlock()
        let operation = RecoveryStore(url: directory.appendingPathComponent("last-physical-operation"))
        var writes = 0
        var returnedInputs: [String] = []
        var shouldMatch = false
        let sut = MirrorController(
            records: { self.records(current) }, operationLock: { operation },
            engine: RecoveryEngine(capture: { current }, apply: { snapshot in
                XCTAssertEqual(snapshot, baseline)
                writes += 1
                let persisted = try scenarioStore.load()
                XCTAssertEqual(persisted.publicMirrorSession?.removals.first?.state, .needsAttention)
                XCTAssertEqual(persisted.publicMirrorSession?.removals.last?.state, .restoring)
                current = baseline
                if !shouldMatch { current = try self.changedSnapshot(current) { $0[1]["y"] = 0 } }
            }, convergencePause: {}), preflightModes: { _ in },
            restoreTarget: { _, _, _, _ in XCTFail("the last physical Show must verify the whole baseline") })
        XCTAssertFalse(MirrorSessionTopology.canRestoreFinalLayout(
            baseline: baseline, removals: removals, targetUUID: snapshotUUID(2), current: current),
            "must not unmirror another still-hidden target when selecting the already-separate display")
        let wrongMirror = try changedSnapshot(current) { $0[2]["mirrorUUID"] = self.snapshotUUID(4) }
        XCTAssertFalse(MirrorSessionTopology.canRestoreFinalLayout(
            baseline: baseline, removals: removals, targetUUID: snapshotUUID(3), current: wrongMirror))
        let inspector = DisplayHideController(store: scenarioStore, mirror: sut, operationLock: { operation })
        XCTAssertTrue(try XCTUnwrap(inspector.inspect().removals.last).canShow)
        XCTAssertThrowsError(try sut.unmirror(store: scenarioStore, selector: snapshotUUID(3),
                                             returnInputBeforeRestore: { returnedInputs.append($0.uuid) }))
        XCTAssertEqual(returnedInputs, [snapshotUUID(3)])
        XCTAssertTrue(try scenarioStore.load().publicMirrorSession?.removals.allSatisfy { !$0.state.resolved } == true)
        shouldMatch = true
        let result = try sut.unmirror(store: scenarioStore, selector: snapshotUUID(3),
                                      returnInputBeforeRestore: { returnedInputs.append($0.uuid) })
        XCTAssertEqual(writes, 2)
        XCTAssertEqual(result.state, .restored)
        XCTAssertTrue(result.publicMirrorSession?.removals.allSatisfy { $0.state.resolved } == true)
        XCTAssertEqual(returnedInputs, [snapshotUUID(3), snapshotUUID(3)], "never switch a sibling input without its own request")
        try baseline.verify(current)
    }

    func testUntouchedSecondHideAfterMainOriginShiftDoesNotBlockFirstShow() throws {
        let baseline = try sessionSnapshot([:], includeFourth: true)
        var current = baseline
        var commits = 0
        let operation = RecoveryStore(url: directory.appendingPathComponent("shifted-operation"))
        let scenarioStore = RecoveryStore(url: directory.appendingPathComponent("shifted-failure.json"))
        let sut = MirrorController(
            records: { self.records(current) }, operationLock: { operation },
            engine: RecoveryEngine(capture: { current }, apply: { _ in current = baseline }, convergencePause: {}),
            preflightModes: { _ in }, transaction: MirrorTransaction(
                begin: { OpaquePointer(bitPattern: 1)! }, stage: { _, _, _ in },
                complete: { _, _ in
                    commits += 1
                    if commits == 2 { throw RecoveryError.unsafe("interrupted before second mirror applied") }
                    current = try self.sessionSnapshot([1: 2], includeFourth: true)
                    current = try self.changedSnapshot(current) { displays in
                        for index in displays.indices {
                            displays[index]["x"] = (displays[index]["x"] as! Int) - 1920
                        }
                    }
                }, cancel: { _ in XCTFail("completion consumes transaction") }))
        _ = try sut.mirror(selector: snapshotUUID(1), source: snapshotUUID(2), store: scenarioStore)
        let shifted = current
        XCTAssertThrowsError(try sut.mirror(selector: snapshotUUID(3), source: snapshotUUID(2), store: scenarioStore))
        let inspector = DisplayHideController(store: scenarioStore, mirror: sut, operationLock: { operation })
        _ = try inspector.inspect()
        let saved = try scenarioStore.load()
        XCTAssertEqual(saved.publicMirrorSession?.removals.last?.state, .cancelled)
        XCTAssertEqual(current, shifted)
        XCTAssertEqual(saved.publicMirrorSession?.baseline, baseline)
        XCTAssertEqual(try sut.verifyRemoval(store: scenarioStore, selector: snapshotUUID(3)).state, .mirrored)
        let shown = try sut.unmirror(store: scenarioStore, selector: snapshotUUID(1))
        XCTAssertEqual(shown.state, .restored)
        try baseline.verify(current)
    }

    func testVerifySelectionSelfRestoreAndDisconnectPreserveOtherRemoval() throws {
        let baseline = try sessionSnapshot([:], includeFourth: true)
        var active: [Int: Int] = [:]
        var current = baseline
        var stagedTarget: UInt32 = 0
        var stagedSource: UInt32 = 0
        var writerCalls = 0
        let scenarioStore = RecoveryStore(url: directory.appendingPathComponent("verify-disconnect-session.json"))
        let operation = RecoveryStore(url: directory.appendingPathComponent("verify-disconnect-operation"))
        let sut = MirrorController(
            records: { self.records(current) }, operationLock: { operation },
            engine: RecoveryEngine(capture: { current }, apply: { _ in XCTFail("verify never applies a layout") }, convergencePause: {}),
            preflightModes: { _ in },
            transaction: MirrorTransaction(
                begin: { OpaquePointer(bitPattern: 1)! },
                stage: { _, target, source in stagedTarget = target; stagedSource = source },
                complete: { _, _ in
                    writerCalls += 1
                    active[Int(stagedTarget) - 6] = Int(stagedSource) - 6
                    current = try self.sessionSnapshot(active, includeFourth: true)
                }, cancel: { _ in XCTFail("successful fake transaction must not cancel") }
            )
        )
        _ = try sut.mirror(selector: snapshotUUID(2), source: snapshotUUID(1), store: scenarioStore)
        _ = try sut.mirror(selector: snapshotUUID(3), source: snapshotUUID(1), store: scenarioStore)
        XCTAssertEqual(writerCalls, 2)
        XCTAssertThrowsError(try sut.verifyRemoval(store: scenarioStore, selector: nil)) { error in
            XCTAssertTrue(String(describing: error).contains("several displays are removed"))
        }
        XCTAssertThrowsError(try sut.unmirror(store: scenarioStore, selector: nil)) { error in
            XCTAssertTrue(String(describing: error).contains("several displays are removed"))
        }
        XCTAssertEqual(writerCalls, 2, "ambiguous recovery requests never write")
        XCTAssertEqual(try sut.verifyRemoval(store: scenarioStore, selector: snapshotUUID(2)).state, .mirrored,
                       "verify is a no-write check; it does not Show")

        active.removeValue(forKey: 2)
        current = try sessionSnapshot(active, includeFourth: true)
        let selfRestored = try sut.verifyRemoval(store: scenarioStore, selector: snapshotUUID(2))
        XCTAssertEqual(selfRestored.publicMirrorSession?.removals.first(where: {
            $0.targetUUID == snapshotUUID(2)
        })?.state, .restored)
        XCTAssertEqual(selfRestored.publicMirrorSession?.removals.first(where: {
            $0.targetUUID == snapshotUUID(3)
        })?.state, .mirrored, "macOS resolving one display never resolves its sibling")

        current = try withoutDisplay(current, uuid: snapshotUUID(3))
        XCTAssertThrowsError(try sut.unmirror(store: scenarioStore, selector: snapshotUUID(3)))
        let disconnected = try scenarioStore.load()
        XCTAssertEqual(disconnected.publicMirrorSession?.removals.first(where: {
            $0.targetUUID == snapshotUUID(2)
        })?.state, .restored)
        XCTAssertEqual(disconnected.publicMirrorSession?.removals.first(where: {
            $0.targetUUID == snapshotUUID(3)
        })?.state, .needsAttention, "a disconnected target keeps only its own recovery-needed entry")
        XCTAssertEqual(writerCalls, 2, "verify and disconnected refusal never write a display layout")

        current = baseline
        let fullyRestored = try sut.verifyRemoval(store: scenarioStore, selector: snapshotUUID(3))
        XCTAssertEqual(fullyRestored.state, .verified)
        XCTAssertTrue(fullyRestored.publicMirrorSession?.removals.allSatisfy { $0.state == .restored } == true)
        XCTAssertEqual(writerCalls, 2, "macOS self-restoration is observed, never replayed")
    }

    func testAwayAddsBesideHealthyRemovalAndPrintsSelectedBackCommand() throws {
        let baseline = try sessionSnapshot([:], includeFourth: true)
        var active: [Int: Int] = [:]
        var current = baseline
        var stagedTarget: UInt32 = 0
        var stagedSource: UInt32 = 0
        let operation = RecoveryStore(url: directory.appendingPathComponent("away-session-operation"))
        let mirror = MirrorController(
            records: { self.records(current) }, operationLock: { operation },
            engine: RecoveryEngine(capture: { current }, apply: { _ in current = baseline }, convergencePause: {}),
            preflightModes: { _ in },
            transaction: MirrorTransaction(
                begin: { OpaquePointer(bitPattern: 1)! },
                stage: { _, target, source in stagedTarget = target; stagedSource = source },
                complete: { _, _ in
                    active[Int(stagedTarget) - 6] = Int(stagedSource) - 6
                    current = try self.sessionSnapshot(active, includeFourth: true)
                }, cancel: { _ in XCTFail("successful fake mirror must not cancel") }
            ),
            restoreTarget: { _, targetUUID, revalidate, _ in
                try revalidate()
                guard let target = [2, 3].first(where: { self.snapshotUUID($0) == targetUUID }) else {
                    throw RecoveryError.unsafe("unknown fake target")
                }
                active.removeValue(forKey: target)
                current = try self.sessionSnapshot(active, includeFourth: true)
            }
        )
        let scenarioStore = RecoveryStore(url: directory.appendingPathComponent("away-session.json"))
        _ = try mirror.mirror(selector: snapshotUUID(2), source: snapshotUUID(1), store: scenarioStore)
        var reports: [String] = []
        var handoff = HandoffController(mirror: mirror, report: { reports.append($0) })
        handoff.open = { _ in throw RecoveryError.unsafe("DDC must not open when input is omitted") }
        for selector in [snapshotUUID(3), "9", "0x9", "index:3"] {
            reports.removeAll()
            try handoff.away(selector: selector, source: snapshotUUID(1), input: nil, store: scenarioStore)
            XCTAssertTrue(reports.contains { $0.contains("panelctl back --display '\(snapshotUUID(3))'") }, selector)
            try handoff.back(selector: snapshotUUID(3), input: nil, store: scenarioStore)
        }
        try handoff.away(selector: snapshotUUID(3), source: snapshotUUID(1), input: nil, store: scenarioStore)

        let journal = try scenarioStore.load()
        XCTAssertNil(journal.mirrorTargetID, "multi-display sessions do not carry singleton compatibility selectors")
        XCTAssertEqual(journal.publicMirrorSession?.removals.filter { !$0.state.resolved }.map(\.targetUUID),
                       [snapshotUUID(2), snapshotUUID(3)])
        XCTAssertTrue(reports.contains { $0.contains("panelctl back --display '\(snapshotUUID(3))'") },
                      "away reports a back command for the target just added")
        XCTAssertEqual(active.count, 2)
        try handoff.back(selector: snapshotUUID(3), input: nil, store: scenarioStore)
        XCTAssertEqual(active.count, 1, "back Shows only its selected target")
        XCTAssertTrue(reports.contains { $0.contains("selected display shown and verified; 1 removal(s) remain hidden") })
    }

    func testDistinctSourcesAndMainTargetSurviveObservedMacRearrangement() throws {
        let baseline = try sessionSnapshot([:], includeFourth: true, originalMain: 2)
        var active: [Int: Int] = [:]
        var current = baseline
        var stagedTarget: UInt32 = 0
        var stagedSource: UInt32 = 0
        let scenarioStore = RecoveryStore(url: directory.appendingPathComponent("distinct-source-main-target.json"))
        let operation = RecoveryStore(url: directory.appendingPathComponent("distinct-operation"))
        let sut = MirrorController(
            records: { self.records(current) }, operationLock: { operation },
            engine: RecoveryEngine(
                capture: { current },
                apply: { _ in active.removeAll(); current = baseline },
                convergencePause: {}
            ),
            preflightModes: { _ in },
            transaction: MirrorTransaction(
                begin: { OpaquePointer(bitPattern: 1)! },
                stage: { _, target, source in stagedTarget = target; stagedSource = source },
                complete: { _, _ in
                    active[Int(stagedTarget) - 6] = Int(stagedSource) - 6
                    current = try self.sessionSnapshot(active, includeFourth: true, originalMain: 2)
                    // macOS is allowed to move the menu bar and survivor origins
                    // when the first (main) display joins a mirror set.
                    if active[2] != nil {
                        current = try self.changedSnapshot(current) { displays in
                            displays[0]["main"] = false
                            displays[2]["main"] = true
                            displays[3]["x"] = 7200
                        }
                    }
                },
                cancel: { _ in XCTFail("successful fake transaction must not cancel") }
            ),
            restoreTarget: { _, targetUUID, revalidate, _ in
                try revalidate()
                guard let target = [2, 4].first(where: { self.snapshotUUID($0) == targetUUID }) else {
                    throw RecoveryError.unsafe("unknown fake target")
                }
                active.removeValue(forKey: target)
                current = try self.sessionSnapshot(active, includeFourth: true, originalMain: 2)
            }
        )
        _ = try sut.mirror(selector: snapshotUUID(2), source: snapshotUUID(1), store: scenarioStore)
        _ = try sut.mirror(selector: snapshotUUID(4), source: snapshotUUID(3), store: scenarioStore)
        XCTAssertEqual(try scenarioStore.load().publicMirrorSession?.removals.map(\.sourceUUID),
                       [snapshotUUID(1), snapshotUUID(3)])
        XCTAssertTrue(MirrorSessionTopology.matches(
            baseline: baseline,
            removals: try XCTUnwrap(scenarioStore.load().publicMirrorSession?.removals), current: current
        ), "observed macOS origin/main rearrangement remains a verified hidden session")

        _ = try sut.unmirror(store: scenarioStore, selector: snapshotUUID(4))
        XCTAssertEqual(current.displays.first(where: { $0.uuid == snapshotUUID(4) })?.active, true)
        XCTAssertEqual(try scenarioStore.load().publicMirrorSession?.removals.first(where: {
            $0.targetUUID == snapshotUUID(2)
        })?.state, .mirrored)
        let final = try sut.unmirror(store: scenarioStore, selector: snapshotUUID(2))
        XCTAssertEqual(current, baseline, "final Show strictly restores the original main, modes and arrangement")
        XCTAssertEqual(final.state, .restored)
    }

    func testPartialShowPlacementSurvivesAnotherHideAndFinalShowIsExact() throws {
        // Display 2 is saved four points above the main display's top edge;
        // macOS places it at y=0 whenever it returns while 3 is still removed.
        let baseline = try changedSnapshot(sessionSnapshot([:])) { $0[1]["y"] = -4 }
        var active: [Int: Int] = [:]
        var current = baseline
        var staged: (UInt32, UInt32) = (0, 0)
        var fullRestores = 0
        func layout() throws -> RecoverySnapshot {
            try changedSnapshot(sessionSnapshot(active)) { if active[2] == nil { $0[1]["y"] = 0 } }
        }
        let scenarioStore = RecoveryStore(url: directory.appendingPathComponent("placement-rehide.json"))
        let operation = RecoveryStore(url: directory.appendingPathComponent("placement-operation"))
        let sut = MirrorController(
            records: { self.records(current) }, operationLock: { operation },
            engine: RecoveryEngine(capture: { current }, apply: { snapshot in
                XCTAssertEqual(snapshot, baseline)
                fullRestores += 1
                active.removeAll()
                current = baseline
            }, convergencePause: {}),
            preflightModes: { _ in },
            transaction: MirrorTransaction(
                begin: { OpaquePointer(bitPattern: 1)! },
                stage: { _, target, source in staged = (target, source) },
                complete: { _, _ in
                    active[Int(staged.0) - 6] = Int(staged.1) - 6
                    current = try layout()
                }, cancel: { _ in XCTFail("successful fake transaction must not cancel") }),
            restoreTarget: { _, targetUUID, revalidate, _ in
                try revalidate()
                let target = try XCTUnwrap([2, 3].first { self.snapshotUUID($0) == targetUUID })
                active.removeValue(forKey: target)
                current = try layout()
            })
        var inputs: [String] = []
        _ = try sut.mirror(selector: snapshotUUID(2), source: snapshotUUID(1), store: scenarioStore)
        _ = try sut.mirror(selector: snapshotUUID(3), source: snapshotUUID(1), store: scenarioStore)
        _ = try sut.unmirror(store: scenarioStore, selector: snapshotUUID(2), returnInputBeforeRestore: { inputs.append($0.uuid) })
        XCTAssertEqual(current.displays[1].y, 0)
        XCTAssertEqual(inputs, [snapshotUUID(2)])
        // The placed display is an ordinary visible display: inspection keeps
        // the session healthy and it can be removed again.
        let inspector = DisplayHideController(store: scenarioStore, mirror: sut, operationLock: { operation })
        XCTAssertFalse(try inspector.inspect().removals.contains { $0.state == "needsAttention" })
        _ = try sut.mirror(selector: snapshotUUID(2), source: snapshotUUID(1), store: scenarioStore)
        _ = try sut.unmirror(store: scenarioStore, selector: snapshotUUID(3), returnInputBeforeRestore: { inputs.append($0.uuid) })
        XCTAssertEqual(fullRestores, 0)
        let final = try sut.unmirror(store: scenarioStore, selector: snapshotUUID(2), returnInputBeforeRestore: { inputs.append($0.uuid) })
        XCTAssertEqual(fullRestores, 1, "the last Show stages the whole baseline")
        XCTAssertEqual(final.state, .restored)
        XCTAssertEqual(current, baseline, "the original -4 origin returns only with the final Show")
        XCTAssertEqual(inputs, [snapshotUUID(2), snapshotUUID(3), snapshotUUID(2)])
    }

    func testMainTargetMirrorsWhenTargetSourceOrAnotherDisplayRemainsMain() throws {
        let original = try snapshot { displays in
            displays[0]["main"] = true
            displays[1]["main"] = false
        }
        let targetUUID = snapshotUUID(1)
        let sourceUUID = snapshotUUID(2)
        for currentMainID in [UInt32(7), UInt32(8), UInt32(9)] {
            let hidden = try snapshot { displays in
                displays[0]["main"] = currentMainID == 7
                displays[1]["main"] = currentMainID == 8
                displays[2]["main"] = currentMainID == 9
                displays[0]["mirrorUUID"] = sourceUUID
                displays[0]["active"] = false
            }
            let scenarioStore = RecoveryStore(url: directory.appendingPathComponent("main-\(currentMainID).json"))
            var current = original
            var sut = controller(original)
            sut.engine.capture = { current }
            sut.transaction = MirrorTransaction(
                begin: { OpaquePointer(bitPattern: 1)! },
                stage: { _, target, source in
                    XCTAssertEqual(target, 7)
                    XCTAssertEqual(source, 8)
                },
                complete: { _, _ in current = hidden },
                cancel: { _ in XCTFail("successful mirror must consume the fake transaction") }
            )
            let result = try sut.mirror(selector: targetUUID, source: sourceUUID, store: scenarioStore)
            XCTAssertEqual(result.state, .mirrored, "CGMainDisplayID result ID \(currentMainID)")
            XCTAssertTrue(HiddenMirrorTopology.matches(
                snapshot: original, targetID: 7, sourceID: 8, current: current
            ))
        }
    }

    func testNonMainHideRefusesWhenMacMovesMainAndSessionKeepsOriginalMain() throws {
        let baseline = try sessionSnapshot([:])
        let movedMain = try changedSnapshot(sessionSnapshot([2: 3])) { displays in
            displays[0]["main"] = false
            displays[2]["main"] = true
        }
        var current = baseline
        var sut = controller(baseline)
        sut.engine.capture = { current }
        sut.transaction = MirrorTransaction(
            begin: { OpaquePointer(bitPattern: 1)! }, stage: { _, _, _ in },
            complete: { _, _ in current = movedMain },
            cancel: { _ in XCTFail("completion consumes the fake transaction") }
        )
        XCTAssertThrowsError(try sut.mirror(selector: snapshotUUID(2), source: snapshotUUID(3), store: store))
        let saved = try store.load()
        XCTAssertEqual(saved.state, .needsAttention)
        XCTAssertEqual(saved.publicMirrorSession?.removals.first?.state, .needsAttention)
        let removals = try XCTUnwrap(saved.publicMirrorSession?.removals)
        XCTAssertFalse(MirrorSessionTopology.matches(baseline: baseline, removals: removals, current: movedMain),
                       "main may move only while the original main display is removed")
        XCTAssertTrue(MirrorSessionTopology.matches(baseline: baseline, removals: removals,
                                                    current: try sessionSnapshot([2: 3])))

        // With the original main removed, a later non-main Hide still must not move main.
        let mainRemovedBaseline = try sessionSnapshot([:], includeFourth: true, originalMain: 2)
        var active: [Int: Int] = [:]
        var staged: (UInt32, UInt32) = (0, 0)
        let scenarioStore = RecoveryStore(url: directory.appendingPathComponent("main-removed-then-moved.json"))
        current = mainRemovedBaseline
        sut = controller(mainRemovedBaseline)
        sut.records = { self.records(current) }
        sut.engine.capture = { current }
        sut.transaction = MirrorTransaction(
            begin: { OpaquePointer(bitPattern: 1)! }, stage: { _, target, source in staged = (target, source) },
            complete: { _, _ in
                active[Int(staged.0) - 6] = Int(staged.1) - 6
                current = try self.sessionSnapshot(active, includeFourth: true, originalMain: 2)
                if active[3] != nil {
                    current = try self.changedSnapshot(current) { displays in
                        displays[0]["main"] = false
                        displays[3]["main"] = true
                    }
                }
            },
            cancel: { _ in XCTFail("completion consumes the fake transaction") }
        )
        _ = try sut.mirror(selector: snapshotUUID(2), source: snapshotUUID(1), store: scenarioStore)
        XCTAssertThrowsError(try sut.mirror(selector: snapshotUUID(3), source: snapshotUUID(1), store: scenarioStore))
        let entries = try XCTUnwrap(scenarioStore.load().publicMirrorSession?.removals)
        XCTAssertEqual(entries.map(\.state), [.mirrored, .needsAttention])
    }

    func testRecoveryRestoreRestoresOriginalMainAndMismatchKeepsManualGuidance() throws {
        let original = try snapshot { displays in
            displays[0]["main"] = false
            displays[1]["main"] = true
        }
        let hidden = try snapshot { displays in
            displays[0]["main"] = false
            displays[1]["main"] = false
            displays[2]["main"] = true
            displays[1]["mirrorUUID"] = snapshotUUID(1)
            displays[1]["active"] = false
        }

        func makeJournal(_ path: String) throws -> (RecoveryStore, RecoveryJournal) {
            let store = RecoveryStore(url: directory.appendingPathComponent(path))
            try store.lock()
            var journal = RecoveryJournal(snapshot: original)
            journal.mirrorTargetID = 8
            journal.mirrorSourceID = 7
            journal.state = .mirrored
            try store.create(journal)
            journal = try store.load()
            return (store, journal)
        }

        let (restoreStore, restoreJournal) = try makeJournal("recovery-main-restore.json")
        defer { restoreStore.unlock() }
        var restoredTopology = hidden
        var writes = 0
        let restoreEngine = RecoveryEngine(
            capture: { restoredTopology },
            apply: { captured in writes += 1; restoredTopology = captured },
            convergencePause: {}
        )
        var journalToRestore = restoreJournal
        try restoreEngine.finish(&journalToRestore, store: restoreStore, verifyOnly: false, trigger: "manual-restore")
        XCTAssertEqual(try restoreStore.load().state, .restored)
        XCTAssertEqual(writes, 1)
        XCTAssertNoThrow(try original.verify(restoredTopology))
        XCTAssertEqual(restoredTopology.displays.first(where: { $0.id == 8 })?.main, true)

        let (mismatchStore, mismatchJournal) = try makeJournal("recovery-main-mismatch.json")
        defer { mismatchStore.unlock() }
        let mismatchedTopology = hidden
        let mismatchEngine = RecoveryEngine(
            capture: { mismatchedTopology },
            apply: { _ in writes += 1 },
            convergencePause: {}
        )
        var journalToMismatch = mismatchJournal
        XCTAssertThrowsError(try mismatchEngine.finish(
            &journalToMismatch, store: mismatchStore, verifyOnly: false, trigger: "manual-restore"
        )) { error in
            XCTAssertTrue(error.localizedDescription.contains("turn off mirroring"), error.localizedDescription)
            XCTAssertTrue(error.localizedDescription.contains("drag the menu bar"), error.localizedDescription)
        }
        let failed = try mismatchStore.load()
        XCTAssertEqual(failed.state, .needsAttention)
        XCTAssertEqual(failed.snapshot, original)
        XCTAssertTrue(failed.failure?.contains("turn off mirroring") == true)
        XCTAssertTrue(failed.failure?.contains("drag the menu bar") == true)
        XCTAssertEqual(writes, 2)
        XCTAssertNotEqual(mismatchedTopology, original)
    }

    func testRefusesBuiltinInactiveSameMissingAndAmbiguousTargets() throws {
        let original = try snapshot()
        for (target, source) in [("8", "8"), ("missing", "7"), ("8", "missing")] {
            XCTAssertThrowsError(try controller(original).mirror(selector: target, source: source, store: store))
        }
        for (key, value): (String, Any) in [("builtin", true), ("active", false)] {
            let bad = try snapshot { $0[1][key] = value }
            XCTAssertThrowsError(try controller(bad).mirror(selector: "8", source: "7", store: store))
        }
        var missingIdentity = controller(original)
        missingIdentity.records = {
            self.records(original).map { record in
                guard record.id == self.targetID else { return record }
                return DisplayRecord(index: record.index, id: record.id, uuid: nil, name: record.name,
                    active: record.active, online: record.online, asleep: record.asleep,
                    builtin: record.builtin, main: record.main, vendor: record.vendor,
                    model: record.model, serial: record.serial, bounds: record.bounds,
                    pixelWidth: record.pixelWidth, pixelHeight: record.pixelHeight)
            }
        }
        XCTAssertThrowsError(try missingIdentity.mirror(selector: "8", source: "7", store: store))
        var ambiguous = controller(original)
        ambiguous.records = { self.records(original) + self.records(original).suffix(1) }
        XCTAssertThrowsError(try ambiguous.mirror(selector: "8", source: "7", store: store))
        XCTAssertFalse(try store.exists())
    }

    func testRefusesExistingMirrorsIncludingUnrelatedGroupAndChangedSelection() throws {
        for index in [1, 2] {
            let bad = try snapshot { $0[index]["mirrorUUID"] = sourceUUID }
            XCTAssertThrowsError(try controller(bad).mirror(selector: "8", source: "7", store: store))
        }
        let original = try snapshot()
        var sut = controller(original)
        sut.engine.capture = { try self.snapshot { $0[1]["serial"] = 100 } }
        XCTAssertThrowsError(try sut.mirror(selector: "8", source: "7", store: store))
        XCTAssertFalse(try store.exists())
    }

    func testModeAndCaptureFailuresPreventJournalingAndWriting() throws {
        var sut = controller(try snapshot())
        sut.preflightModes = { _ in throw RecoveryError.unsafe("mode unavailable") }
        XCTAssertThrowsError(try sut.mirror(selector: "8", source: "7", store: store))
        XCTAssertFalse(try store.exists())
        sut.engine.capture = { throw RecoveryError.unsafe("capture failed") }
        XCTAssertThrowsError(try sut.mirror(selector: "8", source: "7", store: store))
        XCTAssertFalse(try store.exists())
    }

    func testUnresolvedAndUnsafeJournalPreventAnyTransaction() throws {
        let original = try snapshot()
        let saved = try journal(original)
        XCTAssertThrowsError(try controller(original).mirror(selector: "8", source: "7", store: store))
        XCTAssertEqual(try store.load().id, saved.id)
        // A new capture cannot be acknowledged if its journal cannot be created.
        let invalid = RecoveryStore(url: directory.appendingPathComponent("missing/current.json"))
        try FileManager.default.createDirectory(at: invalid.url, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        XCTAssertThrowsError(try controller(original).mirror(selector: "8", source: "7", store: invalid))
    }

    func testTransactionFailureCleanupAndBoundaryInvalidation() throws {
        for failure in ["before", "begin", "stage", "boundary", "complete", "none"] {
            var events: [String] = []
            var checks = 0
            func fail(_ point: String) throws {
                if failure == point { throw RecoveryError.unsafe(point) }
            }
            let tx = MirrorTransaction(begin: {
                events.append("begin"); try fail("begin"); return OpaquePointer(bitPattern: 1)!
            }, stage: { _, _, _ in events.append("stage"); try fail("stage") },
            complete: { _, scope in
                XCTAssertEqual(scope, .forSession); events.append("complete"); try fail("complete")
            }, cancel: { _ in events.append("cancel") })
            let apply = {
                try tx.apply(target: 8, source: 7) {
                    checks += 1
                    try fail(checks == 1 ? "before" : "boundary")
                }
            }
            if failure == "none" { XCTAssertNoThrow(try apply()) }
            else { XCTAssertThrowsError(try apply()) }
            XCTAssertEqual(events.contains("cancel"), failure == "stage" || failure == "boundary", failure)
            XCTAssertEqual(events.contains("complete"), failure == "complete" || failure == "none", failure)
        }
    }

    func testPostJournalFailuresKeepSnapshotAndReportFallback() throws {
        for failure in ["stage", "commit", "verification"] {
            // Each case has its own store; unresolved evidence must not be replaced.
            let store = RecoveryStore(url: directory.appendingPathComponent("\(failure).json"))
            let original = try snapshot()
            var sut = controller(original)
            var cancels = 0
            sut.transaction = MirrorTransaction(begin: { OpaquePointer(bitPattern: 1)! },
                stage: { _, _, _ in if failure == "stage" { throw RecoveryError.unsafe("stage") } },
                complete: { _, _ in if failure == "commit" { throw RecoveryError.unsafe("commit") } },
                cancel: { _ in cancels += 1 })
            XCTAssertThrowsError(try sut.mirror(selector: "8", source: "7", store: store)) {
                XCTAssertTrue(String(describing: $0).contains("panelctl recovery restore --journal"))
            }
            XCTAssertEqual(cancels, failure == "stage" ? 1 : 0)
            XCTAssertEqual(try store.load().state, .needsAttention)
            XCTAssertEqual(try store.load().snapshot, original)
            XCTAssertNotNil(try store.load().failure)
        }
    }

    func testUnmirrorRestoresExactSnapshotAndVerifiesWithoutPrivateWriter() throws {
        let original = try snapshot()
        var current = try snapshot {
            $0[1]["mirrorUUID"] = sourceUUID; $0[1]["active"] = false
            $0[1]["x"] = 0
            var mode = $0[0]["mode"] as! [String: Any]; mode["refreshRate"] = 30; $0[0]["mode"] = mode
        }
        let saved = try journal(original)
        var writes = 0
        var sut = controller(original)
        sut.engine.capture = { current }
        sut.engine.apply = { snapshot in
            writes += 1
            XCTAssertEqual(try self.store.load().state, .restoring)
            XCTAssertEqual(snapshot, original)
            current = snapshot
        }
        let result = try sut.unmirror(store: store)
        XCTAssertEqual(result.id, saved.id)
        XCTAssertEqual(result.state, .restored)
        XCTAssertEqual(writes, 1)
        XCTAssertNoThrow(try original.verify(current))
        _ = try sut.unmirror(store: store)
        XCTAssertEqual(writes, 1, "resolved journals only verify")
    }

    func testUnmirrorFailuresKeepJournalAndDoNotRepeatWriter() throws {
        for failure in ["apply", "verify", "identity"] {
            let original = try snapshot()
            let store = RecoveryStore(url: directory.appendingPathComponent("\(failure).json"))
            try store.lock()
            var journal = RecoveryJournal(snapshot: original)
            journal.mirrorTargetID = 8; journal.mirrorSourceID = 7
            try store.create(journal); store.unlock()
            let current = try snapshot {
                $0[1]["mirrorUUID"] = sourceUUID
                if failure == "identity" { $0[1]["serial"] = 99 }
            }
            var writes = 0
            var sut = controller(original)
            sut.engine.capture = { current }
            sut.engine.apply = { _ in
                writes += 1
                if failure == "apply" { throw RecoveryError.unsafe("restore failed") }
            }
            XCTAssertThrowsError(try sut.unmirror(store: store)) {
                XCTAssertTrue(String(describing: $0).contains("panelctl recovery restore --journal"))
            }
            XCTAssertEqual(writes, failure == "identity" ? 0 : 1)
            XCTAssertEqual(try store.load().snapshot, original)
            XCTAssertEqual(try store.load().state, .needsAttention)
        }
    }

    func testUnmirrorRejectsUnrelatedJournalAndMalformedMirrorIntent() throws {
        let original = try snapshot()
        try store.lock()
        let unrelated = RecoveryJournal(snapshot: original)
        try store.create(unrelated); store.unlock()
        XCTAssertThrowsError(try controller(original).unmirror(store: store))
        XCTAssertEqual(try store.load().state, .captured)
        var mainTarget = unrelated
        mainTarget.mirrorTargetID = 7; mainTarget.mirrorSourceID = 8
        XCTAssertNoThrow(try mainTarget.validate(), "an external main target is valid public mirror intent")
        for ids: (UInt32?, UInt32?) in [(8, nil), (nil, 7), (8, 8), (8, 99)] {
            var invalid = unrelated
            invalid.mirrorTargetID = ids.0; invalid.mirrorSourceID = ids.1
            XCTAssertThrowsError(try invalid.validate())
        }
        var invalid = unrelated
        invalid.state = .mirrored
        XCTAssertThrowsError(try invalid.validate())
    }

    func testHandoffOrderingSkipsAndFailures() throws {
        for scenario in ["success", "no-input", "no-ddc", "zero-input", "wrong-ddc-target", "unverified",
                         "away-ddc-failure", "back-ddc-failure", "hide-failure", "unhide-failure", "journal-failure",
                         "pre-read-failure", "readback-failure"] {
            let store = RecoveryStore(url: directory.appendingPathComponent("\(scenario).json"))
            let original = try snapshot()
            let mirrored = try snapshot { $0[1]["mirrorUUID"] = sourceUUID; $0[1]["active"] = false }
            var current = original
            var events: [String] = []
            var messages: [String] = []
            var returning = false
            var input: UInt16 = 15
            var reads = 0
            var sut = HandoffController(mirror: controller(original))
            sut.mirror.records = { self.records(current) }
            sut.mirror.engine.capture = { current }
            sut.mirror.engine.apply = { saved in
                events.append("unhide")
                if scenario == "unhide-failure" { throw RecoveryError.unsafe("unhide failed") }
                current = saved
            }
            sut.mirror.transaction = MirrorTransaction(begin: {
                events.append("hide")
                XCTAssertEqual(try store.load().snapshot, original)
                if scenario == "hide-failure" { throw RecoveryError.unsafe("hide failed") }
                return OpaquePointer(bitPattern: 1)!
            }, stage: { _, _, _ in }, complete: { _, _ in current = mirrored }, cancel: { _ in })
            sut.report = { message in
                messages.append(message)
                if message.hasPrefix("To reverse input selection:") { events.append("recovery-command") }
            }
            sut.open = { uuid in
                events.append("open")
                XCTAssertEqual(uuid, original.displays[1].uuid)
                XCTAssertEqual(try store.load().snapshot, original, "journal precedes DDC")
                if scenario == "no-ddc" { throw RecoveryError.unsafe("no DDC") }
                return (DDC.DisplayTarget(id: scenario == "wrong-ddc-target" ? 99 : 8, uuid: uuid),
                        DDCChannel(getVCP: { code in
                            XCTAssertEqual(code, 0x60)
                            events.append("read")
                            reads += 1
                            if scenario == "pre-read-failure" || (scenario == "readback-failure" && reads > 1) {
                                throw RecoveryError.unsafe("read unavailable")
                            }
                            return (scenario == "zero-input" ? 0 : input, 0)
                        }, setVCP: { code, value in
                            XCTAssertEqual(code, 0x60)
                            events.append(returning ? "back-input" : "away-input")
                            if scenario == (returning ? "back-ddc-failure" : "away-ddc-failure") {
                                throw RecoveryError.unsafe("DDC failed")
                            }
                            input = value
                        }))
            }
            sut.select = { value, channel, id, uuid, originalInput in
                if scenario == "unverified" {
                    try channel.setVCP(0x60, UInt16(value))
                    return DDCInputSelection(displayID: id, uuid: uuid, original: originalInput,
                                             requested: value, observed: nil, outcome: .unverified, detail: "readback lost")
                }
                return try DDCInput.select(value, channel: channel, displayID: id, uuid: uuid, original: originalInput, readOriginal: false, polls: 1, pause: { _ in })
            }
            if scenario == "journal-failure" {
                try FileManager.default.createDirectory(at: store.url, withIntermediateDirectories: false,
                                                       attributes: [.posixPermissions: 0o700])
            }
            let away = { try sut.away(selector: "8", source: "7", input: scenario == "no-input" ? nil : 17, store: store) }
            if ["away-ddc-failure", "hide-failure", "journal-failure", "wrong-ddc-target"].contains(scenario) {
                XCTAssertThrowsError(try away()) { error in
                    let message = String(describing: error)
                    if scenario == "wrong-ddc-target" {
                        XCTAssertTrue(message.contains("DDC target identity changed"))
                        XCTAssertFalse(message.contains("panelctl ddc-input --display"))
                        XCTAssertTrue(message.contains("panelctl recovery restore --journal"))
                    } else if scenario != "journal-failure" {
                        XCTAssertTrue(message.contains("panelctl ddc-input --display"))
                        XCTAssertTrue(message.contains("panelctl recovery restore --journal"))
                    }
                }
                XCTAssertFalse(events.contains("hide") && ["away-ddc-failure", "wrong-ddc-target"].contains(scenario))
                if scenario == "journal-failure" { XCTAssertTrue(events.isEmpty) }
                continue
            }
            try away()
            XCTAssertEqual(try store.load().state, .mirrored)
            let skipped = ["no-input", "no-ddc", "zero-input", "pre-read-failure"].contains(scenario)
            if skipped {
                XCTAssertFalse(events.contains("away-input"))
                XCTAssertTrue(messages.contains { $0.contains("use the monitor's input button") })
            } else {
                XCTAssertLessThan(try XCTUnwrap(events.firstIndex(of: "recovery-command")), try XCTUnwrap(events.firstIndex(of: "away-input")))
                XCTAssertLessThan(try XCTUnwrap(events.firstIndex(of: "away-input")), try XCTUnwrap(events.firstIndex(of: "hide")))
            }
            if scenario == "readback-failure" {
                XCTAssertEqual(events.filter { $0 == "away-input" }.count, 1)
                XCTAssertEqual(reads, 2, "one pre-read and one readback")
                XCTAssertTrue(messages.contains { $0.contains("Input switch is unverified") })
            }
            returning = true
            reads = 0
            events = []
            let back = { try sut.back(selector: "8", input: scenario == "no-input" ? nil : 15, store: store) }
            if ["back-ddc-failure", "unhide-failure"].contains(scenario) {
                XCTAssertThrowsError(try back()) { error in
                    if scenario == "back-ddc-failure" {
                        XCTAssertTrue(String(describing: error).contains("panelctl ddc-input --display"))
                    } else {
                        XCTAssertTrue(String(describing: error).contains("panelctl recovery restore --journal"))
                    }
                }
            } else { try back() }
            XCTAssertEqual(events.first, scenario == "no-input" ? "unhide" : "open", scenario)
            XCTAssertEqual(events.last, "unhide", "desktop restoration must follow the optional input return")
            if scenario == "unhide-failure" {
                XCTAssertEqual(events.filter { $0 == "back-input" }.count, 1, "input is not retried when restore fails")
                XCTAssertEqual(try store.load().state, .needsAttention)
            } else {
                XCTAssertEqual(current, original)
                XCTAssertEqual(try store.load().state, .restored)
            }
            if scenario == "no-input" { XCTAssertEqual(events, ["unhide"]) }
            if scenario == "unverified" { XCTAssertTrue(messages.contains { $0.contains("Input switch is unverified") }) }
        }
    }

    func testGuardedAppHandoffReportsStructuredInputWithoutDroppingIdentityGuards() throws {
        func fixture(_ name: String) throws -> (DisplayHideController, RecoveryStore, EventLog, (Bool) -> Void) {
            let operationStore = RecoveryStore(url: directory.appendingPathComponent("\(name)-operation"))
            let operationEvents = EventLog()
            let store = RecoveryStore(url: directory.appendingPathComponent("\(name).json"))
            let original = try snapshot()
            let mirrored = try snapshot { $0[1]["mirrorUUID"] = self.sourceUUID; $0[1]["active"] = false }
            var current = original
            var returning = false
            var sut = HandoffController(mirror: controller(original), report: { _ in })
            sut.mirror.records = { self.records(current) }
            sut.mirror.operationLock = { operationStore }
            sut.mirror.engine.capture = { current }
            sut.mirror.engine.apply = { saved in
                operationEvents.values.append("restore")
                current = saved
            }
            sut.mirror.transaction = MirrorTransaction(
                begin: {
                    operationEvents.values.append("hide")
                    XCTAssertTrue(FileManager.default.fileExists(atPath: store.url.path))
                    return OpaquePointer(bitPattern: 1)!
                },
                stage: { _, _, _ in },
                complete: { _, _ in current = mirrored },
                cancel: { _ in XCTFail("successful fake mirror must consume the transaction") }
            )
            sut.open = { uuid in
                operationEvents.values.append("open")
                XCTAssertEqual(uuid, self.snapshotUUID(2))
                XCTAssertTrue(FileManager.default.fileExists(atPath: store.url.path), "the recovery journal must precede DDC")
                if name == "no-ddc" { throw RecoveryError.unsafe("fake DDC unavailable") }
                let displayID: UInt32 = name == "stale-target" ? 99 : self.targetID
                return (DDC.DisplayTarget(id: displayID, uuid: uuid), DDCChannel(
                    getVCP: { code in
                        XCTAssertEqual(code, 0x60)
                        operationEvents.values.append("read")
                        return (15, 0)
                    },
                    setVCP: { code, _ in
                        XCTAssertEqual(code, 0x60)
                        operationEvents.values.append("input-write-\(returning ? "show" : "hide")")
                    }
                ))
            }
            sut.select = { value, channel, id, uuid, originalInput in
                if name == "away-write-failure" && !returning || name == "show-write-failure" && returning {
                    throw RecoveryError.unsafe("fake DDC write failure")
                }
                try channel.setVCP(DDCInput.inputVCP, UInt16(value))
                let outcome: DDCInputSelection.Outcome = name == "unverified" && !returning ? .unverified : .verified
                return DDCInputSelection(displayID: id, uuid: uuid, original: originalInput,
                                         requested: value, observed: outcome == .verified ? value : nil,
                                         outcome: outcome, detail: outcome == .unverified ? "fake readback unavailable" : nil)
            }
            let backend = DisplayHideController(
                store: store,
                mirror: sut.mirror,
                operationLock: { operationStore },
                handoff: sut
            )
            return (backend, store, operationEvents, { returning = $0 })
        }

        for scenario in ["verified", "no-ddc", "unverified", "no-input"] {
            let (backend, scenarioStore, events, setReturning) = try fixture(scenario)
            let outcome = try backend.hide(
                target: DisplayHideIdentity(uuid: snapshotUUID(2), displayID: targetID, name: "Target", vendor: 1, model: 2, serial: 2),
                source: DisplayHideIdentity(uuid: sourceUUID, displayID: sourceID, name: "Source", vendor: 1, model: 1, serial: 1),
                awayInput: scenario == "no-input" ? nil : 17
            )
            XCTAssertEqual(try scenarioStore.load().state, .mirrored)
            switch scenario {
            case "verified":
                XCTAssertEqual(outcome.state, .verified)
                XCTAssertLessThan(try XCTUnwrap(events.values.firstIndex(of: "open")), try XCTUnwrap(events.values.firstIndex(of: "hide")))
            case "no-ddc":
                XCTAssertEqual(outcome.state, .skipped)
                XCTAssertTrue(outcome.detail?.contains("monitor's input button") == true)
                XCTAssertTrue(events.values.contains("hide"))
            case "unverified":
                XCTAssertEqual(outcome.state, .unverified)
                XCTAssertEqual(outcome.observedInput, nil)
                XCTAssertTrue(events.values.contains("hide"))
            default:
                XCTAssertEqual(outcome.state, .notRequested)
                XCTAssertFalse(events.values.contains("open"))
            }
            setReturning(false)
        }

        for scenario in ["away-write-failure", "stale-target"] {
            let (backend, scenarioStore, events, _) = try fixture(scenario)
            XCTAssertThrowsError(try backend.hide(
                target: DisplayHideIdentity(uuid: snapshotUUID(2), displayID: targetID, name: "Target", vendor: 1, model: 2, serial: 2),
                source: DisplayHideIdentity(uuid: sourceUUID, displayID: sourceID, name: "Source", vendor: 1, model: 1, serial: 1),
                awayInput: 17
            )) { error in
                let failure = error as? DisplayHandoffOperationFailure
                XCTAssertNotNil(failure)
                XCTAssertEqual(failure?.inputOutcome.state, .failed)
                XCTAssertTrue(failure?.message.contains("panelctl recovery restore --journal") == true)
                if scenario == "away-write-failure" {
                    XCTAssertTrue(failure?.inputOutcome.recoveryCommand?.contains("panelctl ddc-input --display") == true)
                } else {
                    XCTAssertTrue(failure?.inputOutcome.detail?.contains("identity changed since capture") == true)
                    XCTAssertNil(failure?.inputOutcome.recoveryCommand)
                }
            }
            XCTAssertEqual(try scenarioStore.load().state, .needsAttention)
            XCTAssertFalse(events.values.contains("hide"), "unsafe or failed DDC selection must stop before topology mutation")
            if scenario == "stale-target" { XCTAssertFalse(events.values.contains("read")) }
        }

        let (backend, scenarioStore, events, setReturning) = try fixture("show-write-failure")
        let hiddenOutcome = try backend.hide(
            target: DisplayHideIdentity(uuid: snapshotUUID(2), displayID: targetID, name: "Target", vendor: 1, model: 2, serial: 2),
            source: DisplayHideIdentity(uuid: sourceUUID, displayID: sourceID, name: "Source", vendor: 1, model: 1, serial: 1)
        )
        XCTAssertEqual(hiddenOutcome.state, .notRequested)
        let journalID = try scenarioStore.load().id.uuidString
        setReturning(true)
        let returnOutcome = try backend.show(expectedJournalID: journalID, returnInput: 15)
        XCTAssertEqual(returnOutcome.state, .failed)
        XCTAssertTrue(returnOutcome.recoveryCommand?.contains("panelctl ddc-input --display") == true)
        XCTAssertEqual(try scenarioStore.load().state, .restored, "optional DDC failure cannot replay a subsequently verified desktop restore")
        XCTAssertLessThan(try XCTUnwrap(events.values.lastIndex(of: "open")), try XCTUnwrap(events.values.firstIndex(of: "restore")))

        let opensBeforeDuplicateShow = events.values.filter { $0 == "open" }.count
        let duplicateOutcome = try backend.show(expectedJournalID: journalID, returnInput: 15)
        XCTAssertEqual(duplicateOutcome.state, .notAttempted)
        XCTAssertTrue(duplicateOutcome.detail?.contains("journal was already resolved") == true)
        XCTAssertEqual(events.values.filter { $0 == "open" }.count, opensBeforeDuplicateShow,
                       "resolved-journal app Show must not reopen DDC after an earlier input failure")
        XCTAssertEqual(try scenarioStore.load().state, .restored)
    }

    func testExplicitShowVerifiesDesktopAfterInputReturnEvenWhenModesWereAvailable() throws {
        let original = try snapshot()
        let mirrored = try snapshot { $0[1]["mirrorUUID"] = self.sourceUUID; $0[1]["active"] = false }
        var current = original
        var sut = HandoffController(mirror: controller(original), report: { _ in })
        sut.mirror.records = { self.records(current) }
        sut.mirror.engine.capture = { current }
        sut.mirror.engine.apply = { current = $0 }
        sut.mirror.transaction = MirrorTransaction(
            begin: { OpaquePointer(bitPattern: 1)! }, stage: { _, _, _ in },
            complete: { _, _ in current = mirrored }, cancel: { _ in })
        try sut.away(selector: "8", source: "7", input: nil, store: store)
        let id = try store.load().id
        sut.open = { uuid in
            (DDC.DisplayTarget(id: 8, uuid: uuid), DDCChannel(
                getVCP: { _ in (17, 0) }, setVCP: { _, _ in XCTFail("fake selector only") }))
        }
        var inputWrites = 0
        sut.select = { requested, _, displayID, uuid, originalInput in
            inputWrites += 1
            // Selecting the Mac input causes WindowServer to reinstate its
            // mirror topology. Mode availability alone cannot predict this.
            current = mirrored
            return DDCInputSelection(displayID: displayID, uuid: uuid, original: originalInput,
                requested: requested, observed: requested, outcome: .verified, detail: nil)
        }
        _ = try sut.guardedBack(expectedJournalID: id, input: 15, store: store)
        XCTAssertEqual(inputWrites, 1)
        XCTAssertNoThrow(try original.verify(current), "successful explicit Show must verify AFTER input return")
        XCTAssertTrue(try store.load().state.resolved)
    }

    func testShowAttemptsKnownReturnInputWhenPreReadIsMalformed() throws {
        let original = try snapshot()
        let mirrored = try snapshot { $0[1]["mirrorUUID"] = self.sourceUUID; $0[1]["active"] = false }
        var current = original
        var events: [String] = []
        var sut = HandoffController(mirror: controller(original), report: { _ in })
        sut.mirror.records = { self.records(current) }
        sut.mirror.engine.capture = { current }
        sut.mirror.engine.apply = { current = $0; events.append("restore") }
        sut.mirror.transaction = MirrorTransaction(
            begin: { OpaquePointer(bitPattern: 1)! }, stage: { _, _, _ in },
            complete: { _, _ in current = mirrored }, cancel: { _ in })
        try sut.away(selector: "8", source: "7", input: nil, store: store)
        let id = try store.load().id
        sut.open = { uuid in
            (DDC.DisplayTarget(id: 8, uuid: uuid), DDCChannel(
                getVCP: { _ in
                    events.append("read")
                    if !events.contains("write") { throw DDCError.invalidReply("invalid payload length") }
                    return (15, 0)
                },
                setVCP: { code, value in
                    XCTAssertEqual(code, 0x60)
                    XCTAssertEqual(value, 15)
                    events.append("write")
                }))
        }
        let result = try sut.guardedBack(expectedJournalID: id, input: 15, store: store)
        XCTAssertEqual(result.state, .verified)
        XCTAssertEqual(result.observedInput, 15)
        XCTAssertNil(result.recoveryCommand, "the previous input is unknown, not guessed")
        XCTAssertEqual(events, ["read", "write", "read", "restore"])
        XCTAssertEqual(try store.load().state, .restored)
        let duplicate = try sut.guardedBack(expectedJournalID: id, input: 15, store: store)
        XCTAssertEqual(duplicate.state, .notAttempted)
        XCTAssertEqual(events.filter { $0 == "write" }.count, 1)
    }

    func testBackRefusesDifferentTargetBeforeRestoreOrDDC() throws {
        let original = try snapshot()
        _ = try journal(original)
        var sut = HandoffController(mirror: controller(original))
        sut.open = { _ in XCTFail("must not open DDC"); throw RecoveryError.unsafe("unexpected") }
        for selector in ["7", "9", "missing"] {
            XCTAssertThrowsError(try sut.back(selector: selector, input: 15, store: store))
        }
        XCTAssertEqual(try store.load().state, .captured)
    }

    func testHandoffParser() throws {
        XCTAssertEqual(try CLIParser.parse(["away", "--display", "8", "--source", "7", "--consent-away", "--input", "hdmi1"]),
                       .away(selector: "8", source: "7", input: 17, journalPath: nil))
        XCTAssertEqual(try CLIParser.parse(["back", "--display", "8", "--consent-back", "--input", "0x0F", "--journal", "/private/j.json"]),
                       .back(selector: "8", input: 15, journalPath: "/private/j.json"))
        XCTAssertEqual(try CLIParser.parse(["back", "--display", "8", "--consent-back"]),
                       .back(selector: "8", input: nil, journalPath: nil))
        XCTAssertEqual(try CLIParser.parse(["away", "--display", "8", "--source", "7", "--consent-away"]),
                       .away(selector: "8", source: "7", input: nil, journalPath: nil))
        for command in ["away", "back"] {
            XCTAssertEqual(try CLIParser.parse([command, "--help"]), .help(command: command))
            XCTAssertTrue(CLIHelp.text(for: command).contains("monitor's input button"))
            let base = [command, "--display", "8", "--consent-\(command)"] + (command == "away" ? ["--source", "7"] : [])
            for extra in [["--input", "0"], ["--input", "256"], ["--input", "bogus"], ["--input"],
                          ["--input", "dp1", "--input", "hdmi1"], ["--display", "9"], ["--consent-\(command)"], ["--bogus"]] {
                XCTAssertThrowsError(try CLIParser.parse(base + extra))
            }
        }
        for args in [["away"], ["back"], ["away", "--display", "8", "--consent-away"],
                     ["back", "--display", "8"], ["back", "--display", "8", "--consent-back", "--source", "7"]] {
            XCTAssertThrowsError(try CLIParser.parse(args))
        }
    }

    func testMirrorParserRequiresExplicitConsentAndSource() throws {
        XCTAssertEqual(try CLIParser.parse(["mirror", "--display", "8", "--source", "7", "--consent-mirror"]),
                       .mirror(selector: "8", source: "7", journalPath: nil))
        XCTAssertEqual(try CLIParser.parse(["unmirror", "--consent-unmirror", "--journal", "/private/test.json"]),
                       .unmirror(journalPath: "/private/test.json"))
        XCTAssertEqual(try CLIParser.parse(["unmirror", "--display", "00000000-0000-0000-0000-000000000008", "--consent-unmirror"]),
                       .unmirrorTarget(selector: "00000000-0000-0000-0000-000000000008", journalPath: nil))
        for args in [["mirror"], ["mirror", "--display", "8", "--consent-mirror"],
                     ["mirror", "--display", "8", "--source", "7"], ["unmirror"],
                     ["unmirror", "--consent-mirror"],
                     ["mirror", "--source", "7", "--source", "9"],
                     ["mirror", "--display", ""], ["mirror", "--source", "--consent-mirror"],
                     ["unmirror", "--consent-unmirror", "--consent-unmirror"]] {
            XCTAssertThrowsError(try CLIParser.parse(args), args.joined(separator: " "))
        }
        XCTAssertEqual(try CLIParser.parse(["recovery", "verify", "--display", "00000000-0000-0000-0000-000000000008"]),
                       .recoverySelected(action: .verify, timeout: nil,
                                         selector: "00000000-0000-0000-0000-000000000008", journalPath: nil))
        XCTAssertEqual(try CLIParser.parse(["recovery", "restore", "--display", "00000000-0000-0000-0000-000000000008"]),
                       .recoverySelected(action: .restore, timeout: nil,
                                         selector: "00000000-0000-0000-0000-000000000008", journalPath: nil))
        for command in ["mirror", "unmirror"] {
            XCTAssertEqual(try CLIParser.parse([command, "--help"]), .help(command: command))
            XCTAssertTrue(CLIHelp.text(for: command).contains("Experimental public, session-scoped mirroring"))
            XCTAssertTrue(CLIHelp.text(for: command).contains("do not make untested hardware safe"))
        }
    }
}

private final class EventLog {
    var values: [String] = []
}
