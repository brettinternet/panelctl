import XCTest
import CoreGraphics
import Darwin
@testable import PanelCtlCore

final class RecoveryReenableTests: XCTestCase {
    private var directory: URL!
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("panelctl-enable-tests-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }

    private func fixture(_ modify: (inout [String: Any]) -> Void = { _ in }) throws -> RecoverySnapshot {
        var value: [String: Any] = ["bootSession": "boot", "osBuild": "build", "userID": getuid(),
            "displays": (1...2).map { index -> [String: Any] in
                ["uuid": "00000000-0000-0000-0000-00000000000\(index)", "id": index,
                 "vendor": 4268, "model": 16857, "serial": index, "builtin": false,
                 "main": index == 1, "active": true, "x": (index - 1) * 1920, "y": 0,
                 "rotation": 0, "connector": "connector-\(index)", "colorSpace": "test",
                 "mode": ["id": 1, "width": 1920, "height": 1080, "pixelWidth": 1920,
                          "pixelHeight": 1080, "refreshRate": 60, "flags": 0]]
            }]
        modify(&value)
        return try JSONDecoder().decode(RecoverySnapshot.self, from: JSONSerialization.data(withJSONObject: value))
    }
    private func missing(_ snapshot: RecoverySnapshot) -> RecoverySnapshot {
        RecoverySnapshot(bootSession: snapshot.bootSession, osBuild: snapshot.osBuild,
                         userID: snapshot.userID, displays: Array(snapshot.displays.prefix(1)))
    }
    private func evidence(_ original: RecoverySnapshot, online: Set<UInt32> = [1]) -> RecoveryEnableInventory {
        RecoveryEnableInventory(bootSession: original.bootSession, osBuild: original.osBuild,
                                userID: original.userID, identities: original.displays.map(RecoveryEnableIdentity.init),
                                onlineIDs: online)
    }
    private func store() throws -> RecoveryStore {
        let store = RecoveryStore(url: directory.appendingPathComponent("current.json"))
        try store.lock(); return store
    }

    func testDefaultProviderAndDefaultEngineRefuseMissingDisplay() throws {
        let original = try fixture(), absent = missing(original)
        XCTAssertThrowsError(try RecoveryReenable().target(snapshot: original, current: absent))
        let store = try store()
        var journal = RecoveryJournal(snapshot: original); try store.create(journal)
        let engine = RecoveryEngine(capture: { absent }, apply: { _ in XCTFail("public write") })
        XCTAssertThrowsError(try engine.finish(&journal, store: store, verifyOnly: false, trigger: "test"))
        XCTAssertEqual(try store.load().state, .needsAttention)
        XCTAssertNil(try store.load().reenableAttempted)
    }

    func testIdentityReuseAmbiguityHardwareConnectorAndHostChangesRefused() throws {
        let original = try fixture(), absent = missing(original)
        var variants: [RecoverySnapshot] = []
        for (key, value): (String, Any) in [("id", 3), ("uuid", original.displays[0].uuid),
                                          ("vendor", 99), ("model", 99), ("serial", 99),
                                          ("builtin", true), ("connector", "other")] {
            variants.append(try fixture { object in
                var displays = object["displays"] as! [[String: Any]]
                displays[1][key] = value; object["displays"] = displays
            })
        }
        for key in ["bootSession", "osBuild"] { variants.append(try fixture { $0[key] = "changed" }) }
        variants.append(try fixture { $0["userID"] = getuid() + 1 })
        variants.append(try fixture { data in
            let displays = data["displays"] as! [[String: Any]]
            data["displays"] = displays + [displays[1]]
        })
        for variant in variants {
            let backend = RecoveryReenable(inventory: { self.evidence(variant) }, enable: { _, _ in XCTFail("write") })
            XCTAssertThrowsError(try backend.target(snapshot: original, current: absent))
        }
        let online = RecoveryReenable(inventory: { self.evidence(original, online: [1, 2]) })
        XCTAssertThrowsError(try online.target(snapshot: original, current: absent))
        XCTAssertThrowsError(try online.target(snapshot: original, current: original))
    }

    func testUnknownOriginalIdentityAndMainTargetRefused() throws {
        for key in ["connector", "serial", "vendor", "model"] {
            let original = try fixture { data in
                var displays = data["displays"] as! [[String: Any]]
                displays[1][key] = key == "connector" ? "" : 0
                data["displays"] = displays
            }
            let backend = RecoveryReenable(inventory: { self.evidence(original) })
            XCTAssertThrowsError(try backend.target(snapshot: original, current: missing(original)))
        }
        let main = try fixture { data in
            var displays = data["displays"] as! [[String: Any]]
            displays[0]["main"] = false; displays[1]["main"] = true; data["displays"] = displays
        }
        XCTAssertThrowsError(try RecoveryReenable(inventory: { self.evidence(main) }).target(snapshot: main, current: missing(main)))
    }

    func testOneShotEnablePersistsIntentThenPublicRestoreAndVerification() throws {
        let original = try fixture(), store = try store()
        var current = missing(original), writes = 0
        var journal = RecoveryJournal(snapshot: original); try store.create(journal)
        let backend = RecoveryReenable(inventory: { self.evidence(original) }, enable: { id, validate in
            XCTAssertEqual(id, 2)
            XCTAssertEqual(try store.load().state, .restoring)
            XCTAssertEqual(try store.load().reenableAttempted, true)
            try validate(); writes += 1
            var displays = original.displays; displays[1].x += 10
            current = RecoverySnapshot(bootSession: original.bootSession, osBuild: original.osBuild,
                                       userID: original.userID, displays: displays)
        })
        let engine = RecoveryEngine(capture: { current }, apply: { current = $0 }, reenable: backend)
        try engine.finish(&journal, store: store, verifyOnly: false, trigger: "parent-exit")
        XCTAssertEqual(try store.load().state, .restored)
        XCTAssertEqual(writes, 1)
        try engine.finish(&journal, store: store, verifyOnly: false, trigger: "again")
        XCTAssertEqual(writes, 1)
    }

    func testAPIAbsenceErrorAndUnsuccessfulVerificationRetainEvidenceWithoutReplay() throws {
        for failure in ["API absent", "API error", "success without reconnect"] {
            let store = RecoveryStore(url: directory.appendingPathComponent(UUID().uuidString + ".json"))
            try store.lock()
            let original = try fixture(), absent = missing(original)
            var journal = RecoveryJournal(snapshot: original); try store.create(journal)
            var writes = 0
            let backend = RecoveryReenable(inventory: { self.evidence(original) }, enable: { _, validate in
                try validate(); writes += 1
                if failure != "success without reconnect" { throw RecoveryError.unsafe(failure) }
            })
            let engine = RecoveryEngine(capture: { absent }, apply: { _ in XCTFail("public write") }, reenable: backend)
            XCTAssertThrowsError(try engine.finish(&journal, store: store, verifyOnly: false, trigger: "deadline"))
            XCTAssertEqual(try store.load().snapshot, original)
            XCTAssertEqual(try store.load().state, .needsAttention)
            journal = try store.load()
            XCTAssertThrowsError(try engine.finish(&journal, store: store, verifyOnly: false, trigger: "retry"))
            XCTAssertEqual(writes, 1)
        }
    }

    func testCrashAfterDurableIntentCannotReplayAndVerifyOnlyCannotEnable() throws {
        let original = try fixture(), absent = missing(original), store = try store()
        var journal = RecoveryJournal(snapshot: original)
        journal.state = .restoring; journal.reenableAttempted = true
        try store.create(journal) // Simulates process death after intent, before/after commit.
        journal = try store.load()
        let backend = RecoveryReenable(inventory: { self.evidence(original) }, enable: { _, _ in XCTFail("replayed") })
        let engine = RecoveryEngine(capture: { absent }, apply: { _ in XCTFail("public write") }, reenable: backend)
        XCTAssertThrowsError(try engine.finish(&journal, store: store, verifyOnly: false, trigger: "after-crash"))
        journal.reenableAttempted = nil
        XCTAssertThrowsError(try engine.finish(&journal, store: store, verifyOnly: true, trigger: "verify"))
    }

    func testJournalFailurePreventsEnableAndCompletionFailureRetainsIntent() throws {
        let original = try fixture(), absent = missing(original)
        let unlocked = RecoveryStore(url: directory.appendingPathComponent("unlocked.json"))
        var journal = RecoveryJournal(snapshot: original)
        let blocked = RecoveryReenable(inventory: { self.evidence(original) }, enable: { _, _ in XCTFail("write without intent") })
        XCTAssertThrowsError(try RecoveryEngine(capture: { absent }, reenable: blocked)
            .finish(&journal, store: unlocked, verifyOnly: false, trigger: "test"))

        let store = try store(); journal = RecoveryJournal(snapshot: original); try store.create(journal)
        var current = absent
        let backend = RecoveryReenable(inventory: { self.evidence(original) }, enable: { _, validate in
            try validate(); current = original; store.unlock() // Inject final persistence failure.
        })
        XCTAssertThrowsError(try RecoveryEngine(capture: { current }, reenable: backend)
            .finish(&journal, store: store, verifyOnly: false, trigger: "test"))
        XCTAssertEqual(try store.load().state, .restoring)
        XCTAssertEqual(try store.load().reenableAttempted, true)
        XCTAssertEqual(try store.load().snapshot, original)
    }

    func testIdentityRacePreventsSetter() throws {
        let original = try fixture(), absent = missing(original), store = try store()
        var journal = RecoveryJournal(snapshot: original); try store.create(journal)
        var reads = 0
        let backend = RecoveryReenable(inventory: {
            reads += 1
            if reads > 1 { throw RecoveryError.unsafe("binding changed") }
            return self.evidence(original)
        }, enable: { _, _ in XCTFail("stale identity") })
        XCTAssertThrowsError(try RecoveryEngine(capture: { absent }, reenable: backend)
            .finish(&journal, store: store, verifyOnly: false, trigger: "test"))
    }

    func testTransactionOrderingCancellationAndConsumedCommitErrors() throws {
        let config = CGDisplayConfigRef(bitPattern: 1)!
        for failure in ["none", "begin", "set", "commit", "validate-3"] {
            var events: [String] = [], validations = 0
            func step(_ name: String) throws {
                events.append(name)
                if failure == name { throw RecoveryError.unsafe(name) }
            }
            let transaction = RecoveryEnableTransaction(begin: { try step("begin"); return config },
                setEnabled: { pointer, id in XCTAssertEqual(pointer, config); XCTAssertEqual(id, 2); try step("set") },
                commit: { _ in try step("commit") }, cancel: { _ in events.append("cancel") })
            let operation = {
                try transaction.enable(id: 2) {
                    validations += 1; try step("validate-\(validations)")
                }
            }
            if failure == "none" { XCTAssertNoThrow(try operation()) }
            else { XCTAssertThrowsError(try operation()) }
            XCTAssertEqual(events.contains("cancel"), ["set", "validate-3"].contains(failure))
            if failure == "none" {
                XCTAssertEqual(events, ["validate-1", "begin", "validate-2", "set", "validate-3", "commit"])
            }
        }
    }
}
