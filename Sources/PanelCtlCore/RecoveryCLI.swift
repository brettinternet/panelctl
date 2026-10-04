import Foundation

/// CLI orchestration shares the helper/engine rather than owning a writer.
/// Injection is internal and used only with synthetic observations in tests.
struct RecoveryCLI {
    struct Lease {
        let id: UUID
        var requestDisable: (UInt32) throws -> Void
        var wait: () -> Void
        var shutdown: () throws -> Void
    }
    var records: () throws -> [DisplayRecord] = { DisplayInventory.records() }
    var capture: () throws -> RecoverySnapshot = { try .capture() }
    var preflight: (RecoverySnapshot, UInt32) throws -> Void = { snapshot, target in
        let session = RecoveryPrivateSession(snapshot: snapshot)
        _ = try session.prepareDisable(targetID: target)
    }
    var recover: (RecoveryStore, String) throws -> RecoveryJournal = { store, trigger in
        let journal = try store.load()
        let session = RecoveryPrivateSession(snapshot: journal.snapshot)
        session.observeNotifications()
        return try session.engine.recover(store: store, trigger: trigger, ownedOnly: true, expectedID: journal.id)
    }
    var arm: (RecoveryStore, URL, TimeInterval, RecoverySnapshot) throws -> Lease = { store, executable, timeout, snapshot in
        let helper = try RecoveryWatchdog.start(store: store, executable: executable, timeout: timeout,
            verifyOnly: false, expectedSnapshot: snapshot, privateLease: true)
        return Lease(id: helper.id, requestDisable: helper.requestDisable,
                     wait: helper.wait, shutdown: helper.shutdown)
    }

    func disable(selector: String, timeout: TimeInterval, store: RecoveryStore, executable: URL) throws -> RecoveryJournal {
        guard timeout.isFinite, (1...60).contains(timeout) else { throw CLIParseError.invalidRecoveryTimeout }
        // Never auto-restore unrelated public captures or change other CLI/app
        // startup behavior. Only this explicit private command adopts stranded
        // disabled-by-us intent, under the same recovery locks and identity gates.
        if try store.exists() {
            let previous = try store.load()
            if !previous.state.resolved {
                guard previous.disabledByUsID != nil, previous.disableStaged == true else {
                    throw RecoveryError.unsafe("unresolved journal; verify or recover it before disabling")
                }
                _ = try recover(store, "startup")
                // Recovery never doubles as a new disconnect request. An index
                // may have moved while the target was offline: require reselection.
                throw RecoveryError.unsafe("startup recovery completed; inspect status and explicitly select again")
            }
        }
        let available = try records()
        guard Set(available.map(\.id)).count == available.count,
              Set(available.compactMap { $0.uuid?.lowercased() }).count == available.count,
              let target = DisplaySelector.resolve(selector, in: available), target.online else {
            throw RecoveryError.unsafe("missing or ambiguous display selector; use panelctl list")
        }
        let snapshot = try capture()
        guard let saved = snapshot.displays.first(where: { $0.id == target.id }),
              saved.uuid.caseInsensitiveCompare(target.uuid ?? "") == .orderedSame,
              saved.vendor == target.vendor, saved.model == target.model, saved.serial == target.serial,
              Set(snapshot.displays.map(\.id)) == Set(available.filter(\.online).map(\.id)) else {
            throw RecoveryError.unsafe("selection changed during capture; select again")
        }
        try preflight(snapshot, target.id)
        let lease = try arm(store, executable, timeout, snapshot)
        do {
            try lease.requestDisable(target.id)
            lease.wait()
        } catch {
            // Closing the lease invokes guarded recovery; never kill the helper.
            try? lease.shutdown()
            throw error
        }
        let journal = try store.load()
        guard journal.id == lease.id, journal.disabledByUsID == target.id,
              journal.disableStaged == true, journal.disableCompleted == true,
              journal.state.resolved, journal.privateRecoveryClosed == true,
              journal.trigger?.hasPrefix("disable-error") != true else {
            throw RecoveryError.unsafe(journal.failure ?? "disable/recovery was not acknowledged; retain journal")
        }
        return journal
    }

    func recoverOwned(store: RecoveryStore, trigger: String) throws -> RecoveryJournal {
        let journal = try store.load()
        guard journal.disabledByUsID != nil, journal.disableStaged == true else {
            throw RecoveryError.unsafe("no staged disabled-by-us target in this journal; use verify or public restore")
        }
        return try recover(store, trigger)
    }
}
