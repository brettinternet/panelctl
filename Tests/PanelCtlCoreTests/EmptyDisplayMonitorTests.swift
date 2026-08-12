import CoreGraphics
import XCTest
@testable import PanelCtlCore

final class EmptyDisplayMonitorTests: XCTestCase {
    private let left = EmptyDisplayTarget(
        id: 1,
        bounds: CGRect(x: -100, y: 0, width: 100, height: 100)
    )
    private let right = EmptyDisplayTarget(
        id: 2,
        bounds: CGRect(x: 0, y: 0, width: 100, height: 100)
    )

    func testRuntimeStatusSortsAndDeduplicatesMembership() throws {
        let status = BlackoutRuntimeStatus(
            state: .waiting,
            blackedOutDisplayIDs: [9, 2, 9]
        )
        XCTAssertEqual(status.blackedOutDisplayIDs, [2, 9])
        let decoded = try JSONDecoder().decode(
            BlackoutRuntimeStatus.self,
            from: Data(
                #"{"state":"waiting","blackedOutDisplayIDs":[9,2,9]}"#.utf8
            )
        )
        XCTAssertEqual(decoded, status)
    }

    func testIndependentGraceAndImmediateSampledRestoration() {
        var policy = EmptyDisplayPolicy()
        let targets = [left, right]
        let activeBounds = targets.map(\.bounds)

        XCTAssertEqual(policy.desiredDisplayIDs(
            targets: targets,
            activeDisplayBounds: activeBounds,
            sample: sample(pointer: CGPoint(x: -50, y: 50)),
            uptime: 10
        ), [])
        XCTAssertEqual(policy.desiredDisplayIDs(
            targets: targets,
            activeDisplayBounds: activeBounds,
            sample: sample(pointer: CGPoint(x: -50, y: 50)),
            uptime: 11
        ), [2])

        XCTAssertEqual(policy.desiredDisplayIDs(
            targets: targets,
            activeDisplayBounds: activeBounds,
            sample: sample(pointer: CGPoint(x: 50, y: 50)),
            uptime: 11.25
        ), [])
        XCTAssertEqual(policy.desiredDisplayIDs(
            targets: targets,
            activeDisplayBounds: activeBounds,
            sample: sample(pointer: CGPoint(x: 50, y: 50)),
            uptime: 12.25
        ), [1])
    }

    func testWindowIntersectionOccupiesEveryTouchedTarget() {
        var policy = EmptyDisplayPolicy()
        let targets = [left, right]
        let activeBounds = targets.map(\.bounds)
        let spanning = CGRect(x: -10, y: 20, width: 20, height: 20)

        _ = policy.desiredDisplayIDs(
            targets: targets,
            activeDisplayBounds: activeBounds,
            sample: sample(pointer: CGPoint(x: 150, y: 50), windows: [spanning]),
            uptime: 1
        )
        XCTAssertEqual(policy.desiredDisplayIDs(
            targets: targets,
            activeDisplayBounds: activeBounds + [CGRect(x: 100, y: 0, width: 100, height: 100)],
            sample: sample(pointer: CGPoint(x: 150, y: 50), windows: [spanning]),
            uptime: 2
        ), [])
    }

    func testEdgeOnlyContactDoesNotOccupyAndNegativeOriginsWork() {
        var policy = EmptyDisplayPolicy()
        let activeBounds = [left.bounds, right.bounds]
        let edgeOnly = CGRect(x: -120, y: 20, width: 20, height: 20)
        let pointerOnRight = CGPoint(x: 50, y: 50)

        _ = policy.desiredDisplayIDs(
            targets: [left],
            activeDisplayBounds: activeBounds,
            sample: sample(pointer: pointerOnRight, windows: [edgeOnly]),
            uptime: 3
        )
        XCTAssertEqual(policy.desiredDisplayIDs(
            targets: [left],
            activeDisplayBounds: activeBounds,
            sample: sample(pointer: pointerOnRight, windows: [edgeOnly]),
            uptime: 4
        ), [1])
    }

    func testPointerOnValidNonTargetDoesNotOccupyTarget() {
        var policy = EmptyDisplayPolicy()
        let nonTarget = CGRect(x: 100, y: 0, width: 100, height: 100)
        _ = policy.desiredDisplayIDs(
            targets: [right],
            activeDisplayBounds: [left.bounds, right.bounds, nonTarget],
            sample: sample(pointer: CGPoint(x: 150, y: 50)),
            uptime: 0
        )
        XCTAssertEqual(policy.desiredDisplayIDs(
            targets: [right],
            activeDisplayBounds: [left.bounds, right.bounds, nonTarget],
            sample: sample(pointer: CGPoint(x: 150, y: 50)),
            uptime: 1
        ), [2])
    }

    func testUnavailableSampleClearsDesiredCoverageAndRestartsGrace() {
        var policy = EmptyDisplayPolicy()
        let activeBounds = [right.bounds]
        _ = policy.desiredDisplayIDs(
            targets: [right],
            activeDisplayBounds: activeBounds,
            sample: sample(pointer: CGPoint(x: 50, y: 50)),
            uptime: 0
        )
        _ = policy.desiredDisplayIDs(
            targets: [right],
            activeDisplayBounds: activeBounds,
            sample: sample(pointer: CGPoint(x: 150, y: 50)),
            uptime: 0
        )
        XCTAssertEqual(policy.desiredDisplayIDs(
            targets: [right],
            activeDisplayBounds: activeBounds,
            sample: nil,
            uptime: 1
        ), [])
        XCTAssertEqual(policy.desiredDisplayIDs(
            targets: [right],
            activeDisplayBounds: activeBounds,
            sample: sample(pointer: CGPoint(x: 150, y: 50)),
            uptime: 2
        ), [])
    }

    func testPointerOutsideEveryActiveDisplayFailsOpen() {
        var policy = EmptyDisplayPolicy()
        _ = policy.desiredDisplayIDs(
            targets: [right],
            activeDisplayBounds: [right.bounds],
            sample: sample(pointer: CGPoint(x: 50, y: 50)),
            uptime: 0
        )
        XCTAssertEqual(policy.desiredDisplayIDs(
            targets: [right],
            activeDisplayBounds: [right.bounds],
            sample: sample(pointer: CGPoint(x: 500, y: 500)),
            uptime: 2
        ), [])
        XCTAssertTrue(policy.emptySince.isEmpty)
    }

    func testStaleTargetsAreDropped() {
        var policy = EmptyDisplayPolicy()
        let activeBounds = [
            left.bounds,
            right.bounds,
            CGRect(x: 100, y: 0, width: 100, height: 100)
        ]
        _ = policy.desiredDisplayIDs(
            targets: [left, right],
            activeDisplayBounds: activeBounds,
            sample: sample(pointer: CGPoint(x: 150, y: 50)),
            uptime: 0
        )
        _ = policy.desiredDisplayIDs(
            targets: [right],
            activeDisplayBounds: activeBounds,
            sample: sample(pointer: CGPoint(x: 150, y: 50)),
            uptime: 0.5
        )
        XCTAssertEqual(Set(policy.emptySince.keys), [2])
    }

    func testSourceFiltersTransparentNonzeroLayerAndPanelCtlWindows() {
        let windows: [[String: Any]] = [
            window(pid: 10, bounds: right.bounds),
            window(pid: 20, bounds: left.bounds, alpha: 0),
            window(pid: 30, bounds: left.bounds, layer: 1),
            window(pid: 40, bounds: left.bounds)
        ]
        let source = CoreGraphicsDisplayOccupancySource(
            pointerProvider: { CGPoint(x: 50, y: 50) },
            windowProvider: { windows as CFArray },
            processID: 10,
            parentProcessID: 40,
            excludesParentProcess: true
        )

        XCTAssertEqual(source.sample()?.windowFrames, [])
    }

    func testSourceCountsValidWindowWithUnclassifiableOwner() {
        let ownerless: [[String: Any]] = [[
            kCGWindowLayer as String: 0,
            kCGWindowAlpha as String: 1,
            kCGWindowBounds as String: CGRectCreateDictionaryRepresentation(right.bounds)
        ]]
        let source = CoreGraphicsDisplayOccupancySource(
            pointerProvider: { CGPoint(x: 50, y: 50) },
            windowProvider: { ownerless as CFArray }
        )

        XCTAssertEqual(source.sample()?.windowFrames, [right.bounds])
    }

    func testSourceRejectsMalformedRecordAndNilWindowList() {
        let malformed: [[String: Any]] = [[
            kCGWindowOwnerPID as String: 5,
            kCGWindowLayer as String: 0,
            kCGWindowAlpha as String: 1
        ]]
        XCTAssertNil(CoreGraphicsDisplayOccupancySource(
            pointerProvider: { CGPoint.zero },
            windowProvider: { malformed as CFArray }
        ).sample())
        XCTAssertNil(CoreGraphicsDisplayOccupancySource(
            pointerProvider: { CGPoint.zero },
            windowProvider: { nil }
        ).sample())
    }

    private func sample(pointer: CGPoint, windows: [CGRect] = []) -> DisplayOccupancySample {
        DisplayOccupancySample(pointerLocation: pointer, windowFrames: windows)
    }

    private func window(
        pid: Int32,
        bounds: CGRect,
        alpha: Double = 1,
        layer: Int = 0
    ) -> [String: Any] {
        [
            kCGWindowOwnerPID as String: NSNumber(value: pid),
            kCGWindowLayer as String: NSNumber(value: layer),
            kCGWindowAlpha as String: NSNumber(value: alpha),
            kCGWindowBounds as String: CGRectCreateDictionaryRepresentation(bounds)
        ]
    }
}
