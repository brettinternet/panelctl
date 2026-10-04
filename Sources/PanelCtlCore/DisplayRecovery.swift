import Foundation
import AppKit
import CoreGraphics
import Darwin

public enum RecoveryError: Error, CustomStringConvertible {
    case unsafe(String)
    public var description: String {
        switch self { case .unsafe(let reason): return "display recovery: \(reason)" }
    }
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

    static func capture() throws -> Self {
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
        let metadata = try? CoreDisplayMetadata()
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
            let colorSpace = CGDisplayCopyColorSpace(id)
            let profile = colorSpace.copyICCData() as Data?
            return RecoveryDisplay(
                uuid: identities[id]!, id: id, vendor: CGDisplayVendorNumber(id),
                model: CGDisplayModelNumber(id), serial: CGDisplaySerialNumber(id),
                builtin: CGDisplayIsBuiltin(id) != 0, main: CGDisplayIsMain(id) != 0,
                active: CGDisplayIsActive(id) != 0, x: x, y: y,
                rotation: CGDisplayRotation(id), mirrorUUID: identities[mirrored],
                mode: RecoveryMode(mode), colorSpace: colorSpace.name as String?,
                colorProfileDigest: profile.map(RecoveryColorProfile.digest),
                colorProfileDateIndependentDigest: profile.flatMap(RecoveryColorProfile.dateIndependentDigest),
                connector: info?["IODisplayLocation"] as? String,
                identityEvidence: RecoveryIdentityEvidence(source: .cgAndCoreDisplay, capturedAt: Date(),
                    framebufferLocation: info?["IODisplayLocation"] as? String)
            )
        }
        return Self(bootSession: try systemString("kern.bootsessionuuid"),
                    osBuild: try systemString("kern.osversion"), userID: getuid(),
                    displays: displays.sorted { $0.uuid < $1.uuid })
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
            throw RecoveryError.unsafe("display set changed; reconnect missing displays first; private re-enable is not implemented")
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

private func systemString(_ name: String) throws -> String {
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
    static func restore(_ snapshot: RecoverySnapshot) throws {
        let before = try RecoverySnapshot.capture()
        try snapshot.validateRestoration(to: before)
        // Resolve every mode before starting the transaction. No approximate
        // resolution/refresh-rate fallback, even if macOS offers one.
        let modes = try resolveModes(snapshot)
        var config: CGDisplayConfigRef?
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
        try before.verify(.capture())
        let result = CGCompleteDisplayConfiguration(config, .forSession)
        completed = true
        try checked(result, "commit configuration")
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
    var capture: () throws -> RecoverySnapshot = { try .capture() }
    var apply: (RecoverySnapshot) throws -> Void = { try RecoveryConfiguration.restore($0) }
    // Only tests inject this until offline identity is independently qualified.
    var reenable: RecoveryReenable?

    func finish(_ journal: inout RecoveryJournal, store: RecoveryStore, verifyOnly: Bool, trigger: String) throws {
        do {
            let initial = try capture()
            let missing = journal.snapshot.displays.contains { original in
                !initial.displays.contains { $0.uuid == original.uuid }
            }
            if missing, !verifyOnly, let reenable {
                guard journal.reenableAttempted != true else {
                    throw RecoveryError.unsafe("private re-enable was already attempted; retain evidence and recover manually")
                }
                let target = try reenable.target(snapshot: journal.snapshot, current: initial)
                guard journal.version == 2, journal.disabledByUsID == target.id else {
                    throw RecoveryError.unsafe("missing disabled-by-us intent for retained target; manual recovery required")
                }
                journal.state = .restoring; journal.trigger = trigger
                journal.reenableAttempted = true
                // Durable one-shot intent: a crash must never replay enable.
                try store.save(journal)
                try reenable.restoreMissing(snapshot: journal.snapshot, capture: capture)
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
                    try apply(journal.snapshot)
                }
            }
            try journal.snapshot.verify(capture())
            journal.state = verifyOnly ? .verified : .restored
            journal.failure = nil
            try store.save(journal)
        } catch {
            journal.state = .needsAttention
            journal.trigger = trigger
            journal.failure = String(describing: error)
            // Never discard the original snapshot if either recovery or its
            // final journal write fails.
            try? store.save(journal)
            throw error
        }
    }
}
