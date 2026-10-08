import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import PanelCtlCore

struct WindowMovePlanRequest: @unchecked Sendable {
    let source: DisplayIdentitySnapshot
    let configuration: MoveWindowsConfiguration
    let displays: [DisplayRecord]
    let coveredDisplayIDs: Set<UInt32>
    let removedDisplayUUIDs: Set<String>
    let mirroredDisplayIDs: Set<UInt32>
}

enum WindowMoveGate: Equatable {
    case allowed
    case refused(AppControlWindowMoveReason)
}

struct WindowMoveWindowKey: Hashable, Sendable {
    let processID: Int32
    let accessibilityElementID: UUID
    let frame: CGRect

    init(processID: Int32, accessibilityElementID: UUID, frame: CGRect) {
        self.processID = processID
        self.accessibilityElementID = accessibilityElementID
        self.frame = frame
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.processID == rhs.processID && lhs.accessibilityElementID == rhs.accessibilityElementID
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(processID)
        hasher.combine(accessibilityElementID)
    }
}

struct WindowMoveObservedWindow: Sendable {
    let key: WindowMoveWindowKey
    let frame: CGRect
    let isOnSourceDisplay: Bool
}

struct WindowMoveEnforcementHooks: Sendable {
    let didObserve: @MainActor @Sendable ([WindowMoveObservedWindow]) -> Void
    let shouldAttempt: @MainActor @Sendable (WindowMoveWindowKey, CGRect) -> Bool
    let willWrite: @MainActor @Sendable (WindowMoveWindowKey, CGRect) async -> WindowMoveGate
    let didFinish: @MainActor @Sendable (WindowMoveWindowKey, CGRect, WindowMoveWriteResult) -> Void
}

@MainActor
protocol WindowMoveExecuting {
    func releaseWindowIdentities()

    func move(
        _ request: WindowMovePlanRequest,
        validateBeforeWrite: @escaping @MainActor @Sendable () async -> WindowMoveGate
    ) async -> AppControlWindowMoveResult

    func enforce(
        _ request: WindowMovePlanRequest,
        didObserve: @escaping @MainActor @Sendable ([WindowMoveObservedWindow]) -> Void,
        shouldAttempt: @escaping @MainActor @Sendable (WindowMoveWindowKey, CGRect) -> Bool,
        willWrite: @escaping @MainActor @Sendable (WindowMoveWindowKey, CGRect) async -> WindowMoveGate,
        didFinish: @escaping @MainActor @Sendable (WindowMoveWindowKey, CGRect, WindowMoveWriteResult) -> Void,
        validateBeforeWrite: @escaping @MainActor @Sendable () async -> WindowMoveGate
    ) async -> AppControlWindowMoveResult
}

@MainActor
extension WindowMoveExecuting {
    func releaseWindowIdentities() {}

    func enforce(
        _ request: WindowMovePlanRequest,
        didObserve: @escaping @MainActor @Sendable ([WindowMoveObservedWindow]) -> Void,
        shouldAttempt: @escaping @MainActor @Sendable (WindowMoveWindowKey, CGRect) -> Bool,
        willWrite: @escaping @MainActor @Sendable (WindowMoveWindowKey, CGRect) async -> WindowMoveGate,
        didFinish: @escaping @MainActor @Sendable (WindowMoveWindowKey, CGRect, WindowMoveWriteResult) -> Void,
        validateBeforeWrite: @escaping @MainActor @Sendable () async -> WindowMoveGate
    ) async -> AppControlWindowMoveResult {
        await move(request, validateBeforeWrite: validateBeforeWrite)
    }
}

@MainActor
protocol WindowMovePermissionProviding {
    func state() -> WindowMovePermissionState
    func requestFromExplicitUserInteraction()
}

enum WindowMovePermissionState: Equatable {
    case granted
    case missing
    case stale

    var reason: AppControlWindowMoveReason? {
        switch self {
        case .granted: return nil
        case .missing: return .permissionMissing
        case .stale: return .permissionStale
        }
    }
}

enum WindowMoveDisplaySelector {
    static func select(
        configuration: MoveWindowsConfiguration,
        sourceUUID: String,
        displays: [DisplayRecord],
        coveredDisplayIDs: Set<UInt32>,
        removedDisplayUUIDs: Set<String>,
        mirroredDisplayIDs: Set<UInt32>
    ) -> Result<DisplayRecord, AppControlWindowMoveReason> {
        let source = sourceUUID.lowercased()
        let removed = Set(removedDisplayUUIDs.map { $0.lowercased() })
        let eligible = displays.filter { display in
            guard let uuid = display.uuid, UUID(uuidString: uuid) != nil else { return false }
            let key = uuid.lowercased()
            return key != source && display.active && display.online && !display.asleep &&
                !coveredDisplayIDs.contains(display.id) && !removed.contains(key) &&
                !mirroredDisplayIDs.contains(display.id) && display.bounds.width > 0 && display.bounds.height > 0
        }
        switch configuration.destination {
        case .automatic:
            let selected = eligible.first(where: { $0.main }) ?? eligible.sorted(by: {
                ($0.uuid ?? "").lowercased() < ($1.uuid ?? "").lowercased()
            }).first
            guard let selected else { return .failure(.noDestination) }
            let identityMatches = displays.filter {
                $0.uuid?.caseInsensitiveCompare(selected.uuid ?? "") == .orderedSame
            }
            guard identityMatches.count == 1 else { return .failure(.identityAmbiguous) }
            return .success(selected)
        case .display(let reference):
            let matches = displays.filter { $0.uuid?.caseInsensitiveCompare(reference.uuid) == .orderedSame }
            guard matches.count <= 1 else { return .failure(.identityAmbiguous) }
            guard let selected = matches.first,
                  selected.vendor == reference.vendor, selected.model == reference.model,
                  selected.serial == reference.serial else { return .failure(.destinationUnavailable) }
            guard eligible.contains(where: { $0.id == selected.id }) else { return .failure(.destinationUnavailable) }
            return .success(selected)
        }
    }
}

struct WindowMoveAXWindowState {
    let handle: UUID
    let processID: Int32
    let frame: CGRect
    let minimumSize: CGSize
    let isMinimized: Bool
    let isFullscreen: Bool
    let canSetPosition: Bool
    let canSetSize: Bool
    let enumerationFailure: AppControlWindowMoveReason?

    init(handle: UUID, processID: Int32, frame: CGRect, minimumSize: CGSize, isMinimized: Bool,
         isFullscreen: Bool, canSetPosition: Bool, canSetSize: Bool,
         enumerationFailure: AppControlWindowMoveReason? = nil) {
        self.handle = handle
        self.processID = processID
        self.frame = frame
        self.minimumSize = minimumSize
        self.isMinimized = isMinimized
        self.isFullscreen = isFullscreen
        self.canSetPosition = canSetPosition
        self.canSetSize = canSetSize
        self.enumerationFailure = enumerationFailure
    }
}

struct WindowMoveApplicationEnumeration {
    let windows: [WindowMoveAXWindowState]
    let failure: AppControlWindowMoveReason?
}

enum WindowMoveWriteResult: Equatable {
    case verified
    case failed
    case unverified
    case vanished
    case timedOut
    case refused(AppControlWindowMoveReason)
    case partiallyApplied(AppControlWindowMoveReason)
}

protocol WindowMovePlatform: AnyObject, Sendable {
    func releaseWindowIdentities()
    func processIDs() -> [Int32]
    func visibleWindowSample() -> [WindowMoveCGEvidence]?
    func enumerate(processID: Int32, timeout: TimeInterval, budget: TimeInterval) -> WindowMoveApplicationEnumeration
    func readWindow(_ handle: UUID, processID: Int32, timeout: TimeInterval, budget: TimeInterval) -> Result<WindowMoveAXWindowState, AppControlWindowMoveReason>
    func setFrame(_ frame: CGRect, window: WindowMoveAXWindowState, timeout: TimeInterval, budget: TimeInterval,
                  validateBeforeWrite: @escaping @MainActor @Sendable () async -> WindowMoveGate) -> WindowMoveWriteResult
    func finishApplication(processID: Int32)
}

extension WindowMovePlatform {
    func releaseWindowIdentities() {}
}

private final class WindowMoveGateBox {
    var value: WindowMoveGate?
}

func waitForWindowMoveGate(
    _ validate: @escaping @MainActor @Sendable () -> WindowMoveGate
) -> WindowMoveGate {
    let semaphore = DispatchSemaphore(value: 0)
    let box = WindowMoveGateBox()
    Task { @MainActor in
        box.value = validate()
        semaphore.signal()
    }
    semaphore.wait()
    return box.value ?? .refused(.topologyChanged)
}

func waitForWindowMoveGateAsync(
    _ validate: @escaping @MainActor @Sendable () async -> WindowMoveGate
) -> WindowMoveGate {
    let semaphore = DispatchSemaphore(value: 0)
    let box = WindowMoveGateBox()
    Task { @MainActor in
        box.value = await validate()
        semaphore.signal()
    }
    semaphore.wait()
    return box.value ?? .refused(.topologyChanged)
}

func performWindowMoveCallback(_ action: @escaping @MainActor @Sendable () -> Void) {
    let semaphore = DispatchSemaphore(value: 0)
    Task { @MainActor in
        action()
        semaphore.signal()
    }
    semaphore.wait()
}

func waitForWindowMovePolicy(_ evaluate: @escaping @MainActor @Sendable () -> Bool) -> Bool {
    let semaphore = DispatchSemaphore(value: 0)
    let result = WindowMovePolicyBox()
    Task { @MainActor in
        result.allowed = evaluate()
        semaphore.signal()
    }
    semaphore.wait()
    return result.allowed ?? false
}

private final class WindowMovePolicyBox {
    var allowed: Bool?
}

enum WindowMoveGeometry {
    /// AppKit uses a bottom-left origin; AX and CG use the menu-bar display's top-left origin.
    static func quartzVisibleFrame(appKitFrame: CGRect, primaryDisplayHeight: CGFloat) -> CGRect? {
        guard valid(appKitFrame), primaryDisplayHeight.isFinite, primaryDisplayHeight > 0 else { return nil }
        return CGRect(x: appKitFrame.minX, y: primaryDisplayHeight - appKitFrame.maxY,
                      width: appKitFrame.width, height: appKitFrame.height)
    }

    static func attribution(of frame: CGRect, to displays: [DisplayRecord]) -> DisplayRecord? {
        guard valid(frame) else { return nil }
        let intersections = displays.compactMap { display -> (DisplayRecord, CGFloat)? in
            let bounds = CGRect(x: display.bounds.x, y: display.bounds.y,
                                width: display.bounds.width, height: display.bounds.height)
            guard valid(bounds) else { return nil }
            let intersection = frame.intersection(bounds)
            guard !intersection.isNull, intersection.width > 0, intersection.height > 0 else { return nil }
            return (display, intersection.width * intersection.height)
        }
        return intersections.sorted { lhs, rhs in
            if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
            return (lhs.0.uuid ?? "").lowercased() < (rhs.0.uuid ?? "").lowercased()
        }.first?.0
    }

    static func destinationFrame(
        window: CGRect,
        sourceBounds: CGRect,
        destinationVisibleFrame: CGRect,
        minimumSize: CGSize = .zero
    ) -> CGRect? {
        guard valid(window), valid(sourceBounds), valid(destinationVisibleFrame),
              minimumSize.width.isFinite, minimumSize.height.isFinite,
              minimumSize.width >= 0, minimumSize.height >= 0 else { return nil }
        let width = window.width > destinationVisibleFrame.width
            ? max(minimumSize.width, destinationVisibleFrame.width) : window.width
        let height = window.height > destinationVisibleFrame.height
            ? max(minimumSize.height, destinationVisibleFrame.height) : window.height
        let relativeCenterX = (window.midX - sourceBounds.minX) / sourceBounds.width
        let relativeCenterY = (window.midY - sourceBounds.minY) / sourceBounds.height
        let proposedX = destinationVisibleFrame.minX + relativeCenterX * destinationVisibleFrame.width - width / 2
        let proposedY = destinationVisibleFrame.minY + relativeCenterY * destinationVisibleFrame.height - height / 2
        let x = clampOrigin(proposedX, minimum: destinationVisibleFrame.minX,
                            maximum: destinationVisibleFrame.maxX - width, center: destinationVisibleFrame.midX - width / 2)
        let y = clampOrigin(proposedY, minimum: destinationVisibleFrame.minY,
                            maximum: destinationVisibleFrame.maxY - height, center: destinationVisibleFrame.midY - height / 2)
        return CGRect(x: x, y: y, width: width, height: height)
    }

    static func valid(_ rect: CGRect) -> Bool {
        rect.origin.x.isFinite && rect.origin.y.isFinite && rect.width.isFinite && rect.height.isFinite &&
            rect.width > 0 && rect.height > 0
    }

    private static func clampOrigin(_ value: CGFloat, minimum: CGFloat, maximum: CGFloat, center: CGFloat) -> CGFloat {
        maximum < minimum ? center : min(max(value, minimum), maximum)
    }
}

struct WindowMoveAXEvidence {
    let processID: Int32
    let frame: CGRect
}

struct WindowMoveCGEvidence {
    let processID: Int32
    let frame: CGRect
    let layer: Int
}

enum WindowMoveVisibilityMatch: Equatable {
    case matched(cgIndex: Int)
    case unverified
}

enum WindowMoveVisibilityMatcher {
    static func match(axWindows: [WindowMoveAXEvidence], cgWindows: [WindowMoveCGEvidence], tolerance: CGFloat = 1) -> [WindowMoveVisibilityMatch] {
        let normal = cgWindows.enumerated().filter { $0.element.layer == 0 }
        let candidates: [[Int]] = axWindows.map { ax in
            normal.compactMap { index, cg in
                cg.processID == ax.processID && framesMatch(ax.frame, cg.frame, tolerance: tolerance) ? index : nil
            }
        }
        var reverseCounts: [Int: Int] = [:]
        for choices in candidates {
            for index in choices { reverseCounts[index, default: 0] += 1 }
        }
        return candidates.map { choices in
            guard choices.count == 1, reverseCounts[choices[0]] == 1 else { return .unverified }
            return .matched(cgIndex: choices[0])
        }
    }

    private static func framesMatch(_ lhs: CGRect, _ rhs: CGRect, tolerance: CGFloat) -> Bool {
        guard WindowMoveGeometry.valid(lhs), WindowMoveGeometry.valid(rhs), tolerance.isFinite, tolerance >= 0 else { return false }
        return abs(lhs.minX - rhs.minX) <= tolerance && abs(lhs.minY - rhs.minY) <= tolerance &&
            abs(lhs.width - rhs.width) <= tolerance && abs(lhs.height - rhs.height) <= tolerance
    }
}

@MainActor
final class NoWindowMovePermission: WindowMovePermissionProviding {
    func state() -> WindowMovePermissionState { .missing }
    func requestFromExplicitUserInteraction() {}
}

@MainActor
final class SystemWindowMovePermission: WindowMovePermissionProviding {
    private let defaults: UserDefaults
    private let previouslyGrantedKey = "windowMoveAccessibilityPreviouslyGranted"

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func state() -> WindowMovePermissionState {
        if AXIsProcessTrusted() {
            defaults.set(true, forKey: previouslyGrantedKey)
            return .granted
        }
        return defaults.bool(forKey: previouslyGrantedKey) ? .stale : .missing
    }

    func requestFromExplicitUserInteraction() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }
}
