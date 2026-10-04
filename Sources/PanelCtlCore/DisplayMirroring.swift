import Foundation
import CoreGraphics

/// Public mirroring only. A successful mirror is NOT a signal disconnect and
/// does not qualify firmware input switching or private display recovery.
public enum DisplayMirroring {
    public static func mirror(selector: String, source: String, journalPath: String?) throws {
        let store = store(journalPath)
        let journal = try MirrorController().mirror(selector: selector, source: source, store: store)
        print("Mirrored; journal retained: \(store.url.path) (\(journal.id))")
        print("Modes/HDR/refresh, windows and Spaces may change. No gamma or DDC writes.")
    }

    public static func unmirror(journalPath: String?) throws {
        let store = store(journalPath)
        _ = try MirrorController().unmirror(store: store)
        print("Captured arrangement, modes and main display verified; journal retained: \(store.url.path)")
    }

    private static func store(_ path: String?) -> RecoveryStore {
        RecoveryStore(url: path.map { URL(fileURLWithPath: $0) } ?? RecoveryStore.defaultURL)
    }
}

/// Same closure-injected transaction seam as the recovery backend, without
/// resolving or invoking any private setter. Completion consumes even on error.
struct MirrorTransaction {
    var begin: () throws -> CGDisplayConfigRef = {
        var config: CGDisplayConfigRef?
        try check(CGBeginDisplayConfiguration(&config), "begin mirror")
        guard let config else { throw RecoveryError.unsafe("missing mirror transaction") }
        return config
    }
    var stage: (CGDisplayConfigRef, UInt32, UInt32) throws -> Void = {
        try check(CGConfigureDisplayMirrorOfDisplay($0, $1, $2), "stage mirror")
    }
    var complete: (CGDisplayConfigRef, CGConfigureOption) throws -> Void = {
        try check(CGCompleteDisplayConfiguration($0, $1), "commit mirror")
    }
    var cancel: (CGDisplayConfigRef) -> Void = { _ = CGCancelDisplayConfiguration($0) }

    func apply(target: UInt32, source: UInt32, revalidate: () throws -> Void) throws {
        try revalidate()
        let config = try begin()
        var consumed = false
        defer { if !consumed { cancel(config) } }
        try stage(config, target, source)
        try revalidate()
        consumed = true
        try complete(config, .forSession)
    }

    private static func check(_ error: CGError, _ operation: String) throws {
        guard error == .success else {
            throw RecoveryError.unsafe("\(operation) failed (CGError \(error.rawValue))")
        }
    }
}

struct MirrorController {
    var records: () throws -> [DisplayRecord] = { DisplayInventory.records() }
    var operationLock: () -> RecoveryStore = { RecoveryStore.operationLock() }
    var engine = RecoveryEngine.publicMirror
    var preflightModes: (RecoverySnapshot) throws -> Void = { _ = try RecoveryConfiguration.resolveModes($0) }
    var transaction = MirrorTransaction()

    func mirror(selector: String, source: String, store: RecoveryStore,
                expectedTarget: DisplayHideIdentity? = nil,
                expectedSource: DisplayHideIdentity? = nil,
                beforeMirror: (RecoveryDisplay) throws -> Void = { _ in }) throws -> RecoveryJournal {
        let operation = operationLock()
        try operation.lock()
        defer { operation.unlock() }
        try store.lock()
        defer { store.unlock() }
        let available = try records()
        guard Set(available.map(\.id)).count == available.count,
              Set(available.compactMap { $0.uuid?.lowercased() }).count == available.count,
              let target = DisplaySelector.resolve(selector, in: available),
              let source = DisplaySelector.resolve(source, in: available), target.id != source.id,
              target.online, target.active, !target.asleep, !target.main, !target.builtin,
              source.online, source.active, !source.asleep else {
            throw RecoveryError.unsafe("mirror requires one non-main external active target and a distinct active source; missing/ambiguous selectors refused; use panelctl list")
        }
        if let expectedTarget, !matches(expectedTarget, record: target) {
            throw RecoveryError.unsafe("target identity changed after confirmation; refresh Displays and confirm Hide again")
        }
        if let expectedSource, !matches(expectedSource, record: source) {
            throw RecoveryError.unsafe("mirror source identity changed after confirmation; refresh Displays and confirm Hide again")
        }
        let snapshot = try engine.capture()
        guard Set(snapshot.displays.map(\.id)) == Set(available.filter(\.online).map(\.id)),
              snapshot.displays.allSatisfy({ $0.mirrorUUID == nil }) else {
            throw RecoveryError.unsafe("display set changed or existing mirrors present; refusing mirror")
        }
        for record in [target, source] {
            guard let saved = snapshot.displays.first(where: { $0.id == record.id }),
                  saved.uuid.caseInsensitiveCompare(record.uuid ?? "") == .orderedSame,
                  saved.vendor == record.vendor, saved.model == record.model, saved.serial == record.serial,
                  saved.builtin == record.builtin, saved.main == record.main, saved.active else {
                throw RecoveryError.unsafe("selection changed during capture; select again")
            }
        }
        try snapshot.verify(engine.capture())
        try preflightModes(snapshot)
        var journal = RecoveryJournal(snapshot: snapshot)
        journal.mirrorTargetID = target.id
        journal.mirrorSourceID = source.id
        journal.trigger = "mirror"
        try store.create(journal)
        do {
            // Handoff input selection must not precede durable recovery capture.
            try beforeMirror(snapshot.displays.first { $0.id == target.id }!)
            try transaction.apply(target: target.id, source: source.id) {
                try snapshot.verify(engine.capture())
            }
            try engine.converge {
                let current = try engine.capture()
                try snapshot.validateRestoration(to: current)
                for display in current.displays {
                    let original = snapshot.displays.first { $0.id == display.id }!
                    let expectedMirror = display.id == target.id ? source.uuid?.lowercased() : nil
                    guard display.mirrorUUID == expectedMirror, display.main == original.main,
                          display.id != source.id || display.active else {
                        throw RecoveryError.unsafe("mirror topology verification mismatch")
                    }
                }
            }
            journal.state = .mirrored
            try store.save(journal)
            return journal
        } catch {
            journal.state = .needsAttention
            journal.failure = String(describing: error)
            try? store.save(journal)
            throw fallback(error, store: store)
        }
    }

    func unmirror(store: RecoveryStore, selector: String? = nil, expectedID: UUID? = nil,
                  noOpWhenAlreadyResolved: Bool = false,
                  afterRestore: (RecoveryDisplay) throws -> Void = { _ in }) throws -> RecoveryJournal {
        do {
            let operation = operationLock()
            try operation.lock()
            defer { operation.unlock() }
            try store.lock()
            defer { store.unlock() }
            var journal = try store.load()
            if let expectedID, journal.id != expectedID {
                throw RecoveryError.unsafe("journal changed since confirmation; inspect recovery status and confirm again")
            }
            guard journal.mirrorTargetID != nil, journal.mirrorSourceID != nil else {
                throw RecoveryError.unsafe("not a mirror journal; inspect recovery status")
            }
            let target = journal.snapshot.displays.first { $0.id == journal.mirrorTargetID }!
            let source = journal.snapshot.displays.first { $0.id == journal.mirrorSourceID }!
            let wasResolved = journal.state.resolved
            let available = try records()
            guard Set(available.map(\.id)).count == available.count,
                  Set(available.compactMap { $0.uuid?.lowercased() }).count == available.count else {
                throw RecoveryError.unsafe("display identities are ambiguous; reconnect the captured displays and inspect recovery status")
            }
            if let selector {
                guard let selected = DisplaySelector.resolve(selector, in: available),
                      selected.id == target.id,
                      selected.uuid?.lowercased() == target.uuid.lowercased() else {
                    throw RecoveryError.unsafe("back target does not match the journaled mirror target; use panelctl list and recovery status")
                }
            }
            guard let targetRecord = available.first(where: {
                $0.id == target.id && $0.uuid?.caseInsensitiveCompare(target.uuid) == .orderedSame
            }), targetRecord.online, !targetRecord.asleep else {
                throw RecoveryError.unsafe("journaled target is asleep or unavailable; wake or reconnect the exact display, then inspect recovery status before Show")
            }
            guard let sourceRecord = available.first(where: {
                $0.id == source.id && $0.uuid?.caseInsensitiveCompare(source.uuid) == .orderedSame
            }), sourceRecord.online, sourceRecord.active, !sourceRecord.asleep else {
                throw RecoveryError.unsafe("journaled mirror source is asleep, inactive, or unavailable; wake or reconnect the exact display, then inspect recovery status before Show")
            }
            if wasResolved && noOpWhenAlreadyResolved { return journal }
            // Public-only engine: no private re-enable, helper or gamma path.
            try engine.finish(&journal, store: store, verifyOnly: false, trigger: "unmirror")
            try afterRestore(target)
            return journal
        } catch {
            throw fallback(error, store: store)
        }
    }

    private func matches(_ expected: DisplayHideIdentity, record: DisplayRecord) -> Bool {
        expected.uuid.caseInsensitiveCompare(record.uuid ?? "") == .orderedSame &&
            expected.displayID == record.id && expected.vendor == record.vendor &&
            expected.model == record.model && expected.serial == record.serial
    }

    private func fallback(_ error: Error, store: RecoveryStore) -> RecoveryError {
        let path = "'" + store.url.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        return .unsafe("\(error). Journal kept. After inspecting recovery status and with explicit approval, fallback: panelctl recovery restore --journal \(path). Changed identity/rotation/color may require manual correction first; no automatic retry.")
    }
}
