import Foundation
import AppKit
import CoreGraphics
import IOKit.pwr_mgt
import CoreMediaIO
import OSLog

private let shutdownLogger = Logger(
    subsystem: "com.brettinternet.panelctl",
    category: "shutdown"
)

public enum BlackoutError: Error, Equatable, CustomStringConvertible {
    case noScreens
    case unknownSelector(String)
    case nonDrawable(String)
    case mirroredDisplay(String)
    case allScreensSafety
    case invalidScreenFrame(String)
    case coverageMismatch(String)
    case topologyChanged
    case idleMonitoringUnavailable
    case caffeinateExited
    case watchRequiresStableUUID(String)
    case invalidOverlayOpacity
    case invalidHardwareBrightness
    case workingOverlayRequired
    case persistentDimming
    public var description: String {
        switch self {
        case .noScreens: return "no drawable screens are available (headless or no WindowServer context)"
        case .unknownSelector(let selector): return "unknown display selector: \(selector)"
        case .nonDrawable(let selector): return "display is not drawable: \(selector)"
        case .mirroredDisplay(let selector): return "refusing mirrored display target: \(selector)"
        case .allScreensSafety: return "refusing to black out every drawable screen without --all or a finite safety limit"
        case .invalidScreenFrame(let display): return "display has an invalid screen frame: \(display)"
        case .coverageMismatch(let display): return "refusing partial blackout because the window does not exactly cover display \(display)"
        case .topologyChanged: return "display topology changed before blackout could be installed"
        case .idleMonitoringUnavailable: return "combined-session idle monitoring is unavailable"
        case .caffeinateExited: return "caffeinate exited before blackout completed"
        case .watchRequiresStableUUID(let selector):
            return "--watch requires a display with a stable UUID: \(selector)"
        case .invalidOverlayOpacity:
            return "overlay opacity must be an integer from 1 through 100"
        case .invalidHardwareBrightness:
            return "hardware brightness must be an integer from 0 through 100"
        case .workingOverlayRequired:
            return "a partial or disabled overlay requires working mode"
        case .persistentDimming:
            return "refusing persistent blackout with --dim-to because DDC restore is not time-bounded"
    }
    }
}

public enum BlackoutRuntimeState: String, Codable, Equatable {
    case waiting
    case waitingForInput = "waiting_for_input"
    case waitingForPlayback = "waiting_for_playback"
    case blackedOut = "blacked_out"
    case sleeping
    case stopped
}

public struct BlackoutRuntimeStatus: Codable, Equatable {
    public let state: BlackoutRuntimeState
    public let blackedOutDisplayIDs: [CGDirectDisplayID]
    private enum CodingKeys: String, CodingKey {
        case state
        case blackedOutDisplayIDs
    }

    public init(
        state: BlackoutRuntimeState,
        blackedOutDisplayIDs: [CGDirectDisplayID]
    ) {
        self.state = state
        self.blackedOutDisplayIDs = Array(Set(blackedOutDisplayIDs)).sorted()
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            state: try values.decode(BlackoutRuntimeState.self, forKey: .state),
            blackedOutDisplayIDs: try values.decode(
                [CGDirectDisplayID].self,
                forKey: .blackedOutDisplayIDs
            )
        )
    }
}

public enum BlackoutControlCommand: String, Equatable, Sendable {
    case blackoutNow = "blackout-now"
    case restore
}

struct IdleSample: Equatable {
    let seconds: TimeInterval
    let lastInputUptime: TimeInterval

    func applyingSyntheticActivity(at activityUptime: TimeInterval) -> Self {
        let sampleUptime = lastInputUptime + seconds
        let effectiveInputUptime = max(lastInputUptime, activityUptime)
        return Self(
            seconds: max(0, sampleUptime - effectiveInputUptime),
            lastInputUptime: effectiveInputUptime
        )
    }
}

protocol IdleTimeSource {
    func secondsSinceLastInput() -> TimeInterval?
}

struct CombinedSessionIdleTimeSource: IdleTimeSource {
    func secondsSinceLastInput() -> TimeInterval? {
        guard let anyInput = CGEventType(rawValue: UInt32.max) else { return nil }
        return CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInput)
    }
}

/// Returns whether another process is actively preventing the display from
/// becoming idle (for example, while media playback is in progress).
/// Assertion API failures intentionally fail open so protection continues.
func playbackAssertionIsActive() -> Bool {
    var assertions: Unmanaged<CFDictionary>?
    guard IOPMCopyAssertionsByProcess(&assertions) == kIOReturnSuccess,
          let dictionary = assertions?.takeRetainedValue() as NSDictionary? else {
        return false
    }
    return hasExternalDisplaySleepAssertion(
        in: dictionary as? [AnyHashable: Any] ?? [:],
        excludingPID: ProcessInfo.processInfo.processIdentifier
    )
}

/// Returns whether any camera device is currently running. Reading the
/// CoreMediaIO device state does not open a capture session. Fail open when the
/// device list or an individual device cannot be queried.
func cameraCaptureIsActive() -> Bool {
    var devicesAddress = CMIOObjectPropertyAddress(
        mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices),
        mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
        mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
    )
    var devicesDataSize: UInt32 = 0
    guard CMIOObjectGetPropertyDataSize(
        CMIOObjectID(kCMIOObjectSystemObject),
        &devicesAddress,
        0,
        nil,
        &devicesDataSize
    ) == noErr else {
        return false
    }

    let deviceCount = Int(devicesDataSize) / MemoryLayout<CMIOObjectID>.size
    guard deviceCount > 0 else { return false }
    var deviceIDs = [CMIOObjectID](repeating: 0, count: deviceCount)
    var devicesDataUsed: UInt32 = 0
    let devicesStatus = deviceIDs.withUnsafeMutableBytes { buffer in
        CMIOObjectGetPropertyData(
            CMIOObjectID(kCMIOObjectSystemObject),
            &devicesAddress,
            0,
            nil,
            devicesDataSize,
            &devicesDataUsed,
            buffer.baseAddress!
        )
    }
    guard devicesStatus == noErr else { return false }

    let returnedDeviceCount = Int(devicesDataUsed) / MemoryLayout<CMIOObjectID>.size
    return deviceIDs.prefix(returnedDeviceCount).contains { deviceID in
        var runningAddress = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(
                kCMIODevicePropertyDeviceIsRunningSomewhere
            ),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
        )
        var isRunning: UInt32 = 0
        var runningDataUsed: UInt32 = 0
        let runningDataSize = UInt32(MemoryLayout<UInt32>.size)
        return CMIOObjectGetPropertyData(
            deviceID,
            &runningAddress,
            0,
            nil,
            runningDataSize,
            &runningDataUsed,
            &isRunning
        ) == noErr && isRunning != 0
    }
}

/// Interprets IOPMCopyAssertionsByProcess output while ignoring PanelCtl's own
/// native display assertion. Fail-open for unknown dictionary shapes.
func hasExternalDisplaySleepAssertion(
    in assertions: [AnyHashable: Any],
    excludingPID: Int32
) -> Bool {
    let expectedType = kIOPMAssertPreventUserIdleDisplaySleep as String
    for (rawPID, rawEntries) in assertions {
        guard let pid = (rawPID as? NSNumber)?.int32Value,
              pid != excludingPID,
              let entries = rawEntries as? [Any] else { continue }
        for rawEntry in entries {
            guard let entry = rawEntry as? [AnyHashable: Any],
                  let type = entry[kIOPMAssertionTypeKey as String] as? String,
                  type == expectedType else { continue }
            if (entry[kIOPMAssertionLevelKey as String] as? NSNumber)?.intValue ?? 0 > 0 {
                return true
            }
        }
    }
    return false
}

enum BlackoutLimitAction: Equatable {
    case none
    case finish
    case sleep
}

enum BlackoutInputAction: Equatable {
    case none
    case restore
    case resetLimit
}

/// The small, deterministic part of the watch lifecycle.  A suspension is
/// cleared only by its matching wake event; this matters when wake
/// notifications arrive in a different order than their sleep notifications.
enum BlackoutWatchSuspension: Hashable {
    case sessionInactive
    case systemSleeping
    case screensAsleep
}

enum BlackoutWatchReset: Equatable {
    case input
    case timeout
    case sleepAfter
    case suspension(BlackoutWatchSuspension)
    case topologyChanged
}

struct BlackoutWatchState: Equatable {
    private(set) var suspensions: Set<BlackoutWatchSuspension> = []
    private(set) var awaitingFreshInput = false
    private(set) var terminated = false
    private(set) var rearmInputBaseline: TimeInterval?

    mutating func reset(_ reset: BlackoutWatchReset, after inputBaseline: TimeInterval) {
        guard !terminated else { return }
        awaitingFreshInput = true
        rearmInputBaseline = inputBaseline
        if case .suspension(let reason) = reset {
            suspensions.insert(reason)
        }
    }

    mutating func resume(_ reason: BlackoutWatchSuspension, after inputBaseline: TimeInterval) {
        guard !terminated else { return }
        suspensions.remove(reason)
        awaitingFreshInput = true
        rearmInputBaseline = inputBaseline
    }

    mutating func terminate() {
        terminated = true
    }

    mutating func acceptManualActivity() {
        guard !terminated else { return }
        awaitingFreshInput = false
        rearmInputBaseline = nil
    }

    mutating func consumeFreshInput(_ sample: IdleSample, allowScreenWakeFallback: Bool) -> Bool {
        guard awaitingFreshInput, !terminated else { return false }
        guard let baseline = rearmInputBaseline,
              sample.lastInputUptime > baseline + 0.001 else {
            return false
        }
        if allowScreenWakeFallback {
            suspensions.remove(.screensAsleep)
        }
        guard suspensions.isEmpty else { return false }
        awaitingFreshInput = false
        rearmInputBaseline = nil
        return true
    }

    var mayBeginCycle: Bool {
        !terminated && suspensions.isEmpty && !awaitingFreshInput
    }
}

struct BlackoutScreenTarget: Equatable {
    let id: CGDirectDisplayID
    let uuid: String?
    let selector: String

    func resolvedID(in records: [DisplayRecord], watch: Bool) throws -> CGDirectDisplayID {
        guard watch else { return id }
        guard let uuid else { throw BlackoutError.watchRequiresStableUUID(selector) }
        guard let record = records.first(where: {
            $0.uuid?.caseInsensitiveCompare(uuid) == .orderedSame
        }) else {
            throw BlackoutError.topologyChanged
        }
        return record.id
    }
}

struct BlackoutPolicy {
    let idleAfter: TimeInterval?
    let timeout: TimeInterval?
    let sleepAfter: TimeInterval?
    let keepBlackoutOnInput: Bool
    let deferPlayback: Bool
    let deferCamera: Bool

    init(
        idleAfter: TimeInterval?,
        timeout: TimeInterval?,
        sleepAfter: TimeInterval?,
        keepBlackoutOnInput: Bool = false,
        deferPlayback: Bool = true,
        deferCamera: Bool = false
    ) {
        self.idleAfter = idleAfter
        self.timeout = timeout
        self.sleepAfter = sleepAfter
        self.keepBlackoutOnInput = keepBlackoutOnInput
        self.deferPlayback = deferPlayback
        self.deferCamera = deferCamera
    }

    func shouldBegin(idleSeconds: TimeInterval) -> Bool {
        idleAfter.map { idleSeconds >= $0 } ?? true
    }

    func shouldDeferForActivity(
        assertionActive: Bool,
        cameraActive: Bool,
        immediateBlackoutRequested: Bool
    ) -> Bool {
        idleAfter != nil &&
            ((deferPlayback && assertionActive) || (deferCamera && cameraActive)) &&
            !immediateBlackoutRequested
    }

    func hasNewInput(_ sample: IdleSample, after baselineUptime: TimeInterval) -> Bool {
        sample.lastInputUptime > baselineUptime + 0.001
    }

    func inputAction(
        for sample: IdleSample,
        after baselineUptime: TimeInterval,
        resetLimitOnInput: Bool
    ) -> BlackoutInputAction {
        guard hasNewInput(sample, after: baselineUptime) else { return .none }
        guard keepBlackoutOnInput else { return .restore }
        return resetLimitOnInput ? .resetLimit : .none
    }

    func limitAction(elapsed: TimeInterval) -> BlackoutLimitAction {
        if let timeout, elapsed >= timeout { return .finish }
        if let sleepAfter, elapsed >= sleepAfter { return .sleep }
        return .none
    }
}

public final class BlackoutController {
    enum WorkspaceEvent: Equatable {
        case reset(BlackoutWatchReset)
        case resume(BlackoutWatchSuspension)
    }
    private struct EmptyDisplayContext {
        let screensByID: [CGDirectDisplayID: NSScreen]
        let targets: [EmptyDisplayTarget]
        let activeDisplayBounds: [CGRect]
    }

    private static let manualBlackoutInputSettlingDuration: TimeInterval = 0.25

    private var windows: [CGDirectDisplayID: NSWindow] = [:]
    private var signalSources: [DispatchSourceSignal] = []
    private var screenObserver: NSObjectProtocol?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var assertion: CaffeinateAssertion?
    private var displayAssertion: CaffeinateAssertion?
    private var keepDisplaysAwake = false
    private var stopRequested = false
    private var intentionalDisplaySleep = false
    private var displayWakeObserved = false
    private var watchMode = false
    private var watchState = BlackoutWatchState()
    private var fullCycleActive = false
    private var runtimeState: BlackoutRuntimeState = .waiting
    private var lastStatus: BlackoutRuntimeStatus?
    private var blackoutEmptyDisplays = false
    private var emptyDisplayPolicy = EmptyDisplayPolicy()
    private var screenConfigurationGeneration: UInt64 = 0
    private var cachedEmptyDisplayContext: (
        generation: UInt64,
        context: EmptyDisplayContext
    )?
    private var emptyResolutionRetryAfter: TimeInterval = 0
    private var targets: [BlackoutScreenTarget] = []
    private var lastInputUptime: TimeInterval?
    private var immediateBlackoutRequested = false
    private var manualActivityUptime: TimeInterval?
    private var restoreGeneration: UInt64 = 0
    private var dimming: BlackoutDimming?
    private let occupancySource: DisplayOccupancySource
    private let idleSource: IdleTimeSource
    private let uptime: () -> TimeInterval
    private let playbackAssertionActive: () -> Bool
    private let cameraCaptureActive: () -> Bool
    private let statusHandler: ((BlackoutRuntimeStatus) -> Void)?

    public convenience init() {
        self.init(
            idleSource: CombinedSessionIdleTimeSource(),
            uptime: { ProcessInfo.processInfo.systemUptime },
            playbackAssertionActive: playbackAssertionIsActive,
            cameraCaptureActive: cameraCaptureIsActive,
            statusHandler: nil
        )
    }

    public convenience init(
        statusHandler: @escaping (BlackoutRuntimeStatus) -> Void
    ) {
        self.init(
            idleSource: CombinedSessionIdleTimeSource(),
            uptime: { ProcessInfo.processInfo.systemUptime },
            playbackAssertionActive: playbackAssertionIsActive,
            cameraCaptureActive: cameraCaptureIsActive,
            statusHandler: statusHandler
        )
    }

    init(
        idleSource: IdleTimeSource,
        uptime: @escaping () -> TimeInterval,
        playbackAssertionActive: @escaping () -> Bool = playbackAssertionIsActive,
        cameraCaptureActive: @escaping () -> Bool = cameraCaptureIsActive,
        occupancySource: DisplayOccupancySource = CoreGraphicsDisplayOccupancySource(),
        statusHandler: ((BlackoutRuntimeStatus) -> Void)? = nil
    ) {
        self.idleSource = idleSource
        self.uptime = uptime
        self.playbackAssertionActive = playbackAssertionActive
        self.cameraCaptureActive = cameraCaptureActive
        self.occupancySource = occupancySource
        self.statusHandler = statusHandler
    }

    public func run(options: BlackoutOptions) throws {
        try Self.validateOptions(options)
        watchMode = options.watch
        keepDisplaysAwake = options.keepDisplaysAwake
        blackoutEmptyDisplays = options.blackoutEmptyDisplays
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.finishLaunching()

        installSignals()
        installObservers()
        defer {
            stop()
            setRuntimeState(.stopped)
        }

        let screens = NSScreen.screens
        let drawableScreens = screens.filter { Self.isValidScreenFrame($0.frame) }
        guard !drawableScreens.isEmpty else { throw BlackoutError.noScreens }
        targets = try resolveTargets(options: options, screens: screens, drawableScreens: drawableScreens)
        if options.hardwareBrightnessPercent != nil {
            let dimming = BlackoutDimming()
            dimming.start()
            self.dimming = dimming
        }
        if options.caffeinate { assertion = try CaffeinateAssertion(kind: .system) }
        if options.keepDisplaysAwake { try ensureDisplayAssertion() }

        let policy = BlackoutPolicy(
            idleAfter: options.idleAfter,
            timeout: options.timeout,
            sleepAfter: options.sleepAfter,
            keepBlackoutOnInput: options.effectiveKeepBlackoutOnInput,
            deferPlayback: options.deferPlayback,
            deferCamera: options.deferCamera
        )
        if !watchMode {
            guard let activation = try waitUntilReady(policy: policy, options: options) else {
                return
            }
            if stopRequested { return }
            let selection = try resolveCurrentScreens(options: options)
            try beginFullCycle(
                on: selection.screens,
                mode: options.mode,
                overlayOpacityPercent: options.overlayOpacityPercent,
                hardwareBrightnessPercent: options.hardwareBrightnessPercent
            )
            try runBlackoutCycle(
                policy: policy,
                options: options,
                baseline: activation.sample,
                resetLimitOnInput: options.effectiveKeepBlackoutOnInput && !selection.coversAllDisplays,
                watch: false,
                restoreGeneration: restoreGeneration
            )
            return
        }

        while !stopRequested {
            resetCycleFlags()
            guard let activation = try waitUntilReady(policy: policy, options: options) else {
                return
            }
            if stopRequested { return }
            let cycleRestoreGeneration = restoreGeneration
            do {
                let selection = try resolveCurrentScreens(options: options)
                try beginFullCycle(
                    on: selection.screens,
                    mode: options.mode,
                    overlayOpacityPercent: options.overlayOpacityPercent,
                    hardwareBrightnessPercent: options.hardwareBrightnessPercent
                )
                let cycleBaseline: IdleSample
                if activation.forced {
                    immediateBlackoutRequested = false
                    // Suppress input generated by the manual command while
                    // the newly shown blackout settles on the main run loop.
                    cycleBaseline = try manualBlackoutInputBaseline()
                } else {
                    cycleBaseline = activation.sample
                }
                try runBlackoutCycle(
                    policy: policy,
                    options: options,
                    baseline: cycleBaseline,
                    resetLimitOnInput: options.effectiveKeepBlackoutOnInput && !selection.coversAllDisplays,
                    watch: true,
                    restoreGeneration: cycleRestoreGeneration
                )
            } catch let error as BlackoutError {
                switch error {
                case .topologyChanged, .noScreens, .invalidScreenFrame, .coverageMismatch,
                     .allScreensSafety, .mirroredDisplay:
                    interruptCycle(.topologyChanged)
                default:
                    throw error
                }
            }
        }
    }

    public func handleControl(_ command: BlackoutControlCommand) {
        guard watchMode, !stopRequested else { return }
        let displaysAreAsleep =
            watchState.suspensions.contains(.screensAsleep) ||
            Self.currentDisplaysAreAsleep()
        switch command {
        case .blackoutNow:
            if fullCycleActive {
                emitStatus(force: true)
            } else if intentionalDisplaySleep || displaysAreAsleep {
                if manualActivityUptime != nil {
                    immediateBlackoutRequested = true
                } else {
                    setRuntimeState(.sleeping, force: true)
                }
            } else {
                immediateBlackoutRequested = true
            }
        case .restore:
            let sleeping = intentionalDisplaySleep || displaysAreAsleep
            immediateBlackoutRequested = false
            restoreGeneration &+= 1
            manualActivityUptime = uptime()
            fullCycleActive = false
            dimming?.restore()
            closeAllWindows()
            emptyDisplayPolicy.reset()
            if !sleeping {
                watchState.acceptManualActivity()
            }
            if sleeping {
                do {
                    try DisplaySleepController.wake()
                    setRuntimeState(.waiting, force: true)
                } catch {
                    setRuntimeState(.sleeping, force: true)
                }
            } else {
                setRuntimeState(.waiting, force: true)
            }
        }
    }

    private static func currentDisplaysAreAsleep() -> Bool {
        DisplayInventory.records().contains {
            $0.online && $0.asleep
        }
    }

    private func runBlackoutCycle(
        policy: BlackoutPolicy,
        options: BlackoutOptions,
        baseline: IdleSample,
        resetLimitOnInput: Bool,
        watch: Bool,
        restoreGeneration cycleRestoreGeneration: UInt64
    ) throws {
        var limitBeganAt = uptime()
        var inputBaselineUptime = baseline.lastInputUptime

        func consumeInputAction(_ sample: IdleSample) -> Bool {
            switch policy.inputAction(
                for: sample,
                after: inputBaselineUptime,
                resetLimitOnInput: resetLimitOnInput
            ) {
            case .none:
                return false
            case .restore:
                if watch {
                    watchState.reset(.input, after: inputBaselineUptime)
                }
                finishFullCycle(
                    options: options,
                    nextState: watch ? .waitingForInput : .waiting,
                    reconcileEmpty: watch
                )
                return true
            case .resetLimit:
                limitBeganAt = uptime()
                inputBaselineUptime = sample.lastInputUptime
                return false
            }
        }

        if watch, cycleRestoreGeneration != restoreGeneration {
            return
        }
        let installedSample = try idleSample()
        if consumeInputAction(installedSample) { return }

        while !stopRequested {
            try ensureAssertions()
            runLoopTick()
            if stopRequested { return }
            if watch, cycleRestoreGeneration != restoreGeneration {
                return
            }
            let sample = try idleSample()
            if consumeInputAction(sample) { return }
            if stopRequested { return }
            if watch && !watchState.mayBeginCycle {
                clearAllCoverage(resetGrace: true)
                return
            }

            switch policy.limitAction(elapsed: uptime() - limitBeganAt) {
            case .none:
                continue
            case .finish:
                if watch {
                    watchState.reset(.timeout, after: sample.lastInputUptime)
                }
                finishFullCycle(
                    options: options,
                    nextState: watch ? .waitingForInput : .waiting,
                    reconcileEmpty: watch
                )
                return
            case .sleep:
                let finalSample = try idleSample()
                if stopRequested { return }
                switch policy.inputAction(
                    for: finalSample,
                    after: inputBaselineUptime,
                    resetLimitOnInput: resetLimitOnInput
                ) {
                case .restore:
                    if watch {
                        watchState.reset(.input, after: inputBaselineUptime)
                    }
                    finishFullCycle(
                        options: options,
                        nextState: watch ? .waitingForInput : .waiting,
                        reconcileEmpty: watch
                    )
                    return
                case .resetLimit:
                    limitBeganAt = uptime()
                    inputBaselineUptime = finalSample.lastInputUptime
                    continue
                case .none:
                    break
                }
                intentionalDisplaySleep = true
                clearAllCoverage(resetGrace: true)
                releaseDisplayAssertion()
                setRuntimeState(.sleeping)
                if !watch {
                    try DisplaySleepController.sleep()
                    if assertion != nil {
                        try waitForDisplayWakeOrInput(after: finalSample.lastInputUptime)
                    }
                    return
                }
                watchState.reset(.sleepAfter, after: finalSample.lastInputUptime)
                try DisplaySleepController.sleep()
                try waitForWatchWakeAndInput()
                return
            }
        }
    }

    private func resolveTargets(
        options: BlackoutOptions,
        screens: [NSScreen],
        drawableScreens: [NSScreen]
    ) throws -> [BlackoutScreenTarget] {
        if options.all {
            guard !drawableScreens.isEmpty else { throw BlackoutError.noScreens }
            try Self.validateSelection(
                selectedCount: drawableScreens.count,
                drawableCount: drawableScreens.count,
                hasSafetyLimit: Self.hasSafetyLimit(options)
            )
            if options.watch { return [] }
            return try drawableScreens.map { screen in
                guard let id = Self.screenID(screen) else { throw BlackoutError.topologyChanged }
                return BlackoutScreenTarget(id: id, uuid: nil, selector: "--all")
            }
        }

        let records = DisplayInventory.records()
        var selected: [BlackoutScreenTarget] = []
        var selectedIDs: Set<CGDirectDisplayID> = []
        for selector in options.selectors {
            guard let record = DisplaySelector.resolve(selector, in: records),
                  let screen = screens.first(where: { Self.screenID($0) == record.id }) else {
                throw BlackoutError.unknownSelector(selector)
            }
            guard Self.isValidScreenFrame(screen.frame) else {
                throw BlackoutError.nonDrawable(selector)
            }
            try Self.validateTarget(isMirrored: CGDisplayIsInMirrorSet(record.id) != 0, selector: selector)
            if options.watch, record.uuid == nil {
                throw BlackoutError.watchRequiresStableUUID(selector)
            }
            if selectedIDs.insert(record.id).inserted {
                selected.append(BlackoutScreenTarget(id: record.id, uuid: record.uuid, selector: selector))
            }
        }
        guard !selected.isEmpty else { throw BlackoutError.noScreens }
        try Self.validateSelection(
            selectedCount: selected.count,
            drawableCount: drawableScreens.count,
            hasSafetyLimit: Self.hasSafetyLimit(options)
        )
        return selected
    }

    private func resolveCurrentScreens(options: BlackoutOptions) throws -> (
        screens: [NSScreen],
        coversAllDisplays: Bool
    ) {
        let currentScreens = NSScreen.screens
        let drawable = currentScreens.filter { Self.isValidScreenFrame($0.frame) }
        guard !drawable.isEmpty else { throw BlackoutError.noScreens }
        if options.all {
            if watchMode {
                try Self.validateSelection(
                    selectedCount: drawable.count,
                    drawableCount: drawable.count,
                    hasSafetyLimit: Self.hasSafetyLimit(options)
                )
                return (drawable, true)
            }
            var currentByID: [CGDirectDisplayID: NSScreen] = [:]
            for screen in drawable {
                guard let id = Self.screenID(screen), currentByID[id] == nil else {
                    throw BlackoutError.topologyChanged
                }
                currentByID[id] = screen
            }
            guard Set(targets.map(\.id)) == Set(currentByID.keys) else {
                throw BlackoutError.topologyChanged
            }
            let selected = targets.compactMap { currentByID[$0.id] }
            try Self.validateSelection(
                selectedCount: selected.count,
                drawableCount: drawable.count,
                hasSafetyLimit: Self.hasSafetyLimit(options)
            )
            return (selected, true)
        }

        let records = watchMode ? DisplayInventory.records() : []
        let selected = try targets.map { target -> NSScreen in
            let currentID = try target.resolvedID(in: records, watch: watchMode)
            let screen = currentScreens.first(where: { Self.screenID($0) == currentID })
            guard let screen, Self.isValidScreenFrame(screen.frame) else {
                throw BlackoutError.topologyChanged
            }
            guard let id = Self.screenID(screen) else { throw BlackoutError.topologyChanged }
            try Self.validateTarget(isMirrored: CGDisplayIsInMirrorSet(id) != 0, selector: target.selector)
            return screen
        }
        guard !selected.isEmpty else { throw BlackoutError.noScreens }
        try Self.validateSelection(
            selectedCount: selected.count,
            drawableCount: drawable.count,
            hasSafetyLimit: Self.hasSafetyLimit(options)
        )
        return (selected, selected.count >= drawable.count)
    }

    private func beginFullCycle(
        on screens: [NSScreen],
        mode: BlackoutMode,
        overlayOpacityPercent: Int?,
        hardwareBrightnessPercent: Int?
    ) throws {
        try reconcileWindows(
            on: screens,
            mode: mode,
            overlayOpacityPercent: overlayOpacityPercent
        )
        fullCycleActive = true
        if let hardwareBrightnessPercent {
            dimming?.dim(
                targets,
                to: hardwareBrightnessPercent,
                screenIDs: screens.compactMap(Self.screenID)
            )
        }
        runtimeState = .blackedOut
        emitStatus()
    }

    private func reconcileWindows(
        on desiredScreens: [NSScreen],
        mode: BlackoutMode,
        overlayOpacityPercent: Int?
    ) throws {
        var screensByID: [CGDirectDisplayID: NSScreen] = [:]
        for screen in desiredScreens {
            guard Self.isValidScreenFrame(screen.frame),
                  let targetID = Self.screenID(screen),
                  screensByID[targetID] == nil else {
                throw BlackoutError.invalidScreenFrame(screen.localizedName)
            }
            screensByID[targetID] = screen
        }

        var prepared: [CGDirectDisplayID: NSWindow] = [:]
        var committed = false
        defer {
            if !committed {
                prepared.values.forEach {
                    $0.orderOut(nil)
                    $0.close()
                }
            }
        }

        for (targetID, screen) in screensByID {
            if let existing = windows[targetID] {
                guard Self.exactlyCovers(
                    windowFrame: existing.frame,
                    screenFrame: screen.frame,
                    windowScreenID: existing.screen.flatMap(Self.screenID),
                    targetScreenID: targetID
                ) else {
                    throw BlackoutError.coverageMismatch(screen.localizedName)
                }
                continue
            }
            let window = makeWindow(
                for: screen,
                mode: mode,
                overlayOpacityPercent: overlayOpacityPercent
            )
            guard Self.exactlyCovers(
                windowFrame: window.frame,
                screenFrame: screen.frame,
                windowScreenID: window.screen.flatMap(Self.screenID),
                targetScreenID: targetID
            ) else {
                window.close()
                throw BlackoutError.coverageMismatch(screen.localizedName)
            }
            prepared[targetID] = window
        }

        if stopRequested { throw BlackoutError.topologyChanged }
        prepared.keys.sorted().forEach { prepared[$0]?.orderFrontRegardless() }
        for (targetID, screen) in screensByID {
            guard let window = prepared[targetID] ?? windows[targetID],
                  Self.exactlyCovers(
                    windowFrame: window.frame,
                    screenFrame: screen.frame,
                    windowScreenID: window.screen.flatMap(Self.screenID),
                    targetScreenID: targetID
                  ) else {
                throw BlackoutError.coverageMismatch(screen.localizedName)
            }
        }

        let removedIDs = Set(windows.keys).subtracting(screensByID.keys)
        removedIDs.forEach { id in
            windows[id]?.orderOut(nil)
            windows[id]?.close()
        }
        windows = windows.filter { screensByID[$0.key] != nil }
        prepared.forEach { windows[$0.key] = $0.value }
        committed = true
    }

    func makeWindow(
        for screen: NSScreen,
        mode: BlackoutMode,
        overlayOpacityPercent: Int?
    ) -> NSWindow {
        let window = NSWindow(
            contentRect: Self.windowContentRect(for: screen.frame),
            styleMask: .borderless,
            backing: .buffered,
            defer: false,
            screen: screen
        )
        Self.configureWindow(
            window,
            mode: mode,
            overlayOpacityPercent: overlayOpacityPercent
        )
        window.setFrame(screen.frame, display: false)
        return window
    }

    private func finishFullCycle(
        options: BlackoutOptions,
        nextState: BlackoutRuntimeState,
        reconcileEmpty: Bool
    ) {
        fullCycleActive = false
        dimming?.restore()
        runtimeState = nextState
        if reconcileEmpty, blackoutEmptyDisplays {
            reconcileEmptyCoverage(options: options)
        } else {
            closeAllWindows()
            emitStatus()
        }
    }

    private func reconcileEmptyCoverage(options: BlackoutOptions) {
        guard !fullCycleActive else { return }
        guard blackoutEmptyDisplays,
              watchMode,
              watchState.suspensions.isEmpty else {
            closeAllWindows()
            emptyDisplayPolicy.reset()
            emitStatus()
            return
        }
        let now = uptime()
        guard now >= emptyResolutionRetryAfter else { return }
        do {
            let context = try emptyDisplayContext(options: options)
            let desiredIDs = emptyDisplayPolicy.desiredDisplayIDs(
                targets: context.targets,
                activeDisplayBounds: context.activeDisplayBounds,
                sample: occupancySource.sample(),
                uptime: now
            )
            let desiredScreens = desiredIDs.compactMap { context.screensByID[$0] }
            guard desiredScreens.count == desiredIDs.count else {
                throw BlackoutError.topologyChanged
            }
            try reconcileWindows(
                on: desiredScreens,
                mode: options.mode,
                overlayOpacityPercent: options.overlayOpacityPercent
            )
            emitStatus()
        } catch {
            closeAllWindows()
            emptyDisplayPolicy.reset()
            cachedEmptyDisplayContext = nil
            emptyResolutionRetryAfter = now + 1
            releaseDisplayAssertion()
            watchState.reset(.topologyChanged, after: observedInputBaseline())
            runtimeState = .waitingForInput
            emitStatus()
        }
    }

    private func emptyDisplayContext(options: BlackoutOptions) throws -> EmptyDisplayContext {
        if let cached = cachedEmptyDisplayContext,
           cached.generation == screenConfigurationGeneration {
            return cached.context
        }
        let selection = try resolveCurrentScreens(options: options)
        var screensByID: [CGDirectDisplayID: NSScreen] = [:]
        var selectedTargets: [EmptyDisplayTarget] = []
        for screen in selection.screens {
            guard let id = Self.screenID(screen), screensByID[id] == nil else {
                throw BlackoutError.topologyChanged
            }
            let bounds = CGDisplayBounds(id)
            guard Self.isValidScreenFrame(bounds) else {
                throw BlackoutError.invalidScreenFrame(screen.localizedName)
            }
            screensByID[id] = screen
            selectedTargets.append(EmptyDisplayTarget(id: id, bounds: bounds))
        }
        var activeBounds: [CGRect] = []
        for screen in NSScreen.screens {
            guard Self.isValidScreenFrame(screen.frame),
                  let id = Self.screenID(screen) else {
                throw BlackoutError.topologyChanged
            }
            let bounds = CGDisplayBounds(id)
            guard Self.isValidScreenFrame(bounds) else {
                throw BlackoutError.topologyChanged
            }
            activeBounds.append(bounds)
        }
        guard !activeBounds.isEmpty else { throw BlackoutError.noScreens }
        let context = EmptyDisplayContext(
            screensByID: screensByID,
            targets: selectedTargets,
            activeDisplayBounds: activeBounds
        )
        cachedEmptyDisplayContext = (screenConfigurationGeneration, context)
        emptyResolutionRetryAfter = 0
        return context
    }

    private func waitUntilReady(
        policy: BlackoutPolicy,
        options: BlackoutOptions
    ) throws -> (sample: IdleSample, forced: Bool)? {
        var deferredActivityWasActive = false
        var activityDeferralUptime: TimeInterval?
        func reportState(_ state: BlackoutRuntimeState) {
            setRuntimeState(state)
        }

        while !stopRequested {
            let screensAreSuspended = watchMode &&
                watchState.suspensions.contains(.screensAsleep)
            let waitsForInput = watchMode &&
                !watchState.mayBeginCycle &&
                !immediateBlackoutRequested
            if screensAreSuspended {
                deferredActivityWasActive = false
                activityDeferralUptime = nil
                reportState(.sleeping)
            } else if waitsForInput {
                deferredActivityWasActive = false
                activityDeferralUptime = nil
                reportState(.waitingForInput)
            } else {
                let canAutomaticallyDefer = policy.idleAfter != nil &&
                    !immediateBlackoutRequested
                let defersForActivity = policy.shouldDeferForActivity(
                    assertionActive: canAutomaticallyDefer &&
                        policy.deferPlayback && playbackAssertionActive(),
                    cameraActive: canAutomaticallyDefer &&
                        policy.deferCamera && cameraCaptureActive(),
                    immediateBlackoutRequested: immediateBlackoutRequested
                )
                if defersForActivity {
                    deferredActivityWasActive = true
                    activityDeferralUptime = nil
                    reportState(.waitingForPlayback)
                    reconcileEmptyCoverage(options: options)
                    try ensureAssertions()
                    runLoopTick()
                    continue
                }
                if deferredActivityWasActive {
                    deferredActivityWasActive = false
                    activityDeferralUptime = uptime()
                }
                reportState(.waiting)
            }
            try ensureAssertions()
            let sample = try idleSample()
            if watchMode && consumeFreshInput(sample) {
                // Input is a rearm edge, not an activation edge. The next
                // sample must satisfy the complete idle interval.
                reconcileEmptyCoverage(options: options)
                runLoopTick()
                continue
            }
            if watchMode,
               immediateBlackoutRequested,
               watchState.suspensions.isEmpty {
                watchState.acceptManualActivity()
                manualActivityUptime = nil
                return (sample, true)
            }
            if watchMode && !watchState.mayBeginCycle {
                reconcileEmptyCoverage(options: options)
                runLoopTick()
                continue
            }
            let activationSample = manualActivityUptime.map {
                sample.applyingSyntheticActivity(at: $0)
            } ?? activityDeferralUptime.map {
                sample.applyingSyntheticActivity(at: $0)
            } ?? sample
            if policy.shouldBegin(idleSeconds: activationSample.seconds) {
                manualActivityUptime = nil
                activityDeferralUptime = nil
                return (activationSample, false)
            }
            reconcileEmptyCoverage(options: options)
            runLoopTick()
        }
        return nil
    }

    private func waitForWatchWakeAndInput() throws {
        while !stopRequested {
            try ensureAssertions()
            runLoopTick()
            let sample = try idleSample()
            if immediateBlackoutRequested,
               watchState.suspensions.isEmpty {
                watchState.acceptManualActivity()
                return
            }
            if consumeFreshInput(sample) { return }
            if watchState.suspensions.isEmpty && !watchState.awaitingFreshInput {
                return
            }
        }
    }

    private func waitForDisplayWakeOrInput(after baselineUptime: TimeInterval) throws {
        let inputPolicy = BlackoutPolicy(idleAfter: nil, timeout: nil, sleepAfter: nil)
        while !stopRequested, !displayWakeObserved {
            try ensureAssertions()
            runLoopTick()
            if stopRequested { return }
            let sample = try idleSample()
            if inputPolicy.hasNewInput(sample, after: baselineUptime) { return }
        }
    }

    func idleSample() throws -> IdleSample {
        guard let seconds = idleSource.secondsSinceLastInput() else {
            clearAllCoverage(resetGrace: true)
            throw BlackoutError.idleMonitoringUnavailable
        }
        // Query first: CoreGraphics' first idle query can take tens of milliseconds.
        // Sampling uptime before it would make that latency look like new input.
        let now = uptime()
        guard seconds.isFinite,
              seconds >= 0,
              seconds <= now + 1 else {
            clearAllCoverage(resetGrace: true)
            throw BlackoutError.idleMonitoringUnavailable
        }

        let sample = IdleSample(seconds: seconds, lastInputUptime: now - seconds)
        lastInputUptime = sample.lastInputUptime
        return sample
    }


    private func consumeFreshInput(_ sample: IdleSample) -> Bool {
        // Input can wake a display even if AppKit drops the matching wake
        // notification. Never infer system or session resume this way.
        watchState.consumeFreshInput(sample, allowScreenWakeFallback: true)
    }

    private func resetCycleFlags() {
        intentionalDisplaySleep = false
        displayWakeObserved = false
    }

    private func ensureCaffeinate() throws {
        if assertion != nil, assertion?.isRunning != true {
            clearAllCoverage(resetGrace: true)
            throw BlackoutError.caffeinateExited
        }
    }

    private func ensureAssertions() throws {
        try ensureCaffeinate()
        try ensureDisplayAssertion()
    }

    private func ensureDisplayAssertion() throws {
        guard keepDisplaysAwake else { return }
        guard !intentionalDisplaySleep else {
            releaseDisplayAssertion()
            return
        }
        guard (!watchMode || watchState.suspensions.isEmpty) &&
              (!watchMode || !watchState.awaitingFreshInput) else {
            releaseDisplayAssertion()
            return
        }
        if displayAssertion == nil {
            displayAssertion = try CaffeinateAssertion(kind: .display)
        }
        guard displayAssertion?.isRunning == true else {
            clearAllCoverage(resetGrace: true)
            throw BlackoutError.caffeinateExited
        }
    }

    private func releaseDisplayAssertion() {
        displayAssertion?.stop()
        displayAssertion = nil
    }

    private func manualBlackoutInputBaseline() throws -> IdleSample {
        let deadline = Date(
            timeIntervalSinceNow: Self.manualBlackoutInputSettlingDuration
        )
        var sample = try idleSample()
        while Date() < deadline {
            _ = RunLoop.current.run(mode: .default, before: deadline)
            sample = try idleSample()
        }
        return sample
    }

    private func runLoopTick() {
        _ = RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.25))
    }

    private func closeAllWindows() {
        windows.values.forEach {
            $0.orderOut(nil)
            $0.close()
        }
        windows.removeAll()
    }

    private func clearAllCoverage(resetGrace: Bool) {
        fullCycleActive = false
        let restoreStartedAt = uptime()
        dimming?.restore()
        let restoreElapsed = uptime() - restoreStartedAt
        let closeStartedAt = uptime()
        closeAllWindows()
        let closeElapsed = uptime() - closeStartedAt
        if restoreElapsed >= 0.1 || closeElapsed >= 0.1 {
            let restoreDuration = String(format: "%.3f", restoreElapsed)
            let closeDuration = String(format: "%.3f", closeElapsed)
            shutdownLogger.notice(
                "Slow blackout cleanup: DDC restore \(restoreDuration, privacy: .public)s, window close \(closeDuration, privacy: .public)s"
            )
        }
        if resetGrace {
            emptyDisplayPolicy.reset()
        }
    }

    private func setRuntimeState(
        _ state: BlackoutRuntimeState,
        force: Bool = false
    ) {
        runtimeState = state
        emitStatus(force: force)
    }

    private func emitStatus(force: Bool = false) {
        let status = BlackoutRuntimeStatus(
            state: runtimeState,
            blackedOutDisplayIDs: Array(windows.keys)
        )
        guard force || status != lastStatus else { return }
        lastStatus = status
        statusHandler?(status)
    }

    private func invalidateScreenConfiguration() {
        screenConfigurationGeneration &+= 1
        cachedEmptyDisplayContext = nil
        emptyResolutionRetryAfter = 0
    }

    private func installObservers() {
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.invalidateScreenConfiguration()
            if self.watchMode {
                self.interruptCycle(.topologyChanged)
            } else {
                self.requestStop()
            }
        }

        let center = NSWorkspace.shared.notificationCenter
        let terminalNames: [Notification.Name] = [
            NSWorkspace.willSleepNotification,
            NSWorkspace.didWakeNotification,
            NSWorkspace.sessionDidResignActiveNotification,
            NSWorkspace.sessionDidBecomeActiveNotification
        ]
        for name in terminalNames {
            workspaceObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                guard let self, let event = Self.workspaceEvent(for: name) else { return }
                self.handleWorkspaceEvent(event)
            })
        }
        workspaceObservers.append(center.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self,
                  let event = Self.workspaceEvent(for: NSWorkspace.screensDidSleepNotification) else {
                return
            }
            self.handleWorkspaceEvent(event)
        })
        workspaceObservers.append(center.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.invalidateScreenConfiguration()
            self.dimming?.recoverStale()
            self.displayWakeObserved = true
            if self.watchMode {
                if let event = Self.workspaceEvent(for: NSWorkspace.screensDidWakeNotification) {
                    self.handleWorkspaceEvent(event)
                }
                self.intentionalDisplaySleep = false
            } else if self.intentionalDisplaySleep {
                self.intentionalDisplaySleep = false
            } else {
                self.requestStop()
            }
        })
    }

    private func requestStop() {
        stopRequested = true
        watchState.terminate()
        clearAllCoverage(resetGrace: true)
    }

    private func interruptCycle(_ reset: BlackoutWatchReset) {
        releaseDisplayAssertion()
        if reset == .topologyChanged {
            invalidateScreenConfiguration()
        }
        watchState.reset(reset, after: observedInputBaseline())
        clearAllCoverage(resetGrace: true)
        if case .suspension(.screensAsleep) = reset {
            setRuntimeState(.sleeping)
        } else {
            setRuntimeState(.waiting)
        }
    }

    private func handleWorkspaceEvent(_ event: WorkspaceEvent) {
        if case .resume(let reason) = event, reason != .screensAsleep {
            dimming?.recoverStale()
        }
        guard watchMode else {
            switch event {
            case .reset(.suspension(.screensAsleep)):
                clearAllCoverage(resetGrace: true)
                if !intentionalDisplaySleep { requestStop() }
            case .resume(.screensAsleep): break
            default: requestStop()
            }
            return
        }
        switch event {
        case .reset(let reset):
            interruptCycle(reset)
        case .resume(let reason):
            watchState.resume(reason, after: observedInputBaseline())
            if manualActivityUptime != nil, watchState.suspensions.isEmpty {
                manualActivityUptime = uptime()
                watchState.acceptManualActivity()
            }
            setRuntimeState(
                watchState.suspensions.contains(.screensAsleep)
                    ? .sleeping
                    : .waiting
            )
        }
    }

    private func observedInputBaseline() -> TimeInterval {
        if let lastInputUptime { return lastInputUptime }
        let baseline = uptime()
        lastInputUptime = baseline
        return baseline
    }

    static func workspaceEvent(for name: Notification.Name) -> WorkspaceEvent? {
        switch name {
        case NSWorkspace.sessionDidResignActiveNotification:
            return .reset(.suspension(.sessionInactive))
        case NSWorkspace.sessionDidBecomeActiveNotification:
            return .resume(.sessionInactive)
        case NSWorkspace.willSleepNotification:
            return .reset(.suspension(.systemSleeping))
        case NSWorkspace.didWakeNotification:
            return .resume(.systemSleeping)
        case NSWorkspace.screensDidSleepNotification:
            return .reset(.suspension(.screensAsleep))
        case NSWorkspace.screensDidWakeNotification:
            return .resume(.screensAsleep)
        default:
            return nil
        }
    }

    public func stop() {
        stopRequested = true
        clearAllCoverage(resetGrace: true)
        dimming?.stop()
        dimming = nil
        signalSources.forEach { $0.cancel() }
        signalSources.removeAll()
        for number in [SIGINT, SIGTERM, SIGHUP] {
            signal(number, SIG_DFL)
        }
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
            self.screenObserver = nil
        }
        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers.forEach { center.removeObserver($0) }
        workspaceObservers.removeAll()
        assertion?.stop()
        assertion = nil
        releaseDisplayAssertion()
    }

    private func installSignals() {
        for number in [SIGINT, SIGTERM, SIGHUP] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler { [weak self] in self?.requestStop() }
            source.resume()
            signalSources.append(source)
        }
    }

    static func validateTarget(isMirrored: Bool, selector: String) throws {
        if isMirrored { throw BlackoutError.mirroredDisplay(selector) }
    }

    static func validateOptions(_ options: BlackoutOptions) throws {
        if let opacity = options.overlayOpacityPercent,
           !(1...100).contains(opacity) {
            throw BlackoutError.invalidOverlayOpacity
        }
        if options.mode == .blocking, options.overlayOpacityPercent != 100 {
            throw BlackoutError.workingOverlayRequired
        }
        if let brightness = options.hardwareBrightnessPercent,
           !(0...100).contains(brightness) {
            throw BlackoutError.invalidHardwareBrightness
        }
        if options.mode == .blocking,
           options.keepBlackoutOnInput,
           options.hardwareBrightnessPercent != nil {
            throw BlackoutError.persistentDimming
        }
    }

    static func validateSelection(
        selectedCount: Int,
        drawableCount: Int,
        hasSafetyLimit: Bool = false
    ) throws {
        if selectedCount >= drawableCount, !hasSafetyLimit {
            throw BlackoutError.allScreensSafety
        }
    }

    private static func hasSafetyLimit(_ options: BlackoutOptions) -> Bool {
        [options.timeout, options.sleepAfter].contains {
            guard let duration = $0 else { return false }
            return duration > 0 && duration.isFinite
        }
    }

    static func configureWindow(
        _ window: NSWindow,
        mode: BlackoutMode,
        overlayOpacityPercent: Int?
    ) {
        window.backgroundColor = .black
        window.alphaValue = CGFloat(overlayOpacityPercent ?? 0) / 100
        window.isOpaque = mode == .blocking && overlayOpacityPercent == 100
        window.hasShadow = false
        window.level = .screenSaver
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.ignoresMouseEvents = mode == .working
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none

        let contentView = NSView(frame: window.contentView?.bounds ?? .zero)
        contentView.autoresizingMask = [.width, .height]
        contentView.wantsLayer = true
        contentView.layer?.backgroundColor = NSColor.black.cgColor
        window.contentView = contentView
    }

    static func windowContentRect(for screenFrame: CGRect) -> CGRect {
        CGRect(origin: .zero, size: screenFrame.size)
    }

    static func isValidScreenFrame(_ frame: CGRect) -> Bool {
        frame.origin.x.isFinite &&
        frame.origin.y.isFinite &&
        frame.width.isFinite &&
        frame.height.isFinite &&
        frame.width > 0 &&
        frame.height > 0
    }

    static func exactlyCovers(
        windowFrame: CGRect,
        screenFrame: CGRect,
        windowScreenID: CGDirectDisplayID?,
        targetScreenID: CGDirectDisplayID
    ) -> Bool {
        isValidScreenFrame(screenFrame) &&
        isValidScreenFrame(windowFrame) &&
        windowFrame == screenFrame &&
        windowScreenID == targetScreenID
    }

    private static func screenID(_ screen: NSScreen) -> CGDirectDisplayID? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

}
