import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import PanelCtlCore

final class AccessibilityWindowMover: WindowMoveExecuting {
    private let permission: WindowMovePermissionProviding
    private let platform: WindowMovePlatform
    private let visibleFramesProvider: @MainActor () -> [UInt32: CGRect]
    private let worker = DispatchQueue(label: "com.brettinternet.panelctl.window-move", qos: .userInitiated)
    nonisolated private static let elementTimeout: TimeInterval = 0.25
    nonisolated private static let appBudget: TimeInterval = 1

    @MainActor
    init(permission: WindowMovePermissionProviding, platform: WindowMovePlatform = SystemWindowMovePlatform(),
         visibleFramesProvider: @escaping @MainActor () -> [UInt32: CGRect] = AccessibilityWindowMover.systemVisibleFrames) {
        self.permission = permission
        self.platform = platform
        self.visibleFramesProvider = visibleFramesProvider
    }

    @MainActor
    func move(
        _ request: WindowMovePlanRequest,
        validateBeforeWrite: @escaping @MainActor @Sendable () -> WindowMoveGate
    ) async -> AppControlWindowMoveResult {
        let permissionState = permission.state()
        guard permissionState == .granted else {
            return AppControlWindowMoveResult(refusalReason: permissionState.reason)
        }
        let visibleFrames = visibleFramesProvider()
        return await withCheckedContinuation { continuation in
            let platform = self.platform
            worker.async {
                let result = Self.perform(request, platform: platform, visibleFrames: visibleFrames,
                                          validateBeforeWrite: validateBeforeWrite)
                continuation.resume(returning: result)
            }
        }
    }

    nonisolated private static func perform(
        _ request: WindowMovePlanRequest,
        platform: WindowMovePlatform,
        visibleFrames: [UInt32: CGRect],
        validateBeforeWrite: @escaping @MainActor @Sendable () -> WindowMoveGate
    ) -> AppControlWindowMoveResult {
        var windowReasons: [AppControlWindowMoveReason: Int] = [:]
        var appReasons: [AppControlWindowMoveReason: Int] = [:]
        var moved = 0
        var skipped = 0
        var failed = 0
        var appFailures = 0
        var refusal: AppControlWindowMoveReason?
        var sourceWindowCount = 0
        let displays = request.displays
        let sourceMatches = displays.filter { $0.uuid?.caseInsensitiveCompare(request.source.uuid) == .orderedSame }
        guard sourceMatches.count == 1, let source = sourceMatches.first else {
            return AppControlWindowMoveResult(refusalReason: sourceMatches.isEmpty ? .sourceUnavailable : .identityAmbiguous)
        }
        guard source.vendor == request.source.vendor, source.model == request.source.model,
              source.serial == request.source.serial, source.active, source.online, !source.asleep else {
            return AppControlWindowMoveResult(refusalReason: .sourceUnavailable)
        }
        let selection = WindowMoveDisplaySelector.select(
            configuration: request.configuration, sourceUUID: request.source.uuid,
            displays: displays, coveredDisplayIDs: request.coveredDisplayIDs,
            removedDisplayUUIDs: request.removedDisplayUUIDs,
            mirroredDisplayIDs: request.mirroredDisplayIDs
        )
        let destination: DisplayRecord
        switch selection {
        case .success(let display): destination = display
        case .failure(let reason): return AppControlWindowMoveResult(refusalReason: reason)
        }
        let sourceBounds = CGRect(x: source.bounds.x, y: source.bounds.y,
                                  width: source.bounds.width, height: source.bounds.height)
        guard let visibleFrame = visibleFrames[destination.id] else {
            return AppControlWindowMoveResult(refusalReason: .destinationUnavailable)
        }
        guard platform.visibleWindowSample() != nil else {
            return AppControlWindowMoveResult(refusalReason: .visibilityUnverified)
        }

        for processID in platform.processIDs() {
            let appStarted = ProcessInfo.processInfo.systemUptime
            let enumeration = platform.enumerate(
                processID: processID, timeout: elementTimeout, budget: appBudget
            )
            if let failure = enumeration.failure {
                appFailures += 1
                appReasons[failure, default: 0] += 1
                platform.finishApplication(processID: processID)
                continue
            }
            let windows = enumeration.windows
            let initialMatches = visibilityMatches(windows: windows, platform: platform)
            var stopApplication = false
            windowLoop: for (index, window) in windows.enumerated() {
                if let reason = window.enumerationFailure {
                    skipped += 1
                    windowReasons[reason, default: 0] += 1
                    continue
                }
                guard let attributed = WindowMoveGeometry.attribution(of: window.frame, to: displays) else {
                    skipped += 1
                    windowReasons[.unattributed, default: 0] += 1
                    continue
                }
                guard attributed.id == source.id else { continue }
                sourceWindowCount += 1
                if window.isFullscreen || fillsDisplayBounds(window.frame, displays: displays) {
                    skipped += 1
                    windowReasons[.fullscreen, default: 0] += 1
                    continue
                }
                if window.isMinimized {
                    skipped += 1
                    windowReasons[.minimized, default: 0] += 1
                    continue
                }
                guard window.canSetPosition else {
                    skipped += 1
                    windowReasons[.nonmovable, default: 0] += 1
                    continue
                }
                guard case .matched = initialMatches[index] else {
                    skipped += 1
                    windowReasons[.visibilityUnverified, default: 0] += 1
                    continue
                }
                if ProcessInfo.processInfo.systemUptime - appStarted >= appBudget {
                    appFailures += 1
                    appReasons[.appTimeout, default: 0] += 1
                    stopApplication = true
                    break
                }
                let refreshed: WindowMoveAXWindowState
                switch platform.readWindow(window.handle, processID: processID,
                                           timeout: elementTimeout, budget: remainingBudget(since: appStarted)) {
                case .success(let state): refreshed = state
                case .failure(let reason):
                    if reason == .appTimeout {
                        appFailures += 1
                        appReasons[.appTimeout, default: 0] += 1
                        stopApplication = true
                    } else {
                        skipped += 1
                        windowReasons[reason, default: 0] += 1
                    }
                    if stopApplication { break windowLoop }
                    continue
                }
                guard let currentSource = WindowMoveGeometry.attribution(of: refreshed.frame, to: displays) else {
                    skipped += 1
                    windowReasons[.unattributed, default: 0] += 1
                    continue
                }
                guard currentSource.id == source.id else { continue }
                guard let freshCG = platform.visibleWindowSample() else {
                    refusal = .visibilityUnverified
                    break
                }
                let freshMatches = WindowMoveVisibilityMatcher.match(
                    axWindows: windows.enumerated().map { offset, item in
                        WindowMoveAXEvidence(processID: item.processID,
                            frame: offset == index ? refreshed.frame : item.frame)
                    },
                    cgWindows: freshCG
                )
                guard case .matched = freshMatches[index] else {
                    skipped += 1
                    windowReasons[.visibilityUnverified, default: 0] += 1
                    continue
                }
                if refreshed.isFullscreen || fillsDisplayBounds(refreshed.frame, displays: displays) {
                    skipped += 1
                    windowReasons[.fullscreen, default: 0] += 1
                    continue
                }
                if refreshed.isMinimized {
                    skipped += 1
                    windowReasons[.minimized, default: 0] += 1
                    continue
                }
                guard refreshed.canSetPosition else {
                    skipped += 1
                    windowReasons[.nonmovable, default: 0] += 1
                    continue
                }
                let targetFrame = WindowMoveGeometry.destinationFrame(
                    window: refreshed.frame, sourceBounds: sourceBounds,
                    destinationVisibleFrame: visibleFrame,
                    minimumSize: refreshed.canSetSize ? refreshed.minimumSize : .zero
                )
                guard let targetFrame else {
                    skipped += 1
                    windowReasons[.unattributed, default: 0] += 1
                    continue
                }
                if targetFrame.size != refreshed.frame.size && !refreshed.canSetSize {
                    skipped += 1
                    windowReasons[.nonmovable, default: 0] += 1
                    continue
                }
                switch platform.setFrame(targetFrame, window: refreshed, timeout: elementTimeout,
                                         budget: remainingBudget(since: appStarted),
                                         validateBeforeWrite: validateBeforeWrite) {
                case .verified:
                    moved += 1
                case .failed:
                    failed += 1
                    windowReasons[.moveFailed, default: 0] += 1
                case .unverified:
                    failed += 1
                    windowReasons[.moveUnverified, default: 0] += 1
                case .vanished:
                    skipped += 1
                    windowReasons[.vanished, default: 0] += 1
                case .timedOut:
                    failed += 1
                    windowReasons[.moveUnverified, default: 0] += 1
                    appFailures += 1
                    appReasons[.appTimeout, default: 0] += 1
                    stopApplication = true
                case .refused(let reason):
                    refusal = reason
                case .partiallyApplied(let reason):
                    failed += 1
                    windowReasons[.moveUnverified, default: 0] += 1
                    refusal = reason
                }
                if stopApplication || refusal != nil { break }
            }
            platform.finishApplication(processID: processID)
            if refusal != nil { break }
        }
        if sourceWindowCount == 0 && appFailures == 0 && refusal == nil && windowReasons.isEmpty {
            windowReasons[.noWindows, default: 0] = 0
        }
        return AppControlWindowMoveResult(
            moved: moved, skipped: skipped, failed: failed,
            reasons: windowReasons.sorted { $0.key.rawValue < $1.key.rawValue }.map {
                AppControlWindowMoveReasonCount(reason: $0.key, count: $0.value)
            }, appFailures: appFailures,
            appFailureReasons: appReasons.sorted { $0.key.rawValue < $1.key.rawValue }.map {
                AppControlWindowMoveReasonCount(reason: $0.key, count: $0.value)
            }, refusalReason: refusal
        )
    }

    nonisolated private static func fillsDisplayBounds(_ frame: CGRect, displays: [DisplayRecord]) -> Bool {
        displays.contains { display in
            let bounds = CGRect(x: display.bounds.x, y: display.bounds.y,
                                width: display.bounds.width, height: display.bounds.height)
            return abs(frame.minX - bounds.minX) <= 1 && abs(frame.minY - bounds.minY) <= 1 &&
                abs(frame.width - bounds.width) <= 1 && abs(frame.height - bounds.height) <= 1
        }
    }

    nonisolated private static func visibilityMatches(
        windows: [WindowMoveAXWindowState], platform: WindowMovePlatform
    ) -> [WindowMoveVisibilityMatch] {
        guard let sample = platform.visibleWindowSample() else {
            return Array(repeating: .unverified, count: windows.count)
        }
        return WindowMoveVisibilityMatcher.match(
            axWindows: windows.map { WindowMoveAXEvidence(processID: $0.processID, frame: $0.frame) },
            cgWindows: sample
        )
    }

    nonisolated private static func remainingBudget(since start: TimeInterval) -> TimeInterval {
        max(0, appBudget - (ProcessInfo.processInfo.systemUptime - start))
    }

    @MainActor
    private static func systemVisibleFrames() -> [UInt32: CGRect] {
        let primaryHeight = CGDisplayBounds(CGMainDisplayID()).height
        return Dictionary(uniqueKeysWithValues: NSScreen.screens.compactMap { screen -> (UInt32, CGRect)? in
            guard let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value,
                  let frame = WindowMoveGeometry.quartzVisibleFrame(
                    appKitFrame: screen.visibleFrame, primaryDisplayHeight: primaryHeight
                  ) else { return nil }
            return (id, frame)
        })
    }
}

final class SystemWindowMovePlatform: WindowMovePlatform, @unchecked Sendable {
    private var elements: [UUID: AXUIElement] = [:]
    private var handlesByProcess: [Int32: Set<UUID>] = [:]
    private var appElements: [Int32: AXUIElement] = [:]
    private var appStartedAt: [Int32: TimeInterval] = [:]
    private let appBudget: TimeInterval = 1
    private let excludedBundleIdentifiers: Set<String> = [
        "com.apple.dock", "com.apple.systemuiserver", "com.apple.controlcenter",
        "com.apple.notificationcenterui", "com.apple.WindowManager", "com.apple.loginwindow",
        "com.brettinternet.panelctl.cli"
    ]

    func processIDs() -> [Int32] {
        NSWorkspace.shared.runningApplications.compactMap { application in
            guard application.activationPolicy == .regular,
                  application.processIdentifier != ProcessInfo.processInfo.processIdentifier,
                  !excludedBundleIdentifiers.contains(application.bundleIdentifier ?? "") else { return nil }
            return application.processIdentifier
        }
    }

    func visibleWindowSample() -> [WindowMoveCGEvidence]? {
        guard let rows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return nil }
        var result: [WindowMoveCGEvidence] = []
        for row in rows {
            guard let pid = (row[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                  let layer = (row[kCGWindowLayer as String] as? NSNumber)?.intValue,
                  let dictionary = row[kCGWindowBounds as String] as? NSDictionary else { return nil }
            var frame = CGRect.zero
            guard CGRectMakeWithDictionaryRepresentation(dictionary, &frame), WindowMoveGeometry.valid(frame) else { return nil }
            result.append(WindowMoveCGEvidence(processID: pid, frame: frame, layer: layer))
        }
        return result
    }

    func enumerate(processID: Int32, timeout: TimeInterval, budget: TimeInterval) -> WindowMoveApplicationEnumeration {
        let app = AXUIElementCreateApplication(processID)
        appElements[processID] = app
        appStartedAt[processID] = ProcessInfo.processInfo.systemUptime
        guard budget > 0, setTimeout(timeout, on: app, processID: processID) else {
            return WindowMoveApplicationEnumeration(windows: [], failure: .appTimeout)
        }
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value)
        guard result == .success else {
            return WindowMoveApplicationEnumeration(windows: [], failure: result == .cannotComplete ? .appTimeout : .enumerationFailed)
        }
        guard let children = value as? [AXUIElement] else {
            return WindowMoveApplicationEnumeration(windows: [], failure: .enumerationFailed)
        }
        var windows: [WindowMoveAXWindowState] = []
        for element in children {
            guard remainingBudget(processID) > 0 else {
                return WindowMoveApplicationEnumeration(windows: windows, failure: .appTimeout)
            }
            guard setTimeout(timeout, on: element, processID: processID) else {
                return WindowMoveApplicationEnumeration(windows: windows, failure: .appTimeout)
            }
            let handle = UUID()
            switch readFrame(element, processID: processID, timeout: timeout) {
            case .failure(.appTimeout):
                return WindowMoveApplicationEnumeration(windows: windows, failure: .appTimeout)
            case .failure(let reason):
                windows.append(unavailableWindow(handle, processID: processID, reason: reason))
                continue
            case .success(let frame):
                guard WindowMoveGeometry.valid(frame) else {
                    windows.append(unavailableWindow(handle, processID: processID, reason: .unattributed))
                    continue
                }
                elements[handle] = element
                handlesByProcess[processID, default: []].insert(handle)
                let minimized: Bool
                switch readBool(element, attribute: kAXMinimizedAttribute, processID: processID, timeout: timeout) {
                case .success(let value): minimized = value
                case .failure(.appTimeout):
                    return WindowMoveApplicationEnumeration(windows: windows, failure: .appTimeout)
                case .failure(let reason):
                    windows.append(unavailableWindow(handle, processID: processID, reason: reason))
                    continue
                }
                var positionSettable = DarwinBoolean(false)
                guard setTimeout(timeout, on: element, processID: processID) else {
                    return WindowMoveApplicationEnumeration(windows: windows, failure: .appTimeout)
                }
                let positionResult = AXUIElementIsAttributeSettable(element, kAXPositionAttribute as CFString, &positionSettable)
                if positionResult == .cannotComplete {
                    return WindowMoveApplicationEnumeration(windows: windows, failure: .appTimeout)
                }
                var sizeSettable = DarwinBoolean(false)
                guard setTimeout(timeout, on: element, processID: processID) else {
                    return WindowMoveApplicationEnumeration(windows: windows, failure: .appTimeout)
                }
                let sizeResult = AXUIElementIsAttributeSettable(element, kAXSizeAttribute as CFString, &sizeSettable)
                if sizeResult == .cannotComplete {
                    return WindowMoveApplicationEnumeration(windows: windows, failure: .appTimeout)
                }
                windows.append(WindowMoveAXWindowState(
                    handle: handle, processID: processID, frame: frame, minimumSize: .zero,
                    isMinimized: minimized, isFullscreen: false,
                    canSetPosition: positionResult == .success && positionSettable.boolValue,
                    canSetSize: sizeResult == .success && sizeSettable.boolValue
                ))
            }
        }
        return WindowMoveApplicationEnumeration(windows: windows, failure: nil)
    }

    func readWindow(_ handle: UUID, processID: Int32, timeout: TimeInterval, budget: TimeInterval) -> Result<WindowMoveAXWindowState, AppControlWindowMoveReason> {
        guard budget > 0, remainingBudget(processID) > 0, let element = elements[handle] else {
            return .failure(remainingBudget(processID) <= 0 ? .appTimeout : .vanished)
        }
        let frame: CGRect
        switch readFrame(element, processID: processID, timeout: timeout) {
        case .failure(let reason): return .failure(reason)
        case .success(let value): frame = value
        }
        let minimized: Bool
        switch readBool(element, attribute: kAXMinimizedAttribute, processID: processID, timeout: timeout) {
        case .failure(let reason): return .failure(reason)
        case .success(let value): minimized = value
        }
        var positionSettable = DarwinBoolean(false)
        guard setTimeout(timeout, on: element, processID: processID) else { return .failure(.appTimeout) }
        let positionResult = AXUIElementIsAttributeSettable(element, kAXPositionAttribute as CFString, &positionSettable)
        if positionResult == .cannotComplete { return .failure(.appTimeout) }
        var sizeSettable = DarwinBoolean(false)
        guard setTimeout(timeout, on: element, processID: processID) else { return .failure(.appTimeout) }
        let sizeResult = AXUIElementIsAttributeSettable(element, kAXSizeAttribute as CFString, &sizeSettable)
        if sizeResult == .cannotComplete { return .failure(.appTimeout) }
        return .success(WindowMoveAXWindowState(
            handle: handle, processID: processID, frame: frame, minimumSize: .zero,
            isMinimized: minimized, isFullscreen: false,
            canSetPosition: positionResult == .success && positionSettable.boolValue,
            canSetSize: sizeResult == .success && sizeSettable.boolValue
        ))
    }

    func setFrame(_ frame: CGRect, window: WindowMoveAXWindowState, timeout: TimeInterval, budget: TimeInterval,
                  validateBeforeWrite: @escaping @MainActor @Sendable () -> WindowMoveGate) -> WindowMoveWriteResult {
        guard budget > 0, remainingBudget(window.processID) > 0, let element = elements[window.handle] else {
            return remainingBudget(window.processID) <= 0 ? .timedOut : .vanished
        }
        var sizeWasWritten = false
        if frame.size != window.frame.size {
            guard window.canSetSize else { return .failed }
            if case .refused(let reason) = waitForWindowMoveGate(validateBeforeWrite) { return .refused(reason) }
            guard setTimeout(timeout, on: element, processID: window.processID) else { return .timedOut }
            var size = frame.size
            guard let sizeValue = AXValueCreate(.cgSize, &size) else { return .failed }
            let result = AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, sizeValue)
            if result == .cannotComplete { return .timedOut }
            guard result == .success else { return .failed }
            sizeWasWritten = true
        }
        if case .refused(let reason) = waitForWindowMoveGate(validateBeforeWrite) {
            return sizeWasWritten ? .partiallyApplied(reason) : .refused(reason)
        }
        guard setTimeout(timeout, on: element, processID: window.processID) else { return .timedOut }
        var position = frame.origin
        guard let positionValue = AXValueCreate(.cgPoint, &position) else { return .failed }
        let result = AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, positionValue)
        if result == .cannotComplete { return .timedOut }
        guard result == .success else { return .failed }
        switch readFrame(element, processID: window.processID, timeout: timeout) {
        case .failure(.appTimeout): return .timedOut
        case .failure: return .unverified
        case .success(let observed):
            return abs(observed.minX - frame.minX) <= 1 && abs(observed.minY - frame.minY) <= 1 &&
                abs(observed.width - frame.width) <= 1 && abs(observed.height - frame.height) <= 1 ? .verified : .unverified
        }
    }

    func finishApplication(processID: Int32) {
        appElements[processID] = nil
        appStartedAt[processID] = nil
        // AX references are pass-scoped; retaining them would create a persistent window registry.
        for handle in handlesByProcess.removeValue(forKey: processID) ?? [] { elements[handle] = nil }
    }

    private func remainingBudget(_ processID: Int32) -> TimeInterval {
        guard let started = appStartedAt[processID] else { return 0 }
        return max(0, appBudget - (ProcessInfo.processInfo.systemUptime - started))
    }

    private func setTimeout(_ timeout: TimeInterval, on element: AXUIElement, processID: Int32) -> Bool {
        let remaining = remainingBudget(processID)
        guard remaining > 0 else { return false }
        return AXUIElementSetMessagingTimeout(element, Float(min(timeout, remaining))) == .success
    }

    private func unavailableWindow(_ handle: UUID, processID: Int32, reason: AppControlWindowMoveReason) -> WindowMoveAXWindowState {
        WindowMoveAXWindowState(handle: handle, processID: processID, frame: .zero, minimumSize: .zero,
            isMinimized: false, isFullscreen: false, canSetPosition: false, canSetSize: false,
            enumerationFailure: reason)
    }

    private func readFrame(_ element: AXUIElement, processID: Int32, timeout: TimeInterval) -> Result<CGRect, AppControlWindowMoveReason> {
        let position: CGPoint
        switch readPoint(element, attribute: kAXPositionAttribute, processID: processID, timeout: timeout) {
        case .failure(let reason): return .failure(reason)
        case .success(let value): position = value
        }
        let size: CGSize
        switch readSize(element, attribute: kAXSizeAttribute, processID: processID, timeout: timeout) {
        case .failure(let reason): return .failure(reason)
        case .success(let value): size = value
        }
        let frame = CGRect(origin: position, size: size)
        return WindowMoveGeometry.valid(frame) ? .success(frame) : .failure(.unattributed)
    }

    private func readPoint(_ element: AXUIElement, attribute: String, processID: Int32,
                           timeout: TimeInterval) -> Result<CGPoint, AppControlWindowMoveReason> {
        guard setTimeout(timeout, on: element, processID: processID) else { return .failure(.appTimeout) }
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard result == .success else { return .failure(result == .cannotComplete ? .appTimeout : .vanished) }
        guard let value, CFGetTypeID(value) == AXValueGetTypeID() else { return .failure(.visibilityUnverified) }
        var point = CGPoint.zero
        guard AXValueGetValue(value as! AXValue, .cgPoint, &point), point.x.isFinite, point.y.isFinite else {
            return .failure(.visibilityUnverified)
        }
        return .success(point)
    }

    private func readSize(_ element: AXUIElement, attribute: String, processID: Int32,
                          timeout: TimeInterval) -> Result<CGSize, AppControlWindowMoveReason> {
        guard setTimeout(timeout, on: element, processID: processID) else { return .failure(.appTimeout) }
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard result == .success else { return .failure(result == .cannotComplete ? .appTimeout : .vanished) }
        guard let value, CFGetTypeID(value) == AXValueGetTypeID() else { return .failure(.visibilityUnverified) }
        var size = CGSize.zero
        guard AXValueGetValue(value as! AXValue, .cgSize, &size), size.width.isFinite, size.height.isFinite,
              size.width > 0, size.height > 0 else { return .failure(.visibilityUnverified) }
        return .success(size)
    }

    private func readBool(_ element: AXUIElement, attribute: String, processID: Int32,
                          timeout: TimeInterval) -> Result<Bool, AppControlWindowMoveReason> {
        guard setTimeout(timeout, on: element, processID: processID) else { return .failure(.appTimeout) }
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard result == .success else { return .failure(result == .cannotComplete ? .appTimeout : .visibilityUnverified) }
        guard let bool = (value as? NSNumber)?.boolValue else { return .failure(.visibilityUnverified) }
        return .success(bool)
    }
}
