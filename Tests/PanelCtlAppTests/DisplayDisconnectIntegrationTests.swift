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

    private func model(
        _ f: Fixture,
        extraDisplays: [DisplayRecord] = [],
        cover: @escaping (Set<UInt32>) -> Set<UInt32> = { _ in [] },
        quiesceProtection: ProtectionQuiesce? = nil,
        protectionCoordinator: ProtectionCoordinator? = nil,
        handoffStatusProvider: (() -> DisplayHandoffStatus)? = nil,
        now: @escaping () -> Date = Date.init
    ) -> AppModel {
        AppModel(defaults: defaults, displayProvider: { f.records + extraDisplays }, now: now,
            idleSecondsProvider: { 0 },
            sleepDisplays: { XCTFail("sleep must not run") }, isDisplayMirrored: { _ in false },
            inspectHandoff: handoffStatusProvider ?? {
                let status = try? f.controller.inspect()
                return DisplayHandoffStatus(state: status?.resolved == false ? .unsupported : .none,
                    journalPath: f.store.url.path, journalID: status?.journalID)
            },
            hideDisplay: { _, _, _ in throw RecoveryError.unsafe("no mirror writes") },
            showDisplay: { _, _ in throw RecoveryError.unsafe("no mirror writes") },
            checkDDCInput: { _ in throw RecoveryError.unsafe("no DDC") }, coverDisplays: cover,
            quiesceProtection: quiesceProtection, protectionCoordinator: protectionCoordinator,
            disconnectController: f.controller, disconnectExecutable: { URL(fileURLWithPath: "/unused") })
    }

    private struct WaitTimeout: Error {}

    private func waitUntil(
        file: StaticString = #filePath,
        line: UInt = #line,
        _ condition: () -> Bool
    ) async throws {
        for _ in 0..<500 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Timed out waiting for asynchronous disconnect state", file: file, line: line)
        throw WaitTimeout()
    }

    private func protectionRule(_ name: String, uuid: String, idleSeconds: TimeInterval = 120) -> ProtectionRule {
        var settings = ProtectionPreferences()
        settings.selectedDisplayUUIDs = [uuid]
        settings.didChooseDisplays = true
        settings.idleSeconds = idleSeconds
        settings.followUpAction = .restore
        return ProtectionRule(name: name, isEnabled: true, settings: settings)
    }

    private func saveAutomationPreferences(_ preferences: AutomationPreferences) throws {
        defaults.set(try JSONEncoder().encode(preferences), forKey: "automationRules")
    }

    private func automationCoordinator(
        directory: URL,
        cleanupIsVerified: @escaping () -> Bool = { true }
    ) -> ProtectionCoordinator {
        ProtectionCoordinator(
            verifyJournal: { _ in true },
            ruleJournalDirectory: directory,
            removeDeletedDirectories: false,
            serviceFactory: { ruleID in
                ProtectionService(
                    cleanupRuleID: ruleID,
                    cleanupIsVerified: cleanupIsVerified,
                    displaysAreAsleep: { false }
                )
            }
        )
    }

    private func writeAutomationHelper(ignoreTermination: Bool = false) throws -> URL {
        let helper = directory.appendingPathComponent("fake-panelctl")
        let script = """
        #!/bin/sh
        if [ "${PANELCTL_CLEANUP_ONLY:-}" = "1" ]; then
          printf 'cleanup\\n' >> "$PANELCTL_TEST_LOG"
          printf '{"state":"stopped","blackedOutDisplayIDs":[],"cleanupSucceeded":true}\\n'
          exit 0
        fi
        printf 'watch %s\\n' "$*" >> "$PANELCTL_TEST_LOG"
        printf 'rearm %s\\n' "${PANELCTL_REARM_ON_START:-0}" >> "$PANELCTL_TEST_LOG"
        printf '{"state":"waiting","blackedOutDisplayIDs":[]}\\n'
        if [ "\(ignoreTermination ? "1" : "0")" = "1" ] && [ "${PANELCTL_IGNORE_TERM:-}" = "1" ]; then
          trap '' TERM
          while :; do /bin/sleep 0.05; done
        fi
        while IFS= read -r command; do
          if [ "$command" = "restore" ]; then
            printf '{"state":"waiting","blackedOutDisplayIDs":[]}\\n'
          fi
        done
        """
        try Data(script.utf8).write(to: helper)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
        return helper
    }

    private func launchLines(at log: URL) -> [String] {
        (try? String(contentsOf: log, encoding: .utf8))?
            .split(whereSeparator: \.isNewline).map(String.init) ?? []
    }

    func testBlackOutRefusesDuringDisconnectLease() async throws {
        let f = try fixture()
        let third = DisplayRecord(index: 3, id: 3, uuid: "00000000-0000-0000-0000-000000000003", name: "Synthetic third",
            active: true, online: true, asleep: false, builtin: false, main: false, vendor: 3, model: 3, serial: 3,
            bounds: DisplayBounds(CGRect(x: 3840, y: 0, width: 1920, height: 1080)), pixelWidth: 1920, pixelHeight: 1080)
        var covers: [Set<UInt32>] = []
        let app = model(f, extraDisplays: [third], cover: { ids in covers.append(ids); return [] })
        app.prepareDisconnect(f.uuid)
        try await waitUntil { app.disconnectConsentPending }
        app.confirmDisconnect()
        XCTAssertEqual(f.arms, 1)
        app.refreshDisplays()
        let survivor = try XCTUnwrap(app.displays.first { $0.main })
        XCTAssertEqual(app.blackoutReadiness(for: survivor)?.localizedDescription,
                       "Full disconnect is pausing automation or awaiting verified recovery.")
        var result: DisplayOperationResult?
        app.hide(targetUUID: try XCTUnwrap(survivor.uuid)) { result = $0 }
        XCTAssertEqual(result?.succeeded, false)
        XCTAssertTrue(covers.allSatisfy(\.isEmpty), "no cover is installed during the lease")
        try f.finish?()
    }

    func testConsentCancelExpiryReplayAndQualificationRefusals() async throws {
        let f = try fixture(), app = model(f)
        app.prepareDisconnect(f.uuid)
        try await waitUntil { app.disconnectConsentPending }
        let request = try XCTUnwrap(app.disconnectRequest)
        XCTAssertEqual(request.timeout, 15)
        let consent = ExperimentalDisconnectControls.consentMessage(request)
        for phrase in [request.target.name, "Synthetic survivor", "at this Mac", "manual recovery", "15 seconds",
                       "Automatic reconnect may fail", "other screen is usable", "Don’t unplug displays or change inputs"] {
            XCTAssertTrue(consent.contains(phrase), phrase)
        }
        XCTAssertLessThanOrEqual(consent.split(whereSeparator: { $0.isWhitespace }).count, 55)
        app.cancelDisconnect(); app.confirmDisconnect()
        XCTAssertEqual(f.arms, 0)
        try await waitUntil { app.disconnectBlocker == nil }
        app.prepareDisconnect(f.uuid)
        try await waitUntil { app.disconnectConsentPending }
        f.clock += 31
        app.confirmDisconnect()
        XCTAssertTrue(app.disconnectFailure?.contains("expired") == true)
        XCTAssertEqual(f.arms, 0)
        XCTAssertThrowsError(try f.controller.disconnect(request, consent: false, executable: URL(fileURLWithPath: "/unused")))
        XCTAssertThrowsError(try f.controller.disconnect(request, consent: true, executable: URL(fileURLWithPath: "/unused")))
        XCTAssertEqual(f.arms, 0)
        try await waitUntil { app.disconnectBlocker == nil }
        app.prepareDisconnect("00000000-0000-0000-0000-000000000001")
        try await waitUntil { !app.disconnectPreparationPending }
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

    func testEveryDisplayExposesExperimentalControlsWithoutGrantingConsent() async throws {
        let f = try fixture(), app = model(f)
        for display in app.displays {
            XCTAssertTrue(ExperimentalDisconnectControls.isVisible(model: app, targetUUID: display.uuid))
        }
        XCTAssertFalse(ExperimentalDisconnectControls.isVisible(model: app, targetUUID: nil))
        app.setExperimentalFeaturesEnabled(false)
        XCTAssertFalse(ExperimentalDisconnectControls.isVisible(model: app, targetUUID: f.uuid))
        XCTAssertEqual(f.arms, 0)
        app.acceptExperimentalConsent()
        app.prepareDisconnect(f.uuid)
        try await waitUntil { app.disconnectConsentPending }
        app.confirmDisconnect()
        app.setExperimentalFeaturesEnabled(false)
        XCTAssertTrue(ExperimentalDisconnectControls.isVisible(model: app, targetUUID: nil))
        try f.finish?()
    }

    func testPreparationSupersedesPendingCoordinatorRestartCallback() async throws {
        let f = try fixture("pending-reconcile")
        let helper = try writeAutomationHelper(ignoreTermination: true)
        let log = directory.appendingPathComponent("pending-reconcile.log")
        setenv("PANELCTL_HELPER", helper.path, 1)
        setenv("PANELCTL_TEST_LOG", log.path, 1)
        setenv("PANELCTL_IGNORE_TERM", "1", 1)
        defer {
            unsetenv("PANELCTL_HELPER")
            unsetenv("PANELCTL_TEST_LOG")
            unsetenv("PANELCTL_IGNORE_TERM")
        }
        try saveAutomationPreferences(AutomationPreferences(isEnabled: true, rules: [
            protectionRule("Rule", uuid: f.uuid)
        ]))
        let coordinator = automationCoordinator(
            directory: directory.appendingPathComponent("pending-reconcile-journals", isDirectory: true)
        )
        let app = model(f, protectionCoordinator: coordinator)
        try await waitUntil { launchLines(at: log).filter { $0.hasPrefix("watch") }.count == 1 }

        app.refreshDisplays(restartWatcher: true)
        try await waitUntil {
            if case .stopping = app.runtimeState { return true }
            return false
        }
        app.prepareDisconnect(f.uuid)
        XCTAssertTrue(app.disconnectPreparationPending)
        try await waitUntil { app.disconnectConsentPending }
        XCTAssertEqual(launchLines(at: log).filter { $0.hasPrefix("watch") }.count, 1,
                       "the stale restart callback cannot launch treatment during consent")
        unsetenv("PANELCTL_IGNORE_TERM")

        app.cancelDisconnect()
        try await waitUntil { launchLines(at: log).filter { $0.hasPrefix("watch") }.count == 2 }
        XCTAssertEqual(Array(launchLines(at: log).filter { $0.hasPrefix("rearm") }.suffix(1)), ["rearm 1"],
                       "the safe cancellation launches the helper with the fresh-countdown flag")
        await withCheckedContinuation { continuation in app.shutdown { continuation.resume() } }
    }

    func testAutomationPauseStopsEveryRuleAndCancellationRestartsWithFreshSettings() async throws {
        let f = try fixture("multiple-rules")
        let helper = try writeAutomationHelper()
        let log = directory.appendingPathComponent("multiple-rules.log")
        setenv("PANELCTL_HELPER", helper.path, 1)
        setenv("PANELCTL_TEST_LOG", log.path, 1)
        defer { unsetenv("PANELCTL_HELPER"); unsetenv("PANELCTL_TEST_LOG") }
        let original = AutomationPreferences(isEnabled: true, rules: [
            protectionRule("External", uuid: f.uuid),
            protectionRule("Survivor", uuid: f.baseline.displays[0].uuid)
        ])
        try saveAutomationPreferences(original)
        let coordinator = automationCoordinator(directory: directory.appendingPathComponent("rule-journals", isDirectory: true))
        let app = model(f, protectionCoordinator: coordinator)
        try await waitUntil { launchLines(at: log).filter { $0.hasPrefix("watch") }.count == 2 }

        app.prepareDisconnect(f.uuid)
        XCTAssertTrue(app.disconnectPreparationPending)
        try await waitUntil { app.disconnectConsentPending }
        XCTAssertEqual(app.automationPreferences, original)
        XCTAssertEqual(f.arms, 0, "cleanup and consent do not arm a disconnect")
        XCTAssertEqual(launchLines(at: log).filter { $0.hasPrefix("watch") }.count, 2)
        XCTAssertTrue(app.statusSummary.contains("Automation paused"))
        XCTAssertThrowsError(try app.blackoutNow(), "manual blackout cannot bypass the disconnect pause")

        app.refreshDisplays(restartWatcher: true)
        var edited = app.automationPreferences
        edited.rules[0].settings.idleSeconds = 900
        app.automationPreferences = edited
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(launchLines(at: log).filter { $0.hasPrefix("watch") }.count, 2,
                       "queued refreshes and preference edits cannot restart paused rules")

        app.cancelDisconnect()
        try await waitUntil { launchLines(at: log).filter { $0.hasPrefix("watch") }.count == 4 }
        XCTAssertTrue(app.automationPreferences.isEnabled)
        XCTAssertEqual(app.automationPreferences.rules[0].settings.idleSeconds, 900)
        let loggedLines = launchLines(at: log)
        let resumedLaunches = Array(loggedLines.filter { $0.hasPrefix("watch") }.suffix(2))
        XCTAssertEqual(resumedLaunches.count, 2)
        XCTAssertTrue(resumedLaunches.contains { $0.contains("--idle-after 900") },
                      "the edited rule resumes from its current settings: \(resumedLaunches)")
        XCTAssertTrue(resumedLaunches.contains { $0.contains("--idle-after 120") },
                      "the untouched rule also resumes with its saved settings: \(resumedLaunches)")
        XCTAssertEqual(Array(loggedLines.filter { $0.hasPrefix("rearm") }.suffix(2)), ["rearm 1", "rearm 1"],
                       "fresh countdown resumes must reach helpers via PANELCTL_REARM_ON_START")
        XCTAssertEqual(f.arms, 0)
        await withCheckedContinuation { continuation in app.shutdown { continuation.resume() } }
    }

    func testTemporaryPausePreservesOffStateAndSnoozeExpiry() async throws {
        let helper = try writeAutomationHelper()
        let log = directory.appendingPathComponent("snooze.log")
        setenv("PANELCTL_HELPER", helper.path, 1)
        setenv("PANELCTL_TEST_LOG", log.path, 1)
        defer { unsetenv("PANELCTL_HELPER"); unsetenv("PANELCTL_TEST_LOG") }

        let disabledFixture = try fixture("automation-off")
        try saveAutomationPreferences(AutomationPreferences(isEnabled: false, rules: [
            protectionRule("Off rule", uuid: disabledFixture.uuid)
        ]))
        let disabledApp = model(disabledFixture)
        disabledApp.prepareDisconnect(disabledFixture.uuid)
        try await waitUntil { disabledApp.disconnectConsentPending }
        XCTAssertFalse(disabledApp.automationPreferences.isEnabled)
        disabledApp.cancelDisconnect()
        try await waitUntil { disabledApp.disconnectBlocker == nil }
        XCTAssertFalse(disabledApp.automationPreferences.isEnabled, "cancellation never enables a master switch the user left off")
        await withCheckedContinuation { continuation in disabledApp.shutdown { continuation.resume() } }

        let baseTime = Date(timeIntervalSince1970: 2_000_000_000)
        let futureSnoozeFixture = try fixture("future-snooze")
        let futureDeadline = baseTime.addingTimeInterval(3600)
        let futureClock = baseTime
        try saveAutomationPreferences(AutomationPreferences(isEnabled: true, rules: [
            protectionRule("Future-snoozed rule", uuid: futureSnoozeFixture.uuid)
        ]))
        defaults.set(futureDeadline, forKey: "snoozedUntil")
        let futureSnoozeApp = model(
            futureSnoozeFixture,
            protectionCoordinator: automationCoordinator(
                directory: directory.appendingPathComponent("future-snooze-journals", isDirectory: true)
            ),
            now: { futureClock }
        )
        futureSnoozeApp.prepareDisconnect(futureSnoozeFixture.uuid)
        try await waitUntil { futureSnoozeApp.disconnectConsentPending }
        futureSnoozeApp.cancelDisconnect()
        try await waitUntil { futureSnoozeApp.disconnectBlocker == nil }
        XCTAssertEqual(futureSnoozeApp.snoozedUntil, futureDeadline)
        XCTAssertEqual(defaults.object(forKey: "snoozedUntil") as? Date, futureDeadline)
        XCTAssertTrue(launchLines(at: log).isEmpty, "cancellation preserves a still-active snooze")
        await withCheckedContinuation { continuation in futureSnoozeApp.shutdown { continuation.resume() } }

        let snoozedFixture = try fixture("automation-snoozed")
        var currentTime = baseTime
        let deadline = baseTime.addingTimeInterval(30)
        try saveAutomationPreferences(AutomationPreferences(isEnabled: true, rules: [
            protectionRule("Snoozed rule", uuid: snoozedFixture.uuid)
        ]))
        defaults.set(deadline, forKey: "snoozedUntil")
        let coordinator = automationCoordinator(directory: directory.appendingPathComponent("snoozed-journals", isDirectory: true))
        let snoozedApp = model(snoozedFixture, protectionCoordinator: coordinator, now: { currentTime })
        snoozedApp.prepareDisconnect(snoozedFixture.uuid)
        try await waitUntil { snoozedApp.disconnectConsentPending }
        XCTAssertEqual(defaults.object(forKey: "snoozedUntil") as? Date, deadline)
        currentTime = deadline.addingTimeInterval(1)
        snoozedApp.refreshCountdown()
        XCTAssertNil(snoozedApp.snoozedUntil)
        XCTAssertEqual(defaults.object(forKey: "snoozedUntil") as? Date, deadline,
                       "timer expiry is retained during the disconnect pause")
        XCTAssertTrue(launchLines(at: log).isEmpty, "snooze expiry cannot restart automation before cancellation")
        snoozedApp.cancelDisconnect()
        try await waitUntil { launchLines(at: log).contains { $0.hasPrefix("watch") } }
        XCTAssertNil(defaults.object(forKey: "snoozedUntil"), "the expired snooze clears only as the safe pause ends")
        XCTAssertTrue(snoozedApp.automationPreferences.isEnabled)
        await withCheckedContinuation { continuation in snoozedApp.shutdown { continuation.resume() } }
    }

    func testUserTurningAutomationOffDuringPauseStaysOffAfterCancellation() async throws {
        let f = try fixture("user-turns-automation-off")
        let helper = try writeAutomationHelper()
        let log = directory.appendingPathComponent("user-turns-automation-off.log")
        setenv("PANELCTL_HELPER", helper.path, 1)
        setenv("PANELCTL_TEST_LOG", log.path, 1)
        defer { unsetenv("PANELCTL_HELPER"); unsetenv("PANELCTL_TEST_LOG") }
        try saveAutomationPreferences(AutomationPreferences(isEnabled: true, rules: [
            protectionRule("Rule", uuid: f.uuid)
        ]))
        let app = model(f, protectionCoordinator: automationCoordinator(
            directory: directory.appendingPathComponent("user-off-journals", isDirectory: true)
        ))
        try await waitUntil { launchLines(at: log).filter { $0.hasPrefix("watch") }.count == 1 }
        app.prepareDisconnect(f.uuid)
        try await waitUntil { app.disconnectConsentPending }
        app.setProtectionEnabled(false)
        app.cancelDisconnect()
        try await waitUntil { app.disconnectBlocker == nil }
        XCTAssertFalse(app.automationPreferences.isEnabled)
        XCTAssertEqual(launchLines(at: log).filter { $0.hasPrefix("watch") }.count, 1,
                       "cancellation respects the user's deliberate master-switch change")
        await withCheckedContinuation { continuation in app.shutdown { continuation.resume() } }
    }

    func testQueuedCleanupCancellationNeverPresentsConsentOrWrites() async throws {
        let f = try fixture("queued-cancel")
        try saveAutomationPreferences(AutomationPreferences(isEnabled: false, rules: [
            protectionRule("Off rule", uuid: f.uuid)
        ]))
        var pendingCleanup: ((Bool, String?) -> Void)?
        let app = model(f, quiesceProtection: { pendingCleanup = $0 })
        app.prepareDisconnect(f.uuid)
        XCTAssertTrue(app.disconnectPreparationPending)
        app.cancelDisconnect()
        pendingCleanup?(true, nil)
        try await waitUntil { !app.disconnectPreparationPending && app.disconnectBlocker == nil }
        XCTAssertFalse(app.disconnectConsentPending)
        XCTAssertNil(app.disconnectRequest)
        XCTAssertEqual(f.arms, 0)
        XCTAssertEqual(f.writes, [])
        XCTAssertFalse(app.automationPreferences.isEnabled)
    }

    func testFailedAutomationCleanupBlocksConsentUntilExplicitRetry() async throws {
        let f = try fixture("cleanup-failure")
        let helper = try writeAutomationHelper()
        let log = directory.appendingPathComponent("cleanup-failure.log")
        setenv("PANELCTL_HELPER", helper.path, 1)
        setenv("PANELCTL_TEST_LOG", log.path, 1)
        defer { unsetenv("PANELCTL_HELPER"); unsetenv("PANELCTL_TEST_LOG") }
        try saveAutomationPreferences(AutomationPreferences(isEnabled: true, rules: [
            protectionRule("External", uuid: f.uuid),
            protectionRule("Survivor", uuid: f.baseline.displays[0].uuid)
        ]))
        var cleanupVerified = true
        let coordinator = automationCoordinator(
            directory: directory.appendingPathComponent("cleanup-journals", isDirectory: true),
            cleanupIsVerified: { cleanupVerified }
        )
        let app = model(f, protectionCoordinator: coordinator)
        try await waitUntil { launchLines(at: log).filter { $0.hasPrefix("watch") }.count == 2 }
        cleanupVerified = false
        app.prepareDisconnect(f.uuid)
        try await waitUntil { !app.disconnectPreparationPending && app.protectionQuiescenceFailure != nil }
        XCTAssertNil(app.disconnectRequest)
        XCTAssertFalse(app.disconnectConsentPending)
        XCTAssertEqual(f.arms, 0)
        XCTAssertEqual(f.writes, [])
        XCTAssertTrue(app.disconnectBlocker?.contains("Retry Automation Cleanup") == true)

        cleanupVerified = true
        app.retryAutomationCleanup()
        try await waitUntil {
            app.protectionQuiescenceFailure == nil &&
                launchLines(at: log).filter { $0.hasPrefix("watch") }.count == 4
        }
        XCTAssertFalse(app.disconnectConsentPending, "retry cleans up but never continues the refused operation")
        XCTAssertEqual(f.arms, 0)
        XCTAssertEqual(f.writes, [])
        await withCheckedContinuation { continuation in app.shutdown { continuation.resume() } }
    }

    func testRepairedPublicJournalReleasesPersistedDisconnectBlock() async throws {
        let f = try fixture("public-repaired")
        try f.store.lock()
        var journal = RecoveryJournal(snapshot: f.baseline)
        journal.state = .restored
        try f.store.create(journal)
        f.store.unlock()
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: f.store.url.path)
        let app = model(f)
        XCTAssertNotNil(app.disconnectInspectionFailure, "unsafe permissions fail closed")
        XCTAssertTrue(defaults.bool(forKey: "disconnectRecoveryBlocked"))

        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: f.store.url.path)
        app.refreshCountdown()
        XCTAssertNil(app.disconnectInspectionFailure, "a readable public-only journal is not missing private evidence")
        XCTAssertFalse(defaults.bool(forKey: "disconnectRecoveryBlocked"))
        let relaunched = model(f)
        XCTAssertNil(relaunched.disconnectInspectionFailure)
        XCTAssertNil(relaunched.disconnectBlocker)

        try FileManager.default.removeItem(at: f.store.url)
        defaults.set(true, forKey: "disconnectRecoveryBlocked")
        let missing = model(f)
        XCTAssertNotNil(missing.disconnectInspectionFailure, "a missing journal still fails closed")
        XCTAssertEqual(f.writes, [])
        await withCheckedContinuation { continuation in app.shutdown { continuation.resume() } }
        await withCheckedContinuation { continuation in relaunched.shutdown { continuation.resume() } }
        await withCheckedContinuation { continuation in missing.shutdown { continuation.resume() } }
    }

    func testCancelledDisconnectRetriesBusyHandoffInspectionOnCountdown() async throws {
        let helper = try writeAutomationHelper()
        let f = try fixture("cancel-handoff-busy")
        let log = directory.appendingPathComponent("cancel-handoff-busy.log")
        setenv("PANELCTL_HELPER", helper.path, 1)
        setenv("PANELCTL_TEST_LOG", log.path, 1)
        defer { unsetenv("PANELCTL_HELPER"); unsetenv("PANELCTL_TEST_LOG") }
        try saveAutomationPreferences(AutomationPreferences(isEnabled: true, rules: [
            protectionRule("Survivor rule", uuid: f.baseline.displays[0].uuid)
        ]))
        var handoffBusy = false
        let app = model(
            f,
            protectionCoordinator: automationCoordinator(
                directory: directory.appendingPathComponent("cancel-handoff-journals", isDirectory: true)
            ),
            handoffStatusProvider: {
                handoffBusy
                    ? DisplayHandoffStatus(state: .busy, journalPath: "/synthetic/handoff.json",
                                           reason: "synthetic journal lock busy", inspectionFailure: "synthetic journal lock busy")
                    : DisplayHandoffStatus(state: .none, journalPath: "/synthetic/handoff.json")
            }
        )
        try await waitUntil { launchLines(at: log).filter { $0.hasPrefix("watch") }.count == 1 }
        app.prepareDisconnect(f.uuid)
        try await waitUntil { app.disconnectConsentPending }
        handoffBusy = true
        app.refreshHandoffStatus()
        app.cancelDisconnect()
        XCTAssertNil(app.disconnectStatus, "cancellation created no disconnect journal")
        XCTAssertNotNil(app.handoffInspectionFailure)
        XCTAssertEqual(launchLines(at: log).filter { $0.hasPrefix("watch") }.count, 1)

        handoffBusy = false
        app.refreshCountdown()
        try await waitUntil { launchLines(at: log).filter { $0.hasPrefix("watch") }.count == 2 }
        XCTAssertNil(app.handoffInspectionFailure)
        XCTAssertEqual(f.arms, 0)
        XCTAssertEqual(f.writes, [])
        await withCheckedContinuation { continuation in app.shutdown { continuation.resume() } }
    }

    func testUnreadableDisconnectJournalFailsClosedAcrossRelaunch() async throws {
        let f = try fixture("unreadable")
        let corrupt = Data("not a recovery journal".utf8)
        try corrupt.write(to: f.store.url)
        try saveAutomationPreferences(AutomationPreferences(isEnabled: true, rules: [
            protectionRule("Enabled rule", uuid: f.uuid)
        ]))
        let ruleJournalDirectory = directory.appendingPathComponent("unreadable-rule-journals", isDirectory: true)
        let app = model(f, protectionCoordinator: automationCoordinator(directory: ruleJournalDirectory))
        XCTAssertNotNil(app.disconnectInspectionFailure)
        XCTAssertTrue(defaults.bool(forKey: "disconnectRecoveryBlocked"))
        XCTAssertTrue(app.automationPreferences.isEnabled)
        XCTAssertTrue(app.disconnectBlocker?.contains("panelctl recovery status") == true)
        XCTAssertTrue(ExperimentalDisconnectControls.isVisible(model: app, targetUUID: nil))
        app.setExperimentalFeaturesEnabled(false)
        XCTAssertTrue(ExperimentalDisconnectControls.isVisible(model: app, targetUUID: nil),
                      "unreadable recovery remains visible with Experimental features off")
        app.refreshCountdown()
        XCTAssertNotNil(app.disconnectInspectionFailure)
        XCTAssertEqual(try Data(contentsOf: f.store.url), corrupt)
        XCTAssertEqual(f.arms, 0)
        XCTAssertEqual(f.writes, [])

        let relaunched = model(f, protectionCoordinator: automationCoordinator(directory: ruleJournalDirectory))
        XCTAssertNotNil(relaunched.disconnectInspectionFailure)
        XCTAssertNotNil(relaunched.disconnectBlocker)
        XCTAssertTrue(relaunched.automationPreferences.isEnabled)
        XCTAssertEqual(try Data(contentsOf: f.store.url), corrupt)
        XCTAssertEqual(f.arms, 0, "relaunch never starts automation or private recovery against unreadable evidence")
        XCTAssertEqual(f.writes, [])
        await withCheckedContinuation { continuation in app.shutdown { continuation.resume() } }
        await withCheckedContinuation { continuation in relaunched.shutdown { continuation.resume() } }
    }

    func testVerifiedRecoveryResumesAutomationButFailedRecoveryStaysPausedAcrossRelaunch() async throws {
        let helper = try writeAutomationHelper()
        let successfulFixture = try fixture("verified-resume")
        let successLog = directory.appendingPathComponent("verified-resume.log")
        setenv("PANELCTL_HELPER", helper.path, 1)
        setenv("PANELCTL_TEST_LOG", successLog.path, 1)
        defer { unsetenv("PANELCTL_HELPER"); unsetenv("PANELCTL_TEST_LOG") }
        try saveAutomationPreferences(AutomationPreferences(isEnabled: true, rules: [
            protectionRule("Survivor rule", uuid: successfulFixture.baseline.displays[0].uuid)
        ]))
        let successCoordinator = automationCoordinator(
            directory: directory.appendingPathComponent("verified-resume-journals", isDirectory: true)
        )
        var handoffBusy = false
        var handoffReadCount = 0
        let successfulApp = model(
            successfulFixture,
            protectionCoordinator: successCoordinator,
            handoffStatusProvider: {
                handoffReadCount += 1
                return handoffBusy
                    ? DisplayHandoffStatus(state: .busy, journalPath: "/synthetic/handoff.json",
                                           reason: "synthetic journal lock busy", inspectionFailure: "synthetic journal lock busy")
                    : DisplayHandoffStatus(state: .none, journalPath: "/synthetic/handoff.json")
            }
        )
        try await waitUntil { launchLines(at: successLog).filter { $0.hasPrefix("watch") }.count == 1 }
        successfulApp.prepareDisconnect(successfulFixture.uuid)
        try await waitUntil { successfulApp.disconnectConsentPending }
        successfulApp.confirmDisconnect()
        XCTAssertEqual(launchLines(at: successLog).filter { $0.hasPrefix("watch") }.count, 1,
                       "disconnect lease holds the rule stopped")
        handoffBusy = true
        try successfulFixture.finish?()
        successfulApp.refreshCountdown()
        try await waitUntil { successfulApp.handoffInspectionFailure != nil && !successfulApp.protectionQuiescencePending }
        XCTAssertEqual(successfulApp.disconnectStatus?.resolved, true)
        XCTAssertEqual(launchLines(at: successLog).filter { $0.hasPrefix("watch") }.count, 1,
                       "a transient handoff lock keeps the resumed helper stopped")
        handoffBusy = false
        let priorHandoffReads = handoffReadCount
        successfulApp.refreshCountdown()
        try await waitUntil { launchLines(at: successLog).filter { $0.hasPrefix("watch") }.count == 2 }
        XCTAssertGreaterThan(handoffReadCount, priorHandoffReads,
                             "an unchanged resolved disconnect journal still retries handoff inspection")
        XCTAssertNil(successfulApp.handoffInspectionFailure)
        XCTAssertEqual(Array(launchLines(at: successLog).filter { $0.hasPrefix("rearm") }.suffix(1)), ["rearm 1"],
                       "verified recovery sends the fresh-countdown rearm flag to the helper")
        XCTAssertTrue(successfulApp.disconnectStatus?.resolved == true)
        XCTAssertTrue(successfulApp.automationPreferences.isEnabled)
        await withCheckedContinuation { continuation in successfulApp.shutdown { continuation.resume() } }

        let failedFixture = try fixture("failed-resume")
        let failureLog = directory.appendingPathComponent("failed-resume.log")
        setenv("PANELCTL_TEST_LOG", failureLog.path, 1)
        try saveAutomationPreferences(AutomationPreferences(isEnabled: true, rules: [
            protectionRule("Survivor rule", uuid: failedFixture.baseline.displays[0].uuid)
        ]))
        let failureJournalDirectory = directory.appendingPathComponent("failed-resume-journals", isDirectory: true)
        let failedCoordinator = automationCoordinator(directory: failureJournalDirectory)
        let failedApp = model(failedFixture, protectionCoordinator: failedCoordinator)
        try await waitUntil { launchLines(at: failureLog).filter { $0.hasPrefix("watch") }.count == 1 }
        failedApp.prepareDisconnect(failedFixture.uuid)
        try await waitUntil { failedApp.disconnectConsentPending }
        failedApp.confirmDisconnect()
        failedFixture.fault = "reconnect"
        failedApp.reconnectDisconnect()
        XCTAssertEqual(failedApp.disconnectStatus?.state, "needsAttention")
        XCTAssertTrue(defaults.bool(forKey: "disconnectRecoveryBlocked"))
        XCTAssertTrue(failedApp.statusSummary.contains("waiting for verified disconnect recovery"))
        XCTAssertEqual(launchLines(at: failureLog).filter { $0.hasPrefix("watch") }.count, 1,
                       "failed recovery must not rearm the existing helper")

        let relaunched = model(failedFixture, protectionCoordinator: automationCoordinator(directory: failureJournalDirectory))
        XCTAssertEqual(relaunched.disconnectStatus?.state, "needsAttention")
        XCTAssertNotNil(relaunched.disconnectBlocker)
        XCTAssertTrue(relaunched.automationPreferences.isEnabled)
        XCTAssertEqual(launchLines(at: failureLog).filter { $0.hasPrefix("watch") }.count, 1,
                       "relaunch keeps automation paused instead of replaying the disconnect")
        await withCheckedContinuation { continuation in failedApp.shutdown { continuation.resume() } }
        await withCheckedContinuation { continuation in relaunched.shutdown { continuation.resume() } }
    }

    func testAppToCoreFakeLeaseWatchdogAndReadOnlyRelaunch() async throws {
        let f = try fixture(), app = model(f)
        app.prepareDisconnect(f.uuid)
        try await waitUntil { app.disconnectConsentPending }
        app.confirmDisconnect()
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

    func testRefusalHelperFailureAndFailedReconnectPreserveEvidence() async throws {
        for fault in ["identity", "survivor", "helper", "reconnect"] {
            let f = try fixture(fault), app = model(f)
            f.fault = fault
            app.prepareDisconnect(f.uuid)
            try await waitUntil { !app.disconnectPreparationPending }
            if app.disconnectRequest != nil { app.confirmDisconnect() }
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

    func testConfirmationRevalidatesIdentityAndUnresolvedJournalWithoutWrites() async throws {
        let f = try fixture(), app = model(f)
        app.prepareDisconnect(f.uuid)
        try await waitUntil { app.disconnectConsentPending }
        f.fault = "identity"
        app.confirmDisconnect()
        XCTAssertEqual(f.arms, 0)
        XCTAssertNotNil(app.disconnectFailure)
        f.fault = ""
        try await waitUntil { app.disconnectBlocker == nil }
        app.prepareDisconnect(f.uuid)
        try await waitUntil { app.disconnectConsentPending }
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

    func testReconnectIgnoresExperimentalGateButRejectsChangedConsentJournal() async throws {
        let f = try fixture(), app = model(f)
        app.prepareDisconnect(f.uuid)
        try await waitUntil { app.disconnectConsentPending }
        app.confirmDisconnect()
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

    func testNativeProductionControlsWithFakeStatusRender() async throws {
        _ = NSApplication.shared
        let f = try fixture(), app = model(f)
        func render(_ name: String, targetUUID: String?, model renderingModel: AppModel) throws {
            let host = NSHostingView(rootView: Form {
                ExperimentalDisconnectControls(model: renderingModel, targetUUID: targetUUID)
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
        try render("generic-monitor-ready", targetUUID: f.uuid, model: app)
        try render("main-display-refused", targetUUID: f.baseline.displays[0].uuid, model: app)
        XCTAssertEqual(f.writes, [])
        app.prepareDisconnect(f.uuid)
        try render("automation-pausing", targetUUID: f.uuid, model: app)
        try await waitUntil { app.disconnectConsentPending }
        try render("automation-consent-paused", targetUUID: f.uuid, model: app)
        app.confirmDisconnect()
        app.refreshDisplays()
        try render("integrated-lease", targetUUID: nil, model: app)
        try f.finish?()
        app.refreshCountdown()
        XCTAssertEqual(app.disconnectStatus?.resolved, true)

        let unreadableFixture = try fixture("unreadable-ui")
        try Data("bad journal".utf8).write(to: unreadableFixture.store.url)
        let unreadableApp = model(unreadableFixture)
        try render("unreadable-recovery-paused", targetUUID: nil, model: unreadableApp)
        await withCheckedContinuation { continuation in unreadableApp.shutdown { continuation.resume() } }

        defaults.set(false, forKey: "disconnectRecoveryBlocked")
        let cleanupFixture = try fixture("cleanup-ui")
        var cleanupCompletion: ((Bool, String?) -> Void)?
        let cleanupApp = model(cleanupFixture, quiesceProtection: { cleanupCompletion = $0 })
        cleanupApp.prepareDisconnect(cleanupFixture.uuid)
        cleanupCompletion?(false, "Synthetic saved-brightness cleanup failure")
        try await waitUntil { !cleanupApp.disconnectPreparationPending && cleanupApp.protectionQuiescenceFailure != nil }
        try render("automation-cleanup-blocked", targetUUID: cleanupFixture.uuid, model: cleanupApp)
        await withCheckedContinuation { continuation in cleanupApp.shutdown { continuation.resume() } }
    }
}
