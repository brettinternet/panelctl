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

public struct DisplayHideRemovalSummary: Equatable, Identifiable {
    public let id: String
    public let target: DisplayHideIdentity
    public let source: DisplayHideIdentity
    public let state: String
    public let isUnresolved: Bool
    public let canShow: Bool
    public let showRefusal: String?
    public let failure: String?
    public let topologyVerified: Bool

    init(id: String, target: DisplayHideIdentity, source: DisplayHideIdentity, state: String,
         isUnresolved: Bool, canShow: Bool, showRefusal: String?, failure: String?, topologyVerified: Bool) {
        self.id = id
        self.target = target
        self.source = source
        self.state = state
        self.isUnresolved = isUnresolved
        self.canShow = canShow
        self.showRefusal = showRefusal
        self.failure = failure
        self.topologyVerified = topologyVerified
    }
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
    public let removals: [DisplayHideRemovalSummary]

    init(id: String, state: String, target: DisplayHideIdentity?, source: DisplayHideIdentity?,
         isMirrorJournal: Bool, isUnresolved: Bool, canShow: Bool, showRefusal: String?,
         failure: String?, mirrorTopologyVerified: Bool = false,
         removals: [DisplayHideRemovalSummary] = []) {
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
        self.removals = removals
    }
}

public struct DisplayHideStatus: Equatable {
    public let journalPath: String
    public let observations: [DisplayHideObservation]
    public let journal: DisplayHideJournalSummary?
    public let inspectionFailure: String?
    public let removals: [DisplayHideRemovalSummary]

    public var hasUnresolvedRecovery: Bool { journal?.isUnresolved ?? (inspectionFailure != nil) }
    public var hasUnresolvedMirror: Bool {
        journal?.isUnresolved == true && journal?.isMirrorJournal == true
    }
    public var showAvailable: Bool { journal?.canShow == true }

    public init(journalPath: String, observations: [DisplayHideObservation], journal: DisplayHideJournalSummary?,
                inspectionFailure: String?, removals: [DisplayHideRemovalSummary] = []) {
        self.journalPath = journalPath
        self.observations = observations
        self.journal = journal
        self.inspectionFailure = inspectionFailure
        self.removals = removals
    }

    static func failed(path: String, error: Error) -> Self {
        Self(journalPath: path, observations: [], journal: nil, inspectionFailure: error.localizedDescription, removals: [])
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
        if journal.publicMirrorSession != nil {
            mirror.reconcileSession(&journal, current: current, store: store)
            return statusForMirrorSession(journal, records: records, current: current)
        }
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
    public func show(expectedJournalID: String, targetUUID: String? = nil,
                     returnInput: UInt8? = nil) throws -> DisplayInputOutcome {
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
        return try handoff.guardedBack(expectedJournalID: expectedID, targetUUID: targetUUID,
                                       input: returnInput, store: store)
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
        let mirrorTopologyVerified: Bool
        if unresolved, journal.state == .mirrored,
           let targetID = journal.mirrorTargetID, let sourceID = journal.mirrorSourceID {
            mirrorTopologyVerified = HiddenMirrorTopology.matches(
                snapshot: journal.snapshot, targetID: targetID, sourceID: sourceID, current: current
            )
        } else {
            mirrorTopologyVerified = false
        }

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
            if journal.state == .mirrored, !mirrorTopologyVerified, refusal == nil {
                refusal = "The current mirror topology does not match the journaled Hidden layout; review recovery before Show."
            }
        }

        let observations = currentRecords.map { uuid, record -> DisplayHideObservation in
            let saved = currentByUUID[uuid]
            let displayIdentity = saved.map(identity) ?? identity(record)
            let isTarget = target?.uuid.caseInsensitiveCompare(uuid) == .orderedSame
            let externallyMirrored = saved?.mirrorUUID != nil
            let hidden = mirrorTopologyVerified && isTarget &&
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
            mirrorTopologyVerified: mirrorTopologyVerified
        )
        return DisplayHideStatus(
            journalPath: store.url.path,
            observations: allObservations.sorted { $0.identity.uuid < $1.identity.uuid },
            journal: summary,
            inspectionFailure: nil
        )
    }

    private func statusForMirrorSession(_ journal: RecoveryJournal, records: [DisplayRecord],
                                        current: RecoverySnapshot) -> DisplayHideStatus {
        guard let session = journal.publicMirrorSession else {
            return .failed(path: store.url.path, error: RecoveryError.unsafe("missing public-mirror session"))
        }
        let currentByUUID = Dictionary(uniqueKeysWithValues: current.displays.map { ($0.uuid.lowercased(), $0) })
        let recordsByUUID = Dictionary(uniqueKeysWithValues: records.compactMap { record in
            record.uuid.map { ($0.lowercased(), record) }
        })
        let sessionVerified = MirrorSessionTopology.matches(
            baseline: session.baseline, removals: session.removals, current: current
        )
        let modeFailure: String?
        do { try mirror.preflightModes(session.baseline); modeFailure = nil }
        catch { modeFailure = error.localizedDescription }
        let removals = session.removals.map { removal -> DisplayHideRemovalSummary in
            let savedTarget = session.baseline.displays.first { $0.uuid == removal.targetUUID }
            let savedSource = session.baseline.displays.first { $0.uuid == removal.sourceUUID }
            let targetIdentity = savedTarget.map(identity) ?? DisplayHideIdentity(
                uuid: removal.targetUUID, displayID: removal.targetID, name: nil, vendor: 0, model: 0, serial: 0
            )
            let sourceIdentity = savedSource.map(identity) ?? DisplayHideIdentity(
                uuid: removal.sourceUUID, displayID: removal.sourceID, name: nil, vendor: 0, model: 0, serial: 0
            )
            let observedTarget = currentByUUID[removal.targetUUID]
            let observedSource = currentByUUID[removal.sourceUUID]
            let targetRecord = recordsByUUID[removal.targetUUID]
            let sourceRecord = recordsByUUID[removal.sourceUUID]
            let relationVerified = observedTarget?.id == removal.targetID &&
                observedTarget?.active == false &&
                observedTarget?.mirrorUUID?.caseInsensitiveCompare(removal.sourceUUID) == .orderedSame &&
                observedSource?.id == removal.sourceID && observedSource?.active == true &&
                observedSource?.mirrorUUID == nil && targetRecord?.online == true &&
                targetRecord?.asleep == false && sourceRecord?.online == true &&
                sourceRecord?.active == true && sourceRecord?.asleep == false
            let canRepairLayout = !removal.state.resolved &&
                (MirrorSessionTopology.canRestoreFinalLayout(
                    baseline: session.baseline, removals: session.removals,
                    targetUUID: removal.targetUUID, current: current
                ) || MirrorSessionTopology.canRepairTargetLayout(
                    baseline: session.baseline, removals: session.removals,
                    targetUUID: removal.targetUUID, current: current
                )) && targetRecord?.online == true && targetRecord?.asleep == false &&
                sourceRecord?.online == true && sourceRecord?.active == true && sourceRecord?.asleep == false
            let canShow = modeFailure == nil &&
                ((removal.state == .mirrored && sessionVerified && relationVerified) || canRepairLayout)
            let refusal: String?
            if canShow {
                refusal = nil
            } else if removal.state == .needsAttention {
                refusal = removal.failure ?? "This removal needs recovery."
            } else if !relationVerified {
                refusal = "The exact removed display or its source is unavailable or no longer matches. Reconnect the captured displays and inspect recovery."
            } else if !sessionVerified {
                refusal = journal.failure ?? "Another removal in this session needs attention; inspect recovery before Show."
            } else if let modeFailure {
                refusal = modeFailure
            } else if removal.state != .mirrored {
                refusal = "This removal is still in an interrupted operation; inspect recovery before continuing."
            } else {
                refusal = nil
            }
            return DisplayHideRemovalSummary(
                id: removal.id.uuidString, target: targetIdentity, source: sourceIdentity,
                state: removal.state.rawValue, isUnresolved: !removal.state.resolved,
                canShow: canShow, showRefusal: refusal, failure: removal.failure,
                topologyVerified: relationVerified
            )
        }
        var observations: [DisplayHideObservation] = records.compactMap { record in
            guard let uuid = record.uuid?.lowercased() else { return nil }
            let saved = currentByUUID[uuid]
            let targetRemoval = removals.first { $0.isUnresolved && $0.target.uuid == uuid }
            let displayIdentity = saved.map(identity) ?? identity(record)
            let source = targetRemoval?.source
            let state: DisplayHideObservedState
            let detail: String?
            if let targetRemoval, targetRemoval.topologyVerified,
               targetRemoval.state == PublicMirrorRemovalState.mirrored.rawValue {
                state = .hiddenByPanelCtl
                detail = "Desktop hidden by PanelCtl; monitor input is unknown. Use the monitor's input buttons if needed."
            } else if let targetRemoval {
                state = .recoveryNeeded
                detail = targetRemoval.failure ?? targetRemoval.showRefusal
            } else if saved?.mirrorUUID != nil {
                state = .mirroredExternally
                detail = "Mirrored outside PanelCtl; correct this manually in macOS Displays settings."
            } else {
                state = .separate
                detail = nil
            }
            return DisplayHideObservation(identity: displayIdentity, state: state, source: source,
                                          detail: detail, isJournalTarget: targetRemoval != nil)
        }
        for removal in removals where removal.isUnresolved &&
            !observations.contains(where: { $0.identity.uuid == removal.target.uuid }) {
            observations.append(DisplayHideObservation(
                identity: removal.target, state: .unavailable, source: removal.source,
                detail: removal.showRefusal ?? "Reconnect the exact removed display to continue recovery.",
                isJournalTarget: true
            ))
        }
        let unresolved = removals.filter(\.isUnresolved)
        let primary = unresolved.first
        let summary = DisplayHideJournalSummary(
            id: journal.id.uuidString, state: journal.state.rawValue,
            target: primary?.target, source: primary?.source, isMirrorJournal: true,
            isUnresolved: !journal.state.resolved, canShow: removals.contains(where: \.canShow),
            showRefusal: unresolved.first(where: { !$0.canShow })?.showRefusal,
            failure: journal.failure,
            mirrorTopologyVerified: sessionVerified,
            removals: removals
        )
        return DisplayHideStatus(journalPath: store.url.path,
                                 observations: observations.sorted { $0.identity.uuid < $1.identity.uuid },
                                 journal: summary, inspectionFailure: nil, removals: removals)
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
