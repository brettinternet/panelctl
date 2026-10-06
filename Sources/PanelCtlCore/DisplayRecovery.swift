import Foundation
import AppKit
import CoreGraphics
import Darwin

public enum RecoveryError: Error, CustomStringConvertible, LocalizedError {
    case unsafe(String)
    public var description: String {
        switch self { case .unsafe(let reason): return "display recovery: \(reason)" }
    }
    public var errorDescription: String? { description }
}

struct RecoveryMode: Codable, Equatable {
    let id: Int32
    let width: Int
    let height: Int
    let pixelWidth: Int
    let pixelHeight: Int
    let refreshRate: Double
    let flags: UInt32

    init(_ mode: CGDisplayMode) {
        id = mode.ioDisplayModeID
        width = mode.width; height = mode.height
        pixelWidth = mode.pixelWidth; pixelHeight = mode.pixelHeight
        refreshRate = mode.refreshRate; flags = mode.ioFlags
    }

    // IDs are only meaningful in the captured boot. Still compare the mode's
    // attributes: a reused mode ID alone is not a restoration identity.
}

struct RecoveryDisplay: Codable, Equatable {
    let uuid: String
    let id: UInt32
    let name: String?
    let vendor: UInt32
    let model: UInt32
    let serial: UInt32
    let builtin: Bool
    let main: Bool
    let active: Bool
    var x: Int32
    var y: Int32
    let rotation: Double
    let mirrorUUID: String?
    let mode: RecoveryMode
    let colorSpace: String?
    let colorProfileDigest: String?
    // Optional for legacy journals and profiles ineligible for normalization.
    let colorProfileDateIndependentDigest: String?
    let connector: String?
    var identityEvidence: RecoveryIdentityEvidence? = nil

    func hasSameColorProfile(as other: Self) -> Bool {
        if colorProfileDigest == other.colorProfileDigest { return true }
        guard colorProfileDigest != nil, other.colorProfileDigest != nil,
              let digest = colorProfileDateIndependentDigest,
              let otherDigest = other.colorProfileDateIndependentDigest else { return false }
        return digest == otherDigest
    }
}

struct RecoverySnapshot: Codable, Equatable {
    let bootSession: String
    let osBuild: String
    let userID: UInt32
    let displays: [RecoveryDisplay]
    var hostModel: String? = nil

    static func capture(includePrivateMetadata: Bool = true) throws -> Self {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any],
              session[kCGSessionOnConsoleKey as String] as? Bool == true,
              (session[kCGSessionUserIDKey as String] as? NSNumber)?.uint32Value == getuid() else {
            throw RecoveryError.unsafe("run from the logged-in console user's GUI session")
        }
        var count: UInt32 = 0
        try checked(CGGetOnlineDisplayList(0, nil, &count), "count displays")
        guard count > 0, count <= 128 else { throw RecoveryError.unsafe("no usable display inventory") }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        try checked(CGGetOnlineDisplayList(count, &ids, &count), "list displays")
        ids = Array(ids.prefix(Int(count)))
        var identities: [UInt32: String] = [:]
        for id in ids {
            guard let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() else {
                throw RecoveryError.unsafe("display \(id) has no UUID")
            }
            identities[id] = (CFUUIDCreateString(nil, uuid) as String).lowercased()
        }
        guard Set(identities.values).count == ids.count else {
            throw RecoveryError.unsafe("display UUIDs are ambiguous")
        }
        let metadata = includePrivateMetadata ? try? CoreDisplayMetadata() : nil
        let transports = (try? RecoveryProductionProviders.transports()) ?? []
        let displays = try ids.map { id -> RecoveryDisplay in
            guard let mode = CGDisplayCopyDisplayMode(id) else {
                throw RecoveryError.unsafe("display \(id) has no readable mode")
            }
            let bounds = CGDisplayBounds(id)
            guard let x = Int32(exactly: bounds.origin.x), let y = Int32(exactly: bounds.origin.y) else {
                throw RecoveryError.unsafe("display \(id) has an unrepresentable origin")
            }
            let mirrored = CGDisplayMirrorsDisplay(id)
            guard mirrored == kCGNullDirectDisplay || identities[mirrored] != nil else {
                throw RecoveryError.unsafe("display \(id) has an unknown mirror source")
            }
            let info = metadata?.info(id)?.takeRetainedValue() as? [String: Any]
            let transportMatches = transports.filter {
                $0.vendor == CGDisplayVendorNumber(id) && $0.product == CGDisplayModelNumber(id) &&
                $0.serial == CGDisplaySerialNumber(id)
            }
            let transport = transportMatches.count == 1 ? transportMatches.first : nil
            let framebufferLocation = info?["IODisplayLocation"] as? String
            // Preserve the journaled connector's original CoreDisplay meaning;
            // IOKit transport location is separate supplementary evidence.
            let connector = framebufferLocation
            let transportName = CGDisplayIsBuiltin(id) != 0 ? "InternalDisplay" : transport?.kind
            let colorSpace = CGDisplayCopyColorSpace(id)
            let profile = colorSpace.copyICCData() as Data?
            let displayName = NSScreen.screens.first {
                ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id
            }?.localizedName
            return RecoveryDisplay(
                uuid: identities[id]!, id: id, name: displayName, vendor: CGDisplayVendorNumber(id),
                model: CGDisplayModelNumber(id), serial: CGDisplaySerialNumber(id),
                builtin: CGDisplayIsBuiltin(id) != 0, main: CGDisplayIsMain(id) != 0,
                active: CGDisplayIsActive(id) != 0, x: x, y: y,
                rotation: CGDisplayRotation(id), mirrorUUID: identities[mirrored],
                mode: RecoveryMode(mode), colorSpace: colorSpace.name as String?,
                colorProfileDigest: profile.map(RecoveryColorProfile.digest),
                colorProfileDateIndependentDigest: profile.flatMap(RecoveryColorProfile.dateIndependentDigest),
                connector: connector,
                identityEvidence: RecoveryIdentityEvidence(
                    source: includePrivateMetadata && framebufferLocation != nil ? .cgAndCoreDisplay : .cgAndIOKit,
                    capturedAt: Date(), transport: transportName, transportLocation: transport?.location,
                    hpd: transport?.hpd, framebufferLocation: framebufferLocation)
            )
        }
        return Self(bootSession: try systemString("kern.bootsessionuuid"),
                    osBuild: try systemString("kern.osversion"), userID: getuid(),
                    displays: displays.sorted { $0.uuid < $1.uuid }, hostModel: try? systemString("hw.model"))
    }

    /// No ordinal or stale numeric-ID fallback. The current topology must have
    /// exactly the captured identities before any configuration write.
    func validateRestoration(to current: Self) throws {
        guard bootSession == current.bootSession, osBuild == current.osBuild, userID == current.userID else {
            throw RecoveryError.unsafe("OS, boot session, or user changed; manual recovery required")
        }
        guard !displays.isEmpty, Set(displays.map(\.uuid)).count == displays.count,
              Set(current.displays.map(\.uuid)).count == current.displays.count,
              Set(displays.map(\.uuid)) == Set(current.displays.map(\.uuid)) else {
            throw RecoveryError.unsafe("display set changed; reconnect missing displays first; private re-enable requires qualified retained identity")
        }
        for original in displays {
            let now = current.displays.first { $0.uuid == original.uuid }!
            guard original.id == now.id, original.vendor == now.vendor,
                  original.model == now.model, original.serial == now.serial,
                  original.builtin == now.builtin, original.connector == now.connector else {
                throw RecoveryError.unsafe("identity or connector changed for \(original.uuid); refusing to guess")
            }
            guard original.rotation == now.rotation else {
                throw RecoveryError.unsafe("rotation changed for \(original.uuid); restore it manually first")
            }
            guard original.colorSpace == now.colorSpace else {
                throw RecoveryError.unsafe("color space changed for \(original.uuid); restore it manually first")
            }
            guard original.hasSameColorProfile(as: now) else {
                throw RecoveryError.unsafe("ICC profile changed for \(original.uuid); no proven creation-time-only match; manual recovery required")
            }
        }
    }

    func verify(_ current: Self) throws {
        try validateRestoration(to: current)
        // Identity, rotation, color space and profile content are checked above.
        // Raw ICC hashes may differ only when both snapshots prove a date-only
        // regeneration. They remain stored, unchanged, as diagnostic evidence.
        for original in displays {
            let now = current.displays.first { $0.uuid == original.uuid }!
            guard original.main == now.main, original.active == now.active,
                  original.x == now.x, original.y == now.y,
                  original.mirrorUUID == now.mirrorUUID, original.mode == now.mode else {
                throw RecoveryError.unsafe("display configuration differs from snapshot")
            }
        }
    }
}

func systemString(_ name: String) throws -> String {
    var size = 0
    guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 1, size < 4096 else {
        throw RecoveryError.unsafe("cannot read \(name)")
    }
    var bytes = [CChar](repeating: 0, count: size)
    guard sysctlbyname(name, &bytes, &size, nil, 0) == 0 else {
        throw RecoveryError.unsafe("cannot read \(name)")
    }
    return String(cString: bytes)
}

private func checked(_ error: CGError, _ operation: String) throws {
    guard error == .success else { throw RecoveryError.unsafe("\(operation) failed (CGError \(error.rawValue))") }
}

/// Only public, session-scoped topology restoration. No power, private enable,
/// rotation, gamma, HDR, color-profile, or firmware writes.
enum RecoveryConfiguration {
    static func restore(_ snapshot: RecoverySnapshot, revalidate: () throws -> Void = {},
                        capture: () throws -> RecoverySnapshot = { try .capture() }) throws {
        try revalidate()
        let before = try capture()
        try snapshot.validateRestoration(to: before)
        // Resolve every mode before starting the transaction. No approximate
        // resolution/refresh-rate fallback, even if macOS offers one.
        let modes = try resolveModes(snapshot)
        var config: CGDisplayConfigRef?
        try revalidate()
        try checked(CGBeginDisplayConfiguration(&config), "begin configuration")
        guard let config else { throw RecoveryError.unsafe("missing configuration transaction") }
        var completed = false
        defer { if !completed { CGCancelDisplayConfiguration(config) } }
        let current = Dictionary(uniqueKeysWithValues: before.displays.map { ($0.uuid, $0) })
        for display in snapshot.displays where current[display.uuid]!.mirrorUUID != display.mirrorUUID {
            try checked(CGConfigureDisplayMirrorOfDisplay(config, display.id, kCGNullDirectDisplay), "clear mirror")
        }
        for (display, mode) in zip(snapshot.displays, modes) where current[display.uuid]!.mode != display.mode {
            try checked(CGConfigureDisplayWithDisplayMode(config, display.id, mode, nil), "restore mode")
        }
        // Avoid resetting unchanged modes/mirror groups, and restore the main
        // display's origin last (CoreGraphics uses origin 0,0 to select it).
        for display in snapshot.displays.sorted(by: { !$0.main && $1.main }) {
            let now = current[display.uuid]!
            if display.x != now.x || display.y != now.y || display.main != now.main {
                try checked(CGConfigureDisplayOrigin(config, display.id, display.x, display.y), "restore origin")
            }
        }
        for display in snapshot.displays where current[display.uuid]!.mirrorUUID != display.mirrorUUID {
            if let mirror = display.mirrorUUID {
                guard let source = snapshot.displays.first(where: { $0.uuid == mirror }) else {
                    throw RecoveryError.unsafe("invalid mirror identity")
                }
                try checked(CGConfigureDisplayMirrorOfDisplay(config, display.id, source.id), "restore mirror")
            }
        }
        // Never write permanent WindowServer preferences. Success still needs
        // post-commit verification; asynchronous changes may require a retry.
        try before.verify(capture())
        try revalidate()
        let result = CGCompleteDisplayConfiguration(config, .forSession)
        completed = true
        try checked(result, "commit configuration")
    }

    /// Restore one public-mirror target without staging or replaying any other
    /// removal. The caller verifies every still-hidden relationship afterward.
    static func restoreTarget(_ baseline: RecoverySnapshot, targetUUID: String,
                              revalidate: () throws -> Void = {},
                              capture: () throws -> RecoverySnapshot = { try .capture(includePrivateMetadata: false) }) throws {
        try revalidate()
        let before = try capture()
        try baseline.validateRestoration(to: before)
        guard let target = baseline.displays.first(where: { $0.uuid == targetUUID }),
              let currentTarget = before.displays.first(where: { $0.uuid == targetUUID }),
              !target.builtin, currentTarget.mirrorUUID != nil || currentTarget.active else {
            throw RecoveryError.unsafe("target is unavailable for public-mirror restoration")
        }
        let options = [kCGDisplayShowDuplicateLowResolutionModes as String: true] as CFDictionary
        let available = CGDisplayCopyAllDisplayModes(target.id, options) as? [CGDisplayMode] ?? []
        guard let mode = available.first(where: { RecoveryMode($0) == target.mode }) else {
            throw RecoveryError.unsafe("original mode unavailable for \(target.uuid)")
        }
        try revalidate()
        var config: CGDisplayConfigRef?
        try checked(CGBeginDisplayConfiguration(&config), "begin target restore")
        guard let config else { throw RecoveryError.unsafe("missing configuration transaction") }
        var completed = false
        defer { if !completed { CGCancelDisplayConfiguration(config) } }
        if currentTarget.mirrorUUID != nil {
            try checked(CGConfigureDisplayMirrorOfDisplay(config, target.id, kCGNullDirectDisplay), "restore target mirror")
        }
        if currentTarget.mode != target.mode {
            try checked(CGConfigureDisplayWithDisplayMode(config, target.id, mode, nil), "restore target mode")
        }
        if currentTarget.x != target.x || currentTarget.y != target.y || currentTarget.main != target.main {
            try checked(CGConfigureDisplayOrigin(config, target.id, target.x, target.y), "restore target origin")
        }
        try baseline.validateRestoration(to: capture())
        try revalidate()
        let result = CGCompleteDisplayConfiguration(config, .forSession)
        completed = true
        try checked(result, "commit target restore")
    }

    /// Read-only recoverability preflight, also exercised by rehearsal before
    /// READY. This establishes mode availability, not successful restoration.
    static func resolveModes(_ snapshot: RecoverySnapshot) throws -> [CGDisplayMode] {
        try snapshot.displays.map { display in
            let options = [kCGDisplayShowDuplicateLowResolutionModes as String: true] as CFDictionary
            let available = CGDisplayCopyAllDisplayModes(display.id, options) as? [CGDisplayMode] ?? []
            guard let mode = available.first(where: { RecoveryMode($0) == display.mode }) else {
                throw RecoveryError.unsafe("original mode unavailable for \(display.uuid)")
            }
            return mode
        }
    }
}

/// Closure injection follows BlackoutDimming's test seam; tests never touch
/// real display configuration.
struct RecoveryEngine {
    // Public mirror journals deliberately omit CoreDisplay metadata; use the
    // same public-only identity observations for both capture and restoration.
    static var publicMirror: Self {
        Self(capture: { try .capture(includePrivateMetadata: false) }, apply: { snapshot in
            let publicCapture = { try RecoverySnapshot.capture(includePrivateMetadata: false) }
            let session = RecoveryPrivateSession(snapshot: snapshot, capture: publicCapture,
                apply: { baseline, validate in
                    try RecoveryConfiguration.restore(baseline, revalidate: validate, capture: publicCapture)
                })
            session.observeNotifications()
            try session.makeEngine(requiresPrivateIdentity: false).apply(snapshot)
        })
    }

    var capture: () throws -> RecoverySnapshot = { try .capture() }
    var apply: (RecoverySnapshot) throws -> Void = { try RecoveryConfiguration.restore($0) }
    // Only tests inject this until offline identity is independently qualified.
    var reenable: RecoveryReenable?
    var writeGate: () throws -> Void = {}

    // At most six observations over one second per convergence phase. Never
    // retry a writer. Inject the delay for deterministic offline tests.
    var convergencePause: () -> Void = { Thread.sleep(forTimeInterval: 0.2) }

    func converge(_ check: () throws -> Void) throws {
        for attempt in 0..<6 {
            do { try check(); return }
            catch {
                if attempt == 5 { throw error }
                convergencePause()
            }
        }
    }

    /// Manual, startup and shutdown entry point. Helpers already own both
    /// locks and call finish directly. Custom paths never bypass the user lock.
    @discardableResult
    func recover(store: RecoveryStore, verifyOnly: Bool = false, trigger: String,
                 ownedOnly: Bool = false, expectedID: UUID? = nil) throws -> RecoveryJournal {
        let operation = RecoveryStore.operationLock()
        try operation.lock()
        defer { operation.unlock() }
        try store.lock()
        defer { store.unlock() }
        var journal = try store.load()
        if let expectedID, journal.id != expectedID {
            throw RecoveryError.unsafe("journal changed before recovery lock; inspect status and retry")
        }
        if ownedOnly {
            guard journal.disabledByUsID != nil, journal.disableStaged == true else {
                throw RecoveryError.unsafe("no staged disabled-by-us target in this journal")
            }
        }
        try finish(&journal, store: store, verifyOnly: verifyOnly, trigger: trigger)
        return journal
    }

    func finish(_ journal: inout RecoveryJournal, store: RecoveryStore, verifyOnly: Bool, trigger: String) throws {
        // A command cannot upgrade rehearsal authority, or reactivate a
        // resolved private intent after a later unrelated disappearance.
        if journal.state.resolved { journal.privateRecoveryClosed = true }
        var verifyOnly = verifyOnly || journal.verifyOnly || journal.state.resolved || journal.privateRecoveryClosed == true
        do {
            let initial = try capture()
            if journal.disableStaged == true, let targetID = journal.disabledByUsID,
               initial.displays.contains(where: { $0.id == targetID }) {
                // Observing the retained ID online retires authority even if
                // identity/layout verification fails. This only removes write
                // permission; it never treats a reused ID as qualified identity.
                journal.privateRecoveryClosed = true
                try store.save(journal)
                verifyOnly = true
            }
            let missing = journal.snapshot.displays.contains { original in
                !initial.displays.contains { $0.uuid == original.uuid }
            }
            if missing, !verifyOnly, let reenable {
                try writeGate()
                guard journal.reenableAttempted != true, journal.privateRecoveryClosed != true else {
                    throw RecoveryError.unsafe("private re-enable was already attempted; retain evidence and recover manually")
                }
                let target = try reenable.target(snapshot: journal.snapshot, current: initial)
                guard journal.version == 2, journal.disabledByUsID == target.id,
                      journal.disableStaged == true, journal.disableCommitStarted == true else {
                    throw RecoveryError.unsafe("missing disable completion-attempt evidence for retained target; manual recovery required")
                }
                journal.state = .restoring; journal.trigger = trigger
                journal.reenableAttempted = true
                // Durable one-shot intent: a crash must never replay enable.
                try store.save(journal)
                try reenable.restoreMissing(snapshot: journal.snapshot, capture: capture)
                try converge { try journal.snapshot.validateRestoration(to: capture()) }
            }
            try journal.snapshot.validateRestoration(to: capture())
            journal.trigger = trigger
            if !verifyOnly {
                // Persist intent BEFORE the first possible display write.
                journal.state = .restoring
                try store.save(journal)
                let current = try capture()
                try journal.snapshot.validateRestoration(to: current)
                if (try? journal.snapshot.verify(current)) == nil {
                    try writeGate()
                    try apply(journal.snapshot)
                }
            }
            try converge { try journal.snapshot.verify(capture()) }
            if !journal.state.resolved { journal.state = verifyOnly ? .verified : .restored }
            journal.failure = nil
            journal.privateRecoveryClosed = true
            try store.save(journal)
        } catch {
            let message = journal.mirrorTargetID == nil
                ? String(describing: error)
                : "\(error). \(MirrorRecoveryGuidance.manualSteps)"
            journal.state = .needsAttention
            journal.trigger = trigger
            journal.failure = message
            // Never discard the original snapshot if either recovery or its
            // final journal write fails.
            try? store.save(journal)
            if journal.mirrorTargetID != nil {
                throw RecoveryError.unsafe(message)
            }
            throw error
        }
    }
}
