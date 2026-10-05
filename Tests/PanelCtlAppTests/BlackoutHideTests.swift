import AppKit
import XCTest
@testable import PanelCtlApp
@testable import PanelCtlCore

/// Hide's Black out style, with a fake overlay manager.
@MainActor
final class BlackoutHideTests: XCTestCase {
    private static let mainUUID = "AAAAAAAA-0000-0000-0000-000000000001"
    private static let sideUUID = "BBBBBBBB-0000-0000-0000-000000000002"
    private static let thirdUUID = "CCCCCCCC-0000-0000-0000-000000000003"
    private static let suiteName = "panelctl-blackout-hide-\(ProcessInfo.processInfo.processIdentifier)"

    private let displays = [
        display(1, id: 101, uuid: mainUUID, name: "Main", main: true),
        display(2, id: 202, uuid: sideUUID, name: "Side"),
        display(3, id: 303, uuid: thirdUUID, name: "Third")
    ]
    /// Every set of displays the model asked to cover, in order.
    private var coverRequests: [Set<UInt32>] = []
    /// Displays the fake overlay manager fails to cover.
    private var uncoverable: Set<UInt32> = []

    override func tearDown() {
        UserDefaults(suiteName: Self.suiteName)?.removePersistentDomain(forName: Self.suiteName)
        super.tearDown()
    }

    func testHideBlacksOutUntilShowAndKeepsOneDisplayVisible() throws {
        let model = try makeModel()
        let delegate = AppDelegate()
        delegate.model = model
        XCTAssertTrue(model.displayTiles.allSatisfy { $0.action == .hide && $0.actionBlocker == nil })

        var result = hide(Self.sideUUID, model)
        XCTAssertEqual(result?.succeeded, true)
        XCTAssertEqual(coverRequests.last, [202])
        XCTAssertEqual(tile(Self.sideUUID, model).status, .hidden)
        XCTAssertEqual(tile(Self.sideUUID, model).action, .show)
        XCTAssertNil(tile(Self.sideUUID, model).actionBlocker)
        XCTAssertEqual(model.coveredHiddenDisplayIDs, [202])
        let showSide = try XCTUnwrap(delegate.makeMenu().items.first { $0.title == "Show Side" })
        XCTAssertTrue(showSide.isEnabled)
        if #available(macOS 14.4, *) {
            XCTAssertEqual(showSide.subtitle, "Hidden", "each display shows its state")
        }
        XCTAssertTrue(delegate.makeMenu().items.contains { $0.title == "Hide Main" && $0.isEnabled })
        XCTAssertEqual(hide(Self.sideUUID, model)?.message, "Couldn\u{2019}t hide. This display is already hidden.")

        XCTAssertEqual(hide(Self.thirdUUID, model)?.succeeded, true)
        XCTAssertEqual(coverRequests.last, [202, 303], "several displays can be blacked out at once")

        // The last visible display stays visible.
        let blocker = "PanelCtl keeps at least one display visible, so it won\u{2019}t hide this one."
        XCTAssertEqual(tile(Self.mainUUID, model).actionBlocker, blocker)
        let hideMain = try XCTUnwrap(delegate.makeMenu().items.first { $0.title == "Hide Main" })
        XCTAssertFalse(hideMain.isEnabled, "a Hide that can't run is dimmed")
        XCTAssertEqual(hideMain.toolTip, blocker)
        let requests = coverRequests.count
        result = hide(Self.mainUUID, model)
        XCTAssertEqual(result?.succeeded, false)
        XCTAssertEqual(result?.message, "Couldn\u{2019}t hide. " + blocker)
        XCTAssertEqual(coverRequests.count, requests)
        XCTAssertFalse(model.isBlackoutHidden(Self.mainUUID))

        // Escape on a hidden display shows it; elsewhere it isn't Hide's.
        XCTAssertFalse(model.showHiddenDisplay(at: 101))
        XCTAssertTrue(model.showHiddenDisplay(at: 303))
        XCTAssertEqual(coverRequests.last, [202])
        XCTAssertEqual(model.displayResults[Self.thirdUUID.lowercased()]?.message, "Shown.")

        result = show(Self.sideUUID, model)
        XCTAssertEqual(result?.succeeded, true)
        XCTAssertEqual(coverRequests.last, [])
        XCTAssertEqual(tile(Self.sideUUID, model).status, .on)
        XCTAssertEqual(tile(Self.sideUUID, model).action, .hide)

        // Hidden displays are session-only: relaunch starts with every display shown.
        XCTAssertEqual(hide(Self.sideUUID, model)?.succeeded, true)
        let relaunched = try makeModel(keepingDefaults: true)
        XCTAssertTrue(relaunched.blackoutHiddenDisplays.isEmpty)
        XCTAssertEqual(tile(Self.sideUUID, relaunched).status, .on)
    }

    func testHideRefusesDisplaysItCantBlackOut() throws {
        var current = [displays[0], Self.display(2, id: 202, uuid: Self.sideUUID, name: "Side", asleep: true)]
        var mirrored: Set<UInt32> = []
        let model = try makeModel(displays: { current }, mirrored: { mirrored.contains($0) })

        XCTAssertEqual(tile(Self.sideUUID, model).actionBlocker, "Wake this display to hide it.")
        XCTAssertEqual(hide(Self.mainUUID, model)?.message,
                       "Couldn\u{2019}t hide. PanelCtl keeps at least one display visible, so it won\u{2019}t hide this one.",
                       "an asleep display doesn't count as visible")

        current = displays
        mirrored = [202]
        model.refreshDisplays()
        XCTAssertEqual(hide(Self.sideUUID, model)?.message,
                       "Couldn\u{2019}t hide. macOS is mirroring this display. Turn off mirroring in System Settings \u{2192} Displays first.")

        mirrored = []
        uncoverable = [202]
        let result = hide(Self.sideUUID, model)
        XCTAssertEqual(result?.succeeded, false)
        XCTAssertEqual(result?.message, "Couldn\u{2019}t hide. The display wasn\u{2019}t fully covered. Try again.")
        XCTAssertFalse(model.isBlackoutHidden(Self.sideUUID))
        XCTAssertEqual(coverRequests.last, [])
        XCTAssertTrue(model.uncoveredHiddenDisplays.isEmpty)
    }

    func testHiddenDisplayStaysHiddenThroughDisconnectionAndIsCoveredAgain() throws {
        var current = displays
        let model = try makeModel(displays: { current })
        XCTAssertEqual(hide(Self.sideUUID, model)?.succeeded, true)

        current = [displays[0], displays[2]]
        model.refreshDisplays()
        XCTAssertTrue(model.isBlackoutHidden(Self.sideUUID))
        XCTAssertEqual(coverRequests.last, [])
        XCTAssertEqual(model.coveredHiddenDisplayIDs, [])
        let away = tile(Self.sideUUID, model)
        XCTAssertEqual(away.status, .hidden)
        XCTAssertNil(away.display)
        XCTAssertEqual(away.action, .show, "Show stays reachable while it's away")

        // It reconnects with a new display ID and a cover that fails at first.
        let reconnected = Self.display(2, id: 222, uuid: Self.sideUUID, name: "Side")
        current = [displays[0], reconnected, displays[2]]
        uncoverable = [222]
        model.refreshDisplays()
        XCTAssertEqual(coverRequests.last, [222])
        XCTAssertEqual(model.uncoveredHiddenDisplays, [Self.sideUUID.lowercased()])
        XCTAssertEqual(model.coveredHiddenDisplayIDs, [], "focus never follows onto an uncovered display")

        uncoverable = []
        model.refreshDisplays()
        XCTAssertEqual(coverRequests.last, [222])
        XCTAssertTrue(model.uncoveredHiddenDisplays.isEmpty)
        XCTAssertEqual(model.coveredHiddenDisplayIDs, [222])

        // Show works while it's away, and its tile goes with it.
        current = [displays[0], displays[2]]
        model.refreshDisplays()
        XCTAssertEqual(show(Self.sideUUID, model)?.succeeded, true)
        XCTAssertFalse(model.displayTiles.contains { $0.id == Self.sideUUID.lowercased() })
    }

    func testHiddenDisplaysAreShownWhenNoOtherDisplayRemains() throws {
        var current = [displays[0], displays[1]]
        let model = try makeModel(displays: { current })
        XCTAssertEqual(hide(Self.sideUUID, model)?.succeeded, true)

        current = [displays[1]]
        model.refreshDisplays()
        XCTAssertFalse(model.isBlackoutHidden(Self.sideUUID))
        XCTAssertEqual(coverRequests.last, [])
        XCTAssertEqual(tile(Self.sideUUID, model).status, .on)
        XCTAssertEqual(model.displayResults[Self.sideUUID.lowercased()]?.message,
                       "Shown because no other display was connected.")
    }

    func testHiddenDisplayIsShownWhenMacOSMirrorsIt() throws {
        var mirrored: Set<UInt32> = []
        let model = try makeModel(mirrored: { mirrored.contains($0) })
        XCTAssertEqual(hide(Self.sideUUID, model)?.succeeded, true)

        // Another display now mirrors the hidden one, so it would show the cover too.
        mirrored = [202, 303]
        model.refreshDisplays()
        XCTAssertFalse(model.isBlackoutHidden(Self.sideUUID))
        XCTAssertEqual(coverRequests.last, [])
        XCTAssertEqual(tile(Self.sideUUID, model).status, .mirrored)
        XCTAssertEqual(model.displayResults[Self.sideUUID.lowercased()]?.message,
                       "Shown because macOS started mirroring it.")
    }

    func testAutomationSkipsHiddenDisplaysAndRestoreNeverShowsThem() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("panelctl-blackout-hide-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let helper = directory.appendingPathComponent("fake-panelctl")
        let log = directory.appendingPathComponent("helper.log")
        let script = """
        #!/bin/bash
        printf 'launch:%s\\n' "$*" >> "$PANELCTL_TEST_LOG"
        printf '{"state":"waiting","blackedOutDisplayIDs":[]}\\n'
        trap 'printf "{\\"state\\":\\"stopped\\",\\"blackedOutDisplayIDs\\":[],\\"cleanupSucceeded\\":true}\\n"; exit 0' TERM
        while IFS= read -r command; do
            printf 'command:%s\\n' "$command" >> "$PANELCTL_TEST_LOG"
        done
        """
        try Data(script.utf8).write(to: helper)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)
        setenv("PANELCTL_HELPER", helper.path, 1)
        setenv("PANELCTL_TEST_LOG", log.path, 1)
        defer {
            unsetenv("PANELCTL_HELPER")
            unsetenv("PANELCTL_TEST_LOG")
        }

        let model = try makeModel(configure: { defaults in
            var preferences = ProtectionPreferences()
            preferences.isEnabled = true
            preferences.didChooseDisplays = true
            preferences.selectedDisplayUUIDs = [Self.mainUUID, Self.sideUUID]
            preferences.idleSeconds = 120
            preferences.followUpAction = .restore
            preferences.followUpSeconds = 15
            defaults.set(try JSONEncoder().encode(preferences), forKey: "blackoutPreferences")
        })
        let options = "--mode blocking --overlay-opacity 100 --idle-after 120 --watch --timeout 15"
        let both = "launch:blackout --display \(Self.mainUUID) --display \(Self.sideUUID) \(options)"
        let skippingSide = "launch:blackout --display \(Self.mainUUID) --panelctl-hidden-display \(Self.sideUUID) \(options)"
        var lines = try await waitForLines(1, at: log)
        XCTAssertEqual(lines, [both])

        XCTAssertEqual(hide(Self.sideUUID, model)?.succeeded, true)
        lines = try await waitForLines(2, at: log)
        XCTAssertEqual(lines.last, skippingSide, "automation restarts without the hidden display")

        // Black Out Now and Restore drive automation; neither shows the hidden display.
        try model.blackoutNow()
        lines = try await waitForLines(3, at: log)
        XCTAssertEqual(lines.last, "command:blackout-now")
        try await waitUntil("waiting after Black Out Now") { model.runtimeState == .waiting }
        XCTAssertTrue(try model.restoreBlackout())
        lines = try await waitForLines(4, at: log)
        XCTAssertEqual(lines.last, "command:restore")
        XCTAssertTrue(model.isBlackoutHidden(Self.sideUUID))
        XCTAssertEqual(coverRequests.last, [202])

        // Automation waits while every display it covers is hidden.
        XCTAssertEqual(hide(Self.mainUUID, model)?.succeeded, true)
        try await waitUntil("waiting for a shown display") {
            model.runtimeState == .waitingForDisplays("The displays automation covers are hidden. Show one to resume.")
        }

        XCTAssertEqual(show(Self.mainUUID, model)?.succeeded, true)
        XCTAssertEqual(show(Self.sideUUID, model)?.succeeded, true)
        try await waitUntil("relaunch covering both") {
            (try? String(contentsOf: log, encoding: .utf8))?
                .split(separator: "\n").last.map(String.init) == both
        }

        let stopped = expectation(description: "watcher stopped")
        model.shutdown { stopped.fulfill() }
        await fulfillment(of: [stopped], timeout: 3)
    }

    // MARK: Helpers

    private func makeModel(
        displays: (() -> [DisplayRecord])? = nil,
        mirrored: @escaping (UInt32) -> Bool = { _ in false },
        keepingDefaults: Bool = false,
        configure: (UserDefaults) throws -> Void = { _ in }
    ) throws -> AppModel {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: Self.suiteName))
        if !keepingDefaults {
            defaults.removePersistentDomain(forName: Self.suiteName)
        }
        try configure(defaults)
        let fixed = self.displays
        return AppModel(
            defaults: defaults,
            displayProvider: displays ?? { fixed },
            idleSecondsProvider: { nil },
            isDisplayMirrored: mirrored,
            inspectHandoff: {
                DisplayHandoffStatus(state: .none, journalPath: "/nonexistent/panelctl-blackout-hide.json")
            },
            hideDisplay: { _, _, _ in
                XCTFail("Black out never removes a display from the desktop")
                return .notRequested
            },
            showDisplay: { _, _ in
                XCTFail("Black out never shows a removed display")
                return .notRequested
            },
            checkDDCInput: { _ in
                XCTFail("Black out never queries DDC")
                return DDCInputReading(displayID: 0, uuid: "", current: 1)
            },
            coverDisplays: { [unowned self] ids in
                coverRequests.append(ids)
                return ids.intersection(uncoverable)
            }
        )
    }

    private func hide(_ uuid: String, _ model: AppModel) -> DisplayOperationResult? {
        var result: DisplayOperationResult?
        model.hide(targetUUID: uuid) { result = $0 }
        return result
    }

    private func show(_ uuid: String, _ model: AppModel) -> DisplayOperationResult? {
        var result: DisplayOperationResult?
        model.show(targetUUID: uuid) { result = $0 }
        return result
    }

    private func tile(_ uuid: String, _ model: AppModel) -> DisplayTile {
        guard let tile = model.displayTiles.first(where: { $0.id == uuid.lowercased() }) else {
            XCTFail("no tile for \(uuid)")
            return DisplayTile(id: "", uuid: nil, name: "", status: .unavailable, display: nil)
        }
        return tile
    }

    private func waitForLines(_ count: Int, at log: URL) async throws -> [String] {
        for _ in 0..<150 {
            if let contents = try? String(contentsOf: log, encoding: .utf8) {
                let lines = contents.split(separator: "\n").map(String.init)
                if lines.count >= count { return lines }
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("Timed out waiting for \(count) helper log lines")
        return []
    }

    private func waitUntil(_ condition: String, _ predicate: @escaping @MainActor () -> Bool) async throws {
        for _ in 0..<150 {
            if predicate() { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("Timed out: \(condition)")
    }

    private static func display(
        _ index: Int, id: UInt32, uuid: String, name: String, main: Bool = false, asleep: Bool = false
    ) -> DisplayRecord {
        DisplayRecord(
            index: index,
            id: id,
            uuid: uuid,
            name: name,
            active: true,
            online: true,
            asleep: asleep,
            builtin: false,
            main: main,
            vendor: UInt32(index),
            model: UInt32(index * 10),
            serial: UInt32(index * 100),
            bounds: DisplayBounds(CGRect(x: (index - 1) * 1920, y: 0, width: 1920, height: 1080)),
            pixelWidth: 1920,
            pixelHeight: 1080
        )
    }
}
