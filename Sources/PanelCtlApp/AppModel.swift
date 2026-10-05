import AppKit
import Foundation
import PanelCtlCore

struct AppNotice: Identifiable, Equatable {
    let id = UUID()
    let title: String
    let message: String
    let opensLoginItemSettings: Bool
}

typealias ProtectionQuiesce = (@escaping (Bool, String?) -> Void) -> Void

@MainActor
final class AppModel: ObservableObject {
    static let githubURL = URL(string: "https://github.com/brettinternet/panelctl")!
    static let experimentalDocsURL = URL(string: "https://github.com/brettinternet/panelctl/blob/main/docs/display-hide-ux.md")!

    @Published var preferences: ProtectionPreferences {
        didSet {
            guard preferences != oldValue else { return }
            savePreferences()
            reconcileProtection()
            onStatusChange?()
        }
    }
    @Published var showMenuBarIcon: Bool {
        didSet {
            guard showMenuBarIcon != oldValue else { return }
            defaults.set(showMenuBarIcon, forKey: Self.showMenuBarIconKey)
            onStatusChange?()
        }
    }
    /// Gates experimental display features. Show and recovery never depend on it.
    @Published private(set) var experimentalFeaturesEnabled: Bool {
        didSet {
            guard experimentalFeaturesEnabled != oldValue else { return }
            defaults.set(experimentalFeaturesEnabled, forKey: Self.experimentalFeaturesKey)
            onStatusChange?()
        }
    }
    @Published private(set) var displays: [DisplayRecord]
    @Published private(set) var hidePreferences: DisplayHidePreferences {
        didSet {
            guard hidePreferences != oldValue else { return }
            saveHidePreferences()
            onStatusChange?()
        }
    }
    @Published private(set) var handoffStatus: DisplayHandoffStatus?
    @Published private(set) var handoffInspectionFailure: String?
    @Published private(set) var ddcInputAvailability: [String: DisplayDDCInputAvailability] = [:]
    @Published private(set) var hideOperation: DisplayHideOperation = .idle
    @Published private(set) var protectionQuiescencePending = false
    @Published private(set) var protectionQuiescenceFailure: String?
    @Published private(set) var displayLifecycleTransitioning = false
    @Published private(set) var displayRecoveryFocusRequest = 0
    @Published private(set) var runtimeState: ProtectionRuntimeState = .disabled {
        didSet {
            if runtimeState != oldValue {
                if case .blackedOut = runtimeState {
                    if case .blackedOut = oldValue {
                        // Preserve the original follow-up deadline.
                    } else {
                        stateBeganAt = now()
                    }
                } else {
                    stateBeganAt = nil
                }
                onStatusChange?()
            }
        }
    }
    @Published private(set) var blackedOutDisplayIDs: Set<UInt32> = [] {
        didSet {
            if oldValue != blackedOutDisplayIDs {
                onStatusChange?()
            }
        }
    }
    @Published private(set) var launchAtLoginEnabled: Bool
    @Published var notice: AppNotice?
    @Published var experimentalConsentPending = false
    @Published private(set) var countdownDate = Date()

    var onStatusChange: (() -> Void)?

    private let defaults: UserDefaults
    private let displayProvider: () -> [DisplayRecord]
    private let now: () -> Date
    private let idleSecondsProvider: () -> TimeInterval?
    private let sleepDisplays: () throws -> Void
    private let isDisplayMirrored: (UInt32) -> Bool
    private let inspectHandoff: () -> DisplayHandoffStatus
    private let hideDisplay: (DisplayHideIdentity, DisplayHideIdentity, UInt8?) throws -> DisplayInputOutcome
    private let showDisplay: (String, UInt8?) throws -> DisplayInputOutcome
    private let checkDDCInput: (DisplayHideIdentity) throws -> DDCInputReading
    private let quiesceProtection: ProtectionQuiesce?
    private let service: ProtectionService
    private var snoozeTimer: Timer?
    private var manualActivityDate: Date?
    private var protectionRearmRequired = false
    private static let preferencesKey = "blackoutPreferences"
    private static let hidePreferencesKey = "displayHidePreferences"
    private static let showMenuBarIconKey = "showMenuBarIcon"
    private static let experimentalFeaturesKey = "experimentalFeaturesEnabled"
    private static let snoozedUntilKey = "snoozedUntil"
    static let maximumSnoozeDuration: TimeInterval = 30 * 24 * 60 * 60

    init(
        defaults: UserDefaults = .standard,
        displayProvider: @escaping () -> [DisplayRecord] = { DisplayInventory.records() },
        now: @escaping () -> Date = Date.init,
        idleSecondsProvider: @escaping () -> TimeInterval? = {
            guard let anyInput = CGEventType(rawValue: UInt32.max) else { return nil }
            return CGEventSource.secondsSinceLastEventType(
                .combinedSessionState,
                eventType: anyInput
            )
        },
        sleepDisplays: @escaping () throws -> Void = DisplaySleepController.sleep,
        isDisplayMirrored: @escaping (UInt32) -> Bool = { CGDisplayIsInMirrorSet($0) != 0 },
        inspectHandoff: @escaping () -> DisplayHandoffStatus = DisplayHandoff.inspect,
        hideDisplay: @escaping (DisplayHideIdentity, DisplayHideIdentity, UInt8?) throws -> DisplayInputOutcome = {
            try DisplayHideController().hide(target: $0, source: $1, awayInput: $2)
        },
        showDisplay: @escaping (String, UInt8?) throws -> DisplayInputOutcome = {
            try DisplayHideController().show(expectedJournalID: $0, returnInput: $1)
        },
        checkDDCInput: @escaping (DisplayHideIdentity) throws -> DDCInputReading = {
            try DisplayHideController().checkInputAvailability(target: $0)
        },
        quiesceProtection: ProtectionQuiesce? = nil
    ) {
        self.defaults = defaults
        self.displayProvider = displayProvider
        self.now = now
        self.idleSecondsProvider = idleSecondsProvider
        self.sleepDisplays = sleepDisplays
        self.isDisplayMirrored = isDisplayMirrored
        self.inspectHandoff = inspectHandoff
        self.hideDisplay = hideDisplay
        self.showDisplay = showDisplay
        self.checkDDCInput = checkDDCInput
        self.quiesceProtection = quiesceProtection
        self.showMenuBarIcon = defaults.object(forKey: Self.showMenuBarIconKey) as? Bool ?? true
        self.experimentalFeaturesEnabled = defaults.bool(forKey: Self.experimentalFeaturesKey)
        let loadedHidePreferences = defaults.data(forKey: Self.hidePreferencesKey)
            .flatMap { try? JSONDecoder().decode(DisplayHidePreferences.self, from: $0) }
        self.hidePreferences = loadedHidePreferences ?? DisplayHidePreferences()
        let loadedPreferences = defaults.data(forKey: Self.preferencesKey)
            .flatMap { try? JSONDecoder().decode(ProtectionPreferences.self, from: $0) }

        var preferences = loadedPreferences ?? ProtectionPreferences()
        preferences.selectedDisplayUUIDs = Set(
            preferences.selectedDisplayUUIDs.map { $0.uppercased() }
        )
        let displays = displayProvider()
        if !preferences.didChooseDisplays {
            let drawable = displays.filter {
                $0.active && $0.online && $0.bounds.width > 0 && $0.bounds.height > 0
            }
            let selectable = drawable.filter { $0.uuid != nil }
            let preferred = selectable.filter { !$0.builtin }
            let initial = preferred.first ?? selectable.first
            preferences.allDisplays = false
            preferences.selectedDisplayUUIDs = initial?.uuid
                .map { Set([$0.uppercased()]) } ?? []
            preferences.didChooseDisplays = true
        }

        self.preferences = preferences
        self.displays = displays
        launchAtLoginEnabled = LaunchAtLogin.isEnabled
        service = ProtectionService()
        let storedSnooze = defaults.object(forKey: Self.snoozedUntilKey) as? Date
        if let storedSnooze, storedSnooze > now(), preferences.isEnabled {
            runtimeState = .snoozed(storedSnooze)
        } else {
            defaults.removeObject(forKey: Self.snoozedUntilKey)
        }
        service.onStateChange = { [weak self] state in
            guard let self else { return }
            self.runtimeState = self.presentedRuntimeState(for: state)
            if case .waitingForDisplays = state {
                DispatchQueue.main.async {
                    self.refreshDisplays()
                }
            }
        }
        service.onMembershipChange = { [weak self] displayIDs in
            self?.blackedOutDisplayIDs = displayIDs
        }
        savePreferences()
        defaults.set(showMenuBarIcon, forKey: Self.showMenuBarIconKey)
        refreshHandoffStatus()
        reconcileProtection()
        startCountdownTimer()
    }

    var activeDisplays: [DisplayRecord] {
        displays.filter {
            $0.active &&
            $0.online &&
            $0.bounds.width > 0 &&
            $0.bounds.height > 0
        }
    }

    var menuHideConfigurations: [DisplayHideConfiguration] {
        guard experimentalFeaturesEnabled, !protectionPausedForDisplayRecovery else { return [] }
        return hideDisplayConfigurations.filter {
            $0.enabled && hideReadinessMessage(for: $0) == nil
        }
    }

    var hideDisplayConfigurations: [DisplayHideConfiguration] {
        var result: [DisplayHideConfiguration] = []
        var seen = Set<String>()
        for display in activeDisplays where isEligibleHideTarget(display) {
            guard let uuid = display.uuid else { continue }
            let key = uuid.lowercased()
            result.append(hidePreferences[uuid] ?? DisplayHideConfiguration(target: DisplayIdentitySnapshot(display)))
            seen.insert(key)
        }
        for configuration in hidePreferences.configurations.values
            .sorted(by: { $0.target.uuid.localizedCaseInsensitiveCompare($1.target.uuid) == .orderedAscending })
        where !seen.contains(configuration.target.uuid.lowercased()) {
            result.append(configuration)
            seen.insert(configuration.target.uuid.lowercased())
        }
        if let target = handoffStatus?.target, !seen.contains(target.uuid.lowercased()) {
            let targetIdentity = DisplayIdentitySnapshot(
                uuid: target.uuid,
                id: target.id,
                name: target.name,
                vendor: target.vendor,
                model: target.model,
                serial: target.serial
            )
            let sourceIdentity = handoffStatus?.source.map {
                DisplayIdentitySnapshot(
                    uuid: $0.uuid,
                    id: $0.id,
                    name: $0.name,
                    vendor: $0.vendor,
                    model: $0.model,
                    serial: $0.serial
                )
            }
            result.append(hidePreferences[target.uuid] ?? DisplayHideConfiguration(
                target: targetIdentity,
                source: sourceIdentity
            ))
        }
        return result
    }

    var protectionPausedForDisplayRecovery: Bool {
        handoffStatus?.hasUnresolvedJournal == true || handoffInspectionFailure != nil ||
            protectionQuiescencePending || protectionQuiescenceFailure != nil || hideOperation.isBusy
    }

    var verifiedHiddenMirrorSource: DisplayRecord? {
        guard handoffInspectionFailure == nil,
              !protectionQuiescencePending,
              protectionQuiescenceFailure == nil,
              !hideOperation.isBusy,
              !displayLifecycleTransitioning,
              let status = handoffStatus,
              status.state == .hidden,
              status.canShow,
              status.mirrorTopologyVerified,
              status.journalID != nil,
              let source = status.source else { return nil }
        let matches = activeDisplays.filter {
            $0.uuid?.caseInsensitiveCompare(source.uuid) == .orderedSame
        }
        guard matches.count == 1, let display = matches.first,
              display.id == source.id,
              display.vendor == source.vendor,
              display.model == source.model,
              display.serial == source.serial,
              display.online, display.active, !display.asleep else { return nil }
        return display
    }

    var selectedHiddenMirrorSource: DisplayRecord? {
        guard let source = verifiedHiddenMirrorSource,
              let uuid = source.uuid,
              preferences.allDisplays || preferences.selectedDisplayUUIDs.contains(where: {
                  $0.caseInsensitiveCompare(uuid) == .orderedSame
              }) else { return nil }
        return source
    }

    var hiddenMirrorOverlayPolicyEligible: Bool {
        protectionPausedForDisplayRecovery && preferences.isEnabled &&
            snoozedUntil == nil && selectedHiddenMirrorSource != nil
    }

    var effectiveBlackoutMode: BlackoutMode {
        hiddenMirrorOverlayPolicyEligible ? .blocking : preferences.mode
    }

    var hiddenMirrorProtectionSummary: String {
        guard protectionPausedForDisplayRecovery else { return statusSummary }
        if let failure = protectionQuiescenceFailure {
            return "Automation suspended while desktop is hidden · cleanup needs attention: \(failure)"
        }
        if protectionQuiescencePending {
            return "Automation suspended while desktop is hidden · waiting for cleanup to finish"
        }
        if displayLifecycleTransitioning {
            return "Automation suspended while desktop is hidden · display transition in progress"
        }
        if hiddenMirrorOverlayPolicyEligible, let source = selectedHiddenMirrorSource {
            let name = source.name ?? "Display \(source.id)"
            switch runtimeState {
            case .blackedOut:
                return "Desktop hidden · overlay blackout on \(name); mirrored target is black on the Mac input"
            case .starting:
                return "Desktop hidden · automation is starting on \(name); brightness dimming and automatic Sleep are suspended"
            case .waiting:
                return "Desktop hidden · automation watching \(name); brightness dimming and automatic Sleep are suspended"
            case .waitingForInput:
                return "Desktop hidden · automation waiting for fresh activity on \(name)"
            case .waitingForPlayback:
                return "Desktop hidden · automation paused while media or camera activity is detected on \(name)"
            case .sleeping:
                return "Desktop hidden · automation paused while displays sleep"
            case .stopping:
                return "Desktop hidden · automation is stopping on \(name)"
            case .waitingForDisplays(let message):
                return "Desktop hidden · automation waiting for displays: \(message)"
            case .failed(let message):
                return "Desktop hidden · automation failed on \(name): \(message)"
            case .disabled:
                return "Desktop hidden · automation is off on \(name)"
            case .snoozed:
                return "Automation paused while desktop is hidden"
            }
        }
        if let source = verifiedHiddenMirrorSource {
            let name = source.name ?? "Display \(source.id)"
            if preferences.isEnabled && snoozedUntil == nil {
                return "Automation suspended while hidden · \(name) is not in the idle display list"
            }
            if snoozedUntil != nil { return "Automation paused while desktop is hidden" }
            return "Automation off while desktop is hidden"
        }
        return "Automation suspended until display recovery finishes"
    }

    var hideConfigurationFrozen: Bool {
        handoffStatus?.hasUnresolvedJournal == true || handoffInspectionFailure != nil ||
            hideOperation.isBusy || displayLifecycleTransitioning
    }

    var unavailableSelectedDisplayUUIDs: [String] {
        guard !preferences.allDisplays else { return [] }
        let available = Set(activeDisplays.compactMap(\.uuid).map { $0.uppercased() })
        return preferences.selectedDisplayUUIDs
            .map { $0.uppercased() }
            .filter { !available.contains($0) }
            .sorted()
    }

    var validationMessage: String? {
        do {
            _ = try preferences.commandArguments(for: displays)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func identityIsCurrent(_ identity: DisplayIdentitySnapshot) -> Bool {
        matchingDisplay(identity) != nil
    }

    func sourceChoices(for configuration: DisplayHideConfiguration) -> [DisplayRecord] {
        guard !configuration.target.uuid.isEmpty else { return [] }
        return activeDisplays.filter { display in
            display.online && display.active && !display.asleep &&
                display.uuid.map { $0.caseInsensitiveCompare(configuration.target.uuid) != .orderedSame } == true
        }
    }

    func hideReadinessMessage(
        for configuration: DisplayHideConfiguration,
        allowingCurrentOperation: Bool = false
    ) -> String? {
        guard handoffInspectionFailure == nil else {
            return "Could not inspect shared display recovery: \(handoffInspectionFailure ?? "unknown error")"
        }
        guard allowingCurrentOperation || !hideConfigurationFrozen else {
            return handoffStatus?.state == .busy
                ? "Another display operation is using the shared recovery lock. Refresh and try again."
                : "Resolve display recovery before changing Hide settings."
        }
        guard configuration.enabled else { return "Enable experimental hide for this display first." }
        guard let target = matchingDisplay(configuration.target) else {
            return "Unavailable or changed display identity. Reconnect the exact display and Refresh; PanelCtl will not bind this setting to another display."
        }
        guard isEligibleHideTarget(target) else {
            return "Only an awake, active, non-main external display can be hidden."
        }
        guard !isDisplayMirrored(target.id) else {
            return "This display is already mirrored outside PanelCtl. Correct it in macOS Displays before hiding."
        }
        guard let sourceIdentity = configuration.source else {
            return "Choose a mirror source explicitly; PanelCtl never chooses one for you."
        }
        guard let source = matchingDisplay(sourceIdentity) else {
            return "The saved mirror source is unavailable or its identity changed. Reconnect that exact display and choose the source again."
        }
        guard source.online, source.active, !source.asleep else {
            return "The explicit mirror source must be online, active, and awake."
        }
        guard target.id != source.id else {
            return "The mirror source must be different from the target."
        }
        guard handoffStatus?.state == DisplayHandoffStatus.State.none else {
            return "Resolve the shared display recovery journal before another Hide."
        }
        guard !displayLifecycleTransitioning else {
            return "Wait for the display transition to finish, then Refresh."
        }
        return nil
    }

    func observedDesktopState(for configuration: DisplayHideConfiguration) -> String {
        if handoffInspectionFailure != nil { return "Recovery status unavailable" }
        if let observation = handoffStatus?.observations.first(where: {
            $0.identity.uuid.caseInsensitiveCompare(configuration.target.uuid) == .orderedSame
        }) {
            switch observation.state {
            case .separate: return "Separate"
            case .hiddenByPanelCtl: return "Hidden by PanelCtl"
            case .unavailable: return "Unavailable"
            case .mirroredExternally: return "Mirrored outside PanelCtl"
            case .recoveryNeeded: return "Recovery needed"
            case .unsupportedRecovery: return "Unsupported recovery journal"
            case .unknown: return "Unknown"
            }
        }
        guard let display = matchingDisplay(configuration.target) else { return "Unavailable" }
        guard display.online, display.active else { return "Unavailable" }
        return isDisplayMirrored(display.id) ? "Mirrored outside PanelCtl" : "Separate"
    }

    func automationSelectionState(for configuration: DisplayHideConfiguration) -> String {
        if preferences.allDisplays { return "Included (all displays)" }
        let selected = preferences.selectedDisplayUUIDs.contains {
            $0.caseInsensitiveCompare(configuration.target.uuid) == .orderedSame
        }
        return selected ? "Included" : "Not included"
    }

    func setHideEnabled(_ enabled: Bool, for display: DisplayRecord) {
        guard !hideConfigurationFrozen,
              isEligibleHideTarget(display),
              let uuid = display.uuid else { return }
        var updated = hidePreferences
        let key = uuid.lowercased()
        var configuration = updated[uuid] ?? DisplayHideConfiguration(target: DisplayIdentitySnapshot(display))
        guard matches(configuration.target, display) else { return }
        configuration.enabled = enabled
        updated[key] = configuration
        hidePreferences = updated
    }

    func setHideSource(_ sourceUUID: String?, for targetUUID: String) {
        guard !hideConfigurationFrozen,
              let target = displays.first(where: {
                  $0.uuid?.caseInsensitiveCompare(targetUUID) == .orderedSame
              }),
              let uuid = target.uuid else { return }
        var updated = hidePreferences
        let key = uuid.lowercased()
        var configuration = updated[uuid] ?? DisplayHideConfiguration(target: DisplayIdentitySnapshot(target))
        guard matches(configuration.target, target) else { return }
        if let sourceUUID {
            guard let source = activeDisplays.first(where: {
                $0.uuid?.caseInsensitiveCompare(sourceUUID) == .orderedSame &&
                    $0.id != target.id && !$0.asleep
            }) else { return }
            configuration.source = DisplayIdentitySnapshot(source)
        } else {
            configuration.source = nil
        }
        updated[key] = configuration
        hidePreferences = updated
    }

    @discardableResult
    func setHideAwayInput(_ rawValue: String, for targetUUID: String) -> String? {
        setHideInput(rawValue, for: targetUUID, onHide: true)
    }

    @discardableResult
    func setHideReturnInput(_ rawValue: String, for targetUUID: String) -> String? {
        setHideInput(rawValue, for: targetUUID, onHide: false)
    }

    func checkDDCInputAvailability(for targetUUID: String) {
        let key = targetUUID.lowercased()
        guard let configuration = hidePreferences[targetUUID],
              let matchingDisplay = matchingDisplay(configuration.target) else {
            ddcInputAvailability[key] = .unavailable(
                "Saved display identity is unavailable or changed. Reconnect the exact display and Refresh; PanelCtl will not check another display."
            )
            onStatusChange?()
            return
        }
        do {
            let reading = try checkDDCInput(coreIdentity(configuration.target))
            guard reading.displayID == configuration.target.id,
                  reading.uuid.caseInsensitiveCompare(configuration.target.uuid) == .orderedSame,
                  matches(configuration.target, matchingDisplay) else {
                throw DisplayHideError.identityChanged(
                    "DDC availability check returned a different display identity. Refresh and reconnect the exact display."
                )
            }
            ddcInputAvailability[key] = .readable(current: reading.current)
        } catch {
            ddcInputAvailability[key] = .unavailable(error.localizedDescription)
        }
        onStatusChange?()
    }

    func ddcInputAvailabilityMessage(for configuration: DisplayHideConfiguration) -> String {
        switch ddcInputAvailability[configuration.target.uuid.lowercased()] {
        case .readable(let current):
            return "DDC input readable at \(inputCodeLabel(current)); readability does not prove switching support. Use the monitor's input buttons if a switch is unavailable or fails."
        case .unavailable(let reason):
            return "DDC input unavailable: \(reason) Use the monitor's input buttons; Hide and Show remain available."
        case nil:
            return "DDC input availability is unknown. You can check explicitly or use the monitor's input buttons; Hide and Show do not require DDC."
        }
    }

    func removeHideConfiguration(targetUUID: String) {
        guard !hideConfigurationFrozen else { return }
        var updated = hidePreferences
        updated.remove(uuid: targetUUID)
        hidePreferences = updated
    }

    func hasHideConfiguration(targetUUID: String) -> Bool {
        hidePreferences[targetUUID] != nil
    }

    // Input results are session evidence, not a claim about the monitor's current input.
    private var controlInputOutcomes: [String: DisplayInputOutcome] = [:]

    var controlDisplayOutcome: AppControlOutcome? {
        if hideOperation.isBusy || handoffStatus?.state == .busy { return .busy }
        if handoffInspectionFailure != nil || handoffStatus?.state == .recovery ||
            handoffStatus?.state == .unsupported ||
            (handoffStatus?.state == .hidden && handoffStatus?.canShow != true) { return .recoveryNeeded }
        if controlInputOutcomes.values.contains(where: {
            [.failed, .skipped, .unverified, .notAttempted].contains($0.state)
        }) { return .partial }
        return nil
    }

    var controlDisplayStatuses: [AppControlDisplayStatus] {
        hideDisplayConfigurations.map { configuration in
            let uuid = configuration.target.uuid
            let operation: String
            switch hideOperation {
            case .hiding(let target) where target.caseInsensitiveCompare(uuid) == .orderedSame:
                operation = "hiding"
            case .showing(let target) where target.caseInsensitiveCompare(uuid) == .orderedSame:
                operation = "showing"
            default: operation = "idle"
            }
            let state: String
            switch observedDesktopState(for: configuration) {
            case "Separate": state = "separate"
            case "Hidden by PanelCtl": state = "hidden-by-panelctl"
            case "Unavailable": state = "unavailable"
            case "Mirrored outside PanelCtl": state = "mirrored-externally"
            case "Recovery needed": state = "recovery-needed"
            case "Unsupported recovery journal": state = "unsupported-recovery"
            default: state = "unknown"
            }
            return AppControlDisplayStatus(
                targetUUID: uuid, observedState: state, operation: operation,
                recoveryNeeded: handoffInspectionFailure != nil ||
                    handoffStatus?.state == .recovery || handoffStatus?.state == .unsupported ||
                    (handoffStatus?.state == .hidden && handoffStatus?.canShow != true),
                lastInputOutcome: controlInputOutcomes[uuid.lowercased()]
            )
        }
    }

    /// Headless calls never open confirmation UI or supply consent. The approved
    /// contract requires a fresh, scoped UI confirmation for every actual change.
    func handleDisplayControlRequest(_ request: AppControlRequest) -> AppControlResponse {
        func response(_ outcome: AppControlOutcome, _ message: String) -> AppControlResponse {
            AppControlResponse(
                ok: outcome == .noOp, running: true, enabled: preferences.isEnabled,
                state: runtimeState.controlIdentifier, summary: message,
                error: outcome == .noOp ? nil : message, outcome: outcome,
                displays: controlDisplayStatuses
            )
        }
        guard request.protocolVersion == AppControlRequest.currentProtocol,
              request.command == .hide || request.command == .show,
              request.durationSeconds == nil,
              let uuid = request.targetUUID, UUID(uuidString: uuid) != nil else {
            return response(.refused, "Hide/Show requires --display with an exact UUID and a supported protocol; no duration is accepted.")
        }
        guard !hideOperation.isBusy else {
            return response(.busy, "A UI Hide/Show is in progress. Inspect status after it finishes.")
        }
        displays = displayProvider()
        refreshHandoffStatus()
        guard handoffStatus?.state != .busy else {
            return response(.busy, "Another display operation owns the shared lock. Retry status after it finishes.")
        }
        guard handoffInspectionFailure == nil, handoffStatus != nil else {
            return response(.recoveryNeeded, handoffInspectionFailure ?? "Display recovery status is unknown. Review Settings → Displays.")
        }
        guard !displayLifecycleTransitioning else {
            return response(.refused, "Wait for displays to wake and the display transition to finish.")
        }
        if handoffStatus?.hasUnresolvedJournal == true {
            guard let target = handoffStatus?.target,
                  target.uuid.caseInsensitiveCompare(uuid) == .orderedSame else {
                return response(.recoveryNeeded, "A different or unknown target owns the shared journal. Review display recovery; no target substitution is allowed.")
            }
            if request.command == .hide {
                guard handoffStatus?.state == .hidden, handoffStatus?.canShow == true else {
                    return response(.recoveryNeeded, handoffStatus?.reason ?? "Resolve display recovery before Hide.")
                }
                return response(.noOp, "Desktop is already hidden by PanelCtl; no topology or input write was attempted.")
            }
            do {
                _ = try makeShowRequest()
                return response(.confirmationRequired, "Show requires confirmation of the journaled layout and saved Mac input. Open PanelCtl Settings → Displays and choose Show. Automation may remain off or paused.")
            } catch {
                return response(.recoveryNeeded, error.localizedDescription)
            }
        }
        guard let configuration = hidePreferences[uuid],
              matchingDisplay(configuration.target) != nil else {
            return response(.refused, "No matching saved display identity. Configure the exact display in Settings → Displays; do not substitute an ID.")
        }
        if request.command == .show {
            guard observedDesktopState(for: configuration) == "Separate" else {
                return response(.refused, "The target is not an observed separate desktop and has no PanelCtl-owned journal. Review macOS Displays.")
            }
            return response(.noOp, "Desktop is already shown; no topology or input write was attempted.")
        }
        do {
            _ = try makeHideRequest(targetUUID: uuid)
            return response(.confirmationRequired, "Hide requires confirmation of the saved source, optional inputs, automation suspension and manual fallback. Open PanelCtl Settings → Displays and choose Hide.")
        } catch {
            return response(.refused, error.localizedDescription)
        }
    }

    func makeHideRequest(targetUUID: String) throws -> DisplayHideRequest {
        guard !hideOperation.isBusy else { throw DisplayHideError.actionInProgress }
        guard experimentalFeaturesEnabled else {
            throw DisplayHideError.unavailable("Turn on Experimental features in Settings → General to remove a display from the desktop.")
        }
        guard !displayLifecycleTransitioning else { throw DisplayHideError.sleeping }
        guard protectionQuiescenceFailure == nil else {
            throw DisplayHideError.protectionCleanup(protectionQuiescenceFailure ?? "Automation cleanup needs attention.")
        }
        guard handoffInspectionFailure == nil,
              handoffStatus?.state == DisplayHandoffStatus.State.none else {
            throw DisplayHideError.recoveryBlocksHide("A shared recovery journal is unresolved or could not be inspected. Review display recovery before starting another Hide.")
        }
        guard let configuration = hidePreferences[targetUUID], configuration.enabled else {
            throw DisplayHideError.unavailable("Enable experimental hide for this display in Settings → Displays.")
        }
        if let reason = hideReadinessMessage(for: configuration) {
            if reason.contains("identity") || reason.contains("Unavailable") {
                throw DisplayHideError.identityChanged(reason)
            }
            throw DisplayHideError.unavailable(reason)
        }
        guard let source = configuration.source else {
            throw DisplayHideError.unavailable("Choose an explicit mirror source first.")
        }
        let away = validatedSavedInput(configuration.awayInput, label: "Other computer")
        let returning = validatedSavedInput(configuration.returnInput, label: "Mac")
        return DisplayHideRequest(
            target: configuration.target,
            source: source,
            awayInput: away.value,
            returnInput: returning.value,
            awayInputWarning: away.warning,
            returnInputWarning: returning.warning
        )
    }

    func requestHide(targetUUID: String) {
        do {
            let request = try makeHideRequest(targetUUID: targetUUID)
            guard let onRequestHide else {
                throw DisplayHideError.unavailable("Display Hide confirmation is unavailable.")
            }
            onRequestHide(request)
        } catch {
            presentDisplayError("Cannot hide this desktop", error: error)
        }
    }

    func confirmHide(_ request: DisplayHideRequest, acknowledged: Bool) {
        guard acknowledged else {
            presentDisplayError("Hide canceled", error: DisplayHideError.acknowledgementRequired)
            return
        }
        guard hideOperation == .idle else {
            presentDisplayError("Display operation in progress", error: DisplayHideError.actionInProgress)
            return
        }
        do {
            let current = try makeHideRequest(targetUUID: request.target.uuid)
            guard current == request else {
                throw DisplayHideError.identityChanged("The target, source, or saved configuration changed while confirmation was open. Review the current Displays settings and confirm again.")
            }
        } catch {
            presentDisplayError("Hide not started", error: error)
            return
        }

        hideOperation = .hiding(request.target.uuid)
        manualActivityDate = now()
        onStatusChange?()
        let finish: (Bool, String?) -> Void = { [weak self] succeeded, message in
            Task { @MainActor in
                self?.finishHideAfterProtectionQuiescence(
                    request,
                    cleanupSucceeded: succeeded,
                    cleanupFailure: message
                )
            }
        }
        stopManagedProtection(completion: finish)
    }

    func makeShowRequest() throws -> DisplayShowRequest {
        guard !hideOperation.isBusy else { throw DisplayHideError.actionInProgress }
        guard !displayLifecycleTransitioning else { throw DisplayHideError.sleeping }
        guard !protectionQuiescencePending else {
            throw DisplayHideError.recoveryBlocksAction("PanelCtl is still stopping automation before display recovery. Wait, then Refresh.")
        }
        refreshHandoffStatus()
        guard handoffInspectionFailure == nil,
              let handoffStatus,
              handoffStatus.state == .hidden || handoffStatus.state == .recovery else {
            throw DisplayHideError.recoveryBlocksAction(
                handoffInspectionFailure ?? handoffStatus?.reason ?? "There is no supported unresolved mirror journal to Show."
            )
        }
        guard handoffStatus.canShow else {
            throw DisplayHideError.recoveryBlocksAction(
                handoffStatus.reason ?? "The captured layout is not currently eligible for Show. Refresh after correcting the refusal."
            )
        }
        let input = configuredReturnInput(for: handoffStatus)
        return DisplayShowRequest(status: handoffStatus, returnInput: input.value, returnInputWarning: input.warning)
    }

    func requestShow() {
        do {
            guard let onRequestShow else {
                throw DisplayHideError.recoveryBlocksAction("Display Show confirmation is unavailable.")
            }
            onRequestShow(try makeShowRequest())
        } catch {
            presentDisplayError("Cannot show this desktop", error: error)
        }
    }

    func confirmShow(_ request: DisplayShowRequest, acknowledged: Bool) {
        guard acknowledged else {
            presentDisplayError("Show canceled", error: DisplayHideError.acknowledgementRequired)
            return
        }
        guard hideOperation == .idle else {
            presentDisplayError("Display operation in progress", error: DisplayHideError.actionInProgress)
            return
        }
        do {
            let current = try makeShowRequest()
            guard current.status.journalID == request.status.journalID,
                  current.status.target?.uuid == request.status.target?.uuid,
                  current.status.source?.uuid == request.status.source?.uuid,
                  current.returnInput == request.returnInput,
                  current.returnInputWarning == request.returnInputWarning else {
                throw DisplayHideError.recoveryBlocksAction("The recovery journal or saved Mac input configuration changed while confirmation was open. Refresh and review the captured target/source and input setting before Show.")
            }
        } catch {
            presentDisplayError("Show not started", error: error)
            return
        }

        hideOperation = .showing(request.status.target?.uuid ?? "")
        onStatusChange?()
        let finish: (Bool, String?) -> Void = { [weak self] succeeded, message in
            Task { @MainActor in
                self?.finishShowAfterProtectionQuiescence(
                    request,
                    cleanupSucceeded: succeeded,
                    cleanupFailure: message
                )
            }
        }
        stopManagedProtection(completion: finish)
    }

    func confirmShow(_ status: DisplayHandoffStatus, acknowledged: Bool) {
        let input = configuredReturnInput(for: status)
        confirmShow(
            DisplayShowRequest(status: status, returnInput: input.value, returnInputWarning: input.warning),
            acknowledged: acknowledged
        )
    }

    var onRequestHide: ((DisplayHideRequest) -> Void)?
    var onRequestShow: ((DisplayShowRequest) -> Void)?
    var onShowCompletion: ((Bool) -> Void)?

    func requestDisplayRecoveryFocus() {
        displayRecoveryFocusRequest &+= 1
    }

    func setDisplayLifecycleTransitioning(_ transitioning: Bool) {
        guard displayLifecycleTransitioning != transitioning else { return }
        displayLifecycleTransitioning = transitioning
        if handoffStatus?.hasUnresolvedJournal == true {
            if transitioning {
                protectionRearmRequired = true
                service.disable()
            } else {
                reconcileProtection(restartWatcher: true)
            }
        }
        onStatusChange?()
    }

    func refreshHandoffStatus() {
        let previous = handoffStatus
        let previousFailure = handoffInspectionFailure
        let wasUnresolved = previous?.hasUnresolvedJournal == true || previousFailure != nil
        handoffInspectionFailure = nil
        handoffStatus = inspectHandoff()
        handoffInspectionFailure = handoffStatus?.inspectionFailure
        let isUnresolved = handoffStatus?.hasUnresolvedJournal == true || handoffInspectionFailure != nil
        let enteredHidden = handoffStatus?.state == .hidden &&
            (previous?.state != .hidden || previous?.journalID != handoffStatus?.journalID ||
             previous?.source?.uuid != handoffStatus?.source?.uuid)
        if enteredHidden {
            manualActivityDate = now()
            protectionRearmRequired = true
        }
        if isUnresolved && !wasUnresolved && !hideOperation.isBusy {
            quiesceForExternalRecovery()
        } else if !isUnresolved && wasUnresolved,
                  !protectionQuiescencePending,
                  protectionQuiescenceFailure == nil {
            rearmProtectionAfterDisplayRecovery()
        }
        if previous != handoffStatus || previousFailure != handoffInspectionFailure {
            onStatusChange?()
            if !protectionQuiescencePending && isUnresolved {
                reconcileProtection()
            }
        }
    }

    var version: String {
        if let version = Bundle.main.object(
            forInfoDictionaryKey: "PanelCtlReleaseVersion"
        ) as? String, !version.isEmpty {
            return version
        }
        if let version = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String, !version.isEmpty {
            return version
        }
        return CLIHelp.version.replacingOccurrences(of: "panelctl ", with: "")
    }

    var statusSystemImage: String {
        blackedOutDisplayIDs.isEmpty ? runtimeState.systemImage : "rectangle.fill"
    }

    var statusSummary: String {
        if protectionPausedForDisplayRecovery {
            return hiddenMirrorProtectionSummary
        }
        let label = runtimeState == .blackedOut && preferences.mode == .working
            ? "Dimming active"
            : runtimeState.label
        if !blackedOutDisplayIDs.isEmpty, runtimeState != .blackedOut {
            if let secondsRemaining, let nextAction {
                return "Empty-display blackout active · \(Self.countdownLabel(secondsRemaining)) to \(nextAction)"
            }
            return "Empty-display blackout active · \(runtimeState.label)"
        }
        if let secondsRemaining, let nextAction {
            switch runtimeState {
            case .snoozed(let until):
                return "\(label) until \(Self.expiryFormatter.string(from: until)) · \(Self.countdownLabel(secondsRemaining)) to \(nextAction)"
            default:
                return "\(label) · \(Self.countdownLabel(secondsRemaining)) to \(nextAction)"
            }
        }
        return label
    }

    func setProtectionEnabled(_ enabled: Bool) {
        cancelSnooze()
        if preferences.isEnabled == enabled {
            reconcileProtection()
        } else {
            preferences.isEnabled = enabled
        }
    }

    func retryProtection() {
        guard preferences.isEnabled else { return }
        reconcileProtection()
    }

    func blackoutNow() throws {
        let hiddenOverlaySource: DisplayRecord?
        if protectionPausedForDisplayRecovery {
            hiddenOverlaySource = selectedHiddenMirrorSource
            guard hiddenOverlaySource != nil else {
                throw DisplayHideError.recoveryBlocksAction(
                    "Black Out Now is unavailable during display recovery unless the shared journal verifies Hidden by PanelCtl and its exact mirror source is in the idle display list. Show or review recovery; no display change was requested."
                )
            }
        } else {
            hiddenOverlaySource = nil
        }
        let wasSnoozed = cancelSnooze()
        displays = displayProvider()
        let arguments: [String]
        do {
            if let hiddenOverlaySource {
                guard let overlayArguments = try preferences.hiddenMirrorOverlayArguments(for: hiddenOverlaySource) else {
                    throw DisplayHideError.recoveryBlocksAction("Add the journaled mirror source to the idle display list before using Black Out Now.")
                }
                arguments = overlayArguments
            } else {
                arguments = try preferences.commandArguments(for: displays)
            }
        } catch {
            if wasSnoozed {
                reconcileProtection()
            }
            throw error
        }
        if !preferences.isEnabled {
            preferences.isEnabled = true
        }
        service.run(arguments: arguments)
        try service.sendControl(.blackoutNow)
    }

    @discardableResult
    func restoreBlackout() throws -> Bool {
        if protectionPausedForDisplayRecovery && !hiddenMirrorOverlayPolicyEligible { return false }
        guard snoozedUntil == nil else { return false }
        guard preferences.isEnabled, service.canReceiveControl else {
            return false
        }
        let restored = try service.sendControl(.restore)
        if restored {
            manualActivityDate = now()
        }
        return restored
    }

    func sleepAllNow() throws {
        let wasSnoozed = cancelSnooze()
        if wasSnoozed {
            reconcileProtection()
        }
        try sleepDisplays()
    }

    func snooze(for duration: TimeInterval) {
        guard duration.isFinite,
              duration > 0,
              duration <= Self.maximumSnoozeDuration else { return }
        snooze(until: now().addingTimeInterval(duration))
    }

    func snoozeUntilTomorrow(calendar: Calendar = .current) {
        let current = now()
        let tomorrow = calendar.date(
            byAdding: .day,
            value: 1,
            to: calendar.startOfDay(for: current)
        ) ?? current.addingTimeInterval(24 * 60 * 60)
        let expiry = calendar.date(
            bySettingHour: 8,
            minute: 0,
            second: 0,
            of: tomorrow
        )
        snooze(until: expiry ?? tomorrow)
    }

    func resumeProtection() {
        let wasSnoozed = defaults.object(forKey: Self.snoozedUntilKey) != nil
        cancelSnooze()
        guard preferences.isEnabled else { return }
        if wasSnoozed {
            manualActivityDate = now()
        }
        reconcileProtection()
    }

    func refreshDisplays(restartWatcher: Bool = false) {
        displays = displayProvider()
        refreshHandoffStatus()
        if preferences.isEnabled {
            reconcileProtection(restartWatcher: restartWatcher)
        }
        runtimeState = presentedRuntimeState(for: service.state)
        onStatusChange?()
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        switch LaunchAtLogin.setEnabled(enabled) {
        case .enabled:
            launchAtLoginEnabled = true
        case .disabled:
            launchAtLoginEnabled = false
        case .requiresApproval:
            launchAtLoginEnabled = LaunchAtLogin.isEnabled
            notice = AppNotice(
                title: "Approval required",
                message: "Allow PanelCtl in System Settings → General → Login Items.",
                opensLoginItemSettings: true
            )
        case .failed(let message):
            launchAtLoginEnabled = LaunchAtLogin.isEnabled
            notice = AppNotice(
                title: "Could not update Login Items",
                message: message,
                opensLoginItemSettings: false
            )
        }
    }

    func setShowMenuBarIcon(_ enabled: Bool) {
        showMenuBarIcon = enabled
    }

    /// Turning Experimental features on only asks for consent; Settings
    /// presents it and calls `acceptExperimentalConsent()`.
    func setExperimentalFeaturesEnabled(_ enabled: Bool) {
        if enabled {
            experimentalConsentPending = !experimentalFeaturesEnabled
        } else {
            experimentalConsentPending = false
            experimentalFeaturesEnabled = false
        }
    }

    func acceptExperimentalConsent() {
        experimentalConsentPending = false
        experimentalFeaturesEnabled = true
    }

    func refreshLaunchAtLoginStatus() {
        launchAtLoginEnabled = LaunchAtLogin.isEnabled
    }

    func openLoginItemSettings() {
        LaunchAtLogin.openSystemSettings()
    }

    func openGitHub() {
        NSWorkspace.shared.open(Self.githubURL)
    }

    func shutdown(completion: @escaping () -> Void) {
        snoozeTimer?.invalidate()
        service.shutdown(completion: completion)
    }

    var snoozedUntil: Date? {
        guard let date = defaults.object(forKey: Self.snoozedUntilKey) as? Date,
              date > now() else {
            return nil
        }
        return date
    }

    var nextAction: String? {
        switch runtimeState {
        case .snoozed:
            return "resume"
        case .waiting:
            return preferences.mode == .working ? "dim" : "blackout"
        case .blackedOut:
            if hiddenMirrorOverlayPolicyEligible { return "restore overlay" }
            switch preferences.followUpAction {
            case .restore: return "restore"
            case .sleepDisplays: return "sleep"
            case .untilActivity: return nil
            }
        default:
            return nil
        }
    }

    var secondsRemaining: Int? {
        let remaining: TimeInterval
        switch runtimeState {
        case .snoozed(let until):
            remaining = until.timeIntervalSince(now())
        case .waiting:
            var idle = idleSecondsProvider() ?? 0
            if let manualActivityDate {
                idle = min(idle, max(0, now().timeIntervalSince(manualActivityDate)))
            }
            remaining = preferences.idleSeconds - idle
        case .blackedOut:
            guard let stateBeganAt else { return nil }
            let elapsed = now().timeIntervalSince(stateBeganAt)
            let inputElapsed = idleSecondsProvider() ?? elapsed
            if hiddenMirrorOverlayPolicyEligible {
                let timeout = min(
                    preferences.followUpAction == .untilActivity
                        ? 24 * 60 * 60
                        : preferences.followUpSeconds,
                    24 * 60 * 60
                )
                remaining = timeout - (
                    hiddenMirrorOverlayResetsLimitOnInput ? min(elapsed, inputElapsed) : elapsed
                )
            } else {
                guard preferences.followUpAction != .untilActivity else { return nil }
                remaining = preferences.followUpSeconds - (
                    resetsBlackoutLimitOnInput ? min(elapsed, inputElapsed) : elapsed
                )
            }
        default:
            return nil
        }
        return max(0, Int(ceil(remaining)))
    }

    private var stateBeganAt: Date?

    private var hiddenMirrorOverlayResetsLimitOnInput: Bool {
        (preferences.mode == .working || preferences.keepBlackoutOnInput) && activeDisplays.count > 1
    }

    private var resetsBlackoutLimitOnInput: Bool {
        guard (preferences.mode == .working || preferences.keepBlackoutOnInput),
              !preferences.allDisplays else {
            return false
        }
        let selectedDisplayIDs = Set(activeDisplays.compactMap { display -> UInt32? in
            guard let uuid = display.uuid,
                  preferences.selectedDisplayUUIDs.contains(where: {
                      $0.caseInsensitiveCompare(uuid) == .orderedSame
                  }) else {
                return nil
            }
            return display.id
        })
        return selectedDisplayIDs.count < activeDisplays.count
    }

    private func reconcileProtection(restartWatcher: Bool = false) {
        if protectionPausedForDisplayRecovery {
            guard !protectionQuiescencePending,
                  protectionQuiescenceFailure == nil,
                  !hideOperation.isBusy,
                  !displayLifecycleTransitioning,
                  preferences.isEnabled else {
                service.disable()
                return
            }
            if let until = snoozedUntil {
                runtimeState = .snoozed(until)
                service.disable()
                return
            }
            guard let source = selectedHiddenMirrorSource else {
                service.disable()
                return
            }
            do {
                guard let arguments = try preferences.hiddenMirrorOverlayArguments(for: source) else {
                    service.disable()
                    return
                }
                service.run(
                    arguments: arguments,
                    restartForDisplayChange: restartWatcher || protectionRearmRequired
                )
                if service.hasManagedProcess { protectionRearmRequired = false }
            } catch {
                service.fail(error.localizedDescription)
            }
            return
        }
        if let until = snoozedUntil {
            runtimeState = .snoozed(until)
            service.disable()
            return
        }
        guard preferences.isEnabled else {
            service.disable()
            return
        }
        do {
            let rearm = restartWatcher || protectionRearmRequired
            service.run(
                arguments: try preferences.commandArguments(for: displays),
                restartForDisplayChange: rearm
            )
            if service.hasManagedProcess {
                protectionRearmRequired = false
            }
        } catch ProtectionConfigurationError.noDisplays {
            service.waitForDisplays(ProtectionConfigurationError.noDisplays.localizedDescription)
        } catch let error as ProtectionConfigurationError {
            if case .selectedDisplayUnavailable = error {
                service.waitForDisplays(error.localizedDescription)
            } else {
                service.fail(error.localizedDescription)
            }
        } catch {
            service.fail(error.localizedDescription)
        }
    }

    private func presentedRuntimeState(
        for serviceState: ProtectionRuntimeState
    ) -> ProtectionRuntimeState {
        if protectionPausedForDisplayRecovery && !hiddenMirrorOverlayPolicyEligible { return .disabled }
        if let until = snoozedUntil {
            return .snoozed(until)
        }
        guard preferences.isEnabled else { return serviceState }
        switch serviceState {
        case .starting, .waiting, .waitingForInput, .waitingForPlayback, .blackedOut, .sleeping:
            break
        default:
            return serviceState
        }

        do {
            if hiddenMirrorOverlayPolicyEligible {
                guard let source = selectedHiddenMirrorSource,
                      try preferences.hiddenMirrorOverlayArguments(for: source) != nil else {
                    return .disabled
                }
                return serviceState
            }
            _ = try preferences.commandArguments(for: displays)
            return serviceState
        } catch ProtectionConfigurationError.noDisplays {
            return .waitingForDisplays(
                ProtectionConfigurationError.noDisplays.localizedDescription
            )
        } catch let error as ProtectionConfigurationError {
            if case .selectedDisplayUnavailable = error {
                return .waitingForDisplays(error.localizedDescription)
            }
            return serviceState
        } catch {
            return serviceState
        }
    }

    private func stopManagedProtection(completion: @escaping (Bool, String?) -> Void) {
        if let quiesceProtection {
            quiesceProtection(completion)
        } else {
            service.disableForDisplayHide(completion: completion)
        }
    }

    private func quiesceForExternalRecovery() {
        protectionQuiescencePending = true
        onStatusChange?()
        stopManagedProtection { [weak self] succeeded, message in
            Task { @MainActor in
                guard let self else { return }
                self.protectionQuiescencePending = false
                self.protectionQuiescenceFailure = succeeded
                    ? nil
                    : (message ?? "Automation cleanup could not be verified.")
                if self.handoffStatus?.hasUnresolvedJournal != true,
                   self.handoffInspectionFailure == nil,
                   self.hideOperation == .idle,
                   self.protectionQuiescenceFailure == nil {
                    self.rearmProtectionAfterDisplayRecovery()
                } else {
                    self.reconcileProtection()
                }
                self.onStatusChange?()
            }
        }
    }

    private func rearmProtectionAfterDisplayRecovery() {
        guard handoffStatus?.hasUnresolvedJournal != true,
              handoffInspectionFailure == nil,
              protectionQuiescenceFailure == nil else {
            reconcileProtection()
            return
        }
        manualActivityDate = now()
        protectionRearmRequired = true
        reconcileProtection(restartWatcher: true)
    }

    private func savePreferences() {
        guard let data = try? JSONEncoder().encode(preferences) else { return }
        defaults.set(data, forKey: Self.preferencesKey)
    }

    private func saveHidePreferences() {
        guard let data = try? JSONEncoder().encode(hidePreferences) else { return }
        defaults.set(data, forKey: Self.hidePreferencesKey)
    }

    private func coreIdentity(_ identity: DisplayIdentitySnapshot) -> DisplayHideIdentity {
        DisplayHideIdentity(
            uuid: identity.uuid,
            displayID: identity.id,
            name: identity.name,
            vendor: identity.vendor,
            model: identity.model,
            serial: identity.serial
        )
    }

    private func isEligibleHideTarget(_ display: DisplayRecord) -> Bool {
        display.active && display.online && !display.asleep &&
            !display.main && !display.builtin &&
            display.uuid.flatMap(UUID.init(uuidString:)) != nil &&
            display.bounds.width > 0 && display.bounds.height > 0
    }

    private func matchingDisplay(_ identity: DisplayIdentitySnapshot) -> DisplayRecord? {
        let candidates = displays.filter {
            $0.uuid?.caseInsensitiveCompare(identity.uuid) == .orderedSame
        }
        guard candidates.count == 1,
              let display = candidates.first,
              matches(identity, display) else { return nil }
        return display
    }

    private func matches(_ identity: DisplayIdentitySnapshot, _ display: DisplayRecord) -> Bool {
        display.uuid?.caseInsensitiveCompare(identity.uuid) == .orderedSame &&
            display.id == identity.id && display.vendor == identity.vendor &&
            display.model == identity.model && display.serial == identity.serial
    }

    private func setHideInput(_ rawValue: String, for targetUUID: String, onHide: Bool) -> String? {
        guard !hideConfigurationFrozen,
              let target = displays.first(where: { $0.uuid?.caseInsensitiveCompare(targetUUID) == .orderedSame }),
              let uuid = target.uuid else { return nil }
        var updated = hidePreferences
        var configuration = updated[uuid] ?? DisplayHideConfiguration(target: DisplayIdentitySnapshot(target))
        guard matches(configuration.target, target) else { return nil }
        let value = rawValue.isEmpty ? nil : DDCInput.parseValue(rawValue)
        let validation = rawValue.isEmpty || value != nil
            ? nil
            : "Invalid DDC input code. Enter dp1, dp2, hdmi1, hdmi2, a decimal value from 1–255, or a 0x-prefixed hexadecimal value. This input was not saved; clear the field to use monitor buttons."
        if onHide {
            configuration.awayInput = value
        } else {
            configuration.returnInput = value
        }
        updated[uuid] = configuration
        hidePreferences = updated
        return validation
    }

    private func validatedSavedInput(_ value: UInt8?, label: String) -> (value: UInt8?, warning: String?) {
        guard let value else { return (nil, nil) }
        guard DDCInput.parseValue(String(value)) != nil else {
            return (nil, "Saved \(label) input code 0x\(String(format: "%02X", value)) is invalid and will not be sent. Correct it in Settings → Displays or clear it to use monitor buttons.")
        }
        return (value, nil)
    }

    private func configuredReturnInput(for status: DisplayHandoffStatus) -> (value: UInt8?, warning: String?) {
        guard let target = status.target,
              let configuration = hidePreferences[target.uuid] else { return (nil, nil) }
        guard configuration.target.uuid.caseInsensitiveCompare(target.uuid) == .orderedSame,
              configuration.target.id == target.id,
              configuration.target.vendor == target.vendor,
              configuration.target.model == target.model,
              configuration.target.serial == target.serial else {
            return (nil, "Saved Mac input belongs to a different display identity and was not sent. Review Settings → Displays; use the monitor buttons if needed.")
        }
        return validatedSavedInput(configuration.returnInput, label: "Mac")
    }

    private func inputCodeLabel(_ value: UInt8) -> String {
        let code = String(format: "0x%02X", value)
        if let named = DDCInput.namedValues.first(where: { $0.value == value }) {
            return "\(named.name) (\(code))"
        }
        return code
    }

    private func hideRequest(target: DisplayIdentitySnapshot, source: DisplayIdentitySnapshot,
                             configuration: DisplayHideConfiguration) -> DisplayHideRequest {
        let away = validatedSavedInput(configuration.awayInput, label: "Other computer")
        let returning = validatedSavedInput(configuration.returnInput, label: "Mac")
        return DisplayHideRequest(
            target: target,
            source: source,
            awayInput: away.value,
            returnInput: returning.value,
            awayInputWarning: away.warning,
            returnInputWarning: returning.warning
        )
    }

    private func finishHideAfterProtectionQuiescence(
        _ request: DisplayHideRequest,
        cleanupSucceeded: Bool,
        cleanupFailure: String?
    ) {
        guard hideOperation == .hiding(request.target.uuid) else { return }
        if !cleanupSucceeded {
            let failure = cleanupFailure ?? "Automation cleanup could not be verified."
            protectionQuiescenceFailure = failure
            hideOperation = .idle
            refreshHandoffStatus()
            reconcileProtection()
            presentDisplayError(
                "Hide not started",
                error: DisplayHideError.protectionCleanup("PanelCtl could not confirm that blackout/dimming cleanup finished: \(failure) No desktop change was attempted; inspect automation status and try again only after it is clear.")
            )
            onStatusChange?()
            return
        }
        protectionQuiescenceFailure = nil
        var returnedInputOutcome: DisplayInputOutcome?
        do {
            displays = displayProvider()
            refreshHandoffStatus()
            guard let configuration = hidePreferences[request.target.uuid],
                  hideReadinessMessage(for: configuration, allowingCurrentOperation: true) == nil,
                  let source = configuration.source,
                  request == hideRequest(target: configuration.target, source: source, configuration: configuration) else {
                throw DisplayHideError.identityChanged("The target, source, input codes, inventory, or saved configuration changed before Hide began. Review Displays and confirm again.")
            }
            let inputOutcome = try hideDisplay(
                coreIdentity(request.target), coreIdentity(request.source), request.awayInput
            )
            returnedInputOutcome = inputOutcome
            controlInputOutcomes[request.target.uuid.lowercased()] = inputOutcome
            refreshHandoffStatus()
            guard handoffStatus?.state == .hidden else {
                throw DisplayHideError.recoveryBlocksAction(
                    "Hide did not remain observable as active. The journal and observed topology are retained; Refresh Displays and review the recovery details before taking another action."
                )
            }
            hideOperation = .idle
            reconcileProtection()
            notice = AppNotice(
                title: "Desktop hidden",
                message: "Desktop: \(request.target.name ?? request.target.uuid) is hidden by mirroring \(request.source.name ?? request.source.uuid). The Mac signal remains on; modes/HDR may change. While the journal and topology verify Hidden by PanelCtl, automation may cover only the selected source with an overlay; the mirrored target also appears black on the Mac input. Brightness dimming and automatic follow-up Sleep stay suspended; activity/Restore affect only the overlay and Show remains explicit. Unknown, stale, busy, unselected, or recovery-needed state keeps automation suspended.\n\(inputSummary(inputOutcome, purpose: "Other computer", warning: request.awayInputWarning))",
                opensLoginItemSettings: false
            )
        } catch {
            refreshHandoffStatus()
            hideOperation = .idle
            rearmProtectionAfterDisplayRecovery()
            let outcome = returnedInputOutcome ?? (error as? DisplayHandoffOperationFailure)?.inputOutcome ??
                DisplayInputOutcome(
                    state: request.awayInput == nil ? .notRequested : .notAttempted,
                    requestedInput: request.awayInput,
                    detail: "Input operation details are unavailable because the guarded Hide operation did not complete."
                )
            controlInputOutcomes[request.target.uuid.lowercased()] = outcome
            let desktopResult = returnedInputOutcome == nil
                ? "Desktop: Hide did not complete."
                : "Desktop: Hide backend returned, but current desktop/recovery status could not be confirmed. Refresh Displays and review recovery before another action."
            let message = "\(desktopResult)\n\(error.localizedDescription)\n\(inputSummary(outcome, purpose: "Other computer", warning: request.awayInputWarning))"
            presentDisplayError("Could not hide the desktop", message: message)
        }
        onStatusChange?()
    }

    private func finishShowAfterProtectionQuiescence(
        _ request: DisplayShowRequest,
        cleanupSucceeded: Bool,
        cleanupFailure: String?
    ) {
        guard case .showing = hideOperation else { return }
        if cleanupSucceeded {
            protectionQuiescenceFailure = nil
        } else {
            protectionQuiescenceFailure = cleanupFailure ?? "Automation cleanup could not be verified."
            hideOperation = .idle
            reconcileProtection()
            onShowCompletion?(false)
            presentDisplayError(
                "Show not started",
                message: "PanelCtl could not verify that the source overlay was quiesced: \(protectionQuiescenceFailure ?? "automation cleanup failed"). No topology or monitor-input action was attempted. Retry automation cleanup, then Refresh and confirm Show again."
            )
            onStatusChange?()
            return
        }
        guard !displayLifecycleTransitioning else {
            hideOperation = .idle
            reconcileProtection()
            onShowCompletion?(false)
            presentDisplayError(
                "Show paused",
                message: "Desktop: Show was paused during a display transition.\nMonitor input: Not attempted. Wait for displays to wake, then Refresh and confirm again."
            )
            onStatusChange?()
            return
        }
        refreshHandoffStatus()
        guard handoffStatus?.hasUnresolvedJournal == true,
              handoffStatus?.canShow == true,
              handoffStatus?.journalID == request.status.journalID,
              handoffStatus?.target?.uuid == request.status.target?.uuid,
              handoffStatus?.source?.uuid == request.status.source?.uuid,
              let expectedJournalID = request.status.journalID else {
            hideOperation = .idle
            reconcileProtection()
            onShowCompletion?(false)
            presentDisplayError(
                "Show not started",
                error: DisplayHideError.recoveryBlocksAction("The journal or observed topology changed before Show began. Refresh Displays and review the current recovery details.")
            )
            onStatusChange?()
            return
        }
        var returnedInputOutcome: DisplayInputOutcome?
        do {
            let inputOutcome = try showDisplay(expectedJournalID, request.returnInput)
            returnedInputOutcome = inputOutcome
            if let uuid = request.status.target?.uuid {
                controlInputOutcomes[uuid.lowercased()] = inputOutcome
            }
            refreshHandoffStatus()
            guard handoffStatus?.hasUnresolvedJournal != true,
                  handoffInspectionFailure == nil else {
                throw DisplayHideError.recoveryBlocksAction(
                    handoffStatus?.reason ?? handoffInspectionFailure ?? "Show returned, but the journal could not be verified resolved. Keep the journal and inspect the recovery details."
                )
            }
            hideOperation = .idle
            rearmProtectionAfterDisplayRecovery()
            let protectionStatus = protectionQuiescenceFailure.map {
                "Automation cleanup still needs attention: \($0) Automation remains suspended."
            } ?? ""
            notice = AppNotice(
                title: "Desktop restored",
                message: "Desktop: The journaled public display layout and modes were restored and verified. HDR, color profiles, rotation, windows, and Spaces are not restored. \(protectionStatus)\n\(inputSummary(inputOutcome, purpose: "Mac", warning: request.returnInputWarning))",
                opensLoginItemSettings: false
            )
            onShowCompletion?(true)
        } catch {
            refreshHandoffStatus()
            hideOperation = .idle
            reconcileProtection()
            onShowCompletion?(false)
            let outcome = returnedInputOutcome ?? (error as? DisplayHandoffOperationFailure)?.inputOutcome ??
                DisplayInputOutcome(
                    state: request.returnInput == nil ? .notRequested : .notAttempted,
                    requestedInput: request.returnInput,
                    detail: "Input operation details are unavailable because guarded Show did not complete."
                )
            if let uuid = request.status.target?.uuid {
                controlInputOutcomes[uuid.lowercased()] = outcome
            }
            let desktopResult = returnedInputOutcome == nil
                ? "Desktop: Show did not complete."
                : "Desktop: Show backend returned, but current desktop/recovery status could not be confirmed. Refresh Displays and review recovery before assuming the result."
            presentDisplayError(
                "Could not show the journaled desktop",
                message: "\(desktopResult)\n\(error.localizedDescription)\n\(inputSummary(outcome, purpose: "Mac", warning: request.returnInputWarning))"
            )
        }
        onStatusChange?()
    }

    private func inputSummary(_ outcome: DisplayInputOutcome, purpose: String, warning: String?) -> String {
        let prefix = "Monitor input (\(purpose)): "
        if let warning, outcome.state == .notRequested {
            return prefix + "Not requested. \(warning) Use the monitor's input buttons if needed."
        }
        let requested = outcome.requestedInput.map { inputCodeLabel($0) }
        let recovery = outcome.recoveryCommand.map { " To return to the previous input, run: \($0)." } ?? ""
        switch outcome.state {
        case .notRequested:
            return prefix + "No DDC input change was requested. Use the monitor's input buttons to switch manually if needed."
        case .notAttempted:
            return prefix + "Not attempted. \(outcome.detail ?? "The desktop operation did not reach the input step.") Use the monitor's input buttons if needed."
        case .skipped:
            return prefix + "Skipped. \(outcome.detail ?? "DDC was unavailable.") Use the monitor's input buttons if needed."
        case .verified:
            return prefix + "\(requested ?? "Requested input") selected and verified by readback.\(recovery)"
        case .alreadySelected:
            return prefix + "Already on \(requested ?? "the requested input"); no DDC write was sent.\(recovery)"
        case .unverified:
            let detail = outcome.detail ?? "readback was unavailable"
            return prefix + "Selection of \(requested ?? "the requested input") is unverified (\(detail)); PanelCtl does not claim it changed. Check the monitor.\(recovery) Use the monitor's input buttons if needed."
        case .failed:
            return prefix + "Failed. \(outcome.detail ?? "DDC input selection failed.")\(recovery) Use the monitor's input buttons if needed."
        }
    }

    private func presentDisplayError(_ title: String, error: Error) {
        presentDisplayError(title, message: error.localizedDescription)
    }

    private func presentDisplayError(_ title: String, message: String) {
        notice = AppNotice(title: title, message: message, opensLoginItemSettings: false)
    }

    private func snooze(until: Date) {
        defaults.set(until, forKey: Self.snoozedUntilKey)
        if !preferences.isEnabled {
            preferences.isEnabled = true
        }
        runtimeState = .snoozed(until)
        service.disable()
        onStatusChange?()
    }

    @discardableResult
    private func cancelSnooze() -> Bool {
        guard defaults.object(forKey: Self.snoozedUntilKey) != nil else {
            return false
        }
        defaults.removeObject(forKey: Self.snoozedUntilKey)
        return true
    }

    private func startCountdownTimer() {
        snoozeTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) {
            [weak self] _ in
            Task { @MainActor in
                self?.refreshCountdown()
            }
        }
    }

    func refreshCountdown() {
        countdownDate = now()
        if defaults.object(forKey: Self.snoozedUntilKey) != nil,
           snoozedUntil == nil {
            resumeProtection()
        }
    }

    private static let expiryFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter
    }()

    private static func countdownLabel(_ seconds: Int) -> String {
        if seconds >= 3600 {
            return "\(seconds / 3600)h \((seconds % 3600) / 60)m"
        }
        if seconds >= 60 {
            return "\(seconds / 60)m \(seconds % 60)s"
        }
        return "\(seconds)s"
    }

    static func durationLabel(_ seconds: TimeInterval) -> String {
        if seconds >= 3600, seconds.truncatingRemainder(dividingBy: 3600) == 0 {
            let hours = Int(seconds / 3600)
            return "\(hours) \(hours == 1 ? "hour" : "hours")"
        }
        let minutes = Int(seconds / 60)
        return "\(minutes) \(minutes == 1 ? "minute" : "minutes")"
    }
}
