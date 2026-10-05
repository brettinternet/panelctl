import AppKit
import Foundation

/// Main-run-loop adapter for the read-only provider observations and pure
/// lifecycle/eligibility policy. Every writer boundary refreshes synchronously.
final class RecoveryPrivateSession {
    let snapshot: RecoverySnapshot
    var capture: () throws -> RecoverySnapshot
    var inventory: () throws -> RecoveryEnableInventory
    var environment: () throws -> RecoveryEligibilityEnvironment
    var restorationEnvironment: () throws -> RecoveryEligibilityEnvironment
    var transaction: () throws -> RecoveryEnableTransaction
    var apply: (RecoverySnapshot, () throws -> Void) throws -> Void
    var lifecycleObservation: () throws -> RecoveryProductionProviders.LifecycleObservation
    var now: () -> TimeInterval
    private(set) var lifecycle: RecoveryLifecycle
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []

    init(snapshot: RecoverySnapshot,
         capture: @escaping () throws -> RecoverySnapshot = { try .capture() },
         inventory: (() throws -> RecoveryEnableInventory)? = nil,
         environment: (() throws -> RecoveryEligibilityEnvironment)? = nil,
         transaction: @escaping () throws -> RecoveryEnableTransaction = { try RecoveryDisplayBinding.resolve().transaction() },
         apply: @escaping (RecoverySnapshot, () throws -> Void) throws -> Void = { try RecoveryConfiguration.restore($0, revalidate: $1) },
         lifecycleObservation: (() throws -> RecoveryProductionProviders.LifecycleObservation)? = nil,
         now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         initiallyAwake: Bool? = nil) {
        self.snapshot = snapshot
        self.capture = capture
        self.inventory = inventory ?? { try RecoveryProductionProviders.identityInventory(for: snapshot) }
        self.environment = environment ?? {
            try RecoveryProductionProviders.eligibilityEnvironment(current: capture())
        }
        self.restorationEnvironment = environment ?? {
            RecoveryProductionProviders.restorationEnvironment(current: try capture())
        }
        self.transaction = transaction; self.apply = apply; self.now = now
        let observeLifecycle = lifecycleObservation ?? {
            if let initiallyAwake {
                return RecoveryProductionProviders.LifecycleObservation(awake: initiallyAwake,
                    lid: .unknown, diagnostic: "injected lifecycle observation")
            }
            return RecoveryProductionProviders.lifecycleObservation()
        }
        self.lifecycleObservation = observeLifecycle
        let initiallyObservedAwake = initiallyAwake ?? ((try? observeLifecycle().awake) == true)
        lifecycle = RecoveryLifecycle(now: now(), initiallyAwake: initiallyObservedAwake)
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

    private func refreshLifecycle() throws {
        // Do not sample changing system/display state during a bounded suspend
        // interval; retain the prior readiness until a matching resume settles.
        if gate == .deferred { try gate.requireReady() }
        let observation = try lifecycleObservation()
        lifecycle.refreshAwakeObservation(observation.awake, now: now())
        try gate.requireReady()
    }

    var gate: RecoveryLifecycle.WriteGate { lifecycle.writeGate(now: now()) }

    func prepareDisable(targetID: UInt32) throws -> RecoveryDisable {
        try refreshLifecycle()
        let initial = try capture()
        try snapshot.verify(initial)
        let selection = try RecoveryEligibilitySelection(snapshot: snapshot, targetID: targetID,
            identity: inventory(), environment: environment(), lifecycle: lifecycle, now: now())
        func validate(_ current: RecoverySnapshot) throws {
            try refreshLifecycle()
            try selection.validate(current: current, targetID: targetID, identity: inventory(),
                environment: environment(), lifecycle: lifecycle, now: now())
        }
        // Close the observation-to-construction gap before resolving the writer.
        try validate(capture())
        let writer = try transaction()
        return RecoveryDisable(transaction: writer, inventory: inventory, preflight: { current, target in
            guard target == targetID else { throw RecoveryError.unsafe("selected target changed") }
            try validate(current)
        })
    }

    func didDisable(_ id: UInt32) { lifecycle.didDisable(id) }

    func check() throws -> RecoveryLifecycle.Action {
        if gate == .deferred { return .deferWrites }
        try refreshLifecycle()
        let current = try capture()
        return try lifecycle.observe(baseline: snapshot, current: current, identity: inventory(),
            environment: environment(), now: now())
    }

    private func validateMutationBoundary(snapshot baseline: RecoverySnapshot, current: RecoverySnapshot,
                                          allowMissingTarget: Bool, requirePrivateIdentity: Bool) throws {
        try refreshLifecycle()
        let latest = try capture()
        do { try current.verify(latest) }
        catch { throw RecoveryError.unsafe("current topology changed at recovery boundary: \(error)") }
        let onlineIDs = Set(current.displays.map(\.id))
        let retainedIDs = Set(baseline.displays.map(\.id))
        guard onlineIDs.isSubset(of: retainedIDs) else {
            throw RecoveryError.unsafe("new or reused online display identity; retain journal and recover manually")
        }
        let remaining = RecoverySnapshot(bootSession: baseline.bootSession, osBuild: baseline.osBuild,
            userID: baseline.userID, displays: baseline.displays.filter { onlineIDs.contains($0.id) },
            hostModel: baseline.hostModel)
        do { try remaining.validateRestoration(to: current) }
        catch { throw RecoveryError.unsafe("remaining topology changed at recovery boundary: \(error)") }
        if !allowMissingTarget { try baseline.validateRestoration(to: current) }

        if requirePrivateIdentity {
            let evidence = try inventory()
            try RecoveryIdentityPolicy.evaluate(snapshot: baseline, evidence: evidence).requireEligible()
            guard evidence.onlineIDs == onlineIDs else {
                throw RecoveryError.unsafe("identity inventory changed at recovery boundary")
            }
        }
        let observed = try (requirePrivateIdentity ? environment() : restorationEnvironment())
        guard Set(observed.screens.keys) == onlineIDs,
              Set(observed.screens.filter { $0.value.online }.keys) == onlineIDs else {
            throw RecoveryError.unsafe("current online screen inventory is incomplete at recovery boundary")
        }
        if !requirePrivateIdentity, observed.screens.values.contains(where: { !$0.awake }) {
            throw RecoveryError.unsafe("a current screen is asleep or its awake state is unknown at the recovery boundary")
        }
        if requirePrivateIdentity {
            guard observed.architecture == .appleSilicon, observed.drivers == .nativeOnly,
                  observed.mirrored == false else {
                throw RecoveryError.unsafe("platform, driver or mirror state is unknown at recovery boundary")
            }
            for display in current.displays {
                guard RecoveryEligibilityPolicy.unusableReasons(display, environment: observed).isEmpty else {
                    throw RecoveryError.unsafe("display \(display.id) is not currently verified usable")
                }
            }
            if allowMissingTarget, onlineIDs.count < baseline.displays.count,
               !current.displays.contains(where: { display in
                   RecoveryEligibilityPolicy.unusableReasons(display, environment: observed).isEmpty
               }) {
                throw RecoveryError.unsafe("no currently verified physical survivor")
            }
        }
    }

    var engine: RecoveryEngine { makeEngine(requiresPrivateIdentity: true) }

    func makeEngine(requiresPrivateIdentity: Bool) -> RecoveryEngine {
        let reenable: RecoveryReenable? = requiresPrivateIdentity ? RecoveryReenable(inventory: inventory,
            enable: { [self] id, validate in
                try validateMutationBoundary(snapshot: snapshot, current: capture(), allowMissingTarget: true,
                                             requirePrivateIdentity: true)
                let writer = try transaction()
                try writer.enable(id: id) {
                    try validate()
                    try validateMutationBoundary(snapshot: snapshot, current: capture(), allowMissingTarget: true,
                                                 requirePrivateIdentity: true)
                }
            }, preflight: { [self] baseline, current in
                try validateMutationBoundary(snapshot: baseline, current: current, allowMissingTarget: true,
                                             requirePrivateIdentity: true)
            }) : nil
        return RecoveryEngine(capture: capture, apply: { [self] baseline in
            try apply(baseline) {
                try validateMutationBoundary(snapshot: baseline, current: capture(), allowMissingTarget: false,
                                             requirePrivateIdentity: requiresPrivateIdentity)
            }
        }, reenable: reenable, writeGate: { [self] in
            try validateMutationBoundary(snapshot: snapshot, current: capture(), allowMissingTarget: true,
                                         requirePrivateIdentity: requiresPrivateIdentity)
        })
    }
}
