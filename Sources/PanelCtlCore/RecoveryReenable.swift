import Foundation
import CoreGraphics

/// An offline provider must independently establish these bindings, not merely
/// return cached CG metadata for a saved numeric ID. No such provider is yet
/// qualified on this host. This inventory is deliberately not journal data.
struct RecoveryEnableIdentity: Equatable {
    let uuid: String
    let id: UInt32
    let vendor: UInt32
    let model: UInt32
    let serial: UInt32
    let builtin: Bool
    let connector: String?

    init(_ display: RecoveryDisplay) {
        uuid = display.uuid; id = display.id; vendor = display.vendor
        model = display.model; serial = display.serial
        builtin = display.builtin; connector = display.connector
    }
}

struct RecoveryEnableInventory {
    let bootSession: String
    let osBuild: String
    let userID: UInt32
    let identities: [RecoveryEnableIdentity]
    let onlineIDs: Set<UInt32>
    enum Binding { case unqualified, stale, syntheticPhysicalFixture }
    var binding: Binding = .unqualified
}

/// Internal, injection-only recovery seam. The default engine has no backend;
/// both the identity provider and transport refuse by default. The branch's
/// verified binding remains disconnected; no user flag bypasses these boundaries.
struct RecoveryReenable {
    var inventory: () throws -> RecoveryEnableInventory = {
        throw RecoveryError.unsafe("offline hardware-to-CG-ID binding is unqualified; private re-enable unavailable")
    }
    var enable: (UInt32, () throws -> Void) throws -> Void = { _, _ in
        throw RecoveryError.unsafe("private transport unavailable until the verified backend gates pass")
    }

    func target(snapshot: RecoverySnapshot, current: RecoverySnapshot) throws -> RecoveryDisplay {
        // Validate the remaining online displays with the existing strict rules.
        let missing = snapshot.displays.filter { original in
            !current.displays.contains { $0.uuid == original.uuid }
        }
        guard missing.count == 1, let target = missing.first,
              !target.main, !target.builtin, target.active, target.mirrorUUID == nil,
              snapshot.displays.allSatisfy({ $0.mirrorUUID == nil }) else {
            throw RecoveryError.unsafe("re-enable requires exactly one missing non-main external display and no mirrors")
        }
        let remaining = RecoverySnapshot(bootSession: snapshot.bootSession, osBuild: snapshot.osBuild,
                                         userID: snapshot.userID,
                                         displays: snapshot.displays.filter { $0.uuid != target.uuid })
        try remaining.validateRestoration(to: current)
        let evidence = try inventory()
        try RecoveryIdentityPolicy.evaluate(snapshot: snapshot, evidence: evidence).requireEligible()
        guard evidence.onlineIDs == Set(current.displays.map(\.id)) else {
            throw RecoveryError.unsafe("ambiguous: provider online inventory changed; manual recovery required")
        }
        guard !evidence.onlineIDs.contains(target.id) else {
            throw RecoveryError.unsafe("re-enable target is already online")
        }
        return target
    }

    func restoreMissing(snapshot: RecoverySnapshot, capture: () throws -> RecoverySnapshot) throws {
        let target = try target(snapshot: snapshot, current: capture())
        try enable(target.id) {
            guard try self.target(snapshot: snapshot, current: capture()) == target else {
                throw RecoveryError.unsafe("offline identity changed before enable commit")
            }
        }
        // A successful setter/commit is NOT evidence of connectivity. No retries.
        try snapshot.validateRestoration(to: capture())
    }
}

/// Internal transaction primitive shared by re-enable and the future disable
/// orchestrator. No production caller installs it. Closure injection matches
/// RecoveryEngine's seam; tests use fake writers.
struct RecoveryEnableTransaction {
    var begin: () throws -> CGDisplayConfigRef
    var setEnabled: (CGDisplayConfigRef, UInt32, Bool) throws -> Void
    var commit: (CGDisplayConfigRef, CGConfigureOption) throws -> Void
    var cancel: (CGDisplayConfigRef) -> Void

    func enable(id: UInt32, revalidate: () throws -> Void) throws {
        try configure(id: id, enabled: true, revalidate: revalidate)
    }

    func configure(id: UInt32, enabled: Bool, revalidate: () throws -> Void) throws {
        try revalidate()
        let config = try begin()
        var consumed = false
        defer { if !consumed { cancel(config) } }
        try revalidate()
        try setEnabled(config, id, enabled)
        try revalidate()
        // CGCompleteDisplayConfiguration consumes the transaction even on error.
        consumed = true
        try commit(config, .forSession)
    }

}
