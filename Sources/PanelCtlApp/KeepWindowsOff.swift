import CoreGraphics
import Foundation
import PanelCtlCore

@MainActor
protocol KeepWindowsOffTick: AnyObject {
    func cancel()
}

@MainActor
protocol KeepWindowsOffScheduling {
    func scheduleRepeating(every interval: TimeInterval, action: @escaping @MainActor () -> Void) -> KeepWindowsOffTick
}

@MainActor
final class MainRunLoopKeepWindowsOffScheduler: KeepWindowsOffScheduling {
    private final class TimerTick: KeepWindowsOffTick {
        private var timer: Timer?

        init(timer: Timer) { self.timer = timer }

        func cancel() {
            timer?.invalidate()
            timer = nil
        }
    }

    func scheduleRepeating(every interval: TimeInterval, action: @escaping @MainActor () -> Void) -> KeepWindowsOffTick {
        let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in
            Task { @MainActor in action() }
        }
        return TimerTick(timer: timer)
    }
}

/// Keep-off intent of one active blackout Hide. Session-only: it ends with
/// that Hide and is never restored on relaunch.
struct KeepWindowsOffCover: Equatable {
    var configuration: MoveWindowsConfiguration
    var pausedByUser = false
}

struct KeepWindowsOffStatus: Equatable {
    enum State: Equatable {
        case off
        case armed
        case enforcing
        case paused(String)
    }

    let state: State
    let lastMoved: Int
    let lastFailed: Int

    init(state: State, lastMoved: Int = 0, lastFailed: Int = 0) {
        self.state = state
        self.lastMoved = max(0, lastMoved)
        self.lastFailed = max(0, lastFailed)
    }

    var label: String {
        switch state {
        case .off: return "Off"
        case .armed: return "Armed"
        case .enforcing: return "Enforcing"
        case .paused: return "Paused"
        }
    }

    var reason: String? {
        if case .paused(let reason) = state { return reason }
        return nil
    }

    var controlStatus: AppControlWindowEnforcementStatus {
        let controlState: AppControlWindowEnforcementState
        switch state {
        case .off: controlState = .off
        case .armed: controlState = .armed
        case .enforcing: controlState = .enforcing
        case .paused: controlState = .paused
        }
        return AppControlWindowEnforcementStatus(
            state: controlState, reason: reason, lastMoved: lastMoved, lastFailed: lastFailed
        )
    }

    var description: String {
        var value = "Keep windows off: \(label)"
        if let reason { value += " · \(reason)" }
        if state != .off { value += " · last pass: \(lastMoved) moved, \(lastFailed) failed" }
        return value
    }
}

@MainActor
final class KeepWindowsOffDisplayController {
    static let maximumWritesPerPass = 64

    private struct Retry {
        var attempts: Int
        var nextAttempt: TimeInterval
    }

    let uuid: String
    var moveConfiguration: MoveWindowsConfiguration?
    private(set) var status = KeepWindowsOffStatus(state: .off)
    var task: Task<Void, Never>?
    private(set) var generation: UInt64 = 0
    private var retries: [WindowMoveWindowKey: Retry] = [:]
    private var previousFrameByWindow: [WindowMoveWindowKey: CGRect] = [:]
    private var movedToFrameByWindow: [WindowMoveWindowKey: CGRect] = [:]
    private var returningWindows = Set<WindowMoveWindowKey>()
    private var observedThisPass = Set<WindowMoveWindowKey>()
    private let now: () -> TimeInterval

    init(uuid: String, now: @escaping () -> TimeInterval) {
        self.uuid = uuid.lowercased()
        self.now = now
    }

    func update(_ newStatus: KeepWindowsOffStatus) {
        status = newStatus
    }

    func beginEnforcementSession() {
        generation &+= 1
        retries.removeAll()
        previousFrameByWindow.removeAll()
        movedToFrameByWindow.removeAll()
        returningWindows.removeAll()
        observedThisPass.removeAll()
    }

    func cancel() {
        generation &+= 1
        task?.cancel()
        task = nil
        retries.removeAll()
        previousFrameByWindow.removeAll()
        movedToFrameByWindow.removeAll()
        returningWindows.removeAll()
        observedThisPass.removeAll()
    }

    func observe(_ windows: [WindowMoveObservedWindow]) {
        for window in windows {
            let key = window.key
            observedThisPass.insert(key)
            if !window.isOnSourceDisplay {
                retries.removeValue(forKey: key)
                returningWindows.remove(key)
                if movedToFrameByWindow[key] != nil { movedToFrameByWindow[key] = window.frame }
            }
        }
    }

    func shouldAttempt(_ key: WindowMoveWindowKey, frame: CGRect, mouseButtonPressed: Bool) -> Bool {
        observedThisPass.insert(key)
        let previous = previousFrameByWindow[key]
        previousFrameByWindow[key] = frame
        if mouseButtonPressed, let previous, previous != frame {
            scheduleRetry(for: key)
            return false
        }
        if let movedFrame = movedToFrameByWindow[key], !sameFrame(movedFrame, frame), !returningWindows.contains(key) {
            returningWindows.insert(key)
            scheduleRetry(for: key)
            return false
        }
        return retries[key].map { $0.nextAttempt <= now() } ?? true
    }

    func didFinish(_ key: WindowMoveWindowKey, frame: CGRect, result: WindowMoveWriteResult) {
        switch result {
        case .verified:
            movedToFrameByWindow[key] = frame
            returningWindows.remove(key)
        case .failed, .unverified, .timedOut, .partiallyApplied:
            scheduleRetry(for: key)
        case .vanished:
            retries.removeValue(forKey: key)
            movedToFrameByWindow.removeValue(forKey: key)
            returningWindows.remove(key)
        case .refused:
            break
        }
    }

    func finishPass() {
        retries = retries.filter { observedThisPass.contains($0.key) }
        previousFrameByWindow = previousFrameByWindow.filter { observedThisPass.contains($0.key) }
        movedToFrameByWindow = movedToFrameByWindow.filter { observedThisPass.contains($0.key) }
        returningWindows.formIntersection(observedThisPass)
        observedThisPass.removeAll()
    }

    private func sameFrame(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        abs(lhs.minX - rhs.minX) <= 1 && abs(lhs.minY - rhs.minY) <= 1 &&
            abs(lhs.width - rhs.width) <= 1 && abs(lhs.height - rhs.height) <= 1
    }

    private func scheduleRetry(for key: WindowMoveWindowKey) {
        let attempts = (retries[key]?.attempts ?? 0) + 1
        let delay: TimeInterval
        switch attempts {
        case 1: delay = 1
        case 2: delay = 2
        case 3: delay = 4
        case 4: delay = 8
        case 5: delay = 16
        default: delay = 30
        }
        retries[key] = Retry(attempts: attempts, nextAttempt: now() + delay)
    }
}
