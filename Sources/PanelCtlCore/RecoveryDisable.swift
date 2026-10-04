import Foundation

/// Executed only by the existing helper while it owns both recovery locks.
/// Production has no installed instance. TASK-6 supplies physical/lifecycle
/// preflight; tests supply synthetic identity and fake transactions.
struct RecoveryDisable {
    var transaction: RecoveryEnableTransaction
    var inventory: () throws -> RecoveryEnableInventory
    var preflight: (RecoverySnapshot, UInt32) throws -> Void = { _, _ in
        throw RecoveryError.unsafe("physical-display/lifecycle preflight unavailable")
    }

    func perform(_ journal: inout RecoveryJournal, store: RecoveryStore, targetID: UInt32,
                 capture: () throws -> RecoverySnapshot, lease: () throws -> Void) throws {
        guard journal.version == 2, !journal.verifyOnly, journal.state == .armed,
              journal.disableAttempted != true, journal.disableStaged != true, journal.disabledByUsID == nil,
              journal.reenableAttempted != true, journal.privateRecoveryClosed != true,
              let deadline = journal.deadline,
              let target = journal.snapshot.displays.first(where: { $0.id == targetID }),
              !target.main, !target.builtin, target.active,
              journal.snapshot.displays.count > 1,
              journal.snapshot.displays.allSatisfy({ $0.mirrorUUID == nil }) else {
            throw RecoveryError.unsafe("disable requires a fresh armed journal and one non-main external target")
        }
        let baseline = journal.snapshot
        func validate() throws {
            try lease()
            guard deadline > Date() else { throw RecoveryError.unsafe("disable lease expired") }
            let current = try capture()
            try baseline.verify(current)
            let evidence = try inventory()
            try RecoveryIdentityPolicy.evaluate(snapshot: baseline, evidence: evidence).requireEligible()
            guard evidence.onlineIDs == Set(current.displays.map(\.id)) else {
                throw RecoveryError.unsafe("disable online inventory changed")
            }
            try preflight(current, targetID)
        }
        try validate()
        journal.disabledByUsID = targetID
        journal.disableAttempted = true
        journal.state = .disabling
        // Selected intent alone cannot authorize recovery after a later,
        // unrelated disappearance if we die before staging the setter.
        try store.save(journal)
        try transaction.configure(id: targetID, enabled: false, didStage: {
            journal.disableStaged = true
            // Completion cannot run unless successful staging is durable.
            // A failed save cancels the still-uncompleted transaction.
            try store.save(journal)
        }, revalidate: validate)
        journal.state = .disabled
        try store.save(journal)
    }
}
