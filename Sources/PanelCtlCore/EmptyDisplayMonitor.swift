import CoreGraphics
import Foundation
import Darwin

struct DisplayOccupancySample: Equatable {
    let pointerLocation: CGPoint
    let windowFrames: [CGRect]
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

        var windowFrames: [CGRect] = []
        windowFrames.reserveCapacity(rawWindows.count)
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
            windowFrames.append(bounds)
        }
        return DisplayOccupancySample(
            pointerLocation: pointerLocation,
            windowFrames: windowFrames
        )
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

    mutating func reset() {
        emptySince.removeAll(keepingCapacity: true)
    }

    mutating func desiredDisplayIDs(
        targets: [EmptyDisplayTarget],
        activeDisplayBounds: [CGRect],
        sample: DisplayOccupancySample?,
        uptime: TimeInterval
    ) -> Set<CGDirectDisplayID> {
        guard uptime.isFinite,
              let sample,
              Self.isFinite(sample.pointerLocation),
              sample.windowFrames.allSatisfy(Self.isValid),
              !activeDisplayBounds.isEmpty,
              activeDisplayBounds.allSatisfy(Self.isValid),
              targets.allSatisfy({ Self.isValid($0.bounds) }),
              Set(targets.map(\.id)).count == targets.count,
              activeDisplayBounds.contains(where: { $0.contains(sample.pointerLocation) }) else {
            reset()
            return []
        }

        let targetIDs = Set(targets.map(\.id))
        emptySince = emptySince.filter { targetIDs.contains($0.key) }
        var desired: Set<CGDirectDisplayID> = []
        for target in targets {
            let pointerOccupies = target.bounds.contains(sample.pointerLocation)
            let windowOccupies = sample.windowFrames.contains {
                Self.positiveAreaIntersection($0, target.bounds)
            }
            if pointerOccupies || windowOccupies {
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
