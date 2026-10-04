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
            open: { uuid in
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

    private func controller(transaction: MirrorTransaction = MirrorTransaction()) -> DisplayHideController {
        let mirror = MirrorController(
            records: { self.topology.records },
            operationLock: { self.operationStore },
            engine: RecoveryEngine(
                capture: { self.topology.snapshot },
                apply: { snapshot in
                    self.writerCount += 1
                    self.topology.snapshot = snapshot
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
