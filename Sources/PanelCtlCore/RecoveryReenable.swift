import Foundation
import CoreGraphics
import Darwin

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
}

/// Internal, injection-only recovery seam. The default engine has no backend;
/// even explicitly constructing this backend refuses without a qualified live
/// identity provider. There is no user flag that bypasses that boundary.
struct RecoveryReenable {
    var inventory: () throws -> RecoveryEnableInventory = {
        throw RecoveryError.unsafe("offline hardware-to-CG-ID binding is unqualified; private re-enable unavailable")
    }
    var enable: (UInt32, () throws -> Void) throws -> Void = { id, revalidate in
        try RecoveryEnableTransaction.live().enable(id: id, revalidate: revalidate)
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
        guard evidence.bootSession == snapshot.bootSession, evidence.osBuild == snapshot.osBuild,
              evidence.userID == snapshot.userID,
              evidence.onlineIDs == Set(current.displays.map(\.id)),
              Set(evidence.identities.map(\.id)).count == evidence.identities.count,
              Set(evidence.identities.map(\.uuid)).count == evidence.identities.count,
              evidence.identities.count == snapshot.displays.count else {
            throw RecoveryError.unsafe("offline identity context or inventory is ambiguous/changed")
        }
        for original in snapshot.displays {
            let identity = RecoveryEnableIdentity(original)
            guard identity.id != 0, UUID(uuidString: identity.uuid) != nil,
                  identity.vendor != 0, identity.model != 0, identity.serial != 0,
                  identity.connector?.isEmpty == false,
                  evidence.identities.filter({ $0 == identity }).count == 1 else {
                throw RecoveryError.unsafe("offline hardware identity or connector cannot be proven for \(original.uuid)")
            }
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

/// One true-only setter in one session-scoped transaction. Closure injection
/// matches RecoveryEngine's existing seam; tests never call a live setter.
struct RecoveryEnableTransaction {
    var begin: () throws -> CGDisplayConfigRef
    var setEnabled: (CGDisplayConfigRef, UInt32) throws -> Void
    var commit: (CGDisplayConfigRef) throws -> Void
    var cancel: (CGDisplayConfigRef) -> Void

    func enable(id: UInt32, revalidate: () throws -> Void) throws {
        try revalidate()
        let config = try begin()
        var consumed = false
        defer { if !consumed { cancel(config) } }
        try revalidate()
        try setEnabled(config, id)
        try revalidate()
        // CGCompleteDisplayConfiguration consumes the transaction even on error.
        consumed = true
        try commit(config)
    }

    static func live() throws -> Self {
        let api = try RecoveryEnableAPI()
        return Self(begin: {
            var config: CGDisplayConfigRef?
            try check(CGBeginDisplayConfiguration(&config), "begin enable")
            guard let config else { throw RecoveryError.unsafe("missing enable transaction") }
            return config
        }, setEnabled: { config, id in
            try check(api.set(config, id, true), "private re-enable")
        }, commit: { config in
            try check(CGCompleteDisplayConfiguration(config, .forSession), "commit enable")
        }, cancel: { config in _ = CGCancelDisplayConfiguration(config) })
    }

    private static func check(_ result: CGError, _ operation: String) throws {
        guard result == .success else {
            throw RecoveryError.unsafe("\(operation) failed (CGError \(result.rawValue))")
        }
    }
}

private final class RecoveryEnableAPI {
    // C bool, not boolean_t or a WindowServer connection ID. Evidence links in
    // docs/recovery-reenable.md. No disable wrapper or alternate-symbol fallback.
    typealias SetFn = @convention(c) (CGDisplayConfigRef, CGDirectDisplayID, Bool) -> CGError
    let handle: UnsafeMutableRawPointer
    let set: SetFn

    init() throws {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY | RTLD_LOCAL) else {
            throw RecoveryError.unsafe("SkyLight unavailable")
        }
        guard let symbol = dlsym(handle, "CGSConfigureDisplayEnabled") else {
            dlclose(handle)
            throw RecoveryError.unsafe("CGSConfigureDisplayEnabled unavailable")
        }
        self.handle = handle
        set = unsafeBitCast(symbol, to: SetFn.self)
    }

    deinit { dlclose(handle) }
}
