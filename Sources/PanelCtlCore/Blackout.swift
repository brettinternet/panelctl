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
        }
    }
}

struct IdleSample: Equatable {
    let seconds: TimeInterval
    let lastInputUptime: TimeInterval
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
    private var windows: [NSWindow] = []
    private var signalSources: [DispatchSourceSignal] = []
    private var screenObserver: NSObjectProtocol?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var assertion: CaffeinateAssertion?
    private var stopRequested = false
    private var intentionalDisplaySleep = false
    private var displayWakeObserved = false
    private let idleSource: IdleTimeSource
    private let uptime: () -> TimeInterval

    public convenience init() {
        self.init(
            idleSource: CombinedSessionIdleTimeSource(),
            uptime: { ProcessInfo.processInfo.systemUptime }
        )
    }

    init(idleSource: IdleTimeSource, uptime: @escaping () -> TimeInterval) {
        self.idleSource = idleSource
        self.uptime = uptime
    }

    public func run(options: BlackoutOptions) throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.finishLaunching()

        installSignals()
        installObservers()
        defer { stop() }

        let screens = NSScreen.screens
        let drawableScreens = screens.filter { Self.isValidScreenFrame($0.frame) }
        guard !drawableScreens.isEmpty else { throw BlackoutError.noScreens }
        let selected = try resolveScreens(options: options, screens: screens, drawableScreens: drawableScreens)
        if options.caffeinate { assertion = try CaffeinateAssertion() }

        let policy = BlackoutPolicy(
            idleAfter: options.idleAfter,
            timeout: options.timeout,
            sleepAfter: options.sleepAfter
        )
        guard let baseline = try waitUntilReady(policy: policy) else { return }
        if stopRequested { return }

        let currentSelection = try refreshSelection(selected, all: options.all)
        try showWindows(on: currentSelection)
        let startedAt = uptime()
        let installedSample = try idleSample()
        if policy.hasNewInput(installedSample, after: baseline.lastInputUptime) {
            return
        }

        while !stopRequested {
            try ensureCaffeinate()
            runLoopTick()
            if stopRequested { return }
            let sample = try idleSample()
            if policy.hasNewInput(sample, after: baseline.lastInputUptime) {
                return
            }
            if stopRequested { return }

            switch policy.limitAction(elapsed: uptime() - startedAt) {
            case .none:
                continue
            case .finish:
                return
            case .sleep:
                let finalSample = try idleSample()
                if stopRequested || policy.hasNewInput(finalSample, after: baseline.lastInputUptime) { return }
                hideWindows()
                intentionalDisplaySleep = true
                try DisplaySleepController.sleep()
                if assertion != nil {
                    try waitForDisplayWakeOrInput(after: finalSample.lastInputUptime)
                }
                return
            }
        }
    }

    private func resolveScreens(options: BlackoutOptions, screens: [NSScreen], drawableScreens: [NSScreen]) throws -> [NSScreen] {
        if options.all { return drawableScreens }

        let records = DisplayInventory.records()
        var selected: [NSScreen] = []
        for selector in options.selectors {
            guard let screen = match(selector, screens: screens, records: records) else {
                throw BlackoutError.unknownSelector(selector)
            }
            guard Self.isValidScreenFrame(screen.frame) else {
                throw BlackoutError.nonDrawable(selector)
            }
            if let number = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value {
                try Self.validateTarget(isMirrored: CGDisplayIsInMirrorSet(number) != 0, selector: selector)
            }
            guard !selected.contains(where: { $0 === screen }) else { continue }
            selected.append(screen)
        }
        guard !selected.isEmpty else { throw BlackoutError.noScreens }
        try Self.validateSelection(selectedCount: selected.count, drawableCount: drawableScreens.count)
        return selected
    }

    private func refreshSelection(_ original: [NSScreen], all: Bool) throws -> [NSScreen] {
        let originalIDs = original.compactMap(Self.screenID)
        guard originalIDs.count == original.count else { throw BlackoutError.topologyChanged }

        let currentDrawable = NSScreen.screens.filter { Self.isValidScreenFrame($0.frame) }
        var currentByID: [CGDirectDisplayID: NSScreen] = [:]
        for screen in currentDrawable {
            guard let id = Self.screenID(screen), currentByID[id] == nil else {
                throw BlackoutError.topologyChanged
            }
            currentByID[id] = screen
        }
        guard originalIDs.allSatisfy({ currentByID[$0] != nil }) else {
            throw BlackoutError.topologyChanged
        }
        if all, Set(originalIDs) != Set(currentByID.keys) {
            throw BlackoutError.topologyChanged
        }
        return originalIDs.compactMap { currentByID[$0] }
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
    }

    private func waitUntilReady(policy: BlackoutPolicy) throws -> IdleSample? {
        while !stopRequested {
            try ensureCaffeinate()
            let sample = try idleSample()
            if policy.shouldBegin(idleSeconds: sample.seconds) { return sample }
            runLoopTick()
        }
        return nil
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
        return IdleSample(seconds: seconds, lastInputUptime: now - seconds)
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
            self?.requestStop()
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
                self?.requestStop()
            })
        }
        workspaceObservers.append(center.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.hideWindows()
            if !self.intentionalDisplaySleep { self.stopRequested = true }
        })
        workspaceObservers.append(center.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            if self.intentionalDisplaySleep {
                self.displayWakeObserved = true
            } else {
                self.requestStop()
            }
        })
    }

    private func requestStop() {
        stopRequested = true
        hideWindows()
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

    private func match(_ selector: String, screens: [NSScreen], records: [DisplayRecord]) -> NSScreen? {
        guard let record = DisplaySelector.resolve(selector, in: records) else { return nil }
        return screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == record.id
        }
    }
}
