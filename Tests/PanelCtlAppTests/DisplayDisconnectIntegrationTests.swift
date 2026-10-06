import AppKit
import SwiftUI
import XCTest
@testable import PanelCtlApp
@testable import PanelCtlCore

@MainActor
final class DisplayDisconnectIntegrationTests: XCTestCase {
    private var directory: URL!
    private var defaults: UserDefaults!
    private var suite: String!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("panelctl-disconnect-tests-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        suite = "panelctl-disconnect-\(UUID())"
        defaults = UserDefaults(suiteName: suite)!
        defaults.set(true, forKey: "experimentalFeaturesEnabled")
    }
    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suite)
        try FileManager.default.removeItem(at: directory)
    }

    private final class Fixture {
        let baseline: RecoverySnapshot
        var current: RecoverySnapshot
        let store: RecoveryStore
        var writes: [Bool] = []
        var arms = 0
        var fault = ""
        var clock: TimeInterval = 100
        var pending = false
        var finish: (() throws -> Void)?
        let uuid = "00000000-0000-0000-0000-000000000002"

        init(url: URL) throws {
            store = RecoveryStore(url: url)
            let uuid = self.uuid
            let connector = "IOService:/synthetic-native-framebuffer"
            let data: [String: Any] = ["bootSession": "fake-boot", "osBuild": "synthetic-build", "userID": getuid(), "hostModel": "Mac99,1",
                "displays": (1...2).map { id -> [String: Any] in
                    let location = id == 2 ? connector : "fake-survivor-port"
                    return ["uuid": id == 2 ? uuid : "00000000-0000-0000-0000-000000000001", "id": id,
                     "name": id == 2 ? "Synthetic external monitor" : "Synthetic survivor",
                     "vendor": id, "model": id, "serial": id * 100,
                     "builtin": false, "main": id == 1, "active": true, "x": (id - 1) * 1920, "y": 0, "rotation": 0,
                     "connector": location, "identityEvidence": ["source": "cgAndCoreDisplay", "capturedAt": 0,
                         "transport": "HDMI", "transportLocation": id == 2 ? "Port-HDMI/HDMI" : "fake-survivor",
                         "framebufferLocation": location],
                     "mode": ["id": 1, "width": 1920, "height": 1080, "pixelWidth": 1920, "pixelHeight": 1080, "refreshRate": 60, "flags": 0]]
                }]
            baseline = try JSONDecoder().decode(RecoverySnapshot.self, from: JSONSerialization.data(withJSONObject: data))
            current = baseline
        }

        lazy var session = RecoveryPrivateSession(snapshot: baseline, capture: { self.current }, inventory: {
            RecoveryEnableInventory(bootSession: self.baseline.bootSession, osBuild: self.baseline.osBuild,
                userID: self.baseline.userID, identities: self.baseline.displays.map { d in
                    RecoveryEnableIdentity(uuid: self.current.displays.contains { $0.id == d.id } ? d.uuid : nil,
                        id: d.id, vendor: d.vendor, model: d.model, serial: d.serial, builtin: d.builtin,
                        connector: d.connector!, transport: d.identityEvidence!.transport!,
                        framebufferLocation: d.identityEvidence?.framebufferLocation,
                        transportLocation: d.identityEvidence?.transportLocation)
                },
                onlineIDs: Set(self.current.displays.map(\.id)), hostModel: self.baseline.hostModel, architecture: "arm64",
                binding: self.fault == "identity" ? .unqualified : .captureMatch)
        }, environment: {
            RecoveryEligibilityEnvironment(architecture: .appleSilicon, drivers: .nativeOnly,
                lid: .notApplicable, mirrored: false, screens: Dictionary(uniqueKeysWithValues: self.current.displays.map {
                    ($0.id, .init(kind: self.fault == "survivor" && $0.main ? .headless : .physical,
                                online: true, active: true, awake: true))
                }))
        }, transaction: {
            RecoveryEnableTransaction(begin: { CGDisplayConfigRef(bitPattern: 1)! }, setEnabled: { _, id, enabled in
                XCTAssertEqual(id, 2)
                self.writes.append(enabled); self.pending = enabled
            }, commit: { _, scope in
                XCTAssertEqual(scope, .forSession)
                if self.fault == "reconnect" && self.pending { throw RecoveryError.unsafe("fake reconnect failure") }
                self.current = self.pending ? self.baseline : RecoverySnapshot(bootSession: self.baseline.bootSession,
                    osBuild: self.baseline.osBuild, userID: self.baseline.userID,
                    displays: [self.baseline.displays[0]], hostModel: self.baseline.hostModel)
            }, cancel: { _ in })
        }, apply: { _, _ in XCTFail("unexpected public restore") }, now: { self.clock }, initiallyAwake: true)

        var controller: DisplayDisconnectController {
            DisplayDisconnectController(store: store, capture: { self.current }, preflight: { _, id in
                _ = try self.session.prepareDisable(targetID: id)
            }, arm: { [self] store, _, timeout, snapshot, target in
                self.arms += 1
                if self.fault == "helper" { throw RecoveryError.unsafe("fake helper readiness failure") }
                XCTAssertEqual(timeout, 15)
                try store.lock()
                var journal = RecoveryJournal(snapshot: snapshot, timeout: timeout)
                journal.privateLease = true; journal.state = .armed
                try store.create(journal)
                let writer = try self.session.prepareDisable(targetID: target)
                try writer.perform(&journal, store: store, targetID: target, capture: { self.current }, lease: {})
                self.session.didDisable(target)
                var finished = false
                self.finish = { [weak self] in
                    guard let self, !finished else { return }
                    finished = true
                    defer { store.unlock() }
                    try self.session.engine.finish(&journal, store: store, verifyOnly: false, trigger: "deadline")
                }
                return DisplayDisconnectLease(id: journal.id, release: { [weak self] in try self?.finish?() })
            }, recover: { store, id in
                _ = try self.session.engine.recover(store: store, trigger: "app-reconnect", ownedOnly: true, expectedID: id)
            }, now: { self.clock })
        }

        var records: [DisplayRecord] {
            current.displays.enumerated().map { index, d in
                DisplayRecord(index: index + 1, id: d.id, uuid: d.uuid, name: d.name, active: true, online: true,
                    asleep: false, builtin: false, main: d.main, vendor: d.vendor, model: d.model, serial: d.serial,
                    bounds: DisplayBounds(CGRect(x: Int(d.x), y: 0, width: 1920, height: 1080)), pixelWidth: 1920, pixelHeight: 1080)
            }
        }
    }

    private func fixture(_ name: String = "current") throws -> Fixture {
        try Fixture(url: directory.appendingPathComponent("\(name).json"))
    }

    private func model(_ f: Fixture, extraDisplays: [DisplayRecord] = [],
                       cover: @escaping (Set<UInt32>) -> Set<UInt32> = { _ in [] }) -> AppModel {
        AppModel(defaults: defaults, displayProvider: { f.records + extraDisplays }, idleSecondsProvider: { 0 },
            sleepDisplays: { XCTFail("sleep must not run") }, isDisplayMirrored: { _ in false },
            inspectHandoff: {
                let status = try? f.controller.inspect()
                return DisplayHandoffStatus(state: status?.resolved == false ? .unsupported : .none,
                    journalPath: f.store.url.path, journalID: status?.journalID)
            },
            hideDisplay: { _, _, _ in throw RecoveryError.unsafe("no mirror writes") },
            showDisplay: { _, _ in throw RecoveryError.unsafe("no mirror writes") },
            checkDDCInput: { _ in throw RecoveryError.unsafe("no DDC") }, coverDisplays: cover,
            disconnectController: f.controller, disconnectExecutable: { URL(fileURLWithPath: "/unused") })
    }

    func testBlackOutRefusesDuringDisconnectLease() throws {
        let f = try fixture()
        let third = DisplayRecord(index: 3, id: 3, uuid: "00000000-0000-0000-0000-000000000003", name: "Synthetic third",
            active: true, online: true, asleep: false, builtin: false, main: false, vendor: 3, model: 3, serial: 3,
            bounds: DisplayBounds(CGRect(x: 3840, y: 0, width: 1920, height: 1080)), pixelWidth: 1920, pixelHeight: 1080)
        var covers: [Set<UInt32>] = []
        let app = model(f, extraDisplays: [third]) { ids in covers.append(ids); return [] }
        app.prepareDisconnect(f.uuid); app.confirmDisconnect()
        XCTAssertEqual(f.arms, 1)
        app.refreshDisplays()
        let survivor = try XCTUnwrap(app.displays.first { $0.main })
        XCTAssertEqual(app.blackoutReadiness(for: survivor)?.localizedDescription, "Finish the current disconnect first.")
        var result: DisplayOperationResult?
        app.hide(targetUUID: try XCTUnwrap(survivor.uuid)) { result = $0 }
        XCTAssertEqual(result?.succeeded, false)
        XCTAssertTrue(covers.allSatisfy(\.isEmpty), "no cover is installed during the lease")
        try f.finish?()
    }

    func testConsentCancelExpiryReplayAndQualificationRefusals() throws {
        let f = try fixture(), app = model(f)
        app.prepareDisconnect(f.uuid)
        let request = try XCTUnwrap(app.disconnectRequest)
        XCTAssertEqual(request.timeout, 15)
        for phrase in ["private macOS API", "Synthetic survivor", "at this Mac", "recover the monitor manually", "15 seconds", "not guaranteed"] {
            XCTAssertTrue(ExperimentalDisconnectControls.consentMessage(request).contains(phrase), phrase)
        }
        app.cancelDisconnect(); app.confirmDisconnect()
        XCTAssertEqual(f.arms, 0)
        app.prepareDisconnect(f.uuid); f.clock += 31; app.confirmDisconnect()
        XCTAssertTrue(app.disconnectFailure?.contains("expired") == true)
        XCTAssertEqual(f.arms, 0)
        XCTAssertThrowsError(try f.controller.disconnect(request, consent: false, executable: URL(fileURLWithPath: "/unused")))
        XCTAssertThrowsError(try f.controller.disconnect(request, consent: true, executable: URL(fileURLWithPath: "/unused")))
        XCTAssertEqual(f.arms, 0)
        app.prepareDisconnect("00000000-0000-0000-0000-000000000001")
        XCTAssertNil(app.disconnectRequest)
        XCTAssertTrue(app.disconnectFailure?.contains("non-main external") == true)
        XCTAssertEqual(f.writes, [])
    }

    func testUnsafeSelectionRefusesBeforeBackend() throws {
        let f = try fixture()
        let original = try JSONSerialization.jsonObject(with: JSONEncoder().encode(f.baseline)) as! [String: Any]
        for field in ["main", "builtin", "active", "mirrorUUID", "duplicate", "uuid"] {
            var object = original
            var displays = object["displays"] as! [[String: Any]]
            switch field {
            case "main", "builtin": displays[1][field] = true
            case "active": displays[1][field] = false
            case "mirrorUUID": displays[1][field] = displays[0]["uuid"]
            case "duplicate": displays.append(displays[1])
            default: displays[1][field] = "invalid"
            }
            object["displays"] = displays
            let snapshot = try JSONDecoder().decode(RecoverySnapshot.self, from: JSONSerialization.data(withJSONObject: object))
            var controller = f.controller
            controller.capture = { snapshot }
            controller.preflight = { _, _ in XCTFail("unsafe selection reached backend: \(field)") }
            XCTAssertThrowsError(try controller.prepare(targetUUID: field == "uuid" ? "invalid" : f.uuid), field)
        }
        XCTAssertEqual(f.arms, 0)
        XCTAssertEqual(f.writes, [])
    }

    func testEveryDisplayExposesExperimentalControlsWithoutGrantingConsent() throws {
        let f = try fixture(), app = model(f)
        for display in app.displays {
            XCTAssertTrue(ExperimentalDisconnectControls.isVisible(model: app, targetUUID: display.uuid))
        }
        XCTAssertFalse(ExperimentalDisconnectControls.isVisible(model: app, targetUUID: nil))
        app.setExperimentalFeaturesEnabled(false)
        XCTAssertFalse(ExperimentalDisconnectControls.isVisible(model: app, targetUUID: f.uuid))
        XCTAssertEqual(f.arms, 0)
        app.acceptExperimentalConsent()
        app.prepareDisconnect(f.uuid); app.confirmDisconnect()
        app.setExperimentalFeaturesEnabled(false)
        XCTAssertTrue(ExperimentalDisconnectControls.isVisible(model: app, targetUUID: nil))
        try f.finish?()
    }

    func testAppToCoreFakeLeaseWatchdogAndReadOnlyRelaunch() throws {
        let f = try fixture(), app = model(f)
        app.prepareDisconnect(f.uuid); app.confirmDisconnect()
        XCTAssertEqual(f.writes, [false]); XCTAssertEqual(f.arms, 1)
        let status = try XCTUnwrap(app.disconnectStatus)
        XCTAssertEqual(status.state, "disabled"); XCTAssertEqual(status.target?.displayID, 2)
        XCTAssertFalse(f.records.contains { $0.id == 2 })
        let original = try Data(contentsOf: f.store.url)
        let relaunched = model(f)
        relaunched.refreshCountdown()
        XCTAssertEqual(relaunched.disconnectStatus, status)
        XCTAssertEqual(try Data(contentsOf: f.store.url), original)
        XCTAssertEqual(f.writes, [false], "startup and polling must never write")
        XCTAssertNotNil(relaunched.disconnectBlocker)
        try f.finish?() // Fake watchdog deadline, through the real recovery engine.
        app.refreshCountdown()
        XCTAssertEqual(f.writes, [false, true]); XCTAssertEqual(app.disconnectStatus?.resolved, true)
        app.refreshCountdown(); app.confirmDisconnect()
        XCTAssertEqual(f.writes, [false, true], "expiry never renews disconnect")
    }

    func testRefusalHelperFailureAndFailedReconnectPreserveEvidence() throws {
        for fault in ["identity", "survivor", "helper", "reconnect"] {
            let f = try fixture(fault), app = model(f)
            f.fault = fault
            app.prepareDisconnect(f.uuid); app.confirmDisconnect()
            if fault == "reconnect" {
                XCTAssertEqual(f.writes, [false])
                app.reconnectDisconnect()
                XCTAssertEqual(f.writes, [false, true])
                XCTAssertEqual(app.disconnectStatus?.resolved, false)
                XCTAssertTrue(app.disconnectStatus?.failure?.contains("fake reconnect") == true)
                let before = try Data(contentsOf: f.store.url)
                let relaunched = model(f)
                XCTAssertEqual(try Data(contentsOf: f.store.url), before)
                relaunched.reconnectDisconnect()
                XCTAssertEqual(f.writes, [false, true], "private enable is never replayed")
                XCTAssertEqual(try f.store.load().state, .needsAttention)
            } else {
                XCTAssertEqual(f.writes, [], fault)
                XCTAssertNotNil(app.disconnectFailure, fault)
            }
        }
    }

    func testGeneralGateAndAutomationNeverGrantPerSessionConsent() throws {
        let f = try fixture(), app = model(f)
        app.setExperimentalFeaturesEnabled(false)
        app.prepareDisconnect(f.uuid); app.confirmDisconnect()
        XCTAssertNil(app.disconnectRequest); XCTAssertEqual(f.arms, 0)
        app.acceptExperimentalConsent()
        app.refreshCountdown(); app.refreshDisplays()
        XCTAssertEqual(f.arms, 0)
        for command in ["disconnect", "reconnect", "experimental-disconnect"] {
            XCTAssertThrowsError(try JSONDecoder().decode(AppControlRequest.self,
                from: Data("{\"protocol\":1,\"command\":\"\(command)\"}".utf8)))
        }
    }

    func testConfirmationRevalidatesIdentityAndUnresolvedJournalWithoutWrites() throws {
        let f = try fixture(), app = model(f)
        app.prepareDisconnect(f.uuid)
        f.fault = "identity"
        app.confirmDisconnect()
        XCTAssertEqual(f.arms, 0)
        XCTAssertNotNil(app.disconnectFailure)
        f.fault = ""
        app.prepareDisconnect(f.uuid)
        try f.store.lock()
        try f.store.create(RecoveryJournal(snapshot: f.baseline))
        f.store.unlock()
        app.confirmDisconnect()
        XCTAssertEqual(f.arms, 0)
        XCTAssertTrue(app.disconnectFailure?.contains("unresolved") == true)
        XCTAssertEqual(try f.store.load().state, .captured)
        XCTAssertEqual(f.writes, [])
    }

    func testConfirmationKeepsConsentTimeIdentityBaseline() throws {
        for drift in [false, true] {
            let f = try fixture(drift ? "drift" : "unchanged")
            var controller = f.controller
            var writerConstructions = 0
            // Like production, construct a new preflight session from the
            // supplied snapshot, rather than fixing it to the fixture baseline.
            controller.preflight = { snapshot, target in
                let session = RecoveryPrivateSession(snapshot: snapshot, capture: { f.current }, inventory: {
                    RecoveryEnableInventory(bootSession: f.current.bootSession, osBuild: f.current.osBuild,
                        userID: f.current.userID, identities: f.current.displays.map(RecoveryEnableIdentity.init),
                        onlineIDs: Set(f.current.displays.map(\.id)), hostModel: f.current.hostModel,
                        architecture: "arm64", binding: .captureMatch)
                }, environment: { try f.session.environment() }, transaction: {
                    writerConstructions += 1
                    return try f.session.transaction()
                }, initiallyAwake: true)
                _ = try session.prepareDisable(targetID: target)
            }
            let request = try controller.prepare(targetUUID: f.uuid)
            XCTAssertEqual(writerConstructions, 1)
            if drift {
                var target = f.baseline.displays[1]
                target.identityEvidence?.transportLocation = "another-port"
                f.current = RecoverySnapshot(bootSession: f.baseline.bootSession, osBuild: f.baseline.osBuild,
                    userID: f.baseline.userID, displays: [f.baseline.displays[0], target], hostModel: f.baseline.hostModel)
                try f.baseline.verify(f.current) // Public topology comparison alone misses this.
                XCTAssertThrowsError(try controller.disconnect(request, consent: true,
                    executable: URL(fileURLWithPath: "/unused"))) {
                    XCTAssertTrue($0.localizedDescription.contains("transport/location"))
                }
                XCTAssertEqual(writerConstructions, 1, "drift must refuse before writer construction")
                XCTAssertEqual(f.arms, 0, "drift must refuse before helper arming")
                XCTAssertEqual(f.writes, [])
            } else {
                let lease = try controller.disconnect(request, consent: true, executable: URL(fileURLWithPath: "/unused"))
                XCTAssertEqual(writerConstructions, 2)
                XCTAssertEqual(f.arms, 1)
                XCTAssertEqual(f.writes, [false])
                XCTAssertEqual(try f.store.load().snapshot, f.baseline)
                try lease.reconnect()
                XCTAssertEqual(f.writes, [false, true])
            }
        }
    }

    func testReconnectIgnoresExperimentalGateButRejectsChangedConsentJournal() throws {
        let f = try fixture(), app = model(f)
        app.prepareDisconnect(f.uuid); app.confirmDisconnect()
        app.setExperimentalFeaturesEnabled(false)
        let journalID = try XCTUnwrap(app.disconnectStatus?.journalID)
        app.reconnectDisconnect(expectedJournalID: UUID().uuidString)
        XCTAssertEqual(f.writes, [false])
        XCTAssertTrue(app.disconnectFailure?.contains("journal changed") == true)
        app.reconnectDisconnect(expectedJournalID: journalID)
        XCTAssertEqual(f.writes, [false, true])
        XCTAssertEqual(app.disconnectStatus?.resolved, true)
    }

    func testWatchdogRecaptureRetainsQualifiedTransportAndHelperRefusesDrift() throws {
        let f = try fixture()
        var target = f.baseline.displays[1]
        target.identityEvidence?.transportLocation = "Port-USB-C@1/DisplayPort"
        let changed = RecoverySnapshot(bootSession: f.baseline.bootSession, osBuild: f.baseline.osBuild,
            userID: f.baseline.userID, displays: [f.baseline.displays[0], target], hostModel: f.baseline.hostModel)
        try f.baseline.verify(changed) // Public equality alone intentionally misses this drift.
        let executable = directory.appendingPathComponent("nonexistent-helper")
        // Run the real start/capture/journal boundary, but never a helper or writer.
        XCTAssertThrowsError(try RecoveryWatchdog.start(store: f.store, executable: executable,
            timeout: 15, verifyOnly: false, expectedSnapshot: f.baseline, privateLease: true,
            capture: { changed }))
        let retained = try f.store.load().snapshot
        XCTAssertEqual(retained, f.baseline)
        var writerConstructions = 0
        let session = RecoveryPrivateSession(snapshot: retained, capture: { changed }, inventory: {
            RecoveryEnableInventory(bootSession: changed.bootSession, osBuild: changed.osBuild,
                userID: changed.userID, identities: changed.displays.map(RecoveryEnableIdentity.init),
                onlineIDs: Set(changed.displays.map(\.id)), hostModel: changed.hostModel,
                architecture: "arm64", binding: .captureMatch)
        }, environment: {
            RecoveryEligibilityEnvironment(architecture: .appleSilicon, drivers: .nativeOnly,
                lid: .notApplicable, mirrored: false, screens: Dictionary(uniqueKeysWithValues: changed.displays.map {
                    ($0.id, .init(kind: .physical, online: true, active: true, awake: true))
                }))
        }, transaction: {
            writerConstructions += 1
            throw RecoveryError.unsafe("a writer must never be constructed")
        }, initiallyAwake: true)
        XCTAssertThrowsError(try session.prepareDisable(targetID: target.id)) { error in
            XCTAssertTrue(error.localizedDescription.contains("transport/location"), error.localizedDescription)
        }
        XCTAssertEqual(writerConstructions, 0)
    }

    func testNativeProductionControlsWithFakeStatusRender() throws {
        _ = NSApplication.shared
        let f = try fixture(), app = model(f)
        func render(_ name: String, targetUUID: String?) throws {
            let host = NSHostingView(rootView: Form {
                ExperimentalDisconnectControls(model: app, targetUUID: targetUUID)
            }.formStyle(.grouped))
            host.sizingOptions = []
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 700),
                styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = host; window.orderFront(nil)
            defer { window.close() }
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            XCTAssertGreaterThan(bitmap.pixelsWide, 0)
            if let output = ProcessInfo.processInfo.environment["PANELCTL_DISCONNECT_FIXTURE_OUTPUT"] {
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                    .write(to: URL(fileURLWithPath: output).appendingPathComponent("\(name).png"))
            }
        }
        try render("generic-monitor-ready", targetUUID: f.uuid)
        try render("main-display-refused", targetUUID: f.baseline.displays[0].uuid)
        XCTAssertEqual(f.writes, [])
        app.prepareDisconnect(f.uuid); app.confirmDisconnect()
        app.refreshDisplays()
        try render("integrated-lease", targetUUID: nil)
        try f.finish?()
    }
}
