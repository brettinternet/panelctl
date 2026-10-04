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

    func testRefusesMainBuiltinInactiveSameMissingAndAmbiguousTargets() throws {
        let original = try snapshot()
        for (target, source) in [("7", "8"), ("8", "8"), ("missing", "7"), ("8", "missing")] {
            XCTAssertThrowsError(try controller(original).mirror(selector: target, source: source, store: store))
        }
        for (key, value): (String, Any) in [("builtin", true), ("active", false)] {
            let bad = try snapshot { $0[1][key] = value }
            XCTAssertThrowsError(try controller(bad).mirror(selector: "8", source: "7", store: store))
        }
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
        for ids: (UInt32?, UInt32?) in [(8, nil), (nil, 7), (7, 8), (8, 8), (8, 99)] {
            var invalid = unrelated
            invalid.mirrorTargetID = ids.0; invalid.mirrorSourceID = ids.1
            XCTAssertThrowsError(try invalid.validate())
        }
        var invalid = unrelated
        invalid.state = .mirrored
        XCTAssertThrowsError(try invalid.validate())
    }

    func testMirrorParserRequiresExplicitConsentAndSource() throws {
        XCTAssertEqual(try CLIParser.parse(["mirror", "--display", "8", "--source", "7", "--consent-mirror"]),
                       .mirror(selector: "8", source: "7", journalPath: nil))
        XCTAssertEqual(try CLIParser.parse(["unmirror", "--consent-unmirror", "--journal", "/private/test.json"]),
                       .unmirror(journalPath: "/private/test.json"))
        for args in [["mirror"], ["mirror", "--display", "8", "--consent-mirror"],
                     ["mirror", "--display", "8", "--source", "7"], ["unmirror"],
                     ["unmirror", "--consent-mirror"], ["unmirror", "--display", "8", "--consent-unmirror"],
                     ["mirror", "--source", "7", "--source", "9"],
                     ["mirror", "--display", ""], ["mirror", "--source", "--consent-mirror"],
                     ["unmirror", "--consent-unmirror", "--consent-unmirror"]] {
            XCTAssertThrowsError(try CLIParser.parse(args), args.joined(separator: " "))
        }
        for command in ["mirror", "unmirror"] {
            XCTAssertEqual(try CLIParser.parse([command, "--help"]), .help(command: command))
            XCTAssertTrue(CLIHelp.text(for: command).contains("not hardware-qualified"))
        }
    }
}
