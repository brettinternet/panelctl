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

    func testRecordedOriginFailuresRemainFailuresAndFinalLayoutMatches() throws {
        let baseline = try fixture("baseline")
        for name in ["failedPartial", "failedRepair"] {
            let failed = try fixture(name)
            try baseline.validateRestoration(to: failed)
            let target = try XCTUnwrap(failed.displays.first { $0.uuid == targetUUID })
            XCTAssertEqual(target.y, 0)
            XCTAssertEqual(target.mode, baseline.displays.first { $0.uuid == targetUUID }?.mode)
            XCTAssertFalse(MirrorSessionTopology.targetMatchesBaseline(targetUUID, baseline: baseline, current: failed))
            XCTAssertThrowsError(try baseline.verify(failed))
        }
        try baseline.verify(fixture("restored"))
    }

    func testActualStagingAnchorsUnchangedIndependentDesktopsNeverFollowers() throws {
        let baseline = try fixture("baseline")
        let target = try XCTUnwrap(baseline.displays.first { $0.uuid == targetUUID })
        let follower = try XCTUnwrap(baseline.displays.first { $0.uuid == followerUUID })
        let source = try XCTUnwrap(baseline.displays.first { $0.uuid == sourceUUID })
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
            XCTAssertEqual(origins.count, 3)
            XCTAssertFalse(origins.contains { $0.0 == follower.id }, "setting a follower origin would unmirror it")
            XCTAssertTrue(origins.contains { $0.0 == target.id && $0.1 == 3440 && $0.2 == -4 })
            XCTAssertEqual(origins.last?.0, source.id, "the unchanged current main is explicitly staged last")
            for anchor in before.displays where anchor.active && anchor.uuid != targetUUID && anchor.mirrorUUID == nil {
                XCTAssertTrue(origins.contains { $0.0 == anchor.id && $0.1 == anchor.x && $0.2 == anchor.y })
            }
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

    func testAnchoringDoesNotReplayCoordinatesAcrossAMainDisplayChange() throws {
        let baseline = try fixture("baseline")
        var movedMain = try change(fixture("bothHidden"), uuid: sourceUUID) { $0["main"] = false }
        movedMain = try change(movedMain, uuid: "98402864-2a3e-4b75-92e6-0f801b89c132") { $0["main"] = true }
        XCTAssertTrue(RecoveryConfiguration.targetRestoreAnchors(baseline, targetUUID: targetUUID, before: movedMain).isEmpty)
        XCTAssertTrue(RecoveryConfiguration.targetRestoreAnchors(baseline, targetUUID: sourceUUID, before: baseline).isEmpty)
    }

    func testControllerRequiresExactTargetAndIndependentAnchorsBeforeInputReturn() throws {
        let baseline = try fixture("baseline")
        let before = try fixture("bothHidden")
        let target = try XCTUnwrap(baseline.displays.first { $0.uuid == targetUUID })
        let follower = try XCTUnwrap(baseline.displays.first { $0.uuid == followerUUID })
        let source = try XCTUnwrap(baseline.displays.first { $0.uuid == sourceUUID })
        let repaired = try change(fixture("failedPartial"), uuid: targetUUID) { $0["y"] = -4 }
        for outcome in ["exact", "targetY", "anchorX", "anchorMode", "anchorMain", "anchorActive"] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("panelctl-anchor-tests-\(UUID())")
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
                                   "Show anchors must be durable before completion can change topology")
                    completions += 1
                    current = repaired
                    switch outcome {
                    case "targetY": current = try self.change(current, uuid: self.targetUUID) { $0["y"] = 0 }
                    case "anchorX": current = try self.change(current, uuid: self.sourceUUID) { $0["x"] = 1 }
                    case "anchorMode": current = try self.change(current, uuid: self.sourceUUID) {
                        var mode = $0["mode"] as! [String: Any]; mode["refreshRate"] = 60; $0["mode"] = mode
                    }
                    case "anchorMain": current = try self.change(current, uuid: self.sourceUUID) { $0["main"] = false }
                    case "anchorActive": current = try self.change(current, uuid: self.sourceUUID) { $0["active"] = false }
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
            if outcome == "exact" {
                _ = try sut.unmirror(store: store, selector: targetUUID, afterRestore: { _ in inputs += 1 })
            } else {
                XCTAssertThrowsError(try sut.unmirror(store: store, selector: targetUUID, afterRestore: { _ in inputs += 1 }), outcome)
            }
            XCTAssertEqual(completions, 1, "verification reads never retry the writer")
            XCTAssertEqual(inputs, outcome == "exact" ? 1 : 0)
            let saved = try store.load()
            XCTAssertEqual(saved.publicMirrorSession?.removals.first?.state, outcome == "exact" ? .restored : .needsAttention)
            XCTAssertEqual(saved.publicMirrorSession?.removals.last?.state, .mirrored)
            if outcome.hasPrefix("anchor") {
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
                                     "partial repair cannot adopt the wrong anchor as its new expectation")
                XCTAssertEqual(try store.load().publicMirrorSession?.removals.first?.restoreFrom, before)
                XCTAssertEqual(completions, 1)
                XCTAssertEqual(inputs, 0)
                current = repaired
                XCTAssertEqual(try sut.verifyRemoval(store: store, selector: targetUUID).publicMirrorSession?.removals.first?.state,
                               .restored, "only matching the durable expectations can resolve this entry")
                XCTAssertEqual(completions, 1, "read-only reconciliation never retries")
            } else {
                XCTAssertEqual(saved.publicMirrorSession?.removals.first?.restoreFrom == nil, outcome == "exact")
            }
        }
    }
}
