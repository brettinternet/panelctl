import XCTest
import CoreGraphics
import Darwin
@testable import PanelCtlCore

final class TargetRestoreTransactionTests: XCTestCase {
    private let targetUUID = "09084682-3c42-4455-aab8-126a7431125b"
    private let followerUUID = "a8d3635b-35ec-4171-bbe2-95fb8cf76111"
    private let sourceUUID = "1fc57e99-de7c-4daf-b896-3b512cee064f"

    private func fixture(_ name: String) throws -> RecoverySnapshot {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "multi-removal-26A434", withExtension: "json", subdirectory: "Fixtures"))
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let snapshots = try XCTUnwrap(root["snapshots"] as? [String: Any])
        var value = try XCTUnwrap(snapshots[name] as? [String: Any])
        var displays = try XCTUnwrap(value["displays"] as? [[String: Any]])
        // Diagnostic captures include private CoreDisplay metadata, whereas
        // MirrorController always captures public-only. Model that shape here,
        // retaining the raw fixture; runtime identity checks are not altered.
        for index in displays.indices { displays[index].removeValue(forKey: "connector") }
        value["displays"] = displays
        value["userID"] = getuid()
        return try JSONDecoder().decode(RecoverySnapshot.self, from: JSONSerialization.data(withJSONObject: value))
    }

    private func change(_ snapshot: RecoverySnapshot, uuid: String,
                        _ body: (inout [String: Any]) -> Void) throws -> RecoverySnapshot {
        var value = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot)) as? [String: Any])
        var displays = try XCTUnwrap(value["displays"] as? [[String: Any]])
        let index = try XCTUnwrap(displays.firstIndex { $0["uuid"] as? String == uuid })
        body(&displays[index])
        value["displays"] = displays
        return try JSONDecoder().decode(RecoverySnapshot.self, from: JSONSerialization.data(withJSONObject: value))
    }

    private func session(_ baseline: RecoverySnapshot, followerRestored: Bool = false) throws -> [PublicMirrorRemoval] {
        let target = try XCTUnwrap(baseline.displays.first { $0.uuid == targetUUID })
        let follower = try XCTUnwrap(baseline.displays.first { $0.uuid == followerUUID })
        let source = try XCTUnwrap(baseline.displays.first { $0.uuid == sourceUUID })
        return [
            PublicMirrorRemoval(target: target, source: source, beforeOperation: baseline, state: .mirrored),
            PublicMirrorRemoval(target: follower, source: source, beforeOperation: baseline,
                                state: followerRestored ? .restored : .mirrored)
        ]
    }

    func testRecordedPartialShowPlacementVerifiesWhileFinalLayoutStaysExact() throws {
        let baseline = try fixture("baseline")
        let before = try fixture("bothHidden")
        let removals = try session(baseline)
        for name in ["failedPartial", "failedRepair"] {
            let placed = try fixture(name)
            try baseline.validateRestoration(to: placed)
            let target = try XCTUnwrap(placed.displays.first { $0.uuid == targetUUID })
            XCTAssertEqual(target.y, 0, "macOS placed the target four points from its saved origin")
            XCTAssertEqual(target.mode, baseline.displays.first { $0.uuid == targetUUID }?.mode)
            XCTAssertFalse(MirrorSessionTopology.targetMatchesBaseline(targetUUID, baseline: baseline, current: placed))
            XCTAssertThrowsError(try baseline.verify(placed))
            XCTAssertNoThrow(try MirrorSessionTopology.verifyPartialShow(
                baseline: baseline, removals: removals, removalID: removals[0].id, before: before, current: placed
            ), "a partial Show requests but cannot require an origin macOS will not accept")
            // The same placement is never enough once no removal remains.
            let last = try session(baseline, followerRestored: true)
            XCTAssertThrowsError(try MirrorSessionTopology.verifyPartialShow(
                baseline: baseline, removals: last, removalID: last[0].id, before: before, current: placed
            ))
        }
        try baseline.verify(fixture("restored"))
    }

    func testStagingRequestsOnlyTheTargetsSavedOrigin() throws {
        let baseline = try fixture("baseline")
        let target = try XCTUnwrap(baseline.displays.first { $0.uuid == targetUUID })
        for name in ["bothHidden", "failedRepair"] {
            let before = try fixture(name)
            var events: [String] = []
            var origins: [(UInt32, Int32, Int32)] = []
            let transaction = TargetRestoreTransaction(
                begin: { events.append("begin"); return OpaquePointer(bitPattern: 1)! },
                prepareMode: { display in
                    XCTAssertEqual(display, target)
                    events.append("prepare")
                    return { _ in events.append("mode-\(display.id)") }
                },
                clearMirror: { _, id in events.append("unmirror-\(id)") },
                origin: { _, id, x, y in origins.append((id, x, y)) },
                complete: { _, scope in XCTAssertEqual(scope, .forSession); events.append("complete") },
                cancel: { _ in XCTFail("successful completion consumes the transaction") }
            )
            try RecoveryConfiguration.restoreTarget(baseline, targetUUID: targetUUID, capture: { before }, transaction: transaction)
            XCTAssertEqual(Array(events.prefix(2)), ["prepare", "begin"])
            XCTAssertEqual(events.last, "complete")
            XCTAssertEqual(events.contains("unmirror-\(target.id)"), name == "bothHidden")
            XCTAssertEqual(events.contains("mode-\(target.id)"), name == "bothHidden")
            XCTAssertEqual(origins.count, 1, "no other desktop or mirror follower is staged")
            XCTAssertTrue(origins.contains { $0.0 == target.id && $0.1 == 3440 && $0.2 == -4 })
        }
    }

    func testStagingErrorsDriftAndCompletionConsumptionNeverRetry() throws {
        let baseline = try fixture("baseline")
        let before = try fixture("bothHidden")
        let changed = try change(before, uuid: sourceUUID) { $0["serial"] = 123 }
        for failure in ["prepare", "begin", "mirror", "mode", "origin", "complete", "preBeginDrift", "preCommitDrift", "gate"] {
            var begins = 0
            var cancels = 0
            var completes = 0
            var captures = 0
            var gates = 0
            func fail(_ step: String) throws {
                if step == failure { throw RecoveryError.unsafe("injected \(step)") }
            }
            let transaction = TargetRestoreTransaction(
                begin: { begins += 1; try fail("begin"); return OpaquePointer(bitPattern: 1)! },
                prepareMode: { _ in try fail("prepare"); return { _ in try fail("mode") } },
                clearMirror: { _, _ in try fail("mirror") },
                origin: { _, _, _, _ in try fail("origin") },
                complete: { _, scope in completes += 1; XCTAssertEqual(scope, .forSession); try fail("complete") },
                cancel: { _ in cancels += 1 }
            )
            XCTAssertThrowsError(try RecoveryConfiguration.restoreTarget(
                baseline, targetUUID: targetUUID,
                revalidate: { gates += 1; if gates == 3 { try fail("gate") } },
                capture: {
                    captures += 1
                    return (failure == "preBeginDrift" && captures == 2) ||
                        (failure == "preCommitDrift" && captures == 3) ? changed : before
                }, transaction: transaction
            ), failure)
            XCTAssertEqual(begins, ["prepare", "preBeginDrift"].contains(failure) ? 0 : 1, failure)
            XCTAssertEqual(completes, failure == "complete" ? 1 : 0, failure)
            XCTAssertEqual(cancels, ["mirror", "mode", "origin", "preCommitDrift", "gate"].contains(failure) ? 1 : 0, failure)
        }
    }

    func testSurvivorPositionsCompareUnlessTheTargetIsTheOriginalMain() throws {
        let baseline = try fixture("baseline")
        let before = try fixture("bothHidden")
        let otherUUID = "98402864-2a3e-4b75-92e6-0f801b89c132"
        let placed = try fixture("failedPartial")
        XCTAssertTrue(MirrorSessionTopology.showSurvivorsUnchanged(baseline: baseline, targetUUID: targetUUID,
                                                                   before: before, current: placed))
        let moved = try change(placed, uuid: otherUUID) { $0["x"] = -1439 }
        let modeChanged = try change(placed, uuid: otherUUID) {
            var mode = $0["mode"] as! [String: Any]; mode["refreshRate"] = 30; $0["mode"] = mode
        }
        let hidden = try change(placed, uuid: otherUUID) { $0["active"] = false }
        for current in [moved, modeChanged, hidden] {
            XCTAssertFalse(MirrorSessionTopology.showSurvivorsUnchanged(baseline: baseline, targetUUID: targetUUID,
                                                                        before: before, current: current))
        }
        // Coordinates are relative to the main display. A returning original
        // main, or macOS moving main, changes that frame, so only visibility
        // and modes compare; the final Show restores every position.
        var mainMoved = try change(moved, uuid: sourceUUID) { $0["main"] = false }
        mainMoved = try change(mainMoved, uuid: otherUUID) { $0["main"] = true }
        XCTAssertTrue(MirrorSessionTopology.showSurvivorsUnchanged(baseline: baseline, targetUUID: targetUUID,
                                                                   before: before, current: mainMoved))
        XCTAssertTrue(MirrorSessionTopology.showSurvivorsUnchanged(baseline: baseline, targetUUID: sourceUUID,
                                                                   before: before, current: moved))
        for current in [modeChanged, hidden] {
            XCTAssertFalse(MirrorSessionTopology.showSurvivorsUnchanged(baseline: baseline, targetUUID: sourceUUID,
                                                                        before: before, current: current))
        }
    }

    func testControllerVerifiesPartialShowPostconditionAfterInputReturn() throws {
        let baseline = try fixture("baseline")
        let before = try fixture("bothHidden")
        let target = try XCTUnwrap(baseline.displays.first { $0.uuid == targetUUID })
        let follower = try XCTUnwrap(baseline.displays.first { $0.uuid == followerUUID })
        let source = try XCTUnwrap(baseline.displays.first { $0.uuid == sourceUUID })
        // Recorded 26A434 result: exact mode, survivors unchanged, (3440,0).
        let placed = try fixture("failedPartial")
        let succeeds = ["placed", "exact"]
        for outcome in succeeds + ["targetMode", "targetMain", "siblingSeparate",
                                   "survivorX", "survivorMode", "survivorMain", "survivorActive"] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("panelctl-partial-show-tests-\(UUID())")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                   attributes: [.posixPermissions: 0o700])
            defer { try? FileManager.default.removeItem(at: directory) }
            let store = RecoveryStore(url: directory.appendingPathComponent("current.json"))
            let operation = RecoveryStore(url: directory.appendingPathComponent("operation"))
            var journal = RecoveryJournal(snapshot: baseline, publicMirrorSession: PublicMirrorSession(baseline: baseline, removals: [
                PublicMirrorRemoval(target: target, source: source, beforeOperation: baseline, state: .mirrored),
                PublicMirrorRemoval(target: follower, source: source, beforeOperation: baseline, state: .mirrored)
            ]))
            journal.state = .mirrored
            try store.lock(); try store.create(journal); store.unlock()
            var current = before
            var completions = 0
            var inputs = 0
            let transaction = TargetRestoreTransaction(
                begin: { OpaquePointer(bitPattern: 1)! }, prepareMode: { _ in { _ in } },
                clearMirror: { _, id in XCTAssertEqual(id, target.id) },
                origin: { _, id, _, _ in XCTAssertNotEqual(id, follower.id) },
                complete: { _, _ in
                    let pending = try store.load()
                    XCTAssertEqual(pending.publicMirrorSession?.removals.first?.state, .restoring)
                    XCTAssertEqual(pending.publicMirrorSession?.removals.first?.restoreFrom, before,
                                   "Show expectations must be durable before completion can change topology")
                    completions += 1
                    current = placed
                    switch outcome {
                    case "exact": current = try self.change(current, uuid: self.targetUUID) { $0["y"] = -4 }
                    case "targetMode": current = try self.change(current, uuid: self.targetUUID) {
                        var mode = $0["mode"] as! [String: Any]; mode["refreshRate"] = 60; $0["mode"] = mode
                    }
                    case "targetMain": current = try self.change(current, uuid: self.targetUUID) { $0["main"] = true }
                    case "siblingSeparate": current = try self.change(current, uuid: self.followerUUID) {
                        $0["mirrorUUID"] = NSNull(); $0["active"] = true
                    }
                    case "survivorX": current = try self.change(current, uuid: self.sourceUUID) { $0["x"] = 1 }
                    case "survivorMode": current = try self.change(current, uuid: self.sourceUUID) {
                        var mode = $0["mode"] as! [String: Any]; mode["refreshRate"] = 60; $0["mode"] = mode
                    }
                    case "survivorMain": current = try self.change(current, uuid: self.sourceUUID) { $0["main"] = false }
                    case "survivorActive": current = try self.change(current, uuid: self.sourceUUID) { $0["active"] = false }
                    default: break
                    }
                }, cancel: { _ in XCTFail("completion consumes transaction") })
            let sut = MirrorController(
                records: {
                    current.displays.enumerated().map { index, d in
                        DisplayRecord(index: index + 1, id: d.id, uuid: d.uuid, name: d.name, active: d.active,
                                      online: true, asleep: false, builtin: d.builtin, main: d.main,
                                      vendor: d.vendor, model: d.model, serial: d.serial,
                                      bounds: DisplayBounds(CGRect(x: Int(d.x), y: Int(d.y), width: d.mode.width, height: d.mode.height)),
                                      pixelWidth: d.mode.pixelWidth, pixelHeight: d.mode.pixelHeight)
                    }
                }, operationLock: { operation },
                engine: RecoveryEngine(capture: { current }, apply: { _ in XCTFail("no full restore during partial Show") }, convergencePause: {}),
                preflightModes: { _ in }, restoreTarget: { baseline, uuid, validate, capture in
                    try RecoveryConfiguration.restoreTarget(baseline, targetUUID: uuid, revalidate: validate,
                                                            capture: capture, transaction: transaction)
                })
            let success = succeeds.contains(outcome)
            if success {
                _ = try sut.unmirror(store: store, selector: targetUUID, returnInputBeforeRestore: { _ in inputs += 1 })
            } else {
                XCTAssertThrowsError(try sut.unmirror(store: store, selector: targetUUID, returnInputBeforeRestore: { _ in inputs += 1 }), outcome)
            }
            XCTAssertEqual(completions, 1, "verification reads never retry the writer")
            XCTAssertEqual(inputs, 1, "input return runs once before the desktop postcondition: \(outcome)")
            let saved = try store.load()
            XCTAssertEqual(saved.publicMirrorSession?.removals.first?.state, success ? .restored : .needsAttention, outcome)
            XCTAssertEqual(saved.publicMirrorSession?.removals.last?.state, .mirrored, outcome)
            if success {
                // The shown display is an ordinary visible display; the
                // remaining removal stays healthy and verifiable.
                XCTAssertEqual(try sut.verifyRemoval(store: store, selector: followerUUID).state, .mirrored, outcome)
                XCTAssertEqual(try sut.verifyRemoval(store: store, selector: targetUUID)
                    .publicMirrorSession?.removals.first?.state, .restored, outcome)
            }
            if outcome.hasPrefix("survivor") {
                // Also replay a process interruption after commit but before
                // postverification/failure persistence: the pending snapshot
                // alone must prevent weaker inspection from retiring recovery.
                var interrupted = saved
                interrupted.state = .restoring
                interrupted.publicMirrorSession?.removals[0].state = .restoring
                interrupted.publicMirrorSession?.removals[0].failure = nil
                try store.lock(); try store.save(interrupted); store.unlock()
                let inspector = DisplayHideController(store: store, mirror: sut, operationLock: { operation })
                let observed = try inspector.inspect()
                XCTAssertTrue(observed.hasUnresolvedRecovery)
                XCTAssertEqual(observed.removals.first?.state, "needsAttention", outcome)
                XCTAssertThrowsError(try sut.verifyRemoval(store: store, selector: targetUUID), outcome)
                XCTAssertThrowsError(try sut.unmirror(store: store, selector: targetUUID),
                                     "partial repair cannot adopt a changed survivor as its new expectation")
                XCTAssertEqual(try store.load().publicMirrorSession?.removals.first?.restoreFrom, before)
                XCTAssertEqual(completions, 1)
                XCTAssertEqual(inputs, 1, "inspection and failed repair never replay input return")
                // Interrupted after macOS placed the target: the durable
                // pre-Show expectations resolve it without the saved origin.
                current = placed
                XCTAssertEqual(try sut.verifyRemoval(store: store, selector: targetUUID).publicMirrorSession?.removals.first?.state,
                               .restored, "only matching the durable expectations can resolve this entry")
                XCTAssertEqual(completions, 1, "read-only reconciliation never retries")
            } else {
                XCTAssertEqual(saved.publicMirrorSession?.removals.first?.restoreFrom == nil, success, outcome)
            }
        }
    }
}
