import Foundation
import CoreGraphics

/// Production observations use the bounded capture/current contract on the
/// TASK-1 host/build. They do not prove fresh sink acquisition or rule out
/// cached same-port replacement/CG-ID reuse. This inventory is never journal data.
struct RecoveryEnableIdentity: Equatable {
    let uuid: String?
    let id: UInt32
    let vendor: UInt32
    let model: UInt32
    let serial: UInt32
    let builtin: Bool
    let connector: String
    let transport: String
    let transportLocation: String?
    let framebufferLocation: String?

    init(_ display: RecoveryDisplay) {
        self.init(uuid: display.uuid, id: display.id, vendor: display.vendor, model: display.model,
                  serial: display.serial, builtin: display.builtin, connector: display.connector ?? "",
                  transport: display.identityEvidence?.transport ?? "",
                  framebufferLocation: display.identityEvidence?.framebufferLocation,
                  transportLocation: display.identityEvidence?.transportLocation)
    }

    init(uuid: String?, id: UInt32, vendor: UInt32, model: UInt32, serial: UInt32,
         builtin: Bool, connector: String, transport: String, framebufferLocation: String?,
         transportLocation: String? = nil) {
        self.uuid = uuid; self.id = id; self.vendor = vendor; self.model = model
        self.serial = serial; self.builtin = builtin; self.connector = connector
        self.transport = transport; self.transportLocation = transportLocation
        self.framebufferLocation = framebufferLocation
    }
}

struct RecoveryEnableInventory {
    let bootSession: String
    let osBuild: String
    let userID: UInt32
    var identities: [RecoveryEnableIdentity]
    let onlineIDs: Set<UInt32>
    let hostModel: String?
    let architecture: String
    enum Binding: Equatable { case unqualified, stale, captureMatch, syntheticPhysicalFixture }
    var binding: Binding = .unqualified

    init(bootSession: String, osBuild: String, userID: UInt32,
         identities: [RecoveryEnableIdentity], onlineIDs: Set<UInt32>,
         hostModel: String? = nil, architecture: String = "unknown", binding: Binding = .unqualified) {
        self.bootSession = bootSession; self.osBuild = osBuild; self.userID = userID
        self.identities = identities; self.onlineIDs = onlineIDs
        self.hostModel = hostModel; self.architecture = architecture; self.binding = binding
    }
}

/// Shared guarded recovery seam. The public-only engine has no backend;
/// private sessions supply providers and a gated transaction. Defaults refuse,
/// and no user flag bypasses qualification.
struct RecoveryReenable {
    var inventory: () throws -> RecoveryEnableInventory = {
        throw RecoveryError.unsafe("no current hardware identity provider was supplied; private re-enable unavailable")
    }
    var enable: (UInt32, () throws -> Void) throws -> Void = { _, _ in
        throw RecoveryError.unsafe("private transport unavailable until the verified backend gates pass")
    }
    var preflight: (RecoverySnapshot, RecoverySnapshot) throws -> Void = { _, _ in }

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
        do { try remaining.validateRestoration(to: current) }
        catch {
            throw RecoveryError.unsafe("remaining displays \(remaining.displays.map(\.uuid)) do not match online \(current.displays.map(\.uuid)): \(error)")
        }
        try preflight(snapshot, current)
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
        // The engine performs bounded read-only convergence next. Setter or
        // commit success is not evidence of connectivity; never retry writes.
    }
}

/// Internal transaction primitive shared by re-enable and disable.
/// Production observations cannot currently qualify its use. Closure injection
/// matches RecoveryEngine's seam; tests use fake writers.
struct RecoveryEnableTransaction {
    var begin: () throws -> CGDisplayConfigRef
    var setEnabled: (CGDisplayConfigRef, UInt32, Bool) throws -> Void
    var commit: (CGDisplayConfigRef, CGConfigureOption) throws -> Void
    var cancel: (CGDisplayConfigRef) -> Void

    func enable(id: UInt32, revalidate: () throws -> Void) throws {
        try configure(id: id, enabled: true, revalidate: revalidate)
    }

    func configure(id: UInt32, enabled: Bool, didStage: () throws -> Void = {},
                   willCommit: () throws -> Void = {}, revalidate: () throws -> Void) throws {
        try revalidate()
        let config = try begin()
        var consumed = false
        defer { if !consumed { cancel(config) } }
        try revalidate()
        try setEnabled(config, id, enabled)
        try didStage()
        try revalidate()
        try willCommit()
        // CGCompleteDisplayConfiguration consumes the transaction even on error.
        consumed = true
        try commit(config, .forSession)
    }

}
