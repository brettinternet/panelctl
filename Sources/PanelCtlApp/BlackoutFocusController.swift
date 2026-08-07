import AppKit
import CoreGraphics

func isBlackoutRestoreKey(_ event: NSEvent) -> Bool {
    event.type == .keyDown &&
        !event.isARepeat &&
        event.keyCode == 53 &&
        event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty
}

private final class BlackoutFocusProxyWindow: NSWindow {
    private let onRestore: () -> Void

    init(onRestore: @escaping () -> Void) {
        self.onRestore = onRestore
        super.init(
            contentRect: CGRect(x: -10_000, y: -10_000, width: 1, height: 1),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
    }

    override var canBecomeKey: Bool { true }

    override func keyDown(with event: NSEvent) {
        guard isBlackoutRestoreKey(event) else {
            super.keyDown(with: event)
            return
        }
        onRestore()
    }
}

final class BlackoutFocusWindow {
    private let showOperation: () -> Void
    private let closeOperation: () -> Void

    init(show: @escaping () -> Void, close: @escaping () -> Void) {
        showOperation = show
        closeOperation = close
    }

    func show() { showOperation() }
    func close() { closeOperation() }
}

struct BlackoutPreviousApplication {
    let processIdentifier: pid_t
    let isRunning: () -> Bool
    let yieldActivation: () -> Void
    let activate: () -> Bool

    init(
        processIdentifier: pid_t,
        isRunning: @escaping () -> Bool,
        yieldActivation: @escaping () -> Void = {},
        activate: @escaping () -> Bool
    ) {
        self.processIdentifier = processIdentifier
        self.isRunning = isRunning
        self.yieldActivation = yieldActivation
        self.activate = activate
    }
}

struct BlackoutFocusOperations {
    let currentProcessIdentifier: pid_t
    let frontmostApplication: () -> BlackoutPreviousApplication?
    let makeProxyWindow: (@escaping () -> Void) -> BlackoutFocusWindow
    let requestActivation: () -> Void
    let panelIsActive: () -> Bool
    let mouseLocation: () -> CGPoint
    let hideCursor: () -> CGError
    let showCursor: () -> CGError
    let schedule: (@escaping () -> Void) -> Void
    let activationTimeout: TimeInterval

    init(
        currentProcessIdentifier: pid_t = NSRunningApplication.current.processIdentifier,
        frontmostApplication: @escaping () -> BlackoutPreviousApplication? = BlackoutFocusOperations.defaultFrontmostApplication,
        makeProxyWindow: @escaping (@escaping () -> Void) -> BlackoutFocusWindow = BlackoutFocusOperations.defaultProxyWindow,
        requestActivation: @escaping () -> Void = { NSApp.activate(ignoringOtherApps: true) },
        panelIsActive: @escaping () -> Bool = { NSApp.isActive },
        mouseLocation: @escaping () -> CGPoint = { NSEvent.mouseLocation },
        hideCursor: @escaping () -> CGError = { CGDisplayHideCursor(CGMainDisplayID()) },
        showCursor: @escaping () -> CGError = { CGDisplayShowCursor(CGMainDisplayID()) },
        schedule: @escaping (@escaping () -> Void) -> Void = { callback in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.01, execute: callback)
        },
        activationTimeout: TimeInterval = 0.5
    ) {
        self.currentProcessIdentifier = currentProcessIdentifier
        self.frontmostApplication = frontmostApplication
        self.makeProxyWindow = makeProxyWindow
        self.requestActivation = requestActivation
        self.panelIsActive = panelIsActive
        self.mouseLocation = mouseLocation
        self.hideCursor = hideCursor
        self.showCursor = showCursor
        self.schedule = schedule
        self.activationTimeout = activationTimeout
    }

    private static func defaultFrontmostApplication() -> BlackoutPreviousApplication? {
        guard let application = NSWorkspace.shared.frontmostApplication else { return nil }
        return BlackoutPreviousApplication(
            processIdentifier: application.processIdentifier,
            isRunning: { !application.isTerminated },
            yieldActivation: {
                if #available(macOS 14.0, *) { NSApp.yieldActivation(to: application) }
            },
            activate: { application.activate(options: []) }
        )
    }

    private static func defaultProxyWindow(
        onRestore: @escaping () -> Void
    ) -> BlackoutFocusWindow {
        let window = BlackoutFocusProxyWindow(onRestore: onRestore)
        window.level = .floating
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false
        return BlackoutFocusWindow(
            show: {
                window.orderFrontRegardless()
                window.makeKeyAndOrderFront(nil)
            },
            close: {
                window.orderOut(nil)
                window.close()
            }
        )
    }
}

@MainActor
final class BlackoutFocusController {
    private let operations: BlackoutFocusOperations
    private var proxyWindow: BlackoutFocusWindow?
    private var previousApplication: BlackoutPreviousApplication?
    private var cursorHidden = false
    private var ownsActivation = false
    private var activationDeadline = Date.distantPast
    private var willResignObserver: NSObjectProtocol?
    private let requestRestore: () -> Bool
    private var escapeRestoreInFlight = false

    var isEngaged: Bool { proxyWindow != nil || ownsActivation }

    init(
        operations: BlackoutFocusOperations = BlackoutFocusOperations(),
        requestRestore: @escaping () -> Bool = { false }
    ) {
        self.operations = operations
        self.requestRestore = requestRestore
        willResignObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleWillResignActive() }
        }
    }

    deinit {
        if let willResignObserver { NotificationCenter.default.removeObserver(willResignObserver) }
    }

    func enter(targetFrames: [CGRect]) {
        let cursorIsInsideTarget = targetFrames.contains { $0.contains(operations.mouseLocation()) }
        if proxyWindow != nil, !cursorIsInsideTarget {
            leave()
            return
        }
        guard proxyWindow == nil, cursorIsInsideTarget else { return }
        previousApplication = operations.frontmostApplication().flatMap {
            $0.processIdentifier == operations.currentProcessIdentifier ? nil : $0
        }
        let window = operations.makeProxyWindow { [weak self] in
            self?.restoreFromEscape()
        }
        proxyWindow = window
        window.show()
        operations.requestActivation()
        activationDeadline = Date(timeIntervalSinceNow: operations.activationTimeout)
        waitForActivation()
    }

    func leave() {
        guard restoreCursor() else {
            operations.schedule { [weak self] in self?.leave() }
            return
        }
        proxyWindow?.close()
        proxyWindow = nil
        let wasOwned = ownsActivation
        ownsActivation = false
        escapeRestoreInFlight = false
        restorePreviousApplicationIfOwned(wasOwned: wasOwned)
    }

    func shutdown() { leave() }

    private func waitForActivation() {
        guard proxyWindow != nil else { return }
        guard !operations.panelIsActive() else {
            ownsActivation = true
            if operations.hideCursor() == .success { cursorHidden = true }
            return
        }
        guard Date() < activationDeadline else {
            leave()
            return
        }
        operations.schedule { [weak self] in self?.waitForActivation() }
    }

    private func handleWillResignActive() {
        guard ownsActivation else { return }
        _ = restoreCursor()
        ownsActivation = false
    }

    private func restoreFromEscape() {
        guard ownsActivation, !escapeRestoreInFlight, requestRestore() else { return }
        escapeRestoreInFlight = true
    }

    private func restoreCursor() -> Bool {
        guard cursorHidden else { return true }
        if operations.showCursor() == .success { cursorHidden = false }
        return !cursorHidden
    }

    private func restorePreviousApplicationIfOwned(wasOwned: Bool) {
        guard let previousApplication else { return }
        self.previousApplication = nil
        guard wasOwned, operations.panelIsActive(), previousApplication.isRunning() else { return }
        previousApplication.yieldActivation()
        if !previousApplication.activate() { self.previousApplication = previousApplication }
    }
}
