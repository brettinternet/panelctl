import AppKit
import SwiftUI
import XCTest
@testable import PanelCtlApp
@testable import PanelCtlCore

@MainActor
final class ExperimentalDisconnectTests: XCTestCase {
    private let target = DisplayIdentitySnapshot(
        uuid: "00000000-0000-0000-0000-000000000002", id: 2,
        name: "Synthetic external display", vendor: 1, model: 2, serial: 2
    )

    private func presentation(
        _ phase: ExperimentalDisconnectPresentation.Phase,
        seconds: Int = 15, elapsed: Int = 5
    ) -> ExperimentalDisconnectPresentation {
        .init(syntheticSession: .init(
            phase: phase, target: target, journalID: "synthetic-journal",
            journalPath: "/synthetic/recovery/current.json", targetEnumerable: false,
            leaseSeconds: seconds, elapsedSeconds: elapsed, failure: "Synthetic identity ambiguity"
        ))
    }

    func testProductionUnavailableAndAutomationHasNoDisconnectCommand() throws {
        let production = ExperimentalDisconnectPresentation.production
        XCTAssertNil(production.syntheticSession)
        XCTAssertFalse(production.canDisconnect)
        XCTAssertFalse(production.canReconnect)
        XCTAssertTrue(production.detail.contains("qualification is required"))
        for distinction in ["mirror Hide", "blackout", "display sleep", "DDC input", "No alternative"] {
            XCTAssertTrue(ExperimentalDisconnectPresentation.distinction.contains(distinction))
        }
        for command in ["disconnect", "reconnect", "experimental-disconnect"] {
            let payload = Data("{\"protocol\":1,\"command\":\"\(command)\"}".utf8)
            XCTAssertThrowsError(try JSONDecoder().decode(AppControlRequest.self, from: payload))
        }
        // Existing protection disable is not a private display disconnect alias.
        XCTAssertEqual(AppControlCommand(rawValue: "disable"), .disable)
    }

    func testSyntheticConsentAndFailureStatesNeverAuthorizeWrites() {
        for phase in ExperimentalDisconnectPresentation.Phase.allCases {
            let value = presentation(phase)
            XCTAssertFalse(value.canDisconnect)
            XCTAssertFalse(value.canReconnect)
            XCTAssertTrue(value.evidence?.contains(target.uuid) == true)
            XCTAssertTrue(value.evidence?.contains("not enumerable; retained identity only") == true)
            XCTAssertTrue(value.evidence?.contains("never resolves, deletes, or rewrites") == true)
        }
        let consent = presentation(.consent).detail
        for scope in ["15-second", "another verified usable physical screen", "future sessions", "DDC writes", "Cancel"] {
            XCTAssertTrue(consent.contains(scope))
        }
        XCTAssertTrue(presentation(.refused).detail.contains("do not guess a display ID"))
        XCTAssertTrue(presentation(.helperFailed).detail.contains("Do not disconnect"))
        XCTAssertTrue(presentation(.watchdogRecovery).detail.contains("Reconnect is not verified"))
        XCTAssertTrue(presentation(.reconnectFailed).detail.contains("Preserve the journal"))
    }

    func testLeaseProgressExpiryAndInvalidBounds() {
        XCTAssertEqual(presentation(.leased, elapsed: 0).remainingSeconds, 15)
        XCTAssertEqual(presentation(.leased, elapsed: 5).remainingSeconds, 10)
        for elapsed in [15, 16, Int.max] {
            let value = presentation(.leased, elapsed: elapsed)
            XCTAssertEqual(value.remainingSeconds, 0)
            XCTAssertTrue(value.detail.contains("Lease expired"))
            XCTAssertTrue(value.detail.contains("not proof of reconnect"))
        }
        for seconds in [Int.min, 0, 61, Int.max] {
            let value = presentation(.leased, seconds: seconds)
            XCTAssertNil(value.remainingSeconds)
            XCTAssertTrue(value.detail.contains("Refused"))
        }
        XCTAssertNil(presentation(.leased, elapsed: -1).remainingSeconds)
        XCTAssertEqual(presentation(.leased, seconds: 60, elapsed: 59).remainingSeconds, 1)
    }

    func testSyntheticJournalSurvivesRelaunchWithoutEnumerableTargetOrEvidenceMutation() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("panelctl-disconnect-fixture-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("current.json")
        let snapshotJSON: [String: Any] = [
            "bootSession": "synthetic-boot", "osBuild": "synthetic-build", "userID": getuid(),
            "displays": (1...2).map { id -> [String: Any] in
                ["uuid": "00000000-0000-0000-0000-00000000000\(id)", "id": id,
                 "vendor": 1, "model": id, "serial": id, "builtin": false,
                 "main": id == 1, "active": true, "x": (id - 1) * 1920, "y": 0, "rotation": 0,
                 "mode": ["id": 1, "width": 1920, "height": 1080, "pixelWidth": 1920,
                          "pixelHeight": 1080, "refreshRate": 60, "flags": 0]]
            }
        ]
        let snapshot = try JSONDecoder().decode(RecoverySnapshot.self, from: JSONSerialization.data(withJSONObject: snapshotJSON))
        var journal = RecoveryJournal(snapshot: snapshot, timeout: 15, disabledByUsID: 2,
                                      disableStaged: true, disableCommitStarted: true)
        journal.privateLease = true
        journal.state = .needsAttention
        journal.failure = "Identity ambiguous after expired lease; retained target not enumerable"
        journal.trigger = "deadline"
        let store = RecoveryStore(url: url)
        try store.lock()
        try store.create(journal)
        store.unlock()
        let originalBytes = try Data(contentsOf: url)

        // A test-only projection, not a production provider/schema. App-facing
        // private journal and lease observations remain TASK-20 integration work.
        func relaunch() throws -> ExperimentalDisconnectPresentation {
            let reopened = try RecoveryStore(url: url).load()
            let captured = try XCTUnwrap(reopened.snapshot.displays.first { $0.id == reopened.disabledByUsID })
            return .init(syntheticSession: .init(
                phase: .refused,
                target: .init(uuid: captured.uuid, id: captured.id, name: "Synthetic external display",
                              vendor: captured.vendor, model: captured.model, serial: captured.serial),
                journalID: reopened.id.uuidString, journalPath: url.path, targetEnumerable: false,
                leaseSeconds: 15, elapsedSeconds: 20, failure: reopened.failure
            ))
        }
        let firstLaunch = try relaunch()
        let secondLaunch = try relaunch()
        XCTAssertEqual(firstLaunch, secondLaunch)
        XCTAssertEqual(secondLaunch.syntheticSession?.target, target)
        XCTAssertEqual(secondLaunch.syntheticSession?.failure, journal.failure)
        XCTAssertTrue(secondLaunch.detail.contains("Identity ambiguous"))
        XCTAssertEqual(secondLaunch.remainingSeconds, 0)
        XCTAssertFalse(secondLaunch.canReconnect)
        XCTAssertEqual(try Data(contentsOf: url), originalBytes)
        XCTAssertEqual(try RecoveryStore(url: url).load().state, .needsAttention)
    }

    func testNativeSyntheticCardsRenderAtMinimumWidth() throws {
        _ = NSApplication.shared
        let values = [ExperimentalDisconnectPresentation.production]
            + ExperimentalDisconnectPresentation.Phase.allCases.map { presentation($0) }
            + [presentation(.leased, elapsed: 20)]
        for value in values {
            let host = NSHostingView(rootView: ExperimentalDisconnectView(presentation: value)
                .padding(12).frame(maxHeight: .infinity, alignment: .top)
                .background(Color(nsColor: .windowBackgroundColor)))
            host.sizingOptions = []
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 1000),
                                  styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            window.setContentSize(NSSize(width: 440, height: 1000))
            window.orderFront(nil)
            defer { window.close() }
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            XCTAssertEqual(host.bounds.width, 440)
            XCTAssertEqual(host.bounds.height, 1000)
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            XCTAssertGreaterThan(bitmap.pixelsWide, 0)
            if let output = ProcessInfo.processInfo.environment["PANELCTL_DISCONNECT_FIXTURE_OUTPUT"] {
                let name = value.syntheticSession.map { "\($0.phase)-\($0.elapsedSeconds)" } ?? "production"
                let url = URL(fileURLWithPath: output).appendingPathComponent("\(name).png")
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: url)
            }
        }
    }

}
