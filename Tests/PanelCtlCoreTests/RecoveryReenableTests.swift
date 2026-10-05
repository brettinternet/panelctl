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
        var value: [String: Any] = ["bootSession": "boot", "osBuild": "build", "userID": getuid(), "hostModel": "synthetic-model",
            "displays": (1...2).map { index -> [String: Any] in
                let identityEvidence: [String: Any] = ["source": "syntheticFixture", "capturedAt": 0,
                    "transport": "DisplayPort", "framebufferLocation": "frame-\(index)"]
                return ["uuid": "00000000-0000-0000-0000-00000000000\(index)", "id": index,
                    "vendor": 4268, "model": index + 16857, "serial": index, "builtin": false,
                    "main": index == 1, "active": true, "x": (index - 1) * 1920, "y": 0,
                    "rotation": 0, "connector": "connector-\(index)", "colorSpace": "test",
                    "identityEvidence": identityEvidence,
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
                                onlineIDs: online, hostModel: original.hostModel, architecture: "synthetic", binding: .syntheticPhysicalFixture)
    }
    private func store() throws -> RecoveryStore {
        let store = RecoveryStore(url: directory.appendingPathComponent("current.json"))
        try store.lock(); return store
    }

    func testDefaultProviderAndDefaultEngineRefuseMissingDisplay() throws {
        let original = try fixture(), absent = missing(original)
        XCTAssertThrowsError(try RecoveryReenable().target(snapshot: original, current: absent))
        let store = try store()
        var journal = RecoveryJournal(snapshot: original, disabledByUsID: 2, disableStaged: true, disableCommitStarted: true); try store.create(journal)
        let engine = RecoveryEngine(capture: { absent }, apply: { _ in XCTFail("public write") })
        XCTAssertThrowsError(try engine.finish(&journal, store: store, verifyOnly: false, trigger: "test"))
        XCTAssertEqual(try store.load().state, .needsAttention)
        XCTAssertNil(try store.load().reenableAttempted)
    }

    func testDefaultTransportRefusesEvenWithInjectedIdentity() throws {
        let original = try fixture(), absent = missing(original)
        let backend = RecoveryReenable(inventory: { self.evidence(original) })
        XCTAssertThrowsError(try backend.restoreMissing(snapshot: original, capture: { absent })) { error in
            XCTAssertTrue(String(describing: error).contains("private transport unavailable"))
        }
    }

    func testLegacyV1JournalDecodesWithoutPrivateOrNormalizedEvidence() throws {
        let original = try fixture { data in
            var displays = data["displays"] as! [[String: Any]]
            for index in displays.indices { displays[index].removeValue(forKey: "identityEvidence") }
            data["displays"] = displays
        }, store = try store()
        let journal = RecoveryJournal(snapshot: original)
        let bytes = try JSONEncoder().encode(journal)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        object["version"] = 1
        XCTAssertNil(object["reenableAttempted"])
        let displays = try XCTUnwrap((object["snapshot"] as? [String: Any])?["displays"] as? [[String: Any]])
        XCTAssertTrue(displays.allSatisfy { $0["colorProfileDateIndependentDigest"] == nil })
        let legacy = try JSONDecoder().decode(RecoveryJournal.self, from: JSONSerialization.data(withJSONObject: object))
        try store.create(legacy)
        XCTAssertEqual(try store.load().version, 1)
        XCTAssertNil(try store.load().reenableAttempted)
        XCTAssertEqual(try store.load().snapshot, original)
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

    private func productionFixture(_ modify: (inout [String: Any]) -> Void = { _ in }) throws -> RecoverySnapshot {
        try fixture { data in
            data["osBuild"] = RecoveryIdentityPolicy.supportedOSBuild
            data["hostModel"] = RecoveryIdentityPolicy.supportedHostModel
            var displays = data["displays"] as! [[String: Any]]
            for index in displays.indices {
                displays[index]["identityEvidence"] = ["source": "cgAndCoreDisplay", "capturedAt": 0,
                    "transport": "DisplayPort", "transportLocation": "transport-frame-\(index + 1)",
                    "hpd": "High", "framebufferLocation": "frame-\(index + 1)"]
            }
            data["displays"] = displays
            modify(&data)
        }
    }

    private func productionEvidence(_ snapshot: RecoverySnapshot, online: Set<UInt32> = [1]) -> RecoveryEnableInventory {
        let identities = snapshot.displays.map { display in
            RecoveryEnableIdentity(uuid: online.contains(display.id) ? display.uuid : nil, id: display.id,
                vendor: display.vendor, model: display.model, serial: display.serial, builtin: display.builtin,
                connector: display.connector ?? "", transport: display.identityEvidence?.transport ?? "",
                framebufferLocation: online.contains(display.id) ? display.identityEvidence?.framebufferLocation : nil,
                transportLocation: display.identityEvidence?.transportLocation)
        }
        return RecoveryEnableInventory(bootSession: snapshot.bootSession, osBuild: snapshot.osBuild,
            userID: snapshot.userID, identities: identities, onlineIDs: online, hostModel: snapshot.hostModel,
            architecture: "arm64", binding: .captureMatch)
    }

    func testCompleteProductionIdentityMatchAndMismatchMatrix() throws {
        let snapshot = try productionFixture()
        let matched = productionEvidence(snapshot)
        XCTAssertEqual(RecoveryIdentityPolicy.evaluate(snapshot: snapshot, evidence: matched).outcome, .eligible)
        let changes: [(String, (inout RecoveryEnableIdentity) -> Void)] = [
            ("vendor", { $0 = RecoveryEnableIdentity(uuid: $0.uuid, id: $0.id, vendor: 9, model: $0.model, serial: $0.serial, builtin: $0.builtin, connector: $0.connector, transport: $0.transport, framebufferLocation: $0.framebufferLocation, transportLocation: $0.transportLocation) }),
            ("product", { $0 = RecoveryEnableIdentity(uuid: $0.uuid, id: $0.id, vendor: $0.vendor, model: 9, serial: $0.serial, builtin: $0.builtin, connector: $0.connector, transport: $0.transport, framebufferLocation: $0.framebufferLocation, transportLocation: $0.transportLocation) }),
            ("serial", { $0 = RecoveryEnableIdentity(uuid: $0.uuid, id: $0.id, vendor: $0.vendor, model: $0.model, serial: 9, builtin: $0.builtin, connector: $0.connector, transport: $0.transport, framebufferLocation: $0.framebufferLocation, transportLocation: $0.transportLocation) }),
            ("connector", { $0 = RecoveryEnableIdentity(uuid: $0.uuid, id: $0.id, vendor: $0.vendor, model: $0.model, serial: $0.serial, builtin: $0.builtin, connector: "other", transport: $0.transport, framebufferLocation: $0.framebufferLocation, transportLocation: $0.transportLocation) }),
            ("transport", { $0 = RecoveryEnableIdentity(uuid: $0.uuid, id: $0.id, vendor: $0.vendor, model: $0.model, serial: $0.serial, builtin: $0.builtin, connector: $0.connector, transport: "HDMI", framebufferLocation: $0.framebufferLocation, transportLocation: $0.transportLocation) }),
            ("transport location", { $0 = RecoveryEnableIdentity(uuid: $0.uuid, id: $0.id, vendor: $0.vendor, model: $0.model, serial: $0.serial, builtin: $0.builtin, connector: $0.connector, transport: $0.transport, framebufferLocation: $0.framebufferLocation, transportLocation: "other") }),
            ("location", { $0 = RecoveryEnableIdentity(uuid: $0.uuid, id: $0.id, vendor: $0.vendor, model: $0.model, serial: $0.serial, builtin: $0.builtin, connector: $0.connector, transport: $0.transport, framebufferLocation: "other", transportLocation: $0.transportLocation) }),
            ("uuid", { $0 = RecoveryEnableIdentity(uuid: "00000000-0000-0000-0000-000000000099", id: $0.id, vendor: $0.vendor, model: $0.model, serial: $0.serial, builtin: $0.builtin, connector: $0.connector, transport: $0.transport, framebufferLocation: $0.framebufferLocation, transportLocation: $0.transportLocation) })
        ]
        for (field, mutate) in changes {
            var evidence = matched
            mutate(&evidence.identities[0])
            XCTAssertEqual(RecoveryIdentityPolicy.evaluate(snapshot: snapshot, evidence: evidence).outcome, .stale, field)
        }
        for field in ["vendor", "product", "serial", "connector", "transport", "transportLocation"] {
            var evidence = matched
            let old = evidence.identities[0]
            evidence.identities[0] = RecoveryEnableIdentity(uuid: old.uuid, id: old.id,
                vendor: field == "vendor" ? 0 : old.vendor, model: field == "product" ? 0 : old.model,
                serial: field == "serial" ? 0 : old.serial, builtin: old.builtin,
                connector: field == "connector" ? "" : old.connector,
                transport: field == "transport" ? "" : old.transport, framebufferLocation: old.framebufferLocation,
                transportLocation: field == "transportLocation" ? "" : old.transportLocation)
            XCTAssertEqual(RecoveryIdentityPolicy.evaluate(snapshot: snapshot, evidence: evidence).outcome, .missingEvidence, field)
        }
        let peers = try productionFixture { data in
            var displays = data["displays"] as! [[String: Any]]
            displays[1]["model"] = displays[0]["model"]
            data["displays"] = displays
        }
        XCTAssertEqual(RecoveryIdentityPolicy.evaluate(snapshot: peers, evidence: productionEvidence(peers)).outcome, .ambiguous)
        var wrongArchitecture = matched; wrongArchitecture = RecoveryEnableInventory(bootSession: matched.bootSession,
            osBuild: matched.osBuild, userID: matched.userID, identities: matched.identities,
            onlineIDs: matched.onlineIDs, hostModel: matched.hostModel, architecture: "x86_64", binding: .captureMatch)
        XCTAssertEqual(RecoveryIdentityPolicy.evaluate(snapshot: snapshot, evidence: wrongArchitecture).outcome, .unsupported)
        var wrongBuild = RecoveryEnableInventory(bootSession: matched.bootSession, osBuild: "26A435",
            userID: matched.userID, identities: matched.identities, onlineIDs: matched.onlineIDs,
            hostModel: matched.hostModel, architecture: "arm64", binding: .captureMatch)
        XCTAssertEqual(RecoveryIdentityPolicy.evaluate(snapshot: snapshot, evidence: wrongBuild).outcome, .stale)
        wrongBuild = RecoveryEnableInventory(bootSession: snapshot.bootSession, osBuild: "26A435",
            userID: snapshot.userID, identities: matched.identities, onlineIDs: matched.onlineIDs,
            hostModel: snapshot.hostModel, architecture: "arm64", binding: .captureMatch)
        let unsupportedBuild = RecoverySnapshot(bootSession: snapshot.bootSession, osBuild: "26A435",
            userID: snapshot.userID, displays: snapshot.displays, hostModel: snapshot.hostModel)
        XCTAssertEqual(RecoveryIdentityPolicy.evaluate(snapshot: unsupportedBuild, evidence: wrongBuild).outcome, .unsupported)
        let unsupportedHost = try productionFixture { $0["hostModel"] = "Mac14,13" }
        XCTAssertEqual(RecoveryIdentityPolicy.evaluate(snapshot: unsupportedHost,
            evidence: productionEvidence(unsupportedHost)).outcome, .unsupported)
        var changedHost = matched
        changedHost = RecoveryEnableInventory(bootSession: matched.bootSession, osBuild: matched.osBuild,
            userID: matched.userID, identities: matched.identities, onlineIDs: matched.onlineIDs,
            hostModel: "Mac14,13", architecture: "arm64", binding: .captureMatch)
        XCTAssertEqual(RecoveryIdentityPolicy.evaluate(snapshot: snapshot, evidence: changedHost).outcome, .stale)
    }

    func testAbsentTargetCaptureMatchRetainsIDAndFakeWriterEnableRefusesBoundaryChange() throws {
        let snapshot = try productionFixture(), absent = missing(snapshot)
        let store = try store()
        var journal = RecoveryJournal(snapshot: snapshot, disabledByUsID: 2, disableStaged: true, disableCommitStarted: true)
        try store.create(journal)
        var current = absent, calls: [String] = []
        let evidence = productionEvidence(snapshot)
        let transaction = RecoveryEnableTransaction(begin: { calls.append("begin"); return CGDisplayConfigRef(bitPattern: 1)! },
            setEnabled: { _, id, enabled in XCTAssertEqual(id, 2); XCTAssertTrue(enabled); calls.append("setter") },
            commit: { _, scope in XCTAssertEqual(scope, .forSession); calls.append("commit"); current = snapshot },
            cancel: { _ in calls.append("cancel") })
        let backend = RecoveryReenable(inventory: { evidence },
            enable: { id, validate in try transaction.enable(id: id, revalidate: validate) })
        let engine = RecoveryEngine(capture: { current }, apply: { _ in XCTFail("public writer not expected") },
            reenable: backend, convergencePause: {})
        try engine.finish(&journal, store: store, verifyOnly: false, trigger: "fake-writer")
        XCTAssertEqual(calls, ["begin", "setter", "commit"])
        XCTAssertEqual(try store.load().state, .restored)

        var invalidated = evidence
        invalidated.identities[1] = RecoveryEnableIdentity(uuid: nil, id: 2, vendor: 4268,
            model: snapshot.displays[1].model, serial: 99, builtin: false,
            connector: snapshot.displays[1].connector ?? "", transport: "DisplayPort", framebufferLocation: nil,
            transportLocation: snapshot.displays[1].identityEvidence?.transportLocation)
        var refusals: [String] = []
        let guarded = RecoveryReenable(inventory: { invalidated }, enable: { _, _ in XCTFail("mismatch wrote") })
        XCTAssertThrowsError(try guarded.target(snapshot: snapshot, current: absent))
        refusals.append(RecoveryIdentityPolicy.evaluate(snapshot: snapshot, evidence: invalidated).diagnostic)
        XCTAssertEqual(RecoveryIdentityPolicy.evaluate(snapshot: snapshot, evidence: invalidated).outcome, .stale)
        XCTAssertFalse(refusals.isEmpty)
    }

    func testOneShotEnablePersistsIntentThenPublicRestoreAndVerification() throws {
        let original = try fixture(), store = try store()
        var current = missing(original), writes = 0
        var journal = RecoveryJournal(snapshot: original, disabledByUsID: 2, disableStaged: true, disableCommitStarted: true); try store.create(journal)
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
            var journal = RecoveryJournal(snapshot: original, disabledByUsID: 2, disableStaged: true, disableCommitStarted: true); try store.create(journal)
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
        var journal = RecoveryJournal(snapshot: original, disabledByUsID: 2, disableStaged: true, disableCommitStarted: true)
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
        var journal = RecoveryJournal(snapshot: original, disabledByUsID: 2, disableStaged: true, disableCommitStarted: true)
        let blocked = RecoveryReenable(inventory: { self.evidence(original) }, enable: { _, _ in XCTFail("write without intent") })
        XCTAssertThrowsError(try RecoveryEngine(capture: { absent }, reenable: blocked)
            .finish(&journal, store: unlocked, verifyOnly: false, trigger: "test"))

        let store = try store(); journal = RecoveryJournal(snapshot: original, disabledByUsID: 2, disableStaged: true, disableCommitStarted: true); try store.create(journal)
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
        var journal = RecoveryJournal(snapshot: original, disabledByUsID: 2, disableStaged: true, disableCommitStarted: true); try store.create(journal)
        var reads = 0
        let backend = RecoveryReenable(inventory: {
            reads += 1
            if reads > 1 { throw RecoveryError.unsafe("binding changed") }
            return self.evidence(original)
        }, enable: { _, _ in XCTFail("stale identity") })
        XCTAssertThrowsError(try RecoveryEngine(capture: { absent }, reenable: backend)
            .finish(&journal, store: store, verifyOnly: false, trigger: "test"))
    }

    func testPolicyOutcomesAndRefusalsNeverWriteOrReplay() throws {
        let original = try fixture()
        var cases: [(RecoverySnapshot, RecoveryEnableInventory, RecoveryIdentityOutcome)] = []
        cases.append((original, evidence(original), .eligible))
        var cached = evidence(original); cached.binding = .unqualified
        cases.append((original, cached, .unsupported)) // includes ghost/virtual/unqualified providers
        var stale = evidence(original); stale.binding = .stale
        cases.append((original, stale, .stale))
        for (key, value, outcome): (String, Any, RecoveryIdentityOutcome) in [
            ("serial", 0, .missingEvidence),
            ("connector", "", .missingEvidence), ("identityEvidence", NSNull(), .missingEvidence)
        ] {
            let snapshot = try fixture { data in
                var displays = data["displays"] as! [[String: Any]]
                displays[1][key] = value; data["displays"] = displays
            }
            cases.append((snapshot, evidence(snapshot), outcome))
        }
        for (key, value): (String, Any) in [("id", 3), ("serial", 99), ("connector", "other-port")] {
            let changed = try fixture { data in
                var displays = data["displays"] as! [[String: Any]]
                displays[1][key] = value; data["displays"] = displays
            }
            cases.append((original, evidence(changed), .stale))
        }
        for key in ["bootSession", "osBuild", "userID"] {
            let changed = try fixture { $0[key] = key == "userID" ? getuid() + 1 : "changed" }
            cases.append((original, evidence(changed), .stale))
        }
        let identicalModelPeer = try fixture { data in
            var displays = data["displays"] as! [[String: Any]]
            displays[1]["model"] = displays[0]["model"]
            data["displays"] = displays
        }
        cases.append((identicalModelPeer, evidence(identicalModelPeer), .ambiguous))
        var realDisplays = original.displays
        for index in realDisplays.indices {
            realDisplays[index].identityEvidence = RecoveryIdentityEvidence(
                source: .cgAndCoreDisplay, capturedAt: Date(), transport: "DisplayPort",
                hpd: "High", framebufferLocation: "frame-\(index + 1)")
        }
        let realCapture = RecoverySnapshot(bootSession: original.bootSession, osBuild: original.osBuild,
                                           userID: original.userID, displays: realDisplays, hostModel: original.hostModel)
        cases.append((realCapture, evidence(realCapture), .unsupported))
        for (snapshot, inventory, outcome) in cases {
            XCTAssertEqual(RecoveryIdentityPolicy.evaluate(snapshot: snapshot, evidence: inventory).outcome, outcome)
            if outcome == .eligible { continue }
            let store = RecoveryStore(url: directory.appendingPathComponent(UUID().uuidString + ".json"))
            try store.lock()
            var journal = RecoveryJournal(snapshot: snapshot, disabledByUsID: 2, disableStaged: true, disableCommitStarted: true)
            try store.create(journal)
            let backend = RecoveryReenable(inventory: { inventory }, enable: { _, _ in XCTFail("unsafe private write") })
            let engine = RecoveryEngine(capture: { self.missing(snapshot) }, apply: { _ in XCTFail("unsafe public write") }, reenable: backend)
            for _ in 0..<2 {
                XCTAssertThrowsError(try engine.finish(&journal, store: store, verifyOnly: false, trigger: "test"))
                journal = try store.load()
                XCTAssertEqual(journal.state, .needsAttention)
                XCTAssertNil(journal.reenableAttempted)
            }
        }
    }

    func testMissingOrWrongIntentAndLegacyVersionCannotEnable() throws {
        let original = try fixture()
        for intent: UInt32? in [nil, 1, 2] {
            let store = RecoveryStore(url: directory.appendingPathComponent(UUID().uuidString + ".json"))
            try store.lock()
            var journal = RecoveryJournal(snapshot: original, disabledByUsID: intent, disableStaged: true, disableCommitStarted: true)
            if intent == 2 {
                var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(journal)) as! [String: Any]
                object["version"] = 1
                journal = try JSONDecoder().decode(RecoveryJournal.self, from: JSONSerialization.data(withJSONObject: object))
            }
            try store.create(journal)
            let backend = RecoveryReenable(inventory: { self.evidence(original) }, enable: { _, _ in XCTFail("intent missing") })
            XCTAssertThrowsError(try RecoveryEngine(capture: { self.missing(original) }, reenable: backend)
                .finish(&journal, store: store, verifyOnly: false, trigger: "test"))
            XCTAssertEqual(try store.load().state, .needsAttention)
        }
    }

    func testVersionTwoIntentWithoutStagingEvidenceCannotEnable() throws {
        let original = try fixture(), store = try store()
        var journal = RecoveryJournal(snapshot: original, disabledByUsID: 2)
        try store.create(journal)
        let backend = RecoveryReenable(inventory: { self.evidence(original) }, enable: { _, _ in XCTFail("unstaged intent") })
        XCTAssertThrowsError(try RecoveryEngine(capture: { self.missing(original) }, reenable: backend)
            .finish(&journal, store: store, verifyOnly: false, trigger: "startup"))
        XCTAssertEqual(try store.load().state, .needsAttention)
        XCTAssertNil(try store.load().reenableAttempted)
    }

    func testEvidenceAndIntentRoundTripWithoutInferringAuthority() throws {
        let original = try fixture(), store = try store()
        try store.create(RecoveryJournal(snapshot: original, disabledByUsID: 2, disableStaged: true, disableCommitStarted: true))
        let loaded = try store.load()
        XCTAssertEqual(loaded.version, 2)
        XCTAssertEqual(loaded.disabledByUsID, 2)
        XCTAssertEqual(loaded.disableStaged, true)
        XCTAssertEqual(loaded.disableCommitStarted, true)
        XCTAssertEqual(loaded.snapshot, original)
        var unqualified = evidence(loaded.snapshot); unqualified.binding = .unqualified
        XCTAssertEqual(RecoveryIdentityPolicy.evaluate(snapshot: loaded.snapshot, evidence: unqualified).outcome, .unsupported)
    }

    func testConsumedTransactionFailurePreservesJournalAndCannotReplay() throws {
        let original = try fixture(), absent = missing(original), store = try store()
        var journal = RecoveryJournal(snapshot: original, disabledByUsID: 2, disableStaged: true, disableCommitStarted: true)
        try store.create(journal)
        var stages = 0, completions = 0, cancellations = 0
        let transaction = RecoveryEnableTransaction(begin: { CGDisplayConfigRef(bitPattern: 1)! },
            setEnabled: { _, id, enabled in
                XCTAssertEqual(id, 2); XCTAssertTrue(enabled); stages += 1
            }, commit: { _, scope in
                XCTAssertEqual(scope, .forSession); completions += 1
                throw RecoveryError.unsafe("completion failed")
            }, cancel: { _ in cancellations += 1 })
        let backend = RecoveryReenable(inventory: { self.evidence(original) }, enable: transaction.enable)
        let engine = RecoveryEngine(capture: { absent }, apply: { _ in XCTFail("public write") }, reenable: backend)
        XCTAssertThrowsError(try engine.finish(&journal, store: store, verifyOnly: false, trigger: "test"))
        journal = try store.load()
        XCTAssertEqual(journal.state, .needsAttention)
        XCTAssertEqual(journal.snapshot, original)
        XCTAssertEqual(journal.reenableAttempted, true)
        XCTAssertThrowsError(try engine.finish(&journal, store: store, verifyOnly: false, trigger: "retry"))
        XCTAssertEqual(stages, 1); XCTAssertEqual(completions, 1); XCTAssertEqual(cancellations, 0)
    }

    func testTransactionOrderingCancellationAndConsumedCommitErrors() throws {
        let config = CGDisplayConfigRef(bitPattern: 1)!
        for failure in ["none", "begin", "set", "commit", "validate-1", "validate-2", "validate-3"] {
            var events: [String] = [], validations = 0
            func step(_ name: String) throws {
                events.append(name)
                if failure == name { throw RecoveryError.unsafe(name) }
            }
            let transaction = RecoveryEnableTransaction(begin: { try step("begin"); return config },
                setEnabled: { pointer, id, enabled in
                    XCTAssertEqual(pointer, config); XCTAssertEqual(id, 2); XCTAssertTrue(enabled); try step("set")
                }, commit: { pointer, scope in
                    XCTAssertEqual(pointer, config); XCTAssertEqual(scope, .forSession); try step("commit")
                }, cancel: { _ in events.append("cancel") })
            let operation = {
                try transaction.enable(id: 2) {
                    validations += 1; try step("validate-\(validations)")
                }
            }
            if failure == "none" { XCTAssertNoThrow(try operation()) }
            else { XCTAssertThrowsError(try operation()) }
            XCTAssertEqual(events.filter { $0 == "cancel" }.count, ["set", "validate-2", "validate-3"].contains(failure) ? 1 : 0)
            XCTAssertEqual(events.contains("commit"), ["none", "commit"].contains(failure))
            if failure == "none" {
                XCTAssertEqual(events, ["validate-1", "begin", "validate-2", "set", "validate-3", "commit"])
            }
        }
    }
}
