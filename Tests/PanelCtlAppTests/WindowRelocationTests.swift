import XCTest
import CoreGraphics
@testable import PanelCtlApp
@testable import PanelCtlCore

@MainActor
final class WindowRelocationTests: XCTestCase {
    private let sourceUUID = "00000000-0000-0000-0000-000000000201"
    private let mainUUID = "00000000-0000-0000-0000-000000000202"
    private let alternateUUID = "00000000-0000-0000-0000-000000000203"

    func testAutomaticSelectionSkipsSourceCoverageRemovedSleepAndMirrors() throws {
        let records = [
            display(index: 1, id: 1, uuid: sourceUUID, main: false, bounds: CGRect(x: -100, y: 0, width: 100, height: 100)),
            display(index: 2, id: 2, uuid: mainUUID, main: true),
            display(index: 3, id: 3, uuid: alternateUUID, main: false)
        ]
        let selected = try XCTUnwrap(WindowMoveDisplaySelector.select(
            configuration: MoveWindowsConfiguration(), sourceUUID: sourceUUID,
            displays: records, coveredDisplayIDs: [1, 2], removedDisplayUUIDs: [], mirroredDisplayIDs: []
        ).getSuccessForTest())
        XCTAssertEqual(selected.uuid, alternateUUID)

        let mainAgain = try XCTUnwrap(WindowMoveDisplaySelector.select(
            configuration: MoveWindowsConfiguration(), sourceUUID: sourceUUID,
            displays: records, coveredDisplayIDs: [1], removedDisplayUUIDs: [], mirroredDisplayIDs: []
        ).getSuccessForTest())
        XCTAssertEqual(mainAgain.uuid, mainUUID)
        let duplicateDestination = records + [display(index: 4, id: 4, uuid: mainUUID, main: false)]
        XCTAssertEqual(WindowMoveDisplaySelector.select(configuration: MoveWindowsConfiguration(),
            sourceUUID: sourceUUID, displays: duplicateDestination, coveredDisplayIDs: [],
            removedDisplayUUIDs: [], mirroredDisplayIDs: []).getFailureForTest(), .identityAmbiguous)

        let offlineChoices = [records[0],
            display(index: 2, id: 2, uuid: mainUUID, main: true, asleep: true),
            display(index: 3, id: 3, uuid: alternateUUID, main: false)
        ]
        let fallback = try XCTUnwrap(WindowMoveDisplaySelector.select(
            configuration: MoveWindowsConfiguration(), sourceUUID: sourceUUID,
            displays: offlineChoices, coveredDisplayIDs: [], removedDisplayUUIDs: [alternateUUID], mirroredDisplayIDs: []
        ).getFailureForTest())
        XCTAssertEqual(fallback, .noDestination)
    }

    func testExplicitDestinationIsStrictAndNeverFallsBack() throws {
        let records = [
            display(index: 1, id: 1, uuid: sourceUUID, main: false),
            display(index: 2, id: 2, uuid: mainUUID, main: true),
            display(index: 3, id: 3, uuid: alternateUUID, main: false)
        ]
        let reference = DisplayIdentityReference(records[1])
        let selected = try XCTUnwrap(WindowMoveDisplaySelector.select(
            configuration: MoveWindowsConfiguration(destination: .display(reference)),
            sourceUUID: sourceUUID, displays: records, coveredDisplayIDs: [2],
            removedDisplayUUIDs: [], mirroredDisplayIDs: []
        ).getFailureForTest())
        XCTAssertEqual(selected, .destinationUnavailable)

        let sourceAsDestination = WindowMoveDisplaySelector.select(
            configuration: MoveWindowsConfiguration(destination: .display(DisplayIdentityReference(records[0]))),
            sourceUUID: sourceUUID, displays: records, coveredDisplayIDs: [],
            removedDisplayUUIDs: [], mirroredDisplayIDs: []
        )
        XCTAssertEqual(sourceAsDestination.getFailureForTest(), .destinationUnavailable)

        let duplicate = records + [records[1]]
        let ambiguous = WindowMoveDisplaySelector.select(
            configuration: MoveWindowsConfiguration(destination: .display(reference)),
            sourceUUID: sourceUUID, displays: duplicate, coveredDisplayIDs: [],
            removedDisplayUUIDs: [], mirroredDisplayIDs: []
        )
        XCTAssertEqual(ambiguous.getFailureForTest(), .identityAmbiguous)

        let changed = DisplayIdentityReference(uuid: mainUUID, name: "changed", vendor: 999, model: 2, serial: 3)
        let changedIdentity = WindowMoveDisplaySelector.select(
            configuration: MoveWindowsConfiguration(destination: .display(changed)),
            sourceUUID: sourceUUID, displays: records, coveredDisplayIDs: [],
            removedDisplayUUIDs: [], mirroredDisplayIDs: []
        )
        XCTAssertEqual(changedIdentity.getFailureForTest(), .destinationUnavailable)
    }

    func testGeometryPreservesLogicalSizeNegativeOriginsAndVisibleFrameConversion() throws {
        let visible = try XCTUnwrap(WindowMoveGeometry.quartzVisibleFrame(
            appKitFrame: CGRect(x: -1280, y: 40, width: 1280, height: 680), primaryDisplayHeight: 1080
        ))
        XCTAssertEqual(visible, CGRect(x: -1280, y: 360, width: 1280, height: 680))

        let src = display(index: 1, id: 1, uuid: sourceUUID, main: false,
                          bounds: CGRect(x: -1920, y: 0, width: 1920, height: 1080))
        let dst = display(index: 2, id: 2, uuid: mainUUID, main: true,
                          bounds: CGRect(x: 0, y: 0, width: 1280, height: 800), pixelWidth: 2560, pixelHeight: 1600)
        let window = CGRect(x: -1800, y: 100, width: 500, height: 350)
        XCTAssertEqual(WindowMoveGeometry.attribution(of: window, to: [src, dst])?.uuid, sourceUUID)
        let moved = try XCTUnwrap(WindowMoveGeometry.destinationFrame(
            window: window, sourceBounds: CGRect(x: src.bounds.x, y: src.bounds.y, width: src.bounds.width, height: src.bounds.height),
            destinationVisibleFrame: CGRect(x: 0, y: 30, width: 1280, height: 770)
        ))
        XCTAssertEqual(moved.size, window.size, "mixed backing scales never scale logical window size")
        XCTAssertTrue(moved.minX >= 0 && moved.minY >= 30)
        XCTAssertTrue(moved.maxX <= 1280 && moved.maxY <= 800)
    }

    func testGeometryResizesOnlyOversizedWindowsAndRespectsMinimumSize() throws {
        let sourceBounds = CGRect(x: -1000, y: 0, width: 1000, height: 800)
        let visible = CGRect(x: 0, y: 20, width: 600, height: 400)
        let normal = CGRect(x: -800, y: 100, width: 500, height: 300)
        XCTAssertEqual(WindowMoveGeometry.destinationFrame(window: normal, sourceBounds: sourceBounds,
            destinationVisibleFrame: visible)?.size, normal.size)

        let oversized = CGRect(x: -950, y: 0, width: 1200, height: 900)
        let resized = try XCTUnwrap(WindowMoveGeometry.destinationFrame(window: oversized,
            sourceBounds: sourceBounds, destinationVisibleFrame: visible))
        XCTAssertEqual(resized.size, CGSize(width: 600, height: 400))
        XCTAssertEqual(resized.minX, 0)
        XCTAssertEqual(resized.minY, 20)

        let minConstrained = try XCTUnwrap(WindowMoveGeometry.destinationFrame(window: oversized,
            sourceBounds: sourceBounds, destinationVisibleFrame: visible,
            minimumSize: CGSize(width: 700, height: 450)))
        XCTAssertEqual(minConstrained.size, CGSize(width: 700, height: 450))
        XCTAssertEqual(minConstrained.midX, visible.midX)
        XCTAssertEqual(minConstrained.midY, visible.midY)
    }

    func testAttributionUsesLargestOverlapAndStableUUIDForTies() {
        let low = display(index: 1, id: 1, uuid: "00000000-0000-0000-0000-000000000010", main: false,
                         bounds: CGRect(x: 0, y: 0, width: 100, height: 100))
        let high = display(index: 2, id: 2, uuid: "00000000-0000-0000-0000-000000000020", main: false,
                          bounds: CGRect(x: 0, y: 0, width: 100, height: 100))
        XCTAssertEqual(WindowMoveGeometry.attribution(of: CGRect(x: 20, y: 20, width: 40, height: 40), to: [high, low])?.uuid, low.uuid)
        XCTAssertEqual(WindowMoveGeometry.attribution(of: CGRect(x: 200, y: 200, width: 10, height: 10), to: [low, high]), nil)
        let spanning = display(index: 3, id: 3, uuid: alternateUUID, main: false,
                               bounds: CGRect(x: 60, y: 0, width: 100, height: 100))
        XCTAssertEqual(WindowMoveGeometry.attribution(of: CGRect(x: 50, y: 0, width: 100, height: 100), to: [low, spanning])?.uuid, alternateUUID)
    }

    func testVisibilityMatchingRequiresUniqueBidirectionalPIDAndFrameMatch() {
        let ax = [WindowMoveAXEvidence(processID: 7, frame: CGRect(x: 10, y: 20, width: 300, height: 200))]
        let unique = [WindowMoveCGEvidence(processID: 7, frame: CGRect(x: 11, y: 20, width: 300, height: 200), layer: 0)]
        XCTAssertEqual(WindowMoveVisibilityMatcher.match(axWindows: ax, cgWindows: unique), [.matched(cgIndex: 0)])
        XCTAssertEqual(WindowMoveVisibilityMatcher.match(axWindows: ax, cgWindows: [
            WindowMoveCGEvidence(processID: 8, frame: ax[0].frame, layer: 0),
            WindowMoveCGEvidence(processID: 7, frame: ax[0].frame, layer: 2)
        ]), [.unverified])
        XCTAssertEqual(WindowMoveVisibilityMatcher.match(axWindows: ax, cgWindows: [
            WindowMoveCGEvidence(processID: 7, frame: ax[0].frame, layer: 0),
            WindowMoveCGEvidence(processID: 7, frame: ax[0].frame, layer: 0)
        ]), [.unverified])
        XCTAssertEqual(WindowMoveVisibilityMatcher.match(axWindows: ax + ax, cgWindows: unique), [.unverified, .unverified])
        let nearFirst = WindowMoveAXEvidence(processID: 9, frame: CGRect(x: 0.8, y: 0, width: 100, height: 100))
        let ambiguousSecond = WindowMoveAXEvidence(processID: 9, frame: CGRect(x: 1, y: 0, width: 100, height: 100))
        XCTAssertEqual(WindowMoveVisibilityMatcher.match(axWindows: [nearFirst, ambiguousSecond], cgWindows: [
            WindowMoveCGEvidence(processID: 9, frame: CGRect(x: 0, y: 0, width: 100, height: 100), layer: 0),
            WindowMoveCGEvidence(processID: 9, frame: CGRect(x: 2, y: 0, width: 100, height: 100), layer: 0)
        ]), [.unverified, .unverified], "an ambiguous AX candidate also makes the shared CG match non-unique")
    }

    func testFakeAXWorkerSkipsFullscreenMinimizedOtherSpaceVanishedAndNonmovableWindows() async throws {
        let source = display(index: 1, id: 1, uuid: sourceUUID, main: false,
                            bounds: CGRect(x: -100, y: 0, width: 100, height: 100))
        let destination = display(index: 2, id: 2, uuid: mainUUID, main: true,
                                  bounds: CGRect(x: 0, y: 0, width: 100, height: 100))
        let full = axWindow(handle: UUID(), pid: 210, frame: CGRect(x: -100, y: 0, width: 100, height: 100), fullscreen: true)
        let minimized = axWindow(handle: UUID(), pid: 210, frame: CGRect(x: -90, y: 10, width: 40, height: 40), minimized: true)
        let otherSpace = axWindow(handle: UUID(), pid: 210, frame: CGRect(x: -80, y: 20, width: 30, height: 30))
        let nonmovable = axWindow(handle: UUID(), pid: 210, frame: CGRect(x: -70, y: 30, width: 20, height: 20), canSetPosition: false)
        let vanished = axWindow(handle: UUID(), pid: 210, frame: CGRect(x: -60, y: 40, width: 10, height: 10))
        let platform = FakeWindowMovePlatform(processIDs: [210],
            enumerations: [210: .init(windows: [full, minimized, otherSpace, nonmovable, vanished], failure: nil)],
            windows: [full, minimized, otherSpace, nonmovable, vanished], cgWindows: [
                WindowMoveCGEvidence(processID: 210, frame: full.frame, layer: 0),
                WindowMoveCGEvidence(processID: 210, frame: minimized.frame, layer: 0),
                WindowMoveCGEvidence(processID: 210, frame: nonmovable.frame, layer: 0),
                WindowMoveCGEvidence(processID: 210, frame: vanished.frame, layer: 0)
            ], readFailures: [vanished.handle: .vanished])
        let mover = AccessibilityWindowMover(permission: FakeWindowMovePermission(.granted), platform: platform,
            visibleFramesProvider: { [2: CGRect(x: 0, y: 0, width: 100, height: 100)] })
        let result = await mover.move(request(source: source, destination: destination)) { .allowed }
        XCTAssertEqual(result.moved, 0)
        XCTAssertEqual(result.skipped, 5)
        XCTAssertEqual(result.reasons.first(where: { $0.reason == .fullscreen })?.count, 1)
        XCTAssertEqual(result.reasons.first(where: { $0.reason == .minimized })?.count, 1)
        XCTAssertEqual(result.reasons.count, 4, "the privacy-safe reason list is bounded")
        XCTAssertEqual(result.reasons.first(where: { $0.reason == .nonmovable })?.count, 1)
        XCTAssertEqual(result.reasons.first(where: { $0.reason == .vanished })?.count, 1)
        XCTAssertTrue(platform.writes.isEmpty)
    }

    func testFakeAXWorkerReportsUnverifiedVisibilityWithoutWriting() async throws {
        let source = display(index: 1, id: 1, uuid: sourceUUID, main: false,
                            bounds: CGRect(x: -100, y: 0, width: 100, height: 100))
        let destination = display(index: 2, id: 2, uuid: mainUUID, main: true,
                                  bounds: CGRect(x: 0, y: 0, width: 100, height: 100))
        let window = axWindow(handle: UUID(), pid: 211, frame: CGRect(x: -90, y: 10, width: 40, height: 40))
        let platform = FakeWindowMovePlatform(processIDs: [211],
            enumerations: [211: .init(windows: [window], failure: nil)], windows: [window], cgWindows: [])
        let mover = AccessibilityWindowMover(permission: FakeWindowMovePermission(.granted), platform: platform,
            visibleFramesProvider: { [2: CGRect(x: 0, y: 0, width: 100, height: 100)] })
        let result = await mover.move(request(source: source, destination: destination)) { .allowed }
        XCTAssertEqual(result.skipped, 1)
        XCTAssertEqual(result.reasons, [AppControlWindowMoveReasonCount(reason: .visibilityUnverified, count: 1)])
        XCTAssertTrue(platform.writes.isEmpty)
    }

    func testFakeAXWorkerUsesPerElementTimeoutContinuesAfterHungAppAndReportsCounts() async throws {
        let source = display(index: 1, id: 1, uuid: sourceUUID, main: false,
                             bounds: CGRect(x: -100, y: 0, width: 100, height: 100))
        let destination = display(index: 2, id: 2, uuid: mainUUID, main: true,
                                  bounds: CGRect(x: 0, y: 0, width: 100, height: 100))
        let frame = CGRect(x: -90, y: 10, width: 40, height: 40)
        let working = axWindow(handle: UUID(), pid: 200, frame: frame)
        let platform = FakeWindowMovePlatform(
            processIDs: [100, 200],
            enumerations: [100: .init(windows: [], failure: .appTimeout), 200: .init(windows: [working], failure: nil)],
            windows: [working],
            cgWindows: [WindowMoveCGEvidence(processID: 200, frame: frame, layer: 0)]
        )
        let permission = FakeWindowMovePermission(.granted)
        let mover = AccessibilityWindowMover(permission: permission, platform: platform,
            visibleFramesProvider: { [2: CGRect(x: 0, y: 0, width: 100, height: 100)] })
        let result = await mover.move(request(source: source, destination: destination,
                                              coveredDisplayIDs: [source.id])) { .allowed }
        XCTAssertEqual(result.moved, 1, "a blacked-out source remains a valid source for Move")
        XCTAssertEqual(result.failed, 0)
        XCTAssertEqual(result.appFailures, 1)
        XCTAssertEqual(result.appFailureReasons, [AppControlWindowMoveReasonCount(reason: .appTimeout, count: 1)])
        XCTAssertTrue(platform.timeouts.allSatisfy { $0 == 0.25 })
        XCTAssertTrue(platform.budgets.allSatisfy { $0 > 0 && $0 <= 1 })
        XCTAssertTrue(platform.workerThreads.allSatisfy { !$0 }, "AX work never runs on the main thread")
        XCTAssertEqual(platform.writes.count, 1)
        XCTAssertEqual(platform.writes.first?.origin, CGPoint(x: 10, y: 10))
    }

    func testResizeAndPositionSettersRevalidateGateIndependently() async throws {
        let source = display(index: 1, id: 1, uuid: sourceUUID, main: false,
                            bounds: CGRect(x: -100, y: 0, width: 100, height: 100))
        let destination = display(index: 2, id: 2, uuid: mainUUID, main: true,
                                  bounds: CGRect(x: 0, y: 0, width: 100, height: 100))
        let frame = CGRect(x: -90, y: 10, width: 80, height: 60)
        let window = axWindow(handle: UUID(), pid: 204, frame: frame)
        let platform = FakeWindowMovePlatform(processIDs: [204],
            enumerations: [204: .init(windows: [window], failure: nil)], windows: [window],
            cgWindows: [WindowMoveCGEvidence(processID: 204, frame: frame, layer: 0)])
        let mover = AccessibilityWindowMover(permission: FakeWindowMovePermission(.granted), platform: platform,
            visibleFramesProvider: { [2: CGRect(x: 0, y: 0, width: 30, height: 100)] })
        var gates = 0
        let result = await mover.move(request(source: source, destination: destination)) {
            gates += 1
            return gates == 1 ? .allowed : .refused(.topologyChanged)
        }
        XCTAssertEqual(gates, 2, "oversized-window resize and position are separate setters")
        XCTAssertEqual(platform.writes.count, 1, "position is not set after topology changes following resize")
        XCTAssertEqual(platform.writes.first?.size, CGSize(width: 30, height: 60))
        XCTAssertEqual(result.moved, 0)
        XCTAssertEqual(result.failed, 1)
        XCTAssertEqual(result.reasons.first?.reason, .moveUnverified)
        XCTAssertEqual(result.refusalReason, .topologyChanged)
    }

    func testFakeAXWorkerPermissionRevocationTopologyAndTimedOutWriteAreHonest() async throws {
        let source = display(index: 1, id: 1, uuid: sourceUUID, main: false,
                             bounds: CGRect(x: -100, y: 0, width: 100, height: 100))
        let destination = display(index: 2, id: 2, uuid: mainUUID, main: true,
                                  bounds: CGRect(x: 0, y: 0, width: 100, height: 100))
        let frame = CGRect(x: -90, y: 10, width: 40, height: 40)
        let first = axWindow(handle: UUID(), pid: 201, frame: frame)
        let second = axWindow(handle: UUID(), pid: 202, frame: CGRect(x: -40, y: 20, width: 30, height: 30))
        let platform = FakeWindowMovePlatform(processIDs: [201, 202],
            enumerations: [201: .init(windows: [first], failure: nil), 202: .init(windows: [second], failure: nil)],
            windows: [first, second], cgWindows: [
                WindowMoveCGEvidence(processID: 201, frame: first.frame, layer: 0),
                WindowMoveCGEvidence(processID: 202, frame: second.frame, layer: 0)
            ], writeResults: [first.handle: .timedOut])
        let permission = FakeWindowMovePermission(.granted)
        let mover = AccessibilityWindowMover(permission: permission, platform: platform,
            visibleFramesProvider: { [2: CGRect(x: 0, y: 0, width: 100, height: 100)] })
        var gates = 0
        let result = await mover.move(request(source: source, destination: destination)) {
            gates += 1
            if gates == 1 { return .allowed }
            return .refused(.topologyChanged)
        }
        XCTAssertEqual(result.moved, 0)
        XCTAssertEqual(result.failed, 1)
        XCTAssertEqual(result.reasons.first(where: { $0.reason == .moveUnverified })?.count, 1)
        XCTAssertEqual(result.refusalReason, .topologyChanged)
        XCTAssertEqual(result.appFailureReasons.first?.reason, .appTimeout)
        XCTAssertEqual(platform.writes.count, 1, "a timed-out setter is not retried and later topology loss stops the pass")

        let revocationFirst = axWindow(handle: UUID(), pid: 203, frame: frame)
        let revocationSecond = axWindow(handle: UUID(), pid: 203, frame: CGRect(x: -40, y: 20, width: 30, height: 30))
        let revokingPlatform = FakeWindowMovePlatform(processIDs: [203],
            enumerations: [203: .init(windows: [revocationFirst, revocationSecond], failure: nil)],
            windows: [revocationFirst, revocationSecond],
            cgWindows: [WindowMoveCGEvidence(processID: 203, frame: revocationFirst.frame, layer: 0),
                        WindowMoveCGEvidence(processID: 203, frame: revocationSecond.frame, layer: 0)])
        let revokingPermission = FakeWindowMovePermission(.granted)
        let revokingMover = AccessibilityWindowMover(permission: revokingPermission, platform: revokingPlatform,
            visibleFramesProvider: { [2: CGRect(x: 0, y: 0, width: 100, height: 100)] })
        var revocationGates = 0
        let revoked = await revokingMover.move(request(source: source, destination: destination)) {
            revocationGates += 1
            if revocationGates == 1 { revokingPermission.value = .missing; return WindowMoveGate.allowed }
            let reason: AppControlWindowMoveReason = revokingPermission.value.reason ?? .permissionMissing
            return WindowMoveGate.refused(reason)
        }
        XCTAssertEqual(revoked.moved, 1)
        XCTAssertEqual(revoked.refusalReason, .permissionMissing)
        XCTAssertEqual(revokingPlatform.writes.count, 1)

        let deniedPlatform = FakeWindowMovePlatform(processIDs: [], enumerations: [:], windows: [], cgWindows: [])
        let deniedPermission = FakeWindowMovePermission(.missing)
        let deniedMover = AccessibilityWindowMover(permission: deniedPermission, platform: deniedPlatform,
            visibleFramesProvider: { [:] })
        let denied = await deniedMover.move(request(source: source, destination: destination)) { .allowed }
        XCTAssertEqual(denied.refusalReason, .permissionMissing)
        XCTAssertEqual(deniedPlatform.enumerationCalls, 0)
        XCTAssertEqual(deniedPermission.promptCount, 0)
    }

    func testStandaloneMoveLeavesHideStateAloneAndRerunDoesNotTouchMovedWindow() async throws {
        let defaults = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let source = display(index: 1, id: 1, uuid: sourceUUID, main: false,
                             bounds: CGRect(x: -100, y: 0, width: 100, height: 100))
        let destination = display(index: 2, id: 2, uuid: mainUUID, main: true,
                                  bounds: CGRect(x: 0, y: 0, width: 100, height: 100))
        let frame = CGRect(x: -90, y: 10, width: 40, height: 40)
        let window = axWindow(handle: UUID(), pid: 205, frame: frame)
        let platform = FakeWindowMovePlatform(processIDs: [205],
            enumerations: [205: .init(windows: [window], failure: nil)], windows: [window],
            cgWindows: [WindowMoveCGEvidence(processID: 205, frame: frame, layer: 0)])
        let permission = FakeWindowMovePermission(.granted)
        let mover = AccessibilityWindowMover(permission: permission, platform: platform,
            visibleFramesProvider: { [2: CGRect(x: 0, y: 0, width: 100, height: 100)] })
        var covers = 0
        var quiesces = 0
        let model = makeModel(defaults: defaults, records: [source, destination], permission: permission, mover: mover,
            cover: { covers += $0.count; return [] },
            quiesce: { completion in quiesces += 1; completion(true, nil) })
        let action = DisplayAction(name: "Move only", steps: [DisplayActionStep(
            target: DisplayIdentitySnapshot(source), effect: .moveWindows, moveWindows: MoveWindowsConfiguration())])
        try model.saveDisplayAction(action)
        let wasHidden = model.isBlackoutHidden(sourceUUID)
        let firstRun = await run(model, id: action.id)
        XCTAssertEqual(firstRun.outcome, .done)
        XCTAssertFalse(model.isBlackoutHidden(sourceUUID))
        XCTAssertEqual(covers, 0)
        XCTAssertEqual(quiesces, 0)
        XCTAssertEqual(platform.writes.count, 1)
        let secondRun = await run(model, id: action.id)
        XCTAssertEqual(secondRun.outcome, .noOp)
        XCTAssertEqual(secondRun.steps?.first?.windowMove?.reasons.first?.reason, .noWindows)
        XCTAssertEqual(platform.writes.count, 1, "the window is now off the source and remains untouched")
        XCTAssertEqual(model.isBlackoutHidden(sourceUUID), wasHidden)
        XCTAssertEqual(covers, 0)
        XCTAssertEqual(quiesces, 0)
    }

    func testVerifiedRemovedMoveSourceIsSafelySkippedWithoutExecutor() async throws {
        let defaults = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let source = display(index: 1, id: 1, uuid: sourceUUID, main: false)
        let destination = display(index: 2, id: 2, uuid: mainUUID, main: true)
        let removedIdentity = DisplayHandoffIdentity(DisplayHideIdentity(uuid: sourceUUID, displayID: 1,
            name: "Display 1", vendor: source.vendor, model: source.model, serial: source.serial))
        let mirrorIdentity = DisplayHandoffIdentity(DisplayHideIdentity(uuid: mainUUID, displayID: 2,
            name: "Display 2", vendor: destination.vendor, model: destination.model, serial: destination.serial))
        let removal = DisplayHandoffRemoval(id: "session", target: removedIdentity, source: mirrorIdentity,
            state: "mirrored", isUnresolved: true, canShow: true, reason: nil, topologyVerified: true)
        let handoff = DisplayHandoffStatus(state: .hidden, target: removedIdentity, source: mirrorIdentity,
            journalPath: "/tmp/window-move-test.json", canShow: true, mirrorTopologyVerified: true,
            removals: [removal])
        let mover = FakeWindowMoveExecutor(result: AppControlWindowMoveResult())
        let model = makeModel(defaults: defaults, records: [source, destination], mover: mover, handoffStatus: handoff)
        await settleQuiescence(model)
        let action = DisplayAction(name: "Move from removed display", steps: [DisplayActionStep(
            target: DisplayIdentitySnapshot(source), effect: .moveWindows, moveWindows: MoveWindowsConfiguration())])
        try model.saveDisplayAction(action)
        let response = await run(model, id: action.id)
        XCTAssertEqual(response.outcome, .noOp)
        XCTAssertEqual(response.steps?.first?.outcome, .skipped)
        XCTAssertTrue(mover.requests.isEmpty)
    }

    func testRecoveryBlocksMoveBeforeExecutorAndDoesNotPromptForPermission() async throws {
        let defaults = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let source = display(index: 1, id: 1, uuid: sourceUUID, main: false)
        let destination = display(index: 2, id: 2, uuid: mainUUID, main: true)
        let permission = FakeWindowMovePermission(.missing)
        let mover = FakeWindowMoveExecutor(result: AppControlWindowMoveResult())
        let model = makeModel(defaults: defaults, records: [source, destination], permission: permission,
                              mover: mover, handoffState: .recovery)
        await settleQuiescence(model)
        let action = DisplayAction(name: "Move during recovery", steps: [DisplayActionStep(
            target: DisplayIdentitySnapshot(source), effect: .moveWindows, moveWindows: MoveWindowsConfiguration())])
        try model.saveDisplayAction(action)
        let blocker = model.displayActionRunBlocker(for: action)
        XCTAssertTrue(blocker?.localizedCaseInsensitiveContains("recovery") == true, "Unexpected blocker: \(blocker ?? "none")")
        let response = await run(model, id: action.id)
        XCTAssertEqual(response.outcome, .recoveryNeeded)
        XCTAssertEqual(response.steps?.first?.windowMove?.refusalReason, .recoveryRequired)
        XCTAssertTrue(mover.requests.isEmpty)
        XCTAssertEqual(permission.promptCount, 0)
        model.requestWindowMoveAccessibilityPermission()
        XCTAssertEqual(permission.promptCount, 1, "only the explicit in-app action invokes the permission provider")
    }

    func testActionCompositionStableIDsTypedResultsAndStatusExposeMoveCounts() async throws {
        let defaults = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let source = display(index: 1, id: 1, uuid: sourceUUID, main: false,
                             bounds: CGRect(x: -100, y: 0, width: 100, height: 100))
        let destination = display(index: 2, id: 2, uuid: mainUUID, main: true,
                                  bounds: CGRect(x: 0, y: 0, width: 100, height: 100))
        let permission = FakeWindowMovePermission(.granted)
        let windowResult = AppControlWindowMoveResult(moved: 2, skipped: 1,
            reasons: [AppControlWindowMoveReasonCount(reason: .minimized, count: 1)])
        let mover = FakeWindowMoveExecutor(result: windowResult)
        var coverCalls = 0
        var quiesceCalls = 0
        let model = makeModel(defaults: defaults, records: [source, destination], permission: permission, mover: mover,
            cover: { ids in coverCalls += ids.count; return [] },
            quiesce: { completion in quiesceCalls += 1; completion(true, nil) })
        let hideStep = DisplayActionStep(target: DisplayIdentitySnapshot(source), effect: .blackOut)
        let moveStep = DisplayActionStep(target: DisplayIdentitySnapshot(source), effect: .moveWindows,
                                         moveWindows: MoveWindowsConfiguration())
        let action = DisplayAction(name: "Hide and Move", steps: [hideStep, moveStep])
        XCTAssertNil(model.displayActionValidation(for: action))
        XCTAssertNil(model.displayActionValidation(for: DisplayAction(name: "Move and Hide", steps: [moveStep, hideStep])))
        try model.saveDisplayAction(action)
        let saved = try XCTUnwrap(model.displayActions.actions.first)
        let stableStepID = saved.steps[1].id
        let runResult = await run(model, id: saved.id)
        XCTAssertEqual(runResult.outcome, .done)
        XCTAssertEqual(runResult.steps?.map(\.outcome), [.done, .done])
        XCTAssertEqual(runResult.steps?.last?.windowMove, windowResult)
        XCTAssertEqual(mover.requests.count, 1)
        XCTAssertEqual(mover.requests.first?.source.uuid, sourceUUID)
        XCTAssertEqual(quiesceCalls, 1, "only Hide needs helper quiescence; the standalone Move effect does not")
        XCTAssertEqual(coverCalls, 1)
        XCTAssertEqual(model.controlActionStatuses?.first?.steps.last?.windowMove, windowResult)
        let roundTrip = try JSONDecoder().decode(AppControlResponse.self, from: JSONEncoder().encode(runResult))
        XCTAssertEqual(roundTrip.steps?.last?.windowMove, windowResult)
        XCTAssertNotNil(model.displayActionResults[saved.id])
        var edited = saved
        edited.steps[1].moveWindows = MoveWindowsConfiguration(destination: .display(DisplayIdentityReference(destination)))
        try model.saveDisplayAction(edited, replacing: saved.id)
        let reread = try XCTUnwrap(model.displayActions.actions.first)
        XCTAssertEqual(reread.steps[1].id, stableStepID)
        XCTAssertNil(model.displayActionResults[saved.id], "destination edits invalidate cached results")

        let duplicateClass = DisplayAction(name: "Two moves", steps: [moveStep,
            DisplayActionStep(target: DisplayIdentitySnapshot(source), effect: .moveWindows, moveWindows: MoveWindowsConfiguration())])
        XCTAssertNotNil(model.displayActionValidation(for: duplicateClass))
        var duplicateStepIDs = duplicateClass
        duplicateStepIDs.steps[1].id = duplicateStepIDs.steps[0].id
        XCTAssertTrue(model.displayActionValidation(for: duplicateStepIDs)?.localizedCaseInsensitiveContains("stable identity") == true)
        let duplicateDisplayState = DisplayAction(name: "Hide and Show", steps: [hideStep,
            DisplayActionStep(target: DisplayIdentitySnapshot(source), effect: .show)])
        XCTAssertNotNil(model.displayActionValidation(for: duplicateDisplayState))
    }

    func testMovePermissionRefusalNeverPromptsAndPartialMoveStopsLaterSteps() async throws {
        let defaults = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let source = display(index: 1, id: 1, uuid: sourceUUID, main: false,
                             bounds: CGRect(x: -100, y: 0, width: 100, height: 100))
        let destination = display(index: 2, id: 2, uuid: mainUUID, main: true,
                                  bounds: CGRect(x: 0, y: 0, width: 100, height: 100))
        let permission = FakeWindowMovePermission(.missing)
        let mover = FakeWindowMoveExecutor(result: AppControlWindowMoveResult())
        let model = makeModel(defaults: defaults, records: [source, destination], permission: permission, mover: mover)
        let move = DisplayActionStep(target: DisplayIdentitySnapshot(source), effect: .moveWindows,
                                     moveWindows: MoveWindowsConfiguration())
        let action = DisplayAction(name: "Move only", steps: [move])
        try model.saveDisplayAction(action)
        let refused = await run(model, id: action.id)
        XCTAssertEqual(refused.outcome, .refused)
        XCTAssertEqual(refused.steps?.first?.windowMove?.refusalReason, .permissionMissing)
        XCTAssertEqual(permission.promptCount, 0)
        XCTAssertTrue(mover.requests.isEmpty)

        permission.value = .granted
        mover.result = AppControlWindowMoveResult(moved: 1, refusalReason: .permissionStale)
        mover.afterGate = { permission.value = .stale }
        var continuation = DisplayActionStep(target: DisplayIdentitySnapshot(destination), effect: .blackOut)
        continuation.id = UUID()
        let partialAction = DisplayAction(name: "Partial move", steps: [move, continuation])
        try model.saveDisplayAction(partialAction)
        let partial = await run(model, id: partialAction.id)
        XCTAssertEqual(partial.outcome, .partial)
        XCTAssertEqual(partial.steps?.map(\.outcome), [.partial, .notRun])
        XCTAssertEqual(partial.steps?.first?.windowMove?.moved, 1)
        XCTAssertEqual(partial.steps?.first?.windowMove?.failed, 0)
        XCTAssertEqual(partial.steps?.first?.windowMove?.refusalReason, .permissionStale)
        XCTAssertEqual(partial.outcome?.exitCode, 5)
    }

    func testMoveResultsClampAndBoundCountsAndOlderStepResultsDecode() throws {
        let entries = AppControlWindowMoveReason.allCases.prefix(6).enumerated().map { offset, reason in
            AppControlWindowMoveReasonCount(reason: reason, count: offset - 2)
        }
        let result = AppControlWindowMoveResult(moved: -1, skipped: 2, failed: 3, reasons: entries,
            appFailures: -1, appFailureReasons: entries)
        XCTAssertEqual(result.moved, 0)
        XCTAssertEqual(result.appFailures, 0)
        XCTAssertEqual(result.reasons.count, 4)
        XCTAssertEqual(result.reasons.first?.count, 0)
        XCTAssertEqual(result.appFailureReasons.count, 4)
        XCTAssertTrue(result.appFailureReasons.allSatisfy { $0.count >= 0 })

        let legacy = Data("""
        {"index":1,"targetUUID":"\(sourceUUID)","effect":"blackOut","outcome":"done","desktopSummary":"Hidden."}
        """.utf8)
        let decoded = try JSONDecoder().decode(AppControlActionStepResult.self, from: legacy)
        XCTAssertNil(decoded.windowMove)
    }

    func testV2MigrationAssignsStableStepUUIDAndV3CorruptEnvelopeDoesNotFallBack() throws {
        let defaults = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let identity = DisplayIdentityReference(uuid: sourceUUID, name: "Source", vendor: 1, model: 2, serial: 3)
        let actionID = UUID()
        let old = try JSONSerialization.data(withJSONObject: ["version": 2, "actions": [[
            "id": actionID.uuidString, "name": "Old", "steps": [[
                "target": ["uuid": identity.uuid, "name": identity.name!, "vendor": 1, "model": 2, "serial": 3],
                "effect": "blackOut"
            ]]
        ]]])
        defaults.set(old, forKey: AppModel.previousDisplayActionsKey)
        let migrated = makeModel(defaults: defaults)
        let first = try XCTUnwrap(migrated.displayActions.actions.first?.steps.first?.id)
        XCTAssertNotNil(defaults.data(forKey: AppModel.displayActionsKey))
        XCTAssertEqual(makeModel(defaults: defaults).displayActions.actions.first?.steps.first?.id, first)
        XCTAssertEqual(defaults.data(forKey: AppModel.previousDisplayActionsKey), old)

        let corrupt = Data("not-json".utf8)
        defaults.set(corrupt, forKey: AppModel.displayActionsKey)
        let preserved = makeModel(defaults: defaults)
        XCTAssertNotNil(preserved.displayActionStorageFailure)
        XCTAssertEqual(defaults.data(forKey: AppModel.displayActionsKey), corrupt)
        XCTAssertEqual(defaults.data(forKey: AppModel.previousDisplayActionsKey), old)
    }

    func testUnsupportedActionLargeIntegersSurviveSavingValidSibling() throws {
        let defaults = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let valid = DisplayAction(name: "Editable", steps: [DisplayActionStep(
            target: DisplayIdentityReference(uuid: sourceUUID, name: "Source", vendor: 1, model: 2, serial: 3),
            effect: .blackOut)])
        let validJSON = String(decoding: try JSONEncoder().encode(valid), as: UTF8.self)
        let unsupportedID = UUID()
        let original = Data("""
        {"version":3,"actions":[\(validJSON),{
          "id":"\(unsupportedID)","name":"Future Action",
          "steps":[{"id":"\(UUID())","effect":"futureEffect"}],
          "future":{"large":9007199254740993,"negative":-9007199254740993,
                    "minimum":-9223372036854775808,"maximum":18446744073709551615}
        }]}
        """.utf8)
        defaults.set(original, forKey: AppModel.displayActionsKey)
        let model = makeModel(defaults: defaults)
        XCTAssertEqual(model.displayActions.unsupportedActions.count, 1)
        let raw = try XCTUnwrap(model.displayActions.unsupportedActions.first?.raw)
        var edited = try XCTUnwrap(model.displayActions.actions.first)
        edited.name = "Renamed"
        try model.saveDisplayAction(edited, replacing: valid.id)
        let saved = try XCTUnwrap(defaults.data(forKey: AppModel.displayActionsKey))
        let savedText = String(decoding: saved, as: UTF8.self)
        for literal in ["9007199254740993", "-9007199254740993", "-9223372036854775808", "18446744073709551615"] {
            XCTAssertTrue(savedText.contains(literal), "Lost exact integer: \(literal)")
        }
        let reloaded = try JSONDecoder().decode(DisplayActionSet.self, from: saved)
        XCTAssertEqual(reloaded.actions.map(\.name), ["Renamed"])
        XCTAssertEqual(reloaded.unsupportedActions.first?.raw, raw)
        XCTAssertEqual(reloaded.unsupportedActions.first?.id, unsupportedID.uuidString)
    }

    private func request(source: DisplayRecord, destination: DisplayRecord,
                         coveredDisplayIDs: Set<UInt32> = []) -> WindowMovePlanRequest {
        WindowMovePlanRequest(source: DisplayIdentitySnapshot(source), configuration: MoveWindowsConfiguration(),
            displays: [source, destination], coveredDisplayIDs: coveredDisplayIDs,
            removedDisplayUUIDs: [], mirroredDisplayIDs: [])
    }

    private func axWindow(handle: UUID, pid: Int32, frame: CGRect, minimized: Bool = false,
                          fullscreen: Bool = false, canSetPosition: Bool = true, canSetSize: Bool = true) -> WindowMoveAXWindowState {
        WindowMoveAXWindowState(handle: handle, processID: pid, frame: frame, minimumSize: .zero,
            isMinimized: minimized, isFullscreen: fullscreen, canSetPosition: canSetPosition, canSetSize: canSetSize)
    }

    private func display(index: Int, id: UInt32, uuid: String, main: Bool, asleep: Bool = false,
                         active: Bool = true, online: Bool = true, bounds: CGRect = CGRect(x: 0, y: 0, width: 100, height: 100),
                         pixelWidth: Int = 100, pixelHeight: Int = 100) -> DisplayRecord {
        DisplayRecord(index: index, id: id, uuid: uuid, name: "Display \(index)", active: active, online: online,
            asleep: asleep, builtin: false, main: main, vendor: UInt32(index), model: UInt32(index + 10),
            serial: UInt32(index + 20), bounds: DisplayBounds(bounds), pixelWidth: pixelWidth, pixelHeight: pixelHeight)
    }

    private func makeModel(defaults: UserDefaults, records: [DisplayRecord] = [],
                           permission: FakeWindowMovePermission? = nil,
                           mover: WindowMoveExecuting? = nil,
                           handoffStatus: DisplayHandoffStatus? = nil,
                           handoffState: DisplayHandoffStatus.State = .none,
                           cover: @escaping @MainActor (Set<UInt32>) -> Set<UInt32> = { _ in [] },
                           quiesce: @escaping ProtectionQuiesce = { $0(true, nil) }) -> AppModel {
        AppModel(defaults: defaults, displayProvider: { records }, idleSecondsProvider: { nil },
            isDisplayMirrored: { _ in false }, inspectHandoff: {
                handoffStatus ?? DisplayHandoffStatus(state: handoffState, journalPath: "/tmp/window-move-test.json")
            },
            coverDisplays: cover, quiesceProtection: quiesce,
            windowMovePermission: permission ?? FakeWindowMovePermission(.granted),
            windowMoveExecutor: mover ?? FakeWindowMoveExecutor(result: AppControlWindowMoveResult()))
    }

    private func run(_ model: AppModel, id: UUID) async -> AppControlResponse {
        await withCheckedContinuation { continuation in model.runDisplayAction(id: id) { continuation.resume(returning: $0) } }
    }

    private func settleQuiescence(_ model: AppModel) async {
        for _ in 0..<20 where model.protectionQuiescencePending { await Task.yield() }
    }

    private func makeDefaults() throws -> UserDefaults {
        let name = suiteName
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defaults.removePersistentDomain(forName: name)
        defaults.set(true, forKey: "experimentalFeaturesEnabled")
        return defaults
    }

    private var suiteName: String { "panelctl-window-relocation-\(ProcessInfo.processInfo.processIdentifier)" }
}

private extension Result where Success == DisplayRecord, Failure == AppControlWindowMoveReason {
    func getFailureForTest() -> AppControlWindowMoveReason? { if case .failure(let reason) = self { reason } else { nil } }
    func getSuccessForTest() -> DisplayRecord? { if case .success(let display) = self { display } else { nil } }
}

@MainActor
private final class FakeWindowMovePermission: WindowMovePermissionProviding {
    var value: WindowMovePermissionState
    private(set) var promptCount = 0
    init(_ value: WindowMovePermissionState) { self.value = value }
    func state() -> WindowMovePermissionState { value }
    func requestFromExplicitUserInteraction() { promptCount += 1 }
}

@MainActor
private final class FakeWindowMoveExecutor: WindowMoveExecuting {
    var result: AppControlWindowMoveResult
    var afterGate: (() -> Void)?
    private(set) var requests: [WindowMovePlanRequest] = []
    init(result: AppControlWindowMoveResult) { self.result = result }
    func move(_ request: WindowMovePlanRequest,
              validateBeforeWrite: @escaping @MainActor @Sendable () -> WindowMoveGate) async -> AppControlWindowMoveResult {
        requests.append(request)
        guard validateBeforeWrite() == .allowed else {
            return AppControlWindowMoveResult(refusalReason: .topologyChanged)
        }
        afterGate?()
        return result
    }
}

private final class FakeWindowMovePlatform: WindowMovePlatform, @unchecked Sendable {
    let ids: [Int32]
    let enumerations: [Int32: WindowMoveApplicationEnumeration]
    var states: [UUID: WindowMoveAXWindowState]
    var cgWindows: [WindowMoveCGEvidence]
    let writeResults: [UUID: WindowMoveWriteResult]
    let readFailures: [UUID: AppControlWindowMoveReason]
    private(set) var timeouts: [TimeInterval] = []
    private(set) var budgets: [TimeInterval] = []
    private(set) var writes: [CGRect] = []
    private(set) var enumerationCalls = 0
    private(set) var workerThreads: [Bool] = []

    init(processIDs: [Int32], enumerations: [Int32: WindowMoveApplicationEnumeration], windows: [WindowMoveAXWindowState],
         cgWindows: [WindowMoveCGEvidence], writeResults: [UUID: WindowMoveWriteResult] = [:],
         readFailures: [UUID: AppControlWindowMoveReason] = [:]) {
        ids = processIDs
        self.enumerations = enumerations
        states = Dictionary(uniqueKeysWithValues: windows.map { ($0.handle, $0) })
        self.cgWindows = cgWindows
        self.writeResults = writeResults
        self.readFailures = readFailures
    }

    func processIDs() -> [Int32] { workerThreads.append(Thread.isMainThread); return ids }
    func visibleWindowSample() -> [WindowMoveCGEvidence]? { workerThreads.append(Thread.isMainThread); return cgWindows }
    func enumerate(processID: Int32, timeout: TimeInterval, budget: TimeInterval) -> WindowMoveApplicationEnumeration {
        workerThreads.append(Thread.isMainThread)
        timeouts.append(timeout); budgets.append(budget); enumerationCalls += 1
        guard let enumeration = enumerations[processID] else {
            return WindowMoveApplicationEnumeration(windows: [], failure: .enumerationFailed)
        }
        if let failure = enumeration.failure {
            return WindowMoveApplicationEnumeration(windows: enumeration.windows, failure: failure)
        }
        return WindowMoveApplicationEnumeration(windows: enumeration.windows.compactMap { states[$0.handle] }, failure: nil)
    }
    func readWindow(_ handle: UUID, processID: Int32, timeout: TimeInterval, budget: TimeInterval) -> Result<WindowMoveAXWindowState, AppControlWindowMoveReason> {
        workerThreads.append(Thread.isMainThread)
        timeouts.append(timeout); budgets.append(budget)
        if let reason = readFailures[handle] { return .failure(reason) }
        guard let state = states[handle] else { return .failure(.vanished) }
        return .success(state)
    }
    func setFrame(_ frame: CGRect, window: WindowMoveAXWindowState, timeout: TimeInterval, budget: TimeInterval,
                  validateBeforeWrite: @escaping @MainActor @Sendable () -> WindowMoveGate) -> WindowMoveWriteResult {
        workerThreads.append(Thread.isMainThread)
        timeouts.append(timeout); budgets.append(budget)
        let resized = frame.size != window.frame.size
        if resized {
            if case .refused(let reason) = waitForWindowMoveGate(validateBeforeWrite) { return .refused(reason) }
            let sizeOnly = CGRect(origin: window.frame.origin, size: frame.size)
            writes.append(sizeOnly)
            states[window.handle] = WindowMoveAXWindowState(handle: window.handle, processID: window.processID,
                frame: sizeOnly, minimumSize: window.minimumSize, isMinimized: false, isFullscreen: false,
                canSetPosition: window.canSetPosition, canSetSize: window.canSetSize)
            if case .refused(let reason) = waitForWindowMoveGate(validateBeforeWrite) { return .partiallyApplied(reason) }
        } else if case .refused(let reason) = waitForWindowMoveGate(validateBeforeWrite) {
            return .refused(reason)
        }
        writes.append(frame)
        let result = writeResults[window.handle] ?? .verified
        if result == .verified {
            states[window.handle] = WindowMoveAXWindowState(handle: window.handle, processID: window.processID,
                frame: frame, minimumSize: window.minimumSize, isMinimized: false, isFullscreen: false,
                canSetPosition: window.canSetPosition, canSetSize: window.canSetSize)
            if let index = cgWindows.firstIndex(where: { $0.processID == window.processID && $0.frame == window.frame ||
                (resized && $0.processID == window.processID && $0.frame.origin == window.frame.origin) }) {
                cgWindows[index] = WindowMoveCGEvidence(processID: window.processID, frame: frame, layer: 0)
            }
        }
        return result
    }
    func finishApplication(processID: Int32) {}
}
