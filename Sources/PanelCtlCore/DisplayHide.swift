import Foundation

public enum DisplayHideObservedState: String, Equatable {
    case separate
    case hiddenByPanelCtl
    case unavailable
    case mirroredExternally
    case recoveryNeeded
    case unsupportedRecovery
    case unknown
}

public struct DisplayHideIdentity: Equatable, Identifiable {
    public let uuid: String
    public let displayID: UInt32
    public let name: String
    public let vendor: UInt32
    public let model: UInt32
    public let serial: UInt32

    public var id: String { uuid }
    public var detail: String {
        "UUID \(uuid) · vendor \(vendor) · model \(model) · serial \(serial) · display ID \(displayID)"
    }

    public init(uuid: String, displayID: UInt32, name: String?, vendor: UInt32, model: UInt32, serial: UInt32) {
        self.uuid = uuid.lowercased()
        self.displayID = displayID
        self.name = name?.isEmpty == false ? name! : "Display \(displayID)"
        self.vendor = vendor
        self.model = model
        self.serial = serial
    }
}

public struct DisplayHideObservation: Equatable, Identifiable {
    public let identity: DisplayHideIdentity
    public let state: DisplayHideObservedState
    public let source: DisplayHideIdentity?
    public let detail: String?
    public let isJournalTarget: Bool

    public var id: String { identity.uuid }
}

public struct DisplayHideJournalSummary: Equatable {
    public let id: String
    public let state: String
    public let target: DisplayHideIdentity?
    public let source: DisplayHideIdentity?
    public let isMirrorJournal: Bool
    public let isUnresolved: Bool
    public let canShow: Bool
    public let showRefusal: String?
    public let failure: String?
    public let mirrorTopologyVerified: Bool

    init(id: String, state: String, target: DisplayHideIdentity?, source: DisplayHideIdentity?,
         isMirrorJournal: Bool, isUnresolved: Bool, canShow: Bool, showRefusal: String?,
         failure: String?, mirrorTopologyVerified: Bool = false) {
        self.id = id
        self.state = state
        self.target = target
        self.source = source
        self.isMirrorJournal = isMirrorJournal
        self.isUnresolved = isUnresolved
        self.canShow = canShow
        self.showRefusal = showRefusal
        self.failure = failure
        self.mirrorTopologyVerified = mirrorTopologyVerified
    }
}

public struct DisplayHideStatus: Equatable {
    public let journalPath: String
    public let observations: [DisplayHideObservation]
    public let journal: DisplayHideJournalSummary?
    public let inspectionFailure: String?

    public var hasUnresolvedRecovery: Bool { journal?.isUnresolved ?? (inspectionFailure != nil) }
    public var hasUnresolvedMirror: Bool {
        journal?.isUnresolved == true && journal?.isMirrorJournal == true
    }
    public var showAvailable: Bool { journal?.canShow == true }

    static func failed(path: String, error: Error) -> Self {
        Self(journalPath: path, observations: [], journal: nil, inspectionFailure: error.localizedDescription)
    }
}

/// App-facing read/status and explicit Hide/Show entry points. Writes still go
/// through MirrorController's shared operation lock, journal lock and writer.
public struct DisplayHideController {
    private let store: RecoveryStore
    private let mirror: MirrorController
    private let handoff: HandoffController
    private let operationLock: () -> RecoveryStore

    public init() {
        let store = RecoveryStore()
        let mirror = MirrorController()
        self.store = store
        self.mirror = mirror
        handoff = HandoffController(mirror: mirror, report: { _ in })
        operationLock = { RecoveryStore.operationLock() }
    }

    init(store: RecoveryStore, mirror: MirrorController,
         operationLock: @escaping () -> RecoveryStore,
         handoff: HandoffController? = nil) {
        self.store = store
        self.mirror = mirror
        self.handoff = handoff ?? HandoffController(mirror: mirror, report: { _ in })
        self.operationLock = operationLock
    }

    public func inspect() throws -> DisplayHideStatus {
        let operation = operationLock()
        try operation.lock()
        defer { operation.unlock() }
        try store.lock()
        defer { store.unlock() }

        let records = try mirror.records()
        let current = try mirror.engine.capture()
        guard try store.exists() else {
            return statusWithoutJournal(records: records, current: current)
        }

        var journal = try store.load()
        let isMirror = journal.mirrorTargetID != nil && journal.mirrorSourceID != nil
        if !journal.state.resolved, isMirror, (try? journal.snapshot.verify(current)) != nil {
            // Accept a macOS/system restoration only after exact public snapshot
            // verification. This retires journal intent without topology writes.
            journal.state = .verified
            journal.trigger = "system-restoration-verified"
            journal.failure = nil
            try store.save(journal)
        }

        if !isMirror {
            return statusForUnsupportedJournal(journal, records: records, current: current)
        }
        return statusForMirrorJournal(journal, records: records, current: current)
    }

    @discardableResult
    public func hide(target: DisplayHideIdentity, source: DisplayHideIdentity,
                     awayInput: UInt8? = nil) throws -> DisplayInputOutcome {
        guard UUID(uuidString: target.uuid) != nil,
              UUID(uuidString: source.uuid) != nil,
              target.uuid.caseInsensitiveCompare(source.uuid) != .orderedSame else {
            throw RecoveryError.unsafe("Hide requires distinct, explicit display UUIDs")
        }
        return try handoff.guardedAway(target: target, source: source, input: awayInput, store: store)
    }

    @discardableResult
    public func show(expectedJournalID: String, returnInput: UInt8? = nil) throws -> DisplayInputOutcome {
        guard let expectedID = UUID(uuidString: expectedJournalID) else {
            let outcome = returnInput.map {
                DisplayInputOutcome(state: .notAttempted, requestedInput: $0,
                                    detail: "Input selection was not attempted because the journal identity is invalid.")
            } ?? .notRequested
            throw DisplayHandoffOperationFailure(
                action: "show", inputOutcome: outcome,
                message: "invalid journal identity; refresh recovery status and confirm again"
            )
        }
        return try handoff.guardedBack(expectedJournalID: expectedID, input: returnInput, store: store)
    }

    public func checkInputAvailability(target: DisplayHideIdentity) throws -> DDCInputReading {
        let operation = operationLock()
        try operation.lock()
        defer { operation.unlock() }
        let records = try mirror.records()
        guard Self.matches(target, records: records) else {
            throw RecoveryError.unsafe("DDC availability check refused because the saved target identity changed. Refresh Displays and reconnect the exact display.")
        }
        let reading = try DDCInput.read(selector: target.uuid)
        guard reading.displayID == target.displayID,
              reading.uuid.caseInsensitiveCompare(target.uuid) == .orderedSame,
              Self.matches(target, records: try mirror.records()) else {
            throw RecoveryError.unsafe("DDC availability check resolved a different display identity. Refresh Displays; no input was changed.")
        }
        return reading
    }

    private static func matches(_ expected: DisplayHideIdentity, records: [DisplayRecord]) -> Bool {
        let matches = records.filter { $0.uuid?.caseInsensitiveCompare(expected.uuid) == .orderedSame }
        guard matches.count == 1, let record = matches.first else { return false }
        return record.id == expected.displayID && record.vendor == expected.vendor &&
            record.model == expected.model && record.serial == expected.serial
    }

    private func statusWithoutJournal(records: [DisplayRecord], current: RecoverySnapshot) -> DisplayHideStatus {
        let identities = Dictionary(uniqueKeysWithValues: current.displays.map { ($0.uuid.lowercased(), identity($0)) })
        let observations = records.compactMap { record -> DisplayHideObservation? in
            guard let uuid = record.uuid?.lowercased() else { return nil }
            let saved = current.displays.first { $0.uuid.caseInsensitiveCompare(uuid) == .orderedSame }
            let displayIdentity = saved.map(identity) ?? identity(record)
            let source = saved?.mirrorUUID.flatMap { identities[$0.lowercased()] }
            return DisplayHideObservation(
                identity: displayIdentity,
                state: saved?.mirrorUUID == nil ? .separate : .mirroredExternally,
                source: source,
                detail: saved?.mirrorUUID == nil ? nil : "Mirrored outside PanelCtl; correct this manually in macOS Displays settings.",
                isJournalTarget: false
            )
        }
        return DisplayHideStatus(journalPath: store.url.path, observations: observations, journal: nil, inspectionFailure: nil)
    }

    private func statusForMirrorJournal(_ journal: RecoveryJournal, records: [DisplayRecord],
                                        current: RecoverySnapshot) -> DisplayHideStatus {
        let target = journal.snapshot.displays.first { $0.id == journal.mirrorTargetID }
        let source = journal.snapshot.displays.first { $0.id == journal.mirrorSourceID }
        let targetIdentity = target.map(identity)
        let sourceIdentity = source.map(identity)
        let unresolved = !journal.state.resolved
        let currentByUUID = Dictionary(uniqueKeysWithValues: current.displays.map { ($0.uuid.lowercased(), $0) })
        let currentRecords = Dictionary(uniqueKeysWithValues: records.compactMap { record in
            record.uuid.map { ($0.lowercased(), record) }
        })

        var refusal: String?
        var canShow = false
        if unresolved, let target, let source {
            do {
                try journal.snapshot.validateRestoration(to: current)
                try mirror.preflightModes(journal.snapshot)
                canShow = true
            } catch {
                refusal = error.localizedDescription
            }
            if currentByUUID[target.uuid.lowercased()] == nil {
                refusal = "The journaled target is unavailable. Reconnect the exact display identity and Refresh; PanelCtl will not guess a replacement."
                canShow = false
            }
            if currentByUUID[source.uuid.lowercased()] == nil {
                refusal = "The journaled mirror source is unavailable. Reconnect the exact captured displays and Refresh."
                canShow = false
            }
            if let targetRecord = currentRecords[target.uuid.lowercased()],
               !targetRecord.online || targetRecord.asleep {
                refusal = "The journaled target is asleep or unavailable. Wake or reconnect the exact display, then Refresh before Show."
                canShow = false
            }
            if let sourceRecord = currentRecords[source.uuid.lowercased()],
               !sourceRecord.online || !sourceRecord.active || sourceRecord.asleep {
                refusal = "The journaled mirror source is asleep, inactive, or unavailable. Wake or reconnect the exact display, then Refresh before Show."
                canShow = false
            }
        }

        let observations = currentRecords.map { uuid, record -> DisplayHideObservation in
            let saved = currentByUUID[uuid]
            let displayIdentity = saved.map(identity) ?? identity(record)
            let isTarget = target?.uuid.caseInsensitiveCompare(uuid) == .orderedSame
            let externallyMirrored = saved?.mirrorUUID != nil
            let hidden = unresolved && journal.state == .mirrored && isTarget &&
                saved?.mirrorUUID?.caseInsensitiveCompare(source?.uuid ?? "") == .orderedSame
            let state: DisplayHideObservedState = hidden
                ? .hiddenByPanelCtl
                : isTarget && unresolved
                    ? .recoveryNeeded
                    : externallyMirrored ? .mirroredExternally : .separate
            let detail: String?
            if hidden {
                detail = "Desktop hidden by PanelCtl; monitor input is unknown. Use the monitor's input buttons if needed."
            } else if isTarget && unresolved {
                detail = journal.failure ?? refusal ?? "Observed topology does not match the journaled Hide; review recovery."
            } else if externallyMirrored {
                detail = "Mirrored outside PanelCtl; correct this manually in macOS Displays settings."
            } else {
                detail = nil
            }
            return DisplayHideObservation(
                identity: displayIdentity,
                state: state,
                source: isTarget ? sourceIdentity : nil,
                detail: detail,
                isJournalTarget: isTarget
            )
        }

        var allObservations = observations
        if unresolved, let target, currentByUUID[target.uuid.lowercased()] == nil {
            allObservations.append(DisplayHideObservation(
                identity: identity(target), state: .unavailable, source: sourceIdentity,
                detail: refusal, isJournalTarget: true
            ))
        }
        let summary = DisplayHideJournalSummary(
            id: journal.id.uuidString,
            state: journal.state.rawValue,
            target: targetIdentity,
            source: sourceIdentity,
            isMirrorJournal: true,
            isUnresolved: unresolved,
            canShow: canShow,
            showRefusal: unresolved ? refusal : nil,
            failure: journal.failure,
            mirrorTopologyVerified: unresolved && journal.state == .mirrored &&
                Self.matchesHiddenMirrorTopology(journal, current: current)
        )
        return DisplayHideStatus(
            journalPath: store.url.path,
            observations: allObservations.sorted { $0.identity.uuid < $1.identity.uuid },
            journal: summary,
            inspectionFailure: nil
        )
    }

    private static func matchesHiddenMirrorTopology(
        _ journal: RecoveryJournal,
        current: RecoverySnapshot
    ) -> Bool {
        guard let targetID = journal.mirrorTargetID,
              let sourceID = journal.mirrorSourceID,
              let source = journal.snapshot.displays.first(where: { $0.id == sourceID }) else {
            return false
        }
        let originalByID = Dictionary(uniqueKeysWithValues: journal.snapshot.displays.map { ($0.id, $0) })
        guard current.displays.count == originalByID.count else { return false }
        return current.displays.allSatisfy { display in
            guard let original = originalByID[display.id] else { return false }
            let expectedMirror = display.id == targetID ? source.uuid : nil
            let mirrorMatches: Bool
            if let expectedMirror, let observedMirror = display.mirrorUUID {
                mirrorMatches = expectedMirror.caseInsensitiveCompare(observedMirror) == .orderedSame
            } else {
                mirrorMatches = expectedMirror == nil && display.mirrorUUID == nil
            }
            return mirrorMatches && display.main == original.main &&
                (display.id != sourceID || display.active)
        }
    }

    private func statusForUnsupportedJournal(_ journal: RecoveryJournal, records: [DisplayRecord],
                                             current: RecoverySnapshot) -> DisplayHideStatus {
        let privateTarget = journal.disabledByUsID.flatMap { id in journal.snapshot.displays.first { $0.id == id } }
        let targetIdentity = privateTarget.map(identity)
        var observations = statusWithoutJournal(records: records, current: current).observations
        if journal.state.resolved == false, let privateTarget,
           !observations.contains(where: { $0.identity.uuid == privateTarget.uuid.lowercased() }) {
            observations.append(DisplayHideObservation(
                identity: identity(privateTarget), state: .unsupportedRecovery, source: nil,
                detail: "Unsupported recovery kind; use the journal-specific CLI recovery command.", isJournalTarget: true
            ))
        }
        let summary = DisplayHideJournalSummary(
            id: journal.id.uuidString, state: journal.state.rawValue,
            target: targetIdentity, source: nil, isMirrorJournal: false,
            isUnresolved: !journal.state.resolved, canShow: false,
            showRefusal: journal.state.resolved ? nil : "This journal is not a public mirror journal. Use panelctl recovery status --journal '\(store.url.path)' and its recorded CLI recovery action.",
            failure: journal.failure
        )
        return DisplayHideStatus(
            journalPath: store.url.path, observations: observations, journal: summary,
            inspectionFailure: nil
        )
    }

    private func identity(_ display: RecoveryDisplay) -> DisplayHideIdentity {
        DisplayHideIdentity(uuid: display.uuid, displayID: display.id, name: display.name,
                            vendor: display.vendor, model: display.model, serial: display.serial)
    }

    private func identity(_ display: DisplayRecord) -> DisplayHideIdentity {
        DisplayHideIdentity(uuid: display.uuid ?? "unavailable-\(display.id)", displayID: display.id,
                            name: display.name, vendor: display.vendor, model: display.model,
                            serial: display.serial)
    }
}
