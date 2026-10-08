import CoreGraphics
import Foundation
import Darwin

struct DisplayOccupancyWindow: Equatable {
    let ownerPID: Int32?
    let frame: CGRect
}

struct DisplayOccupancySample: Equatable {
    let pointerLocation: CGPoint
    let windows: [DisplayOccupancyWindow]

    var windowFrames: [CGRect] { windows.map(\.frame) }

    init(pointerLocation: CGPoint, windowFrames: [CGRect]) {
        self.pointerLocation = pointerLocation
        self.windows = windowFrames.map { DisplayOccupancyWindow(ownerPID: nil, frame: $0) }
    }

    init(pointerLocation: CGPoint, windows: [DisplayOccupancyWindow]) {
        self.pointerLocation = pointerLocation
        self.windows = windows
    }
}

protocol DisplayOccupancySource {
    func sample() -> DisplayOccupancySample?
}

struct CoreGraphicsDisplayOccupancySource: DisplayOccupancySource {
    typealias PointerProvider = () -> CGPoint?
    typealias WindowProvider = () -> CFArray?

    private let pointerProvider: PointerProvider
    private let windowProvider: WindowProvider
    private let excludedPIDs: Set<pid_t>

    init(
        pointerProvider: @escaping PointerProvider = {
            CGEvent(source: nil)?.location
        },
        windowProvider: @escaping WindowProvider = {
            CGWindowListCopyWindowInfo(
                [.optionOnScreenOnly, .excludeDesktopElements],
                kCGNullWindowID
            )
        },
        processID: pid_t = ProcessInfo.processInfo.processIdentifier,
        parentProcessID: pid_t = getppid(),
        excludesParentProcess: Bool = ProcessInfo.processInfo.environment["PANELCTL_PARENT_PIPE"] == "1"
    ) {
        self.pointerProvider = pointerProvider
        self.windowProvider = windowProvider
        var excludedPIDs = Set([processID])
        if excludesParentProcess {
            excludedPIDs.insert(parentProcessID)
        }
        self.excludedPIDs = excludedPIDs
    }

    func sample() -> DisplayOccupancySample? {
        guard let pointerLocation = pointerProvider(),
              Self.isFinite(pointerLocation),
              let rawWindows = windowProvider() as? [[String: Any]] else {
            return nil
        }

        var windows: [DisplayOccupancyWindow] = []
        windows.reserveCapacity(rawWindows.count)
        for window in rawWindows {
            let ownerPID = (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value
            guard let layer = (window[kCGWindowLayer as String] as? NSNumber)?.intValue,
                  let alpha = (window[kCGWindowAlpha as String] as? NSNumber)?.doubleValue,
                  alpha.isFinite,
                  let boundsDictionary = window[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDictionary),
                  Self.isValid(bounds) else {
                return nil
            }
            guard layer == 0,
                  alpha > 0,
                  ownerPID.map({ !excludedPIDs.contains($0) }) ?? true else {
                continue
            }
            windows.append(DisplayOccupancyWindow(ownerPID: ownerPID, frame: bounds))
        }
        return DisplayOccupancySample(pointerLocation: pointerLocation, windows: windows)
    }

    private static func isFinite(_ point: CGPoint) -> Bool {
        point.x.isFinite && point.y.isFinite
    }

    private static func isValid(_ bounds: CGRect) -> Bool {
        bounds.origin.x.isFinite &&
            bounds.origin.y.isFinite &&
            bounds.width.isFinite &&
            bounds.height.isFinite &&
            bounds.width > 0 &&
            bounds.height > 0
    }
}

struct EmptyDisplayTarget: Equatable {
    let id: CGDirectDisplayID
    let bounds: CGRect
}

struct EmptyDisplayPolicy {
    static let gracePeriod: TimeInterval = 1

    private(set) var emptySince: [CGDirectDisplayID: TimeInterval] = [:]
    private(set) var requiresOccupiedBeforeRearming: Set<CGDirectDisplayID> = []
    // After uncertain writes or provenance overflow, geometry cannot establish
    // independent window activity. Only real pointer occupancy may rearm for
    // the remainder of this helper session; ordinary empty detection is unchanged.
    var windowRearmingIsUnverified = false

    mutating func reset() {
        emptySince.removeAll(keepingCapacity: true)
    }

    mutating func restoredCoveredDisplays(_ displayIDs: Set<CGDirectDisplayID>) {
        requiresOccupiedBeforeRearming.formUnion(displayIDs)
        for id in displayIDs { emptySince.removeValue(forKey: id) }
    }

    /// With the pointer on a display PanelCtl hides, nothing is covered:
    /// covering the others could leave no usable display.
    mutating func desiredDisplayIDs(
        targets: [EmptyDisplayTarget],
        activeDisplayBounds: [CGRect],
        hiddenDisplayBounds: [CGRect] = [],
        sample: DisplayOccupancySample?,
        uptime: TimeInterval,
        relocationSuppressedDisplayIDs: Set<CGDirectDisplayID> = [],
        currentlyCoveredDisplayIDs: Set<CGDirectDisplayID> = [],
        relocatedWindows: Set<BlackoutRelocatedWindow> = []
    ) -> Set<CGDirectDisplayID> {
        guard uptime.isFinite,
              let sample,
              Self.isFinite(sample.pointerLocation),
              sample.windows.allSatisfy({ Self.isValid($0.frame) }),
              !activeDisplayBounds.isEmpty,
              activeDisplayBounds.allSatisfy(Self.isValid),
              targets.allSatisfy({ Self.isValid($0.bounds) }),
              Set(targets.map(\.id)).count == targets.count,
              activeDisplayBounds.contains(where: { $0.contains(sample.pointerLocation) }),
              !hiddenDisplayBounds.contains(where: { $0.contains(sample.pointerLocation) }) else {
            reset()
            return []
        }

        let targetIDs = Set(targets.map(\.id))
        emptySince = emptySince.filter { targetIDs.contains($0.key) }
        requiresOccupiedBeforeRearming.formIntersection(targetIDs)
        var desired: Set<CGDirectDisplayID> = []
        for target in targets {
            let pointerOccupies = target.bounds.contains(sample.pointerLocation)
            if pointerOccupies {
                emptySince.removeValue(forKey: target.id)
                requiresOccupiedBeforeRearming.remove(target.id)
                continue
            }
            let windowOccupies = sample.windows.contains {
                Self.positiveAreaIntersection($0.frame, target.bounds)
            }
            let nonRelocatedWindowOccupies = sample.windows.contains { window in
                guard Self.positiveAreaIntersection(window.frame, target.bounds) else { return false }
                return !relocatedWindows.contains(where: { $0.matches(pid: window.ownerPID, frame: window.frame) })
            }
            if requiresOccupiedBeforeRearming.contains(target.id) {
                emptySince.removeValue(forKey: target.id)
                if nonRelocatedWindowOccupies && !windowRearmingIsUnverified &&
                    !relocationSuppressedDisplayIDs.contains(target.id) {
                    requiresOccupiedBeforeRearming.remove(target.id)
                }
                continue
            }
            if relocationSuppressedDisplayIDs.contains(target.id) {
                emptySince.removeValue(forKey: target.id)
                if currentlyCoveredDisplayIDs.contains(target.id) { desired.insert(target.id) }
                continue
            }
            if windowOccupies {
                emptySince.removeValue(forKey: target.id)
                continue
            }
            let beganAt = emptySince[target.id] ?? uptime
            emptySince[target.id] = beganAt
            if uptime - beganAt >= Self.gracePeriod {
                desired.insert(target.id)
            }
        }
        return desired
    }

    private static func positiveAreaIntersection(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        guard isValid(lhs), isValid(rhs) else { return false }
        let intersection = lhs.intersection(rhs)
        return !intersection.isNull && intersection.width > 0 && intersection.height > 0
    }

    private static func isFinite(_ point: CGPoint) -> Bool {
        point.x.isFinite && point.y.isFinite
    }

    private static func isValid(_ bounds: CGRect) -> Bool {
        bounds.origin.x.isFinite &&
            bounds.origin.y.isFinite &&
            bounds.width.isFinite &&
            bounds.height.isFinite &&
            bounds.width > 0 &&
            bounds.height > 0
    }
}
