import Foundation
import AppKit
import CoreGraphics

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

    public var description: String {
        switch self {
        case .noScreens: return "no drawable screens are available (headless or no WindowServer context)"
        case .unknownSelector(let selector): return "unknown display selector: \(selector)"
        case .nonDrawable(let selector): return "display is not drawable: \(selector)"
        case .mirroredDisplay(let selector): return "refusing mirrored display target: \(selector)"
        case .allScreensSafety: return "refusing to black out every drawable screen without --all"
        case .invalidScreenFrame(let display): return "display has an invalid screen frame: \(display)"
        case .coverageMismatch(let display): return "refusing partial blackout because the window does not exactly cover display \(display)"
        case .topologyChanged: return "display topology changed before blackout could be installed"
        case .idleMonitoringUnavailable: return "combined-session idle monitoring is unavailable"
        case .caffeinateExited: return "caffeinate exited before blackout completed"
        case .watchRequiresStableUUID(let selector):
            return "--watch requires a display with a stable UUID: \(selector)"
        }
    }
}

public enum BlackoutRuntimeState: String, Equatable {
    case waiting
    case blackedOut = "blacked_out"
    case sleeping
    case stopped
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

enum BlackoutLimitAction: Equatable {
    case none
    case finish
    case sleep
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

    func shouldBegin(idleSeconds: TimeInterval) -> Bool {
        idleAfter.map { idleSeconds >= $0 } ?? true
    }

    func hasNewInput(_ sample: IdleSample, after baselineUptime: TimeInterval) -> Bool {
        sample.lastInputUptime > baselineUptime + 0.001
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

    private var windows: [NSWindow] = []
    private var signalSources: [DispatchSourceSignal] = []
    private var screenObserver: NSObjectProtocol?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var assertion: CaffeinateAssertion?
    private var stopRequested = false
    private var intentionalDisplaySleep = false
    private var displayWakeObserved = false
    private var watchMode = false
    private var watchState = BlackoutWatchState()
    private var targets: [BlackoutScreenTarget] = []
    private var lastInputUptime: TimeInterval?
    private var immediateBlackoutRequested = false
    private var manualActivityUptime: TimeInterval?
    private var restoreGeneration: UInt64 = 0
    private let idleSource: IdleTimeSource
    private let uptime: () -> TimeInterval
    private let stateHandler: ((BlackoutRuntimeState) -> Void)?

    public convenience init() {
        self.init(
            idleSource: CombinedSessionIdleTimeSource(),
            uptime: { ProcessInfo.processInfo.systemUptime },
            stateHandler: nil
        )
    }

    public convenience init(stateHandler: @escaping (BlackoutRuntimeState) -> Void) {
        self.init(
            idleSource: CombinedSessionIdleTimeSource(),
            uptime: { ProcessInfo.processInfo.systemUptime },
            stateHandler: stateHandler
        )
    }

    init(
        idleSource: IdleTimeSource,
        uptime: @escaping () -> TimeInterval,
        stateHandler: ((BlackoutRuntimeState) -> Void)? = nil
    ) {
        self.idleSource = idleSource
        self.uptime = uptime
        self.stateHandler = stateHandler
    }

    public func run(options: BlackoutOptions) throws {
        watchMode = options.watch
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.finishLaunching()

        installSignals()
        installObservers()
        defer {
            stop()
            stateHandler?(.stopped)
        }

        let screens = NSScreen.screens
        let drawableScreens = screens.filter { Self.isValidScreenFrame($0.frame) }
        guard !drawableScreens.isEmpty else { throw BlackoutError.noScreens }
        targets = try resolveTargets(options: options, screens: screens, drawableScreens: drawableScreens)
        if options.caffeinate { assertion = try CaffeinateAssertion() }

        let policy = BlackoutPolicy(
            idleAfter: options.idleAfter,
            timeout: options.timeout,
            sleepAfter: options.sleepAfter
        )
        if !watchMode {
            guard let activation = try waitUntilReady(policy: policy) else {
                return
            }
            if stopRequested { return }
            let currentSelection = try resolveCurrentScreens(all: options.all)
            try showWindows(on: currentSelection)
            try runBlackoutCycle(
                policy: policy,
                baseline: activation.sample,
                watch: false,
                restoreGeneration: restoreGeneration
            )
            return
        }

        while !stopRequested {
            resetCycleFlags()
            guard let activation = try waitUntilReady(policy: policy) else {
                return
            }
            if stopRequested { return }
            let cycleRestoreGeneration = restoreGeneration
            do {
                let currentSelection = try resolveCurrentScreens(all: options.all)
                try showWindows(on: currentSelection)
                if activation.forced {
                    immediateBlackoutRequested = false
                }
                try runBlackoutCycle(
                    policy: policy,
                    baseline: activation.sample,
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
            if !windows.isEmpty {
                stateHandler?(.blackedOut)
            } else if intentionalDisplaySleep ||
                        displaysAreAsleep {
                if manualActivityUptime != nil {
                    immediateBlackoutRequested = true
                } else {
                    stateHandler?(.sleeping)
                }
            } else {
                immediateBlackoutRequested = true
            }
        case .restore:
            let sleeping = intentionalDisplaySleep ||
                displaysAreAsleep
            immediateBlackoutRequested = false
            restoreGeneration &+= 1
            manualActivityUptime = uptime()
            if !sleeping {
                watchState.acceptManualActivity()
            }
            hideWindows()
            if sleeping {
                do {
                    try DisplaySleepController.wake()
                    stateHandler?(.waiting)
                } catch {
                    stateHandler?(.sleeping)
                }
            } else {
                stateHandler?(.waiting)
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
        baseline: IdleSample,
        watch: Bool,
        restoreGeneration cycleRestoreGeneration: UInt64
    ) throws {
        let startedAt = uptime()
        if watch, cycleRestoreGeneration != restoreGeneration {
            hideWindows()
            return
        }
        let installedSample = try idleSample()
        if policy.hasNewInput(installedSample, after: baseline.lastInputUptime) {
            hideWindows()
            if watch {
                watchState.reset(.input, after: baseline.lastInputUptime)
            }
            return
        }

        while !stopRequested {
            try ensureCaffeinate()
            runLoopTick()
            if stopRequested { return }
            if watch, cycleRestoreGeneration != restoreGeneration {
                hideWindows()
                return
            }
            let sample = try idleSample()
            if policy.hasNewInput(sample, after: baseline.lastInputUptime) {
                hideWindows()
                if watch {
                    watchState.reset(.input, after: baseline.lastInputUptime)
                }
                return
            }
            if stopRequested { return }
            if watch && !watchState.mayBeginCycle {
                hideWindows()
                return
            }

            switch policy.limitAction(elapsed: uptime() - startedAt) {
            case .none:
                continue
            case .finish:
                if watch {
                    hideWindows()
                    watchState.reset(.timeout, after: sample.lastInputUptime)
                }
                return
            case .sleep:
                let finalSample = try idleSample()
                if stopRequested || policy.hasNewInput(finalSample, after: baseline.lastInputUptime) {
                    hideWindows()
                    if watch {
                        watchState.reset(.input, after: baseline.lastInputUptime)
                    }
                    return
                }
                intentionalDisplaySleep = true
                hideWindows()
                if !watch {
                    stateHandler?(.sleeping)
                    try DisplaySleepController.sleep()
                    if assertion != nil {
                        try waitForDisplayWakeOrInput(after: finalSample.lastInputUptime)
                    }
                    return
                }
                watchState.reset(.sleepAfter, after: finalSample.lastInputUptime)
                stateHandler?(.sleeping)
                try DisplaySleepController.sleep()
                try waitForWatchWakeAndInput()
                return
            }
        }
    }

    private func resolveTargets(options: BlackoutOptions, screens: [NSScreen], drawableScreens: [NSScreen]) throws -> [BlackoutScreenTarget] {
        if options.all {
            guard !drawableScreens.isEmpty else { throw BlackoutError.noScreens }
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
        try Self.validateSelection(selectedCount: selected.count, drawableCount: drawableScreens.count)
        return selected
    }

    private func resolveCurrentScreens(all: Bool) throws -> [NSScreen] {
        let currentScreens = NSScreen.screens
        let drawable = currentScreens.filter { Self.isValidScreenFrame($0.frame) }
        guard !drawable.isEmpty else { throw BlackoutError.noScreens }
        if all {
            if watchMode { return drawable }
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
            return targets.compactMap { currentByID[$0.id] }
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
        try Self.validateSelection(selectedCount: selected.count, drawableCount: drawable.count)
        return selected
    }

    private func showWindows(on screens: [NSScreen]) throws {
        guard windows.isEmpty else { return }
        var prepared: [NSWindow] = []
        var committed = false
        defer {
            if !committed {
                prepared.forEach {
                    $0.orderOut(nil)
                    $0.close()
                }
            }
        }

        for screen in screens {
            guard Self.isValidScreenFrame(screen.frame),
                  let targetID = Self.screenID(screen) else {
                throw BlackoutError.invalidScreenFrame(screen.localizedName)
            }
            let window = NSWindow(
                contentRect: Self.windowContentRect(for: screen.frame),
                styleMask: .borderless,
                backing: .buffered,
                defer: false,
                screen: screen
            )
            window.backgroundColor = .black
            window.isOpaque = true
            window.hasShadow = false
            window.level = .screenSaver
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            window.ignoresMouseEvents = false
            window.isReleasedWhenClosed = false
            window.animationBehavior = .none
            window.contentView?.wantsLayer = true
            window.contentView?.layer?.backgroundColor = NSColor.black.cgColor
            window.setFrame(screen.frame, display: false)

            guard Self.exactlyCovers(
                windowFrame: window.frame,
                screenFrame: screen.frame,
                windowScreenID: window.screen.flatMap(Self.screenID),
                targetScreenID: targetID
            ) else {
                window.close()
                throw BlackoutError.coverageMismatch(screen.localizedName)
            }
            prepared.append(window)
        }

        if stopRequested { throw BlackoutError.topologyChanged }
        prepared.forEach { $0.orderFrontRegardless() }
        for (window, screen) in zip(prepared, screens) {
            guard let targetID = Self.screenID(screen),
                  Self.exactlyCovers(
                    windowFrame: window.frame,
                    screenFrame: screen.frame,
                    windowScreenID: window.screen.flatMap(Self.screenID),
                    targetScreenID: targetID
                  ) else {
                throw BlackoutError.coverageMismatch(screen.localizedName)
            }
        }
        windows = prepared
        committed = true
        stateHandler?(.blackedOut)
    }

    private func waitUntilReady(
        policy: BlackoutPolicy
    ) throws -> (sample: IdleSample, forced: Bool)? {
        stateHandler?(.waiting)
        while !stopRequested {
            try ensureCaffeinate()
            let sample = try idleSample()
            if watchMode && consumeFreshInput(sample) {
                // Input is a rearm edge, not an activation edge. The next
                // sample must satisfy the complete idle interval.
                runLoopTick()
                continue
            }
            if watchMode,
               immediateBlackoutRequested,
               watchState.suspensions.isEmpty {
                watchState.acceptManualActivity()
                let activationSample = manualActivityUptime.map {
                    sample.applyingSyntheticActivity(at: $0)
                } ?? sample
                manualActivityUptime = nil
                return (activationSample, true)
            }
            if watchMode && !watchState.mayBeginCycle {
                runLoopTick()
                continue
            }
            let activationSample = manualActivityUptime.map {
                sample.applyingSyntheticActivity(at: $0)
            } ?? sample
            if policy.shouldBegin(idleSeconds: activationSample.seconds) {
                manualActivityUptime = nil
                return (activationSample, false)
            }
            runLoopTick()
        }
        return nil
    }

    private func waitForWatchWakeAndInput() throws {
        while !stopRequested {
            try ensureCaffeinate()
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
            try ensureCaffeinate()
            runLoopTick()
            if stopRequested { return }
            let sample = try idleSample()
            if inputPolicy.hasNewInput(sample, after: baselineUptime) { return }
        }
    }

    func idleSample() throws -> IdleSample {
        guard let seconds = idleSource.secondsSinceLastInput() else {
            hideWindows()
            throw BlackoutError.idleMonitoringUnavailable
        }
        // Query first: CoreGraphics' first idle query can take tens of milliseconds.
        // Sampling uptime before it would make that latency look like new input.
        let now = uptime()
        guard seconds.isFinite,
              seconds >= 0,
              seconds <= now + 1 else {
            hideWindows()
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
            hideWindows()
            throw BlackoutError.caffeinateExited
        }
    }

    private func runLoopTick() {
        _ = RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.25))
    }

    private func hideWindows() {
        windows.forEach {
            $0.orderOut(nil)
            $0.close()
        }
        windows.removeAll()
    }

    private func installObservers() {
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
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
        hideWindows()
    }

    private func interruptCycle(_ reset: BlackoutWatchReset) {
        watchState.reset(reset, after: observedInputBaseline())
        hideWindows()
        if case .suspension(.screensAsleep) = reset {
            stateHandler?(.sleeping)
        } else {
            stateHandler?(.waiting)
        }
    }

    private func handleWorkspaceEvent(_ event: WorkspaceEvent) {
        guard watchMode else {
            switch event {
            case .reset(.suspension(.screensAsleep)):
                hideWindows()
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
            stateHandler?(
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
        hideWindows()
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

    static func validateSelection(selectedCount: Int, drawableCount: Int) throws {
        if selectedCount >= drawableCount { throw BlackoutError.allScreensSafety }
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
