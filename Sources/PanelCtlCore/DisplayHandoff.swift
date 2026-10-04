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

public struct DisplayInputOutcome: Codable, Equatable, Sendable {
    public enum State: String, Codable, Equatable, Sendable {
        case notRequested
        case notAttempted
        case skipped
        case verified
        case alreadySelected
        case unverified
        case failed
    }

    public let state: State
    public let requestedInput: UInt8?
    public let observedInput: UInt8?
    public let detail: String?
    public let recoveryCommand: String?

    public init(state: State, requestedInput: UInt8? = nil, observedInput: UInt8? = nil,
                detail: String? = nil, recoveryCommand: String? = nil) {
        self.state = state
        self.requestedInput = requestedInput
        self.observedInput = observedInput
        self.detail = detail
        self.recoveryCommand = recoveryCommand
    }

    public static let notRequested = Self(state: .notRequested)
}

public struct DisplayHandoffOperationFailure: Error, LocalizedError {
    public let action: String
    public let inputOutcome: DisplayInputOutcome
    public let message: String

    public var errorDescription: String? { message }

    init(action: String, inputOutcome: DisplayInputOutcome, message: String) {
        self.action = action
        self.inputOutcome = inputOutcome
        self.message = message
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

    func guardedAway(target: DisplayHideIdentity, source: DisplayHideIdentity, input: UInt8?,
                     store: RecoveryStore) throws -> DisplayInputOutcome {
        var inputOutcome = input.map {
            DisplayInputOutcome(state: .notAttempted, requestedInput: $0,
                                detail: "Input selection was not attempted because Hide did not reach the captured handoff step.")
        } ?? .notRequested
        do {
            _ = try mirror.mirror(
                selector: target.uuid,
                source: source.uuid,
                store: store,
                expectedTarget: target,
                expectedSource: source
            ) { capturedTarget in
                guard input != nil else { return }
                let outcome = selectInput(input, target: capturedTarget)
                inputOutcome = outcome
                if outcome.state == .failed {
                    throw RecoveryError.unsafe(outcome.detail ?? "DDC input selection failed")
                }
            }
            return inputOutcome
        } catch {
            throw DisplayHandoffOperationFailure(action: "hide", inputOutcome: inputOutcome,
                                                 message: error.localizedDescription)
        }
    }

    func guardedBack(expectedJournalID: UUID, input: UInt8?, store: RecoveryStore) throws -> DisplayInputOutcome {
        var inputOutcome = input.map {
            DisplayInputOutcome(state: .notAttempted, requestedInput: $0,
                                detail: "Input selection was not attempted because the captured desktop was not restored.")
        } ?? .notRequested
        do {
            var afterRestoreRan = false
            _ = try mirror.unmirror(
                store: store,
                expectedID: expectedJournalID,
                noOpWhenAlreadyResolved: true
            ) { target in
                afterRestoreRan = true
                guard input != nil else { return }
                inputOutcome = selectInput(input, target: target)
            }
            if let input, !afterRestoreRan {
                inputOutcome = DisplayInputOutcome(
                    state: .notAttempted,
                    requestedInput: input,
                    detail: "Input selection was not attempted because the journal was already resolved; duplicate Show did not send DDC."
                )
            }
            return inputOutcome
        } catch {
            throw DisplayHandoffOperationFailure(action: "show", inputOutcome: inputOutcome,
                                                 message: error.localizedDescription)
        }
    }

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

    func selectInput(_ input: UInt8?, target: RecoveryDisplay,
                     willSelect: (String) -> Void = { _ in }) -> DisplayInputOutcome {
        guard let input else { return .notRequested }
        guard input > 0 else {
            return DisplayInputOutcome(state: .failed, requestedInput: input,
                                       detail: "Input code 0 is invalid; choose dp1, dp2, hdmi1, hdmi2, or a value from 1 through 255.")
        }
        do {
            let records = try mirror.records()
            guard matchesCapturedIdentity(target, records: records) else {
                return staleInputTarget(target, requested: input, actual: "current display inventory")
            }
        } catch {
            return DisplayInputOutcome(state: .failed, requestedInput: input,
                                       detail: "Could not verify the captured DDC target identity: \(error.localizedDescription)")
        }

        let session: (display: DDC.DisplayTarget, channel: DDCChannel)
        do {
            session = try open(target.uuid)
        } catch {
            do {
                guard try matchesCapturedIdentity(target, records: mirror.records()) else {
                    return staleInputTarget(target, requested: input, actual: "current display inventory")
                }
            } catch {
                return DisplayInputOutcome(state: .failed, requestedInput: input,
                                           detail: "Could not verify the captured DDC target identity after opening failed: \(error.localizedDescription)")
            }
            return DisplayInputOutcome(state: .skipped, requestedInput: input,
                                       detail: "DDC is unavailable: \(error.localizedDescription). Use the monitor's input button.")
        }
        guard session.display.id == target.id,
              session.display.uuid.caseInsensitiveCompare(target.uuid) == .orderedSame else {
            return staleInputTarget(target, requested: input, actual: "opened DDC display ID \(session.display.id), UUID \(session.display.uuid)")
        }
        do {
            guard try matchesCapturedIdentity(target, records: mirror.records()) else {
                return staleInputTarget(target, requested: input, actual: "current display inventory after opening DDC")
            }
        } catch {
            return DisplayInputOutcome(state: .failed, requestedInput: input,
                                       detail: "Could not revalidate the captured DDC target identity: \(error.localizedDescription)")
        }

        let original: UInt8
        do {
            original = try DDCInput.current(session.channel)
        } catch {
            return DisplayInputOutcome(state: .skipped, requestedInput: input,
                                       detail: "DDC input could not be read: \(error.localizedDescription). Use the monitor's input button.")
        }
        guard original != 0 else {
            return DisplayInputOutcome(state: .skipped, requestedInput: input,
                                       detail: "DDC returned unknown input 0. Use the monitor's input button.")
        }
        let command = "panelctl ddc-input --display \(shellQuote(target.uuid)) --set \(String(format: "0x%02X", original))"
        willSelect(command)
        do {
            let result = try select(input, session.channel, target.id, target.uuid, original)
            switch result.outcome {
            case .alreadySelected:
                return DisplayInputOutcome(state: .alreadySelected, requestedInput: input,
                                           observedInput: result.observed, recoveryCommand: command)
            case .verified:
                return DisplayInputOutcome(state: .verified, requestedInput: input,
                                           observedInput: result.observed, recoveryCommand: command)
            case .unverified:
                return DisplayInputOutcome(state: .unverified, requestedInput: input,
                                           observedInput: result.observed, detail: result.detail,
                                           recoveryCommand: command)
            }
        } catch {
            return DisplayInputOutcome(state: .failed, requestedInput: input,
                                       detail: "DDC selection failed: \(error.localizedDescription)",
                                       recoveryCommand: command)
        }
    }

    private func matchesCapturedIdentity(_ target: RecoveryDisplay, records: [DisplayRecord]) -> Bool {
        let matches = records.filter { $0.uuid?.caseInsensitiveCompare(target.uuid) == .orderedSame }
        guard matches.count == 1, let record = matches.first else { return false }
        return record.id == target.id && record.vendor == target.vendor &&
            record.model == target.model && record.serial == target.serial
    }

    private func staleInputTarget(_ target: RecoveryDisplay, requested: UInt8, actual: String) -> DisplayInputOutcome {
        DisplayInputOutcome(
            state: .failed,
            requestedInput: requested,
            detail: "DDC target identity changed since capture (expected Display ID \(target.id), UUID \(target.uuid), vendor/model/serial \(target.vendor)/\(target.model)/\(target.serial); found \(actual). Refresh Displays and use the exact captured monitor; no input was selected."
        )
    }

    private func switchInput(_ input: UInt8?, target: RecoveryDisplay,
                             recovery: (String) -> Void) throws {
        let outcome = selectInput(input, target: target, willSelect: { command in
            recovery(command + ", or use the monitor's input button")
            report("To reverse input selection: \(command), or use the monitor's input button.")
        })
        switch outcome.state {
        case .notRequested:
            report("DDC skipped (no --input configured); use the monitor's input button.")
        case .notAttempted:
            report("DDC input was not attempted: \(outcome.detail ?? "unknown reason").")
        case .skipped:
            report("DDC skipped (\(outcome.detail ?? "unavailable")); use the monitor's input button.")
        case .verified, .alreadySelected, .unverified:
            report("DDC input outcome=\(outcome.state.rawValue)\(outcome.detail.map { ": \($0)" } ?? "")")
            if outcome.state == .unverified {
                report("Input switch is unverified; check visually and use the monitor's input button if needed.")
            }
        case .failed:
            throw RecoveryError.unsafe("\(outcome.detail ?? "DDC selection failed")\(outcome.recoveryCommand.map { ". Input recovery: \($0), or use the monitor's input button" } ?? "")")
        }
    }

    private func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
