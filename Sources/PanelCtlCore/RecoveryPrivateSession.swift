import AppKit
import Foundation

/// Main-run-loop adapter for the existing pure lifecycle/eligibility policy.
/// Production providers deliberately refuse: CG flags/cache/HPD do not qualify
/// a physical sink. No flag, journal field or environment variable upgrades them.
final class RecoveryPrivateSession {
    let snapshot: RecoverySnapshot
    var capture: () throws -> RecoverySnapshot
    var inventory: () throws -> RecoveryEnableInventory
    var environment: () throws -> RecoveryEligibilityEnvironment
    var transaction: () throws -> RecoveryEnableTransaction
    var apply: (RecoverySnapshot, () throws -> Void) throws -> Void
    var now: () -> TimeInterval
    private(set) var lifecycle: RecoveryLifecycle
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []

    init(snapshot: RecoverySnapshot,
         capture: @escaping () throws -> RecoverySnapshot = { try .capture() },
         inventory: @escaping () throws -> RecoveryEnableInventory = {
             throw RecoveryError.unsafe("unsupported: no qualified fresh physical-sink binding; private display control unavailable")
         },
         environment: @escaping () throws -> RecoveryEligibilityEnvironment = { RecoveryEligibilityEnvironment() },
         transaction: @escaping () throws -> RecoveryEnableTransaction = { try RecoveryDisplayBinding.resolve().transaction() },
         apply: @escaping (RecoverySnapshot, () throws -> Void) throws -> Void = { try RecoveryConfiguration.restore($0, revalidate: $1) },
         now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         initiallyAwake: Bool = false) {
        self.snapshot = snapshot; self.capture = capture; self.inventory = inventory
        self.environment = environment; self.transaction = transaction; self.apply = apply; self.now = now
        lifecycle = RecoveryLifecycle(now: now(), initiallyAwake: initiallyAwake)
    }

    deinit { for (center, observer) in observers { center.removeObserver(observer) } }

    func observeNotifications() {
        guard observers.isEmpty else { return }
        let workspace = NSWorkspace.shared.notificationCenter
        let names = [NSWorkspace.willSleepNotification, NSWorkspace.didWakeNotification,
                     NSWorkspace.screensDidSleepNotification, NSWorkspace.screensDidWakeNotification,
                     NSWorkspace.sessionDidResignActiveNotification, NSWorkspace.sessionDidBecomeActiveNotification]
        for (center, name) in names.map({ (workspace, $0) }) + [(NotificationCenter.default, NSApplication.didChangeScreenParametersNotification)] {
            let observer = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                guard let self, let event = RecoveryLifecycle.event(for: note.name) else { return }
                self.receive(event)
            }
            observers.append((center, observer))
        }
    }

    func receive(_ event: RecoveryLifecycle.Event) { lifecycle.receive(event, now: now()) }
    var gate: RecoveryLifecycle.WriteGate { lifecycle.writeGate(now: now()) }

    func prepareDisable(targetID: UInt32) throws -> RecoveryDisable {
        let selection = try RecoveryEligibilitySelection(snapshot: snapshot, targetID: targetID,
            identity: inventory(), environment: environment(), lifecycle: lifecycle, now: now())
        return RecoveryDisable(transaction: try transaction(), inventory: inventory, preflight: { [self] current, target in
            try selection.validate(current: current, targetID: target, identity: inventory(),
                environment: environment(), lifecycle: lifecycle, now: now())
        })
    }

    func didDisable(_ id: UInt32) { lifecycle.didDisable(id) }

    func check() throws -> RecoveryLifecycle.Action {
        // Do not even sample a changing topology while sleep/wake is unsettled.
        switch gate {
        case .deferred: return .deferWrites
        case .needsAttention: return .needsAttention
        case .ready: break
        }
        return try lifecycle.observe(baseline: snapshot, current: capture(), identity: inventory(),
            environment: environment(), now: now())
    }

    var engine: RecoveryEngine {
        RecoveryEngine(capture: capture, apply: { [self] snapshot in
            try apply(snapshot) { try self.gate.requireReady() }
        }, reenable: RecoveryReenable(inventory: inventory, enable: { [self] id, validate in
            try gate.requireReady()
            let writer = try transaction()
            try writer.enable(id: id) {
                try self.gate.requireReady()
                try validate()
            }
        }), writeGate: { [self] in try gate.requireReady() })
    }
}
