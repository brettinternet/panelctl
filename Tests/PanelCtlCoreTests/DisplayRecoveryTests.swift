import XCTest
import Darwin
@testable import PanelCtlCore

final class DisplayRecoveryTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("panelctl-recovery-tests-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
    }

    private func store() -> RecoveryStore { RecoveryStore(url: directory.appendingPathComponent("current.json")) }

    private func snapshot(_ modify: (inout [String: Any]) -> Void = { _ in }) throws -> RecoverySnapshot {
        var value: [String: Any] = [
            "bootSession": "test-boot", "osBuild": "test-build", "userID": getuid(),
            "displays": [[
                "uuid": "00000000-0000-0000-0000-000000000001", "id": 7,
                "vendor": 1, "model": 2, "serial": 3, "builtin": false,
                "main": true, "active": true, "x": 0, "y": 0, "rotation": 0,
                "colorSpace": "test-color", "connector": "test-connector",
                "mode": ["id": 9, "width": 1920, "height": 1080,
                         "pixelWidth": 1920, "pixelHeight": 1080, "refreshRate": 60, "flags": 0]
            ]]
        ]
        modify(&value)
        return try JSONDecoder().decode(RecoverySnapshot.self, from: JSONSerialization.data(withJSONObject: value))
    }

    private func changedDisplay(_ key: String, _ value: Any) throws -> RecoverySnapshot {
        try snapshot { data in
            var displays = data["displays"] as! [[String: Any]]
            displays[0][key] = value
            data["displays"] = displays
        }
    }

    func testSnapshotRoundTripAndExactVerification() throws {
        let original = try snapshot()
        let decoded = try JSONDecoder().decode(RecoverySnapshot.self, from: JSONEncoder().encode(original))
        XCTAssertEqual(original, decoded)
        XCTAssertNoThrow(try original.verify(decoded))
    }

    func testIdentityChangesFailClosed() throws {
        let original = try snapshot()
        for (key, value): (String, Any) in [
            ("uuid", "00000000-0000-0000-0000-000000000002"), ("id", 8),
            ("vendor", 99), ("model", 99), ("serial", 99), ("builtin", true),
            ("connector", "different"), ("rotation", 90), ("colorSpace", "different"),
            ("colorProfileDigest", String(repeating: "a", count: 64))
        ] {
            XCTAssertThrowsError(try original.validateRestoration(to: changedDisplay(key, value)), key)
        }
    }

    func testHostChangesFailClosed() throws {
        let original = try snapshot()
        for key in ["bootSession", "osBuild"] {
            XCTAssertThrowsError(try original.validateRestoration(to: snapshot { $0[key] = "different" }))
        }
        XCTAssertThrowsError(try original.validateRestoration(to: snapshot { $0["userID"] = getuid() + 1 }))
    }

    func testMissingExtraAndDuplicateDisplaysFailClosed() throws {
        let original = try snapshot()
        XCTAssertThrowsError(try original.validateRestoration(to: snapshot { $0["displays"] = [] }))
        XCTAssertThrowsError(try original.validateRestoration(to: snapshot {
            let displays = $0["displays"] as! [[String: Any]]
            $0["displays"] = displays + displays
        }))
        XCTAssertThrowsError(try original.validateRestoration(to: snapshot {
            var displays = $0["displays"] as! [[String: Any]]
            var extra = displays[0]
            extra["uuid"] = "00000000-0000-0000-0000-000000000002"
            extra["id"] = 8
            displays.append(extra); $0["displays"] = displays
        }))
    }

    func testLayoutChangesAreRestorableButNotVerified() throws {
        let original = try snapshot()
        for (key, value): (String, Any) in [("x", -1920), ("y", 1080), ("main", false), ("active", false)] {
            let current = try changedDisplay(key, value)
            XCTAssertNoThrow(try original.validateRestoration(to: current))
            XCTAssertThrowsError(try original.verify(current))
        }
    }

    func testJournalPermissionsLockAndUnresolvedProtection() throws {
        let store = store()
        try store.lock()
        let journal = RecoveryJournal(snapshot: try snapshot())
        try store.create(journal)
        XCTAssertEqual(try store.load().id, journal.id)
        let attributes = try FileManager.default.attributesOfItem(atPath: store.url.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertThrowsError(try self.store().lock())
        XCTAssertThrowsError(try store.create(RecoveryJournal(snapshot: snapshot())))
        XCTAssertEqual(try store.load().id, journal.id)
        store.unlock()
        let next = self.store()
        XCTAssertNoThrow(try next.lock())
        XCTAssertThrowsError(try store.save(journal))
    }

    func testResolvedJournalIsArchived() throws {
        let store = store(); try store.lock()
        var journal = RecoveryJournal(snapshot: try snapshot())
        journal.state = .verified
        try store.create(journal)
        let next = RecoveryJournal(snapshot: try snapshot())
        try store.create(next)
        XCTAssertEqual(try store.load().id, next.id)
        let archive = directory.appendingPathComponent("recovery-\(journal.id.uuidString).json")
        XCTAssertEqual(try JSONDecoder().decode(RecoveryJournal.self, from: Data(contentsOf: archive)).id, journal.id)
    }

    func testArchiveCreationCanResumeAfterInterruptedReplacement() throws {
        let store = store(); try store.lock()
        var journal = RecoveryJournal(snapshot: try snapshot())
        journal.state = .verified
        try store.create(journal)
        let archive = directory.appendingPathComponent("recovery-\(journal.id.uuidString).json")
        try FileManager.default.copyItem(at: store.url, to: archive)
        let next = RecoveryJournal(snapshot: try snapshot())
        try store.create(next)
        XCTAssertEqual(try store.load().id, next.id)
    }

    func testCorruptAndFutureJournalsAreNotOverwritten() throws {
        let store = store(); try store.lock()
        try Data("broken".utf8).write(to: store.url)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: store.url.path)
        XCTAssertThrowsError(try store.load())
        XCTAssertThrowsError(try store.create(RecoveryJournal(snapshot: snapshot())))
        XCTAssertEqual(try Data(contentsOf: store.url), Data("broken".utf8))
        let journal = RecoveryJournal(snapshot: try snapshot())
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(journal)) as! [String: Any]
        object["version"] = 999
        try JSONSerialization.data(withJSONObject: object).write(to: store.url)
        XCTAssertThrowsError(try store.load())
    }

    func testUnsafeDirectoryAndSymlinkJournalAreRejected() throws {
        let store = store()
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
        XCTAssertThrowsError(try store.lock())
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        try store.lock()
        let destination = directory.appendingPathComponent("other.json")
        try Data("untouched".utf8).write(to: destination)
        try FileManager.default.createSymbolicLink(at: store.url, withDestinationURL: destination)
        XCTAssertThrowsError(try store.load())
        XCTAssertThrowsError(try store.create(RecoveryJournal(snapshot: snapshot())))
        XCTAssertEqual(try String(contentsOf: destination), "untouched")
    }

    func testBadMirrorAndDeadlineAreRejected() throws {
        let bad = try changedDisplay("mirrorUUID", "00000000-0000-0000-0000-000000000001")
        XCTAssertThrowsError(try RecoveryJournal(snapshot: bad).validate())
        for timeout in [0.0, 61.0, -1.0] {
            XCTAssertThrowsError(try RecoveryJournal(snapshot: snapshot(), timeout: timeout).validate())
        }
    }

    func testVerifyOnlyNeverCallsWriterEvenOnMismatch() throws {
        let store = store(); try store.lock()
        var journal = RecoveryJournal(snapshot: try snapshot(), verifyOnly: true)
        try store.create(journal)
        let changed = try changedDisplay("x", 100)
        let engine = RecoveryEngine(capture: { changed }, apply: { _ in XCTFail("verify must not write") })
        XCTAssertThrowsError(try engine.finish(&journal, store: store, verifyOnly: true, trigger: "test"))
        XCTAssertEqual(try store.load().state, .needsAttention)
        XCTAssertEqual(try store.load().snapshot, journal.snapshot)
    }

    func testRestorePersistsIntentThenVerifiesAndIsIdempotent() throws {
        let store = store(); try store.lock()
        let original = try snapshot()
        var journal = RecoveryJournal(snapshot: original)
        try store.create(journal)
        var current = try changedDisplay("x", 100)
        var writes = 0
        let engine = RecoveryEngine(capture: { current }, apply: { target in
            XCTAssertEqual(try store.load().state, .restoring)
            XCTAssertEqual(target, original)
            writes += 1; current = target
        })
        try engine.finish(&journal, store: store, verifyOnly: false, trigger: "test")
        XCTAssertEqual(writes, 1)
        XCTAssertEqual(try store.load().state, .restored)
        try engine.finish(&journal, store: store, verifyOnly: false, trigger: "test-again")
        XCTAssertEqual(writes, 1)
    }

    func testWriterSuccessWithoutRestorationIsFailure() throws {
        let store = store(); try store.lock()
        var journal = RecoveryJournal(snapshot: try snapshot())
        try store.create(journal)
        let changed = try changedDisplay("x", 100)
        let engine = RecoveryEngine(capture: { changed }, apply: { _ in })
        XCTAssertThrowsError(try engine.finish(&journal, store: store, verifyOnly: false, trigger: "deadline"))
        XCTAssertEqual(try store.load().state, .needsAttention)
        XCTAssertNotNil(try store.load().failure)
        XCTAssertEqual(try store.load().trigger, "deadline")
    }

    func testWriteFailureRetainsOriginalAndCanBeRetried() throws {
        let store = store(); try store.lock()
        let original = try snapshot()
        var journal = RecoveryJournal(snapshot: original)
        try store.create(journal)
        var current = try changedDisplay("x", 100)
        var engine = RecoveryEngine(capture: { current }, apply: { _ in throw RecoveryError.unsafe("injected failure") })
        XCTAssertThrowsError(try engine.finish(&journal, store: store, verifyOnly: false, trigger: "test"))
        XCTAssertEqual(try store.load().snapshot, original)
        XCTAssertEqual(try store.load().state, .needsAttention)
        current = original
        engine.apply = { _ in XCTFail("already restored") }
        try engine.finish(&journal, store: store, verifyOnly: false, trigger: "retry")
        XCTAssertEqual(try store.load().state, .restored)
        XCTAssertNil(try store.load().failure)
    }

    func testIdentityFailurePreventsWriter() throws {
        let store = store(); try store.lock()
        var journal = RecoveryJournal(snapshot: try snapshot())
        try store.create(journal)
        let missing = try snapshot { $0["displays"] = [] }
        let engine = RecoveryEngine(capture: { missing }, apply: { _ in XCTFail("unsafe write") })
        XCTAssertThrowsError(try engine.finish(&journal, store: store, verifyOnly: false, trigger: "test"))
        XCTAssertEqual(try store.load().state, .needsAttention)
    }

    func testIdentityChangeAfterIntentPersistenceStillPreventsWriter() throws {
        let store = store(); try store.lock()
        let original = try snapshot()
        var journal = RecoveryJournal(snapshot: original)
        try store.create(journal)
        let recycled = try changedDisplay("id", 99)
        var samples = 0
        let engine = RecoveryEngine(capture: {
            samples += 1
            return samples == 1 ? original : recycled
        }, apply: { _ in XCTFail("identity changed before writer") })
        XCTAssertThrowsError(try engine.finish(&journal, store: store, verifyOnly: false, trigger: "test"))
        XCTAssertEqual(try store.load().state, .needsAttention)
    }

    func testSuccessfulRehearsalNeverCallsWriter() throws {
        let store = store(); try store.lock()
        let original = try snapshot()
        var journal = RecoveryJournal(snapshot: original, verifyOnly: true)
        try store.create(journal)
        let engine = RecoveryEngine(capture: { original }, apply: { _ in XCTFail("rehearsal wrote") })
        try engine.finish(&journal, store: store, verifyOnly: true, trigger: "parent-exit")
        XCTAssertEqual(try store.load().state, .verified)
        XCTAssertEqual(try store.load().trigger, "parent-exit")
    }

    func testPersistenceFailurePreventsWriter() throws {
        let store = store() // Deliberately no lock: journal save must fail.
        var journal = RecoveryJournal(snapshot: try snapshot())
        let changed = try changedDisplay("x", 100)
        let engine = RecoveryEngine(capture: { changed }, apply: { _ in XCTFail("write without durable intent") })
        XCTAssertThrowsError(try engine.finish(&journal, store: store, verifyOnly: false, trigger: "test"))
    }

    private func profileSnapshot(_ profile: Data, includeDateIndependent: Bool = true) throws -> RecoverySnapshot {
        try snapshot { data in
            var displays = data["displays"] as! [[String: Any]]
            displays[0]["colorProfileDigest"] = RecoveryColorProfile.digest(profile)
            if includeDateIndependent {
                displays[0]["colorProfileDateIndependentDigest"] = RecoveryColorProfile.dateIndependentDigest(profile)
            }
            data["displays"] = displays
        }
    }

    func testICCTimestampOnlyRegenerationVerifiesWithoutWriter() throws {
        let original = try profileSnapshot(RecoveryColorProfileTests.profile())
        let current = try profileSnapshot(RecoveryColorProfileTests.profile(second: 2))
        XCTAssertNotEqual(original, current) // Preserve distinct raw evidence.
        XCTAssertNoThrow(try original.verify(current))
        let store = store(); try store.lock()
        var journal = RecoveryJournal(snapshot: original); try store.create(journal)
        let engine = RecoveryEngine(capture: { current }, apply: { _ in XCTFail("date-only change needs no write") })
        try engine.finish(&journal, store: store, verifyOnly: false, trigger: "test")
        XCTAssertEqual(try store.load().state, .restored)
        XCTAssertEqual(try store.load().snapshot, original)
    }

    func testICCContentChangeAndLegacySnapshotsStillBlockWrites() throws {
        let bytes = RecoveryColorProfileTests.profile()
        let original = try profileSnapshot(bytes)
        var altered = bytes; altered[175] ^= 1
        let changed = try profileSnapshot(altered)
        XCTAssertThrowsError(try original.verify(changed))
        let legacy = try profileSnapshot(bytes, includeDateIndependent: false)
        let dated = try profileSnapshot(RecoveryColorProfileTests.profile(second: 2))
        XCTAssertThrowsError(try legacy.verify(dated))
        XCTAssertThrowsError(try dated.verify(legacy))
        XCTAssertNoThrow(try legacy.verify(original)) // Identical raw bytes remain sufficient.
        let store = store(); try store.lock()
        var journal = RecoveryJournal(snapshot: original); try store.create(journal)
        let engine = RecoveryEngine(capture: { changed }, apply: { _ in XCTFail("changed color transform") })
        XCTAssertThrowsError(try engine.finish(&journal, store: store, verifyOnly: false, trigger: "test"))
        XCTAssertEqual(try store.load().state, .needsAttention)
        XCTAssertEqual(try store.load().snapshot, original)
    }

    func testICCDateEvidenceDoesNotHideTopologyOrOtherColorChanges() throws {
        let original = try profileSnapshot(RecoveryColorProfileTests.profile())
        let current = try profileSnapshot(RecoveryColorProfileTests.profile(second: 2))
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(current)) as! [String: Any]
        let unchanged = object["displays"] as! [[String: Any]]
        for (key, value): (String, Any) in [("x", 16), ("active", false), ("main", false),
                                          ("rotation", 90), ("colorSpace", "changed")] {
            var displays = unchanged; displays[0][key] = value; object["displays"] = displays
            let modified = try JSONDecoder().decode(RecoverySnapshot.self, from: JSONSerialization.data(withJSONObject: object))
            XCTAssertThrowsError(try original.verify(modified), key)
        }
        var invalid = unchanged; invalid[0].removeValue(forKey: "colorProfileDigest"); object["displays"] = invalid
        let missing = try JSONDecoder().decode(RecoverySnapshot.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertThrowsError(try original.verify(missing))
        XCTAssertThrowsError(try RecoveryJournal(snapshot: missing).validate())
        invalid = unchanged; invalid[0]["colorProfileDateIndependentDigest"] = "invalid"; object["displays"] = invalid
        let corrupt = try JSONDecoder().decode(RecoverySnapshot.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertThrowsError(try RecoveryJournal(snapshot: corrupt).validate())
    }

    func testOriginTrialOnlyChangesSelectedOrigin() throws {
        let original = try snapshot { data in
            var displays = data["displays"] as! [[String: Any]]
            var target = displays[0]
            target["uuid"] = "00000000-0000-0000-0000-000000000002"
            target["id"] = 8; target["main"] = false; target["x"] = 1920
            displays.append(target); data["displays"] = displays
        }
        let uuid = original.displays[1].uuid
        let moved = try RecoveryOriginTrial(uuid: uuid, x: 1920, y: 16).target(in: original)
        XCTAssertEqual(moved.displays[0], original.displays[0])
        var expected = original.displays[1]; expected.y = 16
        XCTAssertEqual(moved.displays[1], expected)
        for trial in [RecoveryOriginTrial(uuid: uuid, x: 1921, y: 16),
                      RecoveryOriginTrial(uuid: uuid, x: 1920, y: 17),
                      RecoveryOriginTrial(uuid: original.displays[0].uuid, x: 0, y: 16)] {
            XCTAssertThrowsError(try trial.target(in: original))
        }
    }

    /// Explicit opt-in only. The parent may kill ITSELF; never a journal PID.
    func testApprovedLiveOriginTrial() throws {
        let env = ProcessInfo.processInfo.environment
        guard let trialMode = env["PANELCTL_APPROVED_ORIGIN_TRIAL"],
              ["timed", "parent-kill"].contains(trialMode),
              let binary = env["PANELCTL_TRIAL_BINARY"],
              let journalPath = env["PANELCTL_TRIAL_JOURNAL"] else {
            throw XCTSkip("requires specific live-trial approval and artifact paths")
        }
        guard let baselineY = Int32(env["PANELCTL_TRIAL_BASELINE_Y"] ?? "-20"),
              [-20, -4].contains(baselineY) else {
            throw RecoveryError.unsafe("trial baseline must be an explicitly approved origin")
        }
        let baseline = try RecoverySnapshot.capture()
        guard baseline.displays.allSatisfy({ $0.colorProfileDigest != nil && $0.colorProfileDateIndependentDigest != nil }) else {
            throw RecoveryError.unsafe("trial requires complete eligible ICC fingerprint evidence")
        }
        let uuid = "09084682-3c42-4455-aab8-126a7431125b"
        let target = try XCTUnwrap(baseline.displays.first { $0.uuid == uuid })
        XCTAssertEqual(target.vendor, 4268); XCTAssertEqual(target.model, 16857)
        XCTAssertEqual(target.serial, 1094800204)
        guard target.x == 3440, target.y == baselineY, target.vendor == 4268,
              target.model == 16857, target.serial == 1094800204 else {
            throw RecoveryError.unsafe("approved DELL S2721DGF baseline changed")
        }
        let store = RecoveryStore(url: URL(fileURLWithPath: journalPath))
        let session = try RecoveryWatchdog.start(store: store, executable: URL(fileURLWithPath: binary),
                                                timeout: 10, verifyOnly: false,
                                                originTrial: RecoveryOriginTrial(uuid: uuid, x: 3440, y: baselineY + 16))
        try session.requestOriginTrial()
        if trialMode == "parent-kill" {
            let until = Date().addingTimeInterval(3)
            while try store.load().trigger != "origin-trial-applied", Date() < until {
                RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            }
            guard try store.load().trigger == "origin-trial-applied" else {
                throw RecoveryError.unsafe("trial did not apply; will not kill parent")
            }
            raise(SIGKILL)
        }
        session.wait()
        let final = try store.load()
        XCTAssertEqual(final.state, .restored, final.failure ?? "")
        XCTAssertEqual(final.trigger, "deadline")
        try baseline.verify(.capture())
    }

    func testRecoveryCLIValidation() throws {
        for action in ["capture", "status", "verify", "restore", "rehearse", "guard"] {
            XCTAssertEqual(try CLIParser.parse(["recovery", action]),
                           .recovery(action: RecoveryAction(rawValue: action)!, timeout: nil, journalPath: nil))
        }
        XCTAssertEqual(try CLIParser.parse(["recovery", "rehearse", "--timeout", "1m", "--journal", "/private/test/current.json"]),
                       .recovery(action: .rehearse, timeout: 60, journalPath: "/private/test/current.json"))
        for args in [
            ["recovery"], ["recovery", "disable"], ["recovery", "arm"],
            ["recovery", "restore", "--timeout", "5s"],
            ["recovery", "rehearse", "--timeout", "0.5s"],
            ["recovery", "rehearse", "--timeout", "61s"],
            ["recovery", "rehearse", "--timeout", "2s", "--timeout", "3s"],
            ["recovery", "capture", "--journal"],
            ["recovery", "capture", "--journal", "a", "--journal", "b"],
            ["_recovery-helper", "--journal", "a", "--id", "not-a-uuid"]
        ] { XCTAssertThrowsError(try CLIParser.parse(args), args.joined(separator: " ")) }
        XCTAssertEqual(try CLIParser.parse(["recovery", "guard", "--timeout", "15s"]),
                       .recovery(action: .guard, timeout: 15, journalPath: nil))
        XCTAssertTrue(CLIHelp.text(for: "recovery").contains("no-write"))
    }
}
