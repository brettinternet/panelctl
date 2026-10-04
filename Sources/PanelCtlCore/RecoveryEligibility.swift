import Foundation

/// Fresh provider observations, never journal authority. DisplayInventory's CG
/// flags alone cannot supply physical classification or a clean driver state.
struct RecoveryEligibilityEnvironment: Equatable {
    enum Architecture { case appleSilicon, intel, unknown }
    enum Drivers { case nativeOnly, displayLink, virtual, unknown }
    enum Lid { case open, closed, notApplicable, unknown }
    enum PhysicalKind: String { case physical, virtual, headless, displayLink, unknown }
    struct Screen: Equatable {
        var kind: PhysicalKind = .unknown
        var online = false
        var active = false
        var awake = false
    }
    var architecture: Architecture = .unknown
    var drivers: Drivers = .unknown
    var lid: Lid = .unknown
    // nil means the provider could not establish the mirror topology.
    var mirrored: Bool? = nil
    var screens: [UInt32: Screen] = [:]
}

struct RecoveryEligibilityDecision {
    let refusals: [String]
    let usableSurvivors: Set<UInt32>
    var eligible: Bool { refusals.isEmpty }

    func requireEligible() throws {
        guard eligible else { throw RecoveryError.unsafe(refusals.joined(separator: "; ")) }
    }
}

enum RecoveryEligibilityPolicy {
    static func unusableReasons(_ display: RecoveryDisplay,
                                environment: RecoveryEligibilityEnvironment) -> [String] {
        guard let screen = environment.screens[display.id] else {
            return ["display \(display.id): missing physical observation"]
        }
        var reasons: [String] = []
        if screen.kind != .physical { reasons.append("classification is \(screen.kind.rawValue)") }
        if !screen.online { reasons.append("offline") }
        if !screen.active || !display.active { reasons.append("inactive") }
        if !screen.awake { reasons.append("asleep or wake state unknown") }
        if display.mode.width <= 0 || display.mode.height <= 0 {
            reasons.append("no usable mode")
        }
        if display.builtin && environment.lid != .open && environment.lid != .notApplicable {
            reasons.append("built-in lid is closed or unknown")
        }
        return reasons.map { "display \(display.id): \($0)" }
    }

    static func evaluate(snapshot: RecoverySnapshot, targetID: UInt32,
                         identity: RecoveryEnableInventory,
                         environment: RecoveryEligibilityEnvironment) -> RecoveryEligibilityDecision {
        var reasons: [String] = []
        let binding = RecoveryIdentityPolicy.evaluate(snapshot: snapshot, evidence: identity)
        if binding.outcome != .eligible { reasons.append("\(binding.outcome.rawValue): \(binding.diagnostic)") }
        if environment.architecture != .appleSilicon { reasons.append("Apple Silicon required") }
        if environment.drivers != .nativeOnly { reasons.append("DisplayLink, virtual or unknown driver state") }
        if environment.mirrored != false || snapshot.displays.contains(where: { $0.mirrorUUID != nil }) {
            reasons.append("mirrored or unknown mirror topology")
        }
        let ids = Set(snapshot.displays.map(\.id))
        if ids != Set(environment.screens.keys) || identity.onlineIDs != ids ||
            ids != Set(environment.screens.filter { $0.value.online }.keys) {
            reasons.append("physical observations and online snapshot disagree")
        }
        // Unknown classification anywhere cannot be treated as benign just
        // because another screen would suffice.
        for display in snapshot.displays where environment.screens[display.id]?.kind == .unknown {
            reasons.append("display \(display.id): unknown physical classification")
        }
        if let target = snapshot.displays.first(where: { $0.id == targetID }), targetID != 0 {
            if target.main { reasons.append("main display cannot be disabled") }
            if target.builtin { reasons.append("built-in display cannot be disabled") }
            reasons += unusableReasons(target, environment: environment)
        } else { reasons.append("exactly one retained target must be present") }
        let others = snapshot.displays.filter { $0.id != targetID }
        let survivors = Set(others.filter { unusableReasons($0, environment: environment).isEmpty }.map(\.id))
        if survivors.isEmpty {
            reasons.append("no other verified usable physical screen")
            reasons += others.flatMap { unusableReasons($0, environment: environment) }
        }
        return RecoveryEligibilityDecision(refusals: reasons, usableSurvivors: survivors)
    }
}

/// Process-local selection, not a serializable authorization token. Revalidate
/// in RecoveryDisable.preflight at every transaction boundary with fresh reads.
struct RecoveryEligibilitySelection {
    let snapshot: RecoverySnapshot
    let targetID: UInt32
    let environment: RecoveryEligibilityEnvironment
    let revision: UInt64

    init(snapshot: RecoverySnapshot, targetID: UInt32, identity: RecoveryEnableInventory,
         environment: RecoveryEligibilityEnvironment, lifecycle: RecoveryLifecycle, now: TimeInterval) throws {
        try lifecycle.requireDisableReady(now: now)
        try RecoveryEligibilityPolicy.evaluate(snapshot: snapshot, targetID: targetID,
            identity: identity, environment: environment).requireEligible()
        self.snapshot = snapshot; self.targetID = targetID
        self.environment = environment; revision = lifecycle.revision
    }

    func validate(current: RecoverySnapshot, targetID: UInt32, identity: RecoveryEnableInventory,
                  environment: RecoveryEligibilityEnvironment, lifecycle: RecoveryLifecycle,
                  now: TimeInterval) throws {
        try lifecycle.requireDisableReady(now: now)
        guard targetID == self.targetID, revision == lifecycle.revision, environment == self.environment else {
            throw RecoveryError.unsafe("selection invalidated by topology, eligibility or lifecycle change; select again explicitly")
        }
        try snapshot.verify(current)
        try RecoveryEligibilityPolicy.evaluate(snapshot: current, targetID: targetID,
            identity: identity, environment: environment).requireEligible()
    }
}
