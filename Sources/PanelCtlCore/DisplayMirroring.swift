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

    public static func unmirror(selector: String? = nil, journalPath: String?) throws {
        let store = store(journalPath)
        let journal = try MirrorController().unmirror(store: store, selector: selector)
        let remaining = journal.publicMirrorSession?.removals.filter { !$0.state.resolved }.count ?? 0
        if remaining > 0 {
            print("Selected display shown and verified; \(remaining) removal(s) remain. Its position may differ slightly until the last Show restores the original arrangement; journal retained: \(store.url.path)")
        } else {
            print("Captured arrangement, modes and main display verified; journal retained: \(store.url.path)")
        }
    }

    static func verifyRemoval(selector: String?, journalPath: String?) throws {
        let store = store(journalPath)
        let journal = try MirrorController().verifyRemoval(store: store, selector: selector)
        print("Removal state verified; journal retained: \(store.url.path) (\(journal.id))")
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

enum HiddenMirrorTopology {
    static func verify(snapshot: RecoverySnapshot, targetID: UInt32, sourceID: UInt32,
                       current: RecoverySnapshot) throws {
        try snapshot.validateRestoration(to: current)
        guard let target = snapshot.displays.first(where: { $0.id == targetID }),
              let source = snapshot.displays.first(where: { $0.id == sourceID }),
              target.id != source.id,
              current.displays.filter(\.main).count == 1 else {
            throw RecoveryError.unsafe("mirror topology verification mismatch")
        }
        let originalByID = Dictionary(uniqueKeysWithValues: snapshot.displays.map { ($0.id, $0) })
        for display in current.displays {
            guard let original = originalByID[display.id] else {
                throw RecoveryError.unsafe("mirror topology verification mismatch")
            }
            let expectedMirror = display.id == targetID ? source.uuid : nil
            let mirrorMatches: Bool
            if let expectedMirror, let observedMirror = display.mirrorUUID {
                mirrorMatches = expectedMirror.caseInsensitiveCompare(observedMirror) == .orderedSame
            } else {
                mirrorMatches = expectedMirror == nil && display.mirrorUUID == nil
            }
            guard mirrorMatches,
                  (target.main || display.main == original.main),
                  (display.id != sourceID || display.active) else {
                throw RecoveryError.unsafe("mirror topology verification mismatch")
            }
        }
    }

    static func matches(snapshot: RecoverySnapshot, targetID: UInt32, sourceID: UInt32,
                        current: RecoverySnapshot) -> Bool {
        (try? verify(snapshot: snapshot, targetID: targetID, sourceID: sourceID, current: current)) != nil
    }
}

enum MirrorSessionTopology {
    static func activeRemovals(_ removals: [PublicMirrorRemoval]) -> [PublicMirrorRemoval] {
        removals.filter { !$0.state.resolved }
    }

    static func matches(baseline: RecoverySnapshot, removals: [PublicMirrorRemoval],
                        current: RecoverySnapshot) -> Bool {
        guard (try? baseline.validateRestoration(to: current)) != nil,
              current.displays.filter(\.main).count == 1 else { return false }
        if activeRemovals(removals).isEmpty {
            return (try? baseline.verify(current)) != nil
        }
        var activeByTarget: [String: PublicMirrorRemoval] = [:]
        for removal in activeRemovals(removals) {
            guard activeByTarget[removal.targetUUID] == nil,
                  pendingShowSurvivorsMatch(removal, baseline: baseline, current: current) else { return false }
            activeByTarget[removal.targetUUID] = removal
        }
        for original in baseline.displays {
            guard let observed = current.displays.first(where: { $0.uuid == original.uuid }) else { return false }
            if let removal = activeByTarget[original.uuid] {
                guard observed.mirrorUUID?.caseInsensitiveCompare(removal.sourceUUID) == .orderedSame,
                      !observed.active,
                      let source = current.displays.first(where: { $0.uuid == removal.sourceUUID }),
                      source.id == removal.sourceID, source.active, source.mirrorUUID == nil else { return false }
            } else {
                // Positions are not session invariants while any display is
                // removed: macOS may rearrange on mirror and place a partially
                // shown target near its saved origin. The final Show verifies
                // the whole baseline exactly.
                guard observed.mirrorUUID == original.mirrorUUID else { return false }
                if original.active, !observed.active { return false }
            }
        }
        return true
    }

    /// Postcondition of a Show that leaves other displays removed. With other
    /// displays still mirrored, the saved origin may not be a layout macOS
    /// accepts (recorded on 26A434: requested (3440,-4), placed at (3440,0)),
    /// so the target's origin is requested but not required. Everything else
    /// is exact: identity, the target's mode and main role, other visible
    /// displays (see showSurvivorsUnchanged) and every remaining removal.
    /// When no removal remains, matches() requires the whole baseline.
    static func verifyPartialShow(baseline: RecoverySnapshot, removals: [PublicMirrorRemoval], removalID: UUID,
                                  before: RecoverySnapshot, current: RecoverySnapshot) throws {
        try baseline.validateRestoration(to: current)
        guard let index = removals.firstIndex(where: { $0.id == removalID }) else {
            throw RecoveryError.unsafe("selected removal entry disappeared")
        }
        let targetUUID = removals[index].targetUUID
        guard let original = baseline.displays.first(where: { $0.uuid == targetUUID }),
              let observed = current.displays.first(where: { $0.uuid == targetUUID }),
              observed.mirrorUUID == nil, observed.active,
              observed.mode == original.mode, observed.main == original.main else {
            throw RecoveryError.unsafe("Show did not return the display separately with its saved mode and main-display role; keep recovery")
        }
        guard showSurvivorsUnchanged(baseline: baseline, targetUUID: targetUUID, before: before, current: current) else {
            throw RecoveryError.unsafe("Show changed another visible display; keep recovery")
        }
        var proposed = removals
        proposed[index].state = .restored
        guard matches(baseline: baseline, removals: proposed, current: current) else {
            throw RecoveryError.unsafe("Show changed another removal or did not restore the original layout; keep recovery")
        }
    }

    /// Every display that was visible before the Show stays visible with its
    /// exact mode. Positions are global coordinates relative to the main
    /// display's (0,0), so they compare exactly whenever the main display is
    /// unchanged. A returning original main takes (0,0), and macOS may move
    /// main while other displays are removed; then positions do not compare.
    static func showSurvivorsUnchanged(baseline: RecoverySnapshot, targetUUID: String,
                                       before: RecoverySnapshot, current: RecoverySnapshot) -> Bool {
        guard (try? before.validateRestoration(to: current)) != nil,
              let target = baseline.displays.first(where: { $0.uuid == targetUUID }) else { return false }
        let sameFrame = !target.main &&
            before.displays.first(where: \.main)?.uuid == current.displays.first(where: \.main)?.uuid
        return before.displays.allSatisfy { survivor in
            guard survivor.uuid != targetUUID, survivor.active, survivor.mirrorUUID == nil else { return true }
            guard let observed = current.displays.first(where: { $0.uuid == survivor.uuid }),
                  observed.active, observed.mirrorUUID == nil, observed.mode == survivor.mode else { return false }
            return !sameFrame || (observed.main == survivor.main && observed.x == survivor.x && observed.y == survivor.y)
        }
    }

    /// A pending Show's durable pre-Show snapshot keeps its survivor
    /// expectations across failure, crash and relaunch.
    static func pendingShowSurvivorsMatch(_ removal: PublicMirrorRemoval, baseline: RecoverySnapshot,
                                          current: RecoverySnapshot) -> Bool {
        guard let before = removal.restoreFrom else { return true }
        return showSurvivorsUnchanged(baseline: baseline, targetUUID: removal.targetUUID, before: before, current: current)
    }

    /// The final *physical* Show restores the full baseline even if a previous
    /// Show cleared its mirror but retained unresolved layout recovery. Every
    /// other display must already be separate; never replay a sibling mirror.
    static func canRestoreFinalLayout(baseline: RecoverySnapshot, removals: [PublicMirrorRemoval],
                                      targetUUID: String, current: RecoverySnapshot) -> Bool {
        guard let selected = activeRemovals(removals).first(where: { $0.targetUUID == targetUUID }),
              (try? baseline.validateRestoration(to: current)) != nil,
              current.displays.filter(\.main).count == 1 else { return false }
        return current.displays.allSatisfy { display in
            if display.uuid == selected.targetUUID, let source = display.mirrorUUID {
                return source.caseInsensitiveCompare(selected.sourceUUID) == .orderedSame && !display.active
            }
            return display.mirrorUUID == nil &&
                (display.active || baseline.displays.first(where: { $0.uuid == display.uuid })?.active == false)
        }
    }

    /// A partial Show can clear its mirror yet fail its postcondition (for
    /// example its mode). Only that recorded failed target may be repaired;
    /// survivors and sibling topology must still verify before another write.
    static func canRepairTargetLayout(baseline: RecoverySnapshot, removals: [PublicMirrorRemoval],
                                      targetUUID: String, current: RecoverySnapshot) -> Bool {
        guard activeRemovals(removals).count > 1,
              let index = removals.firstIndex(where: { $0.targetUUID == targetUUID && !$0.state.resolved }),
              removals[index].state == .needsAttention || removals[index].state == .restoring,
              pendingShowSurvivorsMatch(removals[index], baseline: baseline, current: current),
              let target = current.displays.first(where: { $0.uuid == targetUUID }),
              target.mirrorUUID == nil, target.active else { return false }
        var siblings = removals
        siblings[index].state = .cancelled
        return matches(baseline: baseline, removals: siblings, current: current)
    }

    static func targetMatchesBaseline(_ targetUUID: String, baseline: RecoverySnapshot,
                                      current: RecoverySnapshot) -> Bool {
        guard (try? baseline.validateRestoration(to: current)) != nil,
              let original = baseline.displays.first(where: { $0.uuid == targetUUID }),
              let observed = current.displays.first(where: { $0.uuid == targetUUID }) else { return false }
        return observed.mirrorUUID == nil && observed.active == original.active &&
            observed.main == original.main && observed.x == original.x && observed.y == original.y &&
            observed.mode == original.mode
    }

    static func matchesBeforeOperation(_ removal: PublicMirrorRemoval,
                                       current: RecoverySnapshot) -> Bool {
        (try? removal.beforeOperation.verify(current)) != nil
    }
}

enum MirrorRecoveryGuidance {
    static let manualSteps = "Manual recovery: keep the journal; in System Settings → Displays, turn off mirroring and drag the menu bar back to the original display. After correcting the layout, inspect recovery status and run recovery verify."
}

struct MirrorController {
    var records: () throws -> [DisplayRecord] = { DisplayInventory.records() }
    var operationLock: () -> RecoveryStore = { RecoveryStore.operationLock() }
    var engine = RecoveryEngine.publicMirror
    var preflightModes: (RecoverySnapshot) throws -> Void = { _ = try RecoveryConfiguration.resolveModes($0) }
    var transaction = MirrorTransaction()
    var restoreTarget: (RecoverySnapshot, String, () throws -> Void, () throws -> RecoverySnapshot) throws -> Void = {
        try RecoveryConfiguration.restoreTarget($0, targetUUID: $1, revalidate: $2, capture: $3)
    }

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
              let sourceRecord = DisplaySelector.resolve(source, in: available), target.id != sourceRecord.id,
              target.online, target.active, !target.asleep, !target.builtin,
              sourceRecord.online, sourceRecord.active, !sourceRecord.asleep else {
            throw RecoveryError.unsafe("mirror requires one stable-identity external active target (built-in displays are refused) and a distinct active source; missing/ambiguous selectors refused; use panelctl list")
        }
        if let expectedTarget, !matches(expectedTarget, record: target) {
            throw RecoveryError.unsafe("target identity changed after confirmation; refresh Displays and confirm Hide again")
        }
        if let expectedSource, !matches(expectedSource, record: sourceRecord) {
            throw RecoveryError.unsafe("mirror source identity changed after confirmation; refresh Displays and confirm Hide again")
        }

        let current = try engine.capture()
        guard Set(current.displays.map(\.id)) == Set(available.filter(\.online).map(\.id)) else {
            throw RecoveryError.unsafe("display set changed during capture; refusing mirror")
        }
        let existing = try store.exists() ? store.load() : nil
        var journal: RecoveryJournal
        var session: PublicMirrorSession
        let baseline: RecoverySnapshot
        if let existing, !existing.state.resolved {
            if let previous = existing.publicMirrorSession {
                guard previous.removals.allSatisfy({ $0.state != .needsAttention && $0.state != .captured && $0.state != .restoring }),
                      MirrorSessionTopology.matches(baseline: previous.baseline, removals: previous.removals, current: current) else {
                    throw RecoveryError.unsafe("display recovery needs attention; resolve it before starting another removal")
                }
                journal = existing
                session = previous
                baseline = previous.baseline
            } else if existing.mirrorTargetID != nil, existing.mirrorSourceID != nil,
                      existing.state == .mirrored, existing.disabledByUsID == nil,
                      let targetSaved = existing.snapshot.displays.first(where: { $0.id == existing.mirrorTargetID }),
                      let sourceSaved = existing.snapshot.displays.first(where: { $0.id == existing.mirrorSourceID }),
                      HiddenMirrorTopology.matches(snapshot: existing.snapshot, targetID: targetSaved.id,
                                                   sourceID: sourceSaved.id, current: current) {
                // Upgrade a healthy singleton public journal atomically. Its
                // original snapshot becomes the immutable session baseline.
                let removal = PublicMirrorRemoval(target: targetSaved, source: sourceSaved,
                                                  beforeOperation: existing.snapshot, state: .mirrored)
                let upgraded = PublicMirrorSession(baseline: existing.snapshot, removals: [removal])
                journal = existing
                journal.version = 3
                journal.publicMirrorSession = upgraded
                session = upgraded
                baseline = existing.snapshot
                try journal.validate()
                try store.save(journal)
            } else {
                throw RecoveryError.unsafe("unresolved journal; verify or recover it before starting a removal")
            }
        } else {
            baseline = current
            guard current.displays.allSatisfy({ $0.mirrorUUID == nil }) else {
                throw RecoveryError.unsafe("existing mirrors are present; refusing to start a public-mirror session")
            }
            session = PublicMirrorSession(baseline: baseline, removals: [])
            journal = RecoveryJournal(snapshot: baseline)
        }

        guard baseline.displays.contains(where: { $0.uuid == (target.uuid ?? "").lowercased() }),
              let targetSaved = baseline.displays.first(where: { $0.id == target.id }),
              let sourceSaved = baseline.displays.first(where: { $0.id == sourceRecord.id }),
              targetSaved.uuid.caseInsensitiveCompare(target.uuid ?? "") == .orderedSame,
              sourceSaved.uuid.caseInsensitiveCompare(sourceRecord.uuid ?? "") == .orderedSame,
              targetSaved.vendor == target.vendor, targetSaved.model == target.model, targetSaved.serial == target.serial,
              sourceSaved.vendor == sourceRecord.vendor, sourceSaved.model == sourceRecord.model, sourceSaved.serial == sourceRecord.serial,
              targetSaved.active, sourceSaved.active else {
            throw RecoveryError.unsafe("selection changed during capture; select again")
        }
        let activeRemovals = session.removals.filter { !$0.state.resolved }
        guard !activeRemovals.contains(where: { $0.targetUUID == targetSaved.uuid }) else {
            throw RecoveryError.unsafe("this display is already removed from the desktop")
        }
        guard !activeRemovals.contains(where: { $0.sourceUUID == targetSaved.uuid }) else {
            throw RecoveryError.unsafe("this display is a source for another removed display; show those displays first")
        }
        guard !activeRemovals.contains(where: { $0.targetUUID == sourceSaved.uuid }) else {
            throw RecoveryError.unsafe("cannot remove a display that another removal mirrors onto")
        }
        guard sourceSaved.uuid != targetSaved.uuid,
              let currentTarget = current.displays.first(where: { $0.id == target.id }),
              let currentSource = current.displays.first(where: { $0.id == sourceRecord.id }),
              currentTarget.mirrorUUID == nil, currentTarget.active,
              currentSource.mirrorUUID == nil, currentSource.active else {
            throw RecoveryError.unsafe("target and source must be separate active displays; removed or externally mirrored displays are refused")
        }
        let visibleAfterHide = current.displays.filter {
            $0.active && $0.mirrorUUID == nil && $0.id != target.id
        }
        guard !visibleAfterHide.isEmpty else {
            throw RecoveryError.unsafe("refusing to hide the last visible display")
        }
        guard MirrorSessionTopology.matches(baseline: baseline, removals: session.removals, current: current) else {
            throw RecoveryError.unsafe("current topology does not match the existing removal session")
        }
        try baseline.validateRestoration(to: current)
        try current.verify(engine.capture())
        try preflightModes(baseline)

        let removal = PublicMirrorRemoval(target: targetSaved, source: sourceSaved, beforeOperation: current)
        session.removals.append(removal)
        journal.version = 3
        journal.publicMirrorSession = session
        journal.mirrorTargetID = session.removals.count == 1 ? target.id : nil
        journal.mirrorSourceID = session.removals.count == 1 ? sourceRecord.id : nil
        journal.state = .captured
        journal.trigger = "mirror"
        journal.failure = nil
        if existing == nil || existing?.state.resolved == true {
            try store.create(journal)
        } else {
            try store.save(journal)
        }

        do {
            // Durable per-display intent precedes both input switching and
            // topology changes. A second Hide cannot replace healthy entries.
            try beforeMirror(targetSaved)
            try transaction.apply(target: target.id, source: sourceRecord.id) {
                try current.verify(engine.capture())
            }
            try engine.converge {
                guard let observed = journal.publicMirrorSession,
                      MirrorSessionTopology.matches(baseline: baseline, removals: observed.removals,
                                                    current: try engine.capture()) else {
                    throw RecoveryError.unsafe("mirror session verification mismatch")
                }
            }
            guard var savedSession = journal.publicMirrorSession,
                  let index = savedSession.removals.firstIndex(where: { $0.id == removal.id }) else {
                throw RecoveryError.unsafe("durable removal entry disappeared")
            }
            savedSession.removals[index].state = .mirrored
            savedSession.removals[index].failure = nil
            journal.publicMirrorSession = savedSession
            journal.state = .mirrored
            try store.save(journal)
            return journal
        } catch {
            if var savedSession = journal.publicMirrorSession,
               let index = savedSession.removals.firstIndex(where: { $0.id == removal.id }) {
                savedSession.removals[index].state = .needsAttention
                savedSession.removals[index].failure = String(describing: error)
                journal.publicMirrorSession = savedSession
            }
            journal.state = .needsAttention
            journal.failure = String(describing: error)
            try? store.save(journal)
            throw fallback(error, store: store, selector: target.uuid)
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
            if journal.publicMirrorSession != nil {
                return try unmirrorSession(&journal, selector: selector, expectedID: expectedID,
                                          noOpWhenAlreadyResolved: noOpWhenAlreadyResolved,
                                          store: store, afterRestore: afterRestore)
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
            throw fallback(error, store: store, selector: selector)
        }
    }

    private func unmirrorSession(_ journal: inout RecoveryJournal, selector: String?, expectedID: UUID?,
                                 noOpWhenAlreadyResolved: Bool, store: RecoveryStore,
                                 afterRestore: (RecoveryDisplay) throws -> Void) throws -> RecoveryJournal {
        guard var session = journal.publicMirrorSession else {
            throw RecoveryError.unsafe("missing public-mirror session")
        }
        if let expectedID, journal.id != expectedID {
            throw RecoveryError.unsafe("journal changed since confirmation; inspect recovery status and confirm again")
        }
        if journal.state.resolved && noOpWhenAlreadyResolved { return journal }
        let initialCurrent = try engine.capture()
        reconcileSession(&journal, current: initialCurrent, store: store)
        guard let reconciled = journal.publicMirrorSession else {
            throw RecoveryError.unsafe("public-mirror session disappeared; keep the journal")
        }
        session = reconciled
        var active = MirrorSessionTopology.activeRemovals(session.removals)
        guard !active.isEmpty else {
            if journal.state.resolved { return journal }
            throw RecoveryError.unsafe("no unresolved display removal; inspect recovery status")
        }

        let selected: PublicMirrorRemoval
        if let selector {
            let selectedUUID: String
            if let requested = UUID(uuidString: selector) {
                selectedUUID = requested.uuidString.lowercased()
            } else if let record = DisplaySelector.resolve(selector, in: try records()), let uuid = record.uuid {
                selectedUUID = uuid.lowercased()
            } else {
                throw RecoveryError.unsafe("missing or ambiguous removal selector; use its captured UUID from recovery status")
            }
            let matches = active.filter { $0.targetUUID.caseInsensitiveCompare(selectedUUID) == .orderedSame }
            if matches.isEmpty,
               session.removals.contains(where: { $0.targetUUID.caseInsensitiveCompare(selectedUUID) == .orderedSame && $0.state.resolved }) {
                return journal
            }
            guard matches.count == 1, let match = matches.first else {
                throw RecoveryError.unsafe("selected display is not an unresolved removal in this journal; use panelctl recovery status")
            }
            selected = match
        } else {
            guard active.count == 1, let only = active.first else {
                throw RecoveryError.unsafe("several displays are removed; specify --display with the target UUID")
            }
            selected = only
        }

        let available = try records()
        guard Set(available.map(\.id)).count == available.count,
              Set(available.compactMap { $0.uuid?.lowercased() }).count == available.count else {
            throw RecoveryError.unsafe("display identities are ambiguous; reconnect the captured displays and inspect recovery status")
        }
        guard let targetRecord = available.first(where: {
            $0.id == selected.targetID && $0.uuid?.caseInsensitiveCompare(selected.targetUUID) == .orderedSame
        }), targetRecord.online, !targetRecord.asleep else {
            throw RecoveryError.unsafe("journaled target is asleep or unavailable; wake or reconnect the exact display, then inspect recovery status before Show")
        }
        guard let sourceRecord = available.first(where: {
            $0.id == selected.sourceID && $0.uuid?.caseInsensitiveCompare(selected.sourceUUID) == .orderedSame
        }), sourceRecord.online, sourceRecord.active, !sourceRecord.asleep else {
            throw RecoveryError.unsafe("journaled mirror source is asleep, inactive, or unavailable; wake or reconnect the exact display, then inspect recovery status before Show")
        }
        let current = try engine.capture()
        try session.baseline.validateRestoration(to: current)
        try preflightModes(session.baseline)
        guard MirrorSessionTopology.matches(baseline: session.baseline, removals: session.removals, current: current) ||
                MirrorSessionTopology.canRestoreFinalLayout(baseline: session.baseline, removals: session.removals,
                                                           targetUUID: selected.targetUUID, current: current) ||
                MirrorSessionTopology.canRepairTargetLayout(baseline: session.baseline, removals: session.removals,
                                                           targetUUID: selected.targetUUID, current: current) else {
            let reason = "current topology does not match the recorded removal session; no other removal was changed"
            markRemovalNeedsAttention(&journal, removalID: selected.id, reason: reason)
            throw RecoveryError.unsafe(reason)
        }
        active = MirrorSessionTopology.activeRemovals(session.removals)
        let finalShow = active.count == 1 || MirrorSessionTopology.canRestoreFinalLayout(
            baseline: session.baseline, removals: session.removals, targetUUID: selected.targetUUID, current: current
        )
        guard var savedSession = journal.publicMirrorSession,
              let index = savedSession.removals.firstIndex(where: { $0.id == selected.id }) else {
            throw RecoveryError.unsafe("selected removal entry disappeared; keep the journal")
        }
        savedSession.removals[index].state = .restoring
        savedSession.removals[index].failure = nil
        savedSession.removals[index].restoreFrom = current
        journal.publicMirrorSession = savedSession
        journal.state = .restoring
        journal.trigger = "unmirror-\(selected.targetUUID)"
        try store.save(journal)

        var topologySaved = false
        do {
            if finalShow {
                if (try? session.baseline.verify(current)) == nil {
                    try engine.apply(session.baseline)
                }
                try engine.converge { try session.baseline.verify(engine.capture()) }
                guard var completed = journal.publicMirrorSession else {
                    throw RecoveryError.unsafe("session disappeared during final restore")
                }
                for index in completed.removals.indices {
                    completed.removals[index].state = .restored
                    completed.removals[index].failure = nil
                    completed.removals[index].restoreFrom = nil
                }
                journal.publicMirrorSession = completed
                journal.state = .restored
                journal.failure = nil
            } else {
                let restoringCurrent = current
                try restoreTarget(session.baseline, selected.targetUUID, {
                    try restoringCurrent.verify(engine.capture())
                }, {
                    try engine.capture()
                })
                try engine.converge {
                    try MirrorSessionTopology.verifyPartialShow(
                        baseline: session.baseline, removals: journal.publicMirrorSession?.removals ?? [],
                        removalID: selected.id, before: restoringCurrent, current: engine.capture()
                    )
                }
                guard var completed = journal.publicMirrorSession,
                      let index = completed.removals.firstIndex(where: { $0.id == selected.id }) else {
                    throw RecoveryError.unsafe("selected removal entry disappeared")
                }
                completed.removals[index].state = .restored
                completed.removals[index].failure = nil
                completed.removals[index].restoreFrom = nil
                journal.publicMirrorSession = completed
                journal.state = completed.removals.contains(where: { $0.state == .needsAttention })
                    ? .needsAttention : .mirrored
                journal.failure = completed.removals.first(where: { $0.state == .needsAttention })?.failure
            }
            try store.save(journal)
            topologySaved = true
            guard let target = session.baseline.displays.first(where: { $0.uuid == selected.targetUUID }) else {
                throw RecoveryError.unsafe("captured target identity is missing")
            }
            try afterRestore(target)
            return journal
        } catch {
            if !topologySaved {
                markRemovalNeedsAttention(&journal, removalID: selected.id, reason: String(describing: error))
                try? store.save(journal)
            }
            throw RecoveryError.unsafe(String(describing: error))
        }
    }

    func verifyRemoval(store: RecoveryStore, selector: String?) throws -> RecoveryJournal {
        let operation = operationLock()
        try operation.lock()
        defer { operation.unlock() }
        try store.lock()
        defer { store.unlock() }
        var journal = try store.load()
        guard var session = journal.publicMirrorSession else {
            throw RecoveryError.unsafe("recovery verify --display applies only to a public-mirror removal session")
        }
        let current = try engine.capture()
        reconcileSession(&journal, current: current, store: store)
        guard let reconciled = journal.publicMirrorSession else {
            throw RecoveryError.unsafe("public-mirror session disappeared; keep the journal")
        }
        session = reconciled
        let active = MirrorSessionTopology.activeRemovals(session.removals)
        let selected: PublicMirrorRemoval
        if let selector {
            let uuid: String
            if let parsed = UUID(uuidString: selector) {
                uuid = parsed.uuidString.lowercased()
            } else if let record = DisplaySelector.resolve(selector, in: try records()), let recordUUID = record.uuid {
                uuid = recordUUID.lowercased()
            } else {
                throw RecoveryError.unsafe("missing or ambiguous removal selector; use its captured UUID from recovery status")
            }
            guard let removal = session.removals.last(where: { $0.targetUUID == uuid }) else {
                throw RecoveryError.unsafe("selected display is not in this removal session")
            }
            selected = removal
        } else {
            guard active.count <= 1 else {
                throw RecoveryError.unsafe("several displays are removed; specify --display with one target UUID")
            }
            guard let only = active.first ?? session.removals.last else {
                throw RecoveryError.unsafe("removal session has no entries")
            }
            selected = only
        }
        if selected.state.resolved {
            guard (try? session.baseline.validateRestoration(to: current)) != nil,
                  (try? session.baseline.verify(current)) != nil ||
                    MirrorSessionTopology.matches(baseline: session.baseline, removals: session.removals, current: current) else {
                throw RecoveryError.unsafe("selected removal does not match its strictly verified restored state")
            }
            return journal
        }
        guard selected.state == .mirrored,
              MirrorSessionTopology.matches(baseline: session.baseline, removals: session.removals, current: current) else {
            throw RecoveryError.unsafe(selected.failure ?? "selected removal needs attention; inspect recovery status")
        }
        return journal
    }

    func reconcileSession(_ journal: inout RecoveryJournal, current: RecoverySnapshot, store: RecoveryStore) {
        guard var session = journal.publicMirrorSession else { return }
        if (try? session.baseline.verify(current)) != nil {
            for index in session.removals.indices {
                session.removals[index].state = .restored
                session.removals[index].failure = nil
                session.removals[index].restoreFrom = nil
            }
            journal.publicMirrorSession = session
            journal.state = .verified
            journal.failure = nil
            journal.trigger = "system-restoration-verified"
            if session.removals.count != 1 {
                journal.mirrorTargetID = nil
                journal.mirrorSourceID = nil
            }
            try? store.save(journal)
            return
        }
        var changed = false
        if MirrorSessionTopology.matches(baseline: session.baseline, removals: session.removals, current: current) {
            for index in session.removals.indices where !session.removals[index].state.resolved {
                if session.removals[index].state != .mirrored || session.removals[index].failure != nil ||
                    session.removals[index].restoreFrom != nil {
                    session.removals[index].state = .mirrored
                    session.removals[index].failure = nil
                    session.removals[index].restoreFrom = nil
                    changed = true
                }
            }
        } else {
            for index in session.removals.indices where !session.removals[index].state.resolved {
                let removal = session.removals[index]
                // An interrupted or retried Show resolves only by its own
                // durable postcondition, never by a later, weaker inspection.
                if let before = removal.restoreFrom,
                   (try? MirrorSessionTopology.verifyPartialShow(baseline: session.baseline, removals: session.removals,
                                                                 removalID: removal.id, before: before,
                                                                 current: current)) != nil {
                    session.removals[index].state = .restored
                    session.removals[index].failure = nil
                    session.removals[index].restoreFrom = nil
                    changed = true
                    continue
                }
                guard MirrorSessionTopology.pendingShowSurvivorsMatch(removal, baseline: session.baseline, current: current) else {
                    session.removals[index].state = .needsAttention
                    session.removals[index].failure = removal.failure ?? "Show changed another visible display; keep recovery"
                    changed = true
                    continue
                }
                if MirrorSessionTopology.activeRemovals(session.removals).count > 1,
                   MirrorSessionTopology.matchesBeforeOperation(removal, current: current) {
                    session.removals[index].state = .cancelled
                    session.removals[index].failure = nil
                    session.removals[index].restoreFrom = nil
                    changed = true
                    continue
                }
                var proposed = session.removals
                proposed[index].state = .restored
                if MirrorSessionTopology.targetMatchesBaseline(removal.targetUUID, baseline: session.baseline, current: current),
                   MirrorSessionTopology.matches(baseline: session.baseline, removals: proposed, current: current) {
                    session.removals[index].state = .restored
                    session.removals[index].failure = nil
                    session.removals[index].restoreFrom = nil
                    changed = true
                    continue
                }
                let targetStillMirrored = current.displays.first(where: { $0.uuid == removal.targetUUID })?.mirrorUUID?
                    .caseInsensitiveCompare(removal.sourceUUID) == .orderedSame
                if !targetStillMirrored {
                    session.removals[index].state = .needsAttention
                    session.removals[index].failure = "display topology no longer matches this removal; inspect recovery before continuing"
                    changed = true
                } else if session.removals[index].state == .captured || session.removals[index].state == .restoring {
                    session.removals[index].state = .mirrored
                    session.removals[index].failure = nil
                    session.removals[index].restoreFrom = nil
                    changed = true
                }
            }
        }
        let unresolved = MirrorSessionTopology.activeRemovals(session.removals)
        let previousJournalState = journal.state
        if unresolved.isEmpty, (try? session.baseline.verify(current)) != nil {
            journal.state = .verified
            journal.failure = nil
            for index in session.removals.indices {
                session.removals[index].state = .restored
                session.removals[index].failure = nil
                session.removals[index].restoreFrom = nil
            }
            changed = true
        } else if unresolved.contains(where: { $0.state == .needsAttention }) {
            journal.state = .needsAttention
            journal.failure = unresolved.first(where: { $0.state == .needsAttention })?.failure
            changed = true
        } else if !unresolved.isEmpty {
            journal.state = .mirrored
            journal.failure = nil
            changed = changed || previousJournalState != .mirrored
        }
        if changed {
            journal.publicMirrorSession = session
            if session.removals.count != 1 {
                journal.mirrorTargetID = nil
                journal.mirrorSourceID = nil
            }
            try? store.save(journal)
        }
    }

    private func markRemovalNeedsAttention(_ journal: inout RecoveryJournal, removalID: UUID, reason: String) {
        guard var session = journal.publicMirrorSession,
              let index = session.removals.firstIndex(where: { $0.id == removalID }) else { return }
        session.removals[index].state = .needsAttention
        session.removals[index].failure = reason
        journal.publicMirrorSession = session
        journal.state = .needsAttention
        journal.failure = reason
    }

    private func matches(_ expected: DisplayHideIdentity, record: DisplayRecord) -> Bool {
        expected.uuid.caseInsensitiveCompare(record.uuid ?? "") == .orderedSame &&
            expected.displayID == record.id && expected.vendor == record.vendor &&
            expected.model == record.model && expected.serial == record.serial
    }

    private func fallback(_ error: Error, store: RecoveryStore, selector: String? = nil) -> RecoveryError {
        let path = "'" + store.url.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let failure = String(describing: error)
        let session = try? store.load().publicMirrorSession
        let removals = session?.removals ?? []
        let activeCount = MirrorSessionTopology.activeRemovals(removals).count
        let target = selector ?? (activeCount == 1 ? MirrorSessionTopology.activeRemovals(removals).first?.targetUUID : nil)
        let restoreCommand: String
        if session != nil, activeCount > 1, let target {
            let escaped = target.replacingOccurrences(of: "'", with: "'\\''")
            restoreCommand = "panelctl recovery restore --display '\(escaped)' --journal \(path)"
        } else if session != nil, activeCount > 1 {
            restoreCommand = "panelctl recovery status --journal \(path) (then select one target with recovery restore --display <UUID>)"
        } else {
            restoreCommand = "panelctl recovery restore --journal \(path)"
        }
        let guidance = failure.contains(MirrorRecoveryGuidance.manualSteps)
            ? "" : " \(MirrorRecoveryGuidance.manualSteps)"
        return .unsafe("\(failure). Journal kept. After inspecting recovery status and with explicit approval, fallback: \(restoreCommand). Changed identity/rotation/color may require manual correction first; no automatic retry.\(guidance)")
    }
}
