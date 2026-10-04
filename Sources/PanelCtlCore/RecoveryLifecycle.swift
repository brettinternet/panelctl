import AppKit
import Foundation

/// No timers, writers or automatic disable actions. The helper supplies a
/// monotonic clock and fresh observations; RecoveryPrivateSession delivers events.
struct RecoveryLifecycle {
    enum Suspension: Hashable { case system, screens, session }
    enum Event { case suspend(Suspension), resume(Suspension), topologyChanged }
    enum WriteGate: Equatable {
        case ready, deferred, needsAttention
        func requireReady() throws {
            guard self == .ready else {
                throw RecoveryError.unsafe(self == .deferred
                    ? "sleep/wake state unsettled; defer writes"
                    : "sleep/wake observation unavailable or deferral exhausted; retain journal")
            }
        }
    }
    enum Action: Equatable {
        case none, deferWrites, needsAttention
        case requestGuardedRecovery(String)
        case reconcileSystemReenable(UInt32)
    }
    static let settleDelay: TimeInterval = 1
    static let maximumDeferral: TimeInterval = 5
    private(set) var revision: UInt64 = 0
    private(set) var disabledTargetID: UInt32?
    private(set) var disableConsumed = false
    private var suspensions: Set<Suspension> = []
    private var knownAwake: Bool
    private var lastEvent: TimeInterval
    private var deadline: TimeInterval?
    private var settledAt: TimeInterval

    init(now: TimeInterval, initiallyAwake: Bool = false) {
        lastEvent = now; settledAt = now
        knownAwake = initiallyAwake && now.isFinite && now >= 0
    }

    static func event(for notification: Notification.Name) -> Event? {
        switch notification {
        case NSWorkspace.willSleepNotification: return .suspend(.system)
        case NSWorkspace.didWakeNotification: return .resume(.system)
        case NSWorkspace.screensDidSleepNotification: return .suspend(.screens)
        case NSWorkspace.screensDidWakeNotification: return .resume(.screens)
        case NSWorkspace.sessionDidResignActiveNotification: return .suspend(.session)
        case NSWorkspace.sessionDidBecomeActiveNotification: return .resume(.session)
        case NSApplication.didChangeScreenParametersNotification: return .topologyChanged
        default: return nil
        }
    }

    mutating func receive(_ event: Event, now: TimeInterval) {
        let wasReady = writeGate(now: now) == .ready
        revision &+= 1
        guard now.isFinite, now >= lastEvent else { knownAwake = false; return }
        lastEvent = now
        // A recovered topology still invalidates selection (ABA protection).
        if case .topologyChanged = event { return }
        if wasReady { deadline = now + Self.maximumDeferral }
        settledAt = now + Self.settleDelay
        switch event {
        case .suspend(let reason): suspensions.insert(reason)
        case .resume(let reason): suspensions.remove(reason)
        case .topologyChanged: break
        }
        // A wake notification alone cannot establish the initial state or
        // clear a different outstanding suspension.
    }

    func writeGate(now: TimeInterval) -> WriteGate {
        guard knownAwake, now.isFinite, now >= lastEvent else { return .needsAttention }
        if let deadline {
            if suspensions.isEmpty && settledAt <= deadline && now >= settledAt { return .ready }
            if now >= deadline { return .needsAttention }
            return .deferred
        }
        return .ready
    }

    func requireDisableReady(now: TimeInterval) throws {
        try writeGate(now: now).requireReady()
        guard !disableConsumed else {
            throw RecoveryError.unsafe("disable intent already consumed; no automatic re-disconnection")
        }
    }

    /// Call only for this journal's durable successful staging/commit evidence;
    /// startup reconstruction must obey the same journal checks as recovery.
    mutating func didDisable(_ targetID: UInt32) {
        disableConsumed = true; disabledTargetID = targetID; revision &+= 1
    }

    mutating func observe(baseline: RecoverySnapshot, current: RecoverySnapshot,
                          identity: RecoveryEnableInventory,
                          environment: RecoveryEligibilityEnvironment,
                          now: TimeInterval) -> Action {
        switch writeGate(now: now) {
        case .deferred: return .deferWrites
        case .needsAttention: return .needsAttention
        case .ready: break
        }
        guard let targetID = disabledTargetID else { return .none }
        let binding = RecoveryIdentityPolicy.evaluate(snapshot: baseline, evidence: identity)
        guard binding.outcome == .eligible else {
            return .requestGuardedRecovery("identity eligibility lost: \(binding.diagnostic)")
        }
        let currentIDs = Set(current.displays.map(\.id))
        guard current.bootSession == baseline.bootSession, current.osBuild == baseline.osBuild,
              current.userID == baseline.userID, currentIDs.count == current.displays.count,
              identity.onlineIDs == currentIDs,
              Set(environment.screens.keys) == currentIDs,
              Set(environment.screens.filter { $0.value.online }.keys) == currentIDs else {
            return .requestGuardedRecovery("online and physical observations disagree")
        }
        if environment.architecture != .appleSilicon || environment.drivers != .nativeOnly ||
            environment.mirrored != false || current.displays.contains(where: { $0.mirrorUUID != nil }) {
            return .requestGuardedRecovery("platform, driver or mirror eligibility lost")
        }
        guard current.displays.allSatisfy({ display in
            environment.screens[display.id]?.kind != .unknown && baseline.displays.contains {
                RecoveryEnableIdentity($0) == RecoveryEnableIdentity(display)
            }
        }) else {
            return .requestGuardedRecovery("physical classification or current identity is unqualified")
        }
        if let target = current.displays.first(where: { $0.id == targetID }) {
            guard RecoveryEligibilityPolicy.unusableReasons(target, environment: environment).isEmpty else {
                return .requestGuardedRecovery("reappeared target is not verified usable")
            }
            // Retire local intent immediately. The caller must reconcile the
            // durable journal through RecoveryEngine before releasing locks.
            disabledTargetID = nil; revision &+= 1
            return .reconcileSystemReenable(targetID)
        }
        let survivors = current.displays.filter { display in
            display.id != targetID && RecoveryEligibilityPolicy.unusableReasons(display, environment: environment).isEmpty
        }
        if survivors.isEmpty {
            return .requestGuardedRecovery("remaining verified usable physical screen lost")
        }
        return .none
    }
}
