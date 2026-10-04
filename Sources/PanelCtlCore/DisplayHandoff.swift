import Foundation

public struct DisplayHandoffIdentity: Equatable {
    public let uuid: String
    public let id: UInt32
    public let name: String
    public let vendor: UInt32
    public let model: UInt32
    public let serial: UInt32

    public var identityDetail: String {
        "Display ID \(id) · UUID \(uuid) · \(vendor):\(model):\(serial)"
    }

    public var detail: String { identityDetail }

    init(_ identity: DisplayHideIdentity) {
        uuid = identity.uuid
        id = identity.displayID
        name = identity.name
        vendor = identity.vendor
        model = identity.model
        serial = identity.serial
    }
}

public struct DisplayHandoffStatus: Equatable {
    public enum State: Equatable {
        case none
        case hidden
        case recovery
        case unsupported
        case busy
    }

    public let state: State
    public let target: DisplayHandoffIdentity?
    public let source: DisplayHandoffIdentity?
    public let journalPath: String
    public let journalID: String?
    public let reason: String?
    public let canShow: Bool
    public let inspectionCommand: String
    public let recoveryCommand: String?
    public let observations: [DisplayHideObservation]
    public let inspectionFailure: String?

    public var hasUnresolvedJournal: Bool { state != .none }

    init(
        state: State,
        target: DisplayHandoffIdentity? = nil,
        source: DisplayHandoffIdentity? = nil,
        journalPath: String,
        journalID: String? = nil,
        reason: String? = nil,
        canShow: Bool = false,
        recoveryCommand: String? = nil,
        observations: [DisplayHideObservation] = [],
        inspectionFailure: String? = nil
    ) {
        self.state = state
        self.target = target
        self.source = source
        self.journalPath = journalPath
        self.journalID = journalID
        self.reason = reason
        self.canShow = canShow
        self.inspectionCommand = "panelctl recovery status --journal \(Self.shellQuote(journalPath))"
        self.recoveryCommand = recoveryCommand
        self.observations = observations
        self.inspectionFailure = inspectionFailure
    }

    fileprivate static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

/// Optional monitor input selection around journal-backed public mirroring.
public enum DisplayHandoff {
    public static var defaultJournalPath: String { RecoveryStore.defaultURL.path }

    public static func run(selector: String, source: String?, input: UInt8?, journalPath: String?) throws {
        let store = RecoveryStore(url: journalPath.map { URL(fileURLWithPath: $0) } ?? RecoveryStore.defaultURL)
        let controller = HandoffController()
        if let source {
            try controller.away(selector: selector, source: source, input: input, store: store)
        } else {
            try controller.back(selector: selector, input: input, store: store)
        }
    }

    /// Reads the shared default journal under the same operation/journal locks
    /// as CLI writers. Exact observed restoration may resolve a mirror journal;
    /// this path never writes display topology or monitor input.
    public static func inspect() -> DisplayHandoffStatus {
        let status: DisplayHideStatus
        do {
            status = try DisplayHideController().inspect()
        } catch {
            let path = defaultJournalPath
            let message = error.localizedDescription
            let busy = message.localizedCaseInsensitiveContains("busy") ||
                message.localizedCaseInsensitiveContains("lock already held")
            return DisplayHandoffStatus(
                state: busy ? .busy : .recovery,
                journalPath: path,
                reason: message,
                recoveryCommand: "panelctl recovery status --journal \(DisplayHandoffStatus.shellQuote(path))",
                inspectionFailure: message
            )
        }
        guard let journal = status.journal, journal.isUnresolved else {
            return DisplayHandoffStatus(
                state: .none,
                journalPath: status.journalPath,
                journalID: status.journal?.id,
                observations: status.observations,
                inspectionFailure: status.inspectionFailure
            )
        }
        guard journal.isMirrorJournal else {
            return DisplayHandoffStatus(
                state: .unsupported,
                target: journal.target.map(DisplayHandoffIdentity.init),
                journalPath: status.journalPath,
                journalID: journal.id,
                reason: journal.showRefusal ?? status.inspectionFailure,
                recoveryCommand: nil,
                observations: status.observations,
                inspectionFailure: status.inspectionFailure
            )
        }
        let observedHidden = status.observations.contains {
            $0.isJournalTarget && $0.state == .hiddenByPanelCtl
        }
        let reason = journal.showRefusal ?? journal.failure ?? status.inspectionFailure ??
            status.observations.first(where: \.isJournalTarget)?.detail
        let recoveryCommand = "panelctl recovery restore --journal \(DisplayHandoffStatus.shellQuote(status.journalPath))"
        return DisplayHandoffStatus(
            state: observedHidden ? .hidden : .recovery,
            target: journal.target.map(DisplayHandoffIdentity.init),
            source: journal.source.map(DisplayHandoffIdentity.init),
            journalPath: status.journalPath,
            journalID: journal.id,
            reason: reason,
            canShow: journal.canShow,
            recoveryCommand: recoveryCommand,
            observations: status.observations,
            inspectionFailure: status.inspectionFailure
        )
    }
}

struct HandoffController {
    var mirror = MirrorController()
    var open: (String) throws -> (display: DDC.DisplayTarget, channel: DDCChannel) = { try DDC.open(selector: $0) }
    var select: (UInt8, DDCChannel, UInt32, String, UInt8) throws -> DDCInputSelection = {
        try DDCInput.select($0, channel: $1, displayID: $2, uuid: $3, original: $4)
    }
    var report: (String) -> Void = { print($0) }

    func away(selector: String, source: String, input: UInt8?, store: RecoveryStore) throws {
        var inputRecovery: String?
        do {
            let journal = try mirror.mirror(selector: selector, source: source, store: store) { target in
                try switchInput(input, target: target) { inputRecovery = $0 }
            }
            report("Away: separate desktop hidden by mirroring; Mac signal remains on. Journal: \(store.url.path)")
            let target = journal.snapshot.displays.first { $0.id == journal.mirrorTargetID }!
            report("Return with: panelctl back --display \(shellQuote(target.uuid)) --consent-back --journal \(shellQuote(store.url.path))")
            report("Add --input <Mac-input> only if DDC switching back is wanted; otherwise use the monitor's input button.")
        } catch {
            throw RecoveryError.unsafe("\(error)\(inputRecovery.map { ". Input recovery: \($0)" } ?? "")")
        }
    }

    func back(selector: String, input: UInt8?, store: RecoveryStore) throws {
        // No DDC open/read/write can prevent the topology restoration.
        _ = try mirror.unmirror(store: store, selector: selector) { target in
            report("Back: captured topology restored and verified. Journal: \(store.url.path)")
            try switchInput(input, target: target) { report("Input recovery: \($0)") }
        }
    }

    private func switchInput(_ input: UInt8?, target: RecoveryDisplay,
                             recovery: (String) -> Void) throws {
        guard let input else {
            report("DDC skipped (no --input configured); use the monitor's input button.")
            return
        }
        let session: (display: DDC.DisplayTarget, channel: DDCChannel)
        let original: UInt8
        do {
            session = try open(target.uuid)
            guard session.display.id == target.id,
                  session.display.uuid.lowercased() == target.uuid.lowercased() else {
                throw RecoveryError.unsafe("DDC target changed since journal capture")
            }
            original = try DDCInput.current(session.channel)
            guard original != 0 else { throw RecoveryError.unsafe("DDC returned unknown input 0") }
        } catch {
            report("DDC skipped (\(error)); use the monitor's input button.")
            return
        }
        let command = "panelctl ddc-input --display \(shellQuote(target.uuid)) --set \(original), or use the monitor's input button"
        recovery(command)
        // Print before attempting a write, including when readback becomes unavailable.
        report("To reverse input selection: \(command)")
        do {
            let result = try select(input, session.channel, target.id, target.uuid, original)
            report("DDC input outcome=\(result.outcome.rawValue)\(result.detail.map { ": \($0)" } ?? "")")
            if result.outcome == .unverified {
                report("Input switch is unverified; check visually and use the monitor's input button if needed.")
            }
        } catch {
            throw RecoveryError.unsafe("DDC selection failed: \(error). Input recovery: \(command)")
        }
    }

    private func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
