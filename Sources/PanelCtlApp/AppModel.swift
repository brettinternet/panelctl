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
    static let experimentalDocsURL = URL(string: "https://github.com/brettinternet/panelctl/blob/main/docs/display-hide-ux.md#experimental-features")!

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
    /// Keyed by lowercased target UUID.
    @Published private(set) var macInputDetections: [String: MacInputDetection] = [:]
    /// Last Hide or Show outcome per display, keyed by lowercased target UUID.
    /// Input outcomes are session evidence, not a claim about the monitor's current input.
    @Published private(set) var displayResults: [String: DisplayOperationResult] = [:]
    @Published private(set) var hideOperation: DisplayHideOperation = .idle
    /// Displays Hide blacked out, keyed by lowercased UUID. They stay hidden
    /// through display changes until Show; quitting shows them.
    @Published private(set) var blackoutHiddenDisplays: [String: DisplayIdentitySnapshot] = [:]
    /// Hidden displays that are on but couldn't be covered; the next display
    /// change tries again.
    @Published private(set) var uncoveredHiddenDisplays: Set<String> = []
    @Published private(set) var protectionQuiescencePending = false
    @Published private(set) var protectionQuiescenceFailure: String? {
        didSet {
            defaults.set(protectionQuiescenceFailure, forKey: Self.cleanupFailureKey)
        }
    }
    @Published private(set) var displayLifecycleTransitioning = false
    /// When a display was last hidden or shown. A script request received
    /// before then waited behind that change, such as while the main thread
    /// switched displays.
    private var lastHideOrShowFinished: ContinuousClock.Instant?
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
    @Published var disconnectConsentPending = false
    @Published private(set) var disconnectRequest: DisplayDisconnectRequest?
    @Published private(set) var disconnectStatus: DisplayDisconnectStatus?
    @Published private(set) var disconnectFailure: String?
    private var disconnectLease: DisplayDisconnectLease?
    private let disconnectController: DisplayDisconnectController
    private let disconnectExecutable: @MainActor () throws -> URL
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
    private let coverDisplays: @MainActor (Set<UInt32>) -> Set<UInt32>
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
    private static let cleanupFailureKey = "automationCleanupFailure"
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
        coverDisplays: (@MainActor (Set<UInt32>) -> Set<UInt32>)? = nil,
        quiesceProtection: ProtectionQuiesce? = nil,
        protectionService: ProtectionService? = nil,
        disconnectController: DisplayDisconnectController = DisplayDisconnectController(),
        disconnectExecutable: @escaping @MainActor () throws -> URL = ProtectionService.helperExecutableURL
    ) {
        self.defaults = defaults
        self.disconnectController = disconnectController
        self.disconnectExecutable = disconnectExecutable
        self.displayProvider = displayProvider
        self.now = now
        self.idleSecondsProvider = idleSecondsProvider
        self.sleepDisplays = sleepDisplays
        self.isDisplayMirrored = isDisplayMirrored
        self.inspectHandoff = inspectHandoff
        self.hideDisplay = hideDisplay
        self.showDisplay = showDisplay
        self.checkDDCInput = checkDDCInput
        self.coverDisplays = coverDisplays ?? HiddenDisplayOverlays().cover
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
        service = protectionService ?? ProtectionService(
            initialCleanupFailure: defaults.string(forKey: Self.cleanupFailureKey)
        )
        protectionQuiescenceFailure = defaults.string(forKey: Self.cleanupFailureKey) ??
            service.unresolvedCleanupFailure
        let storedSnooze = defaults.object(forKey: Self.snoozedUntilKey) as? Date
        if let storedSnooze, storedSnooze > now(), preferences.isEnabled {
            runtimeState = .snoozed(storedSnooze)
        } else {
            defaults.removeObject(forKey: Self.snoozedUntilKey)
        }
        service.onStateChange = { [weak self] state in
            guard let self else { return }
            if let failure = self.service.unresolvedCleanupFailure {
                self.protectionQuiescenceFailure = failure
            }
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
        refreshDisconnectStatus()
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
              !isBlackoutHidden(uuid),
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
            return "Automation suspended · cleanup needs attention: \(failure)"
        }
        if protectionQuiescencePending {
            return "Automation suspended · waiting for cleanup to finish"
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
        disconnectLease != nil || disconnectStatus?.resolved == false ||
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
            _ = try protectionArguments()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// Automation skips displays Hide blacked out.
    private func protectionArguments() throws -> [String] {
        try preferences.commandArguments(for: displays, hiddenDisplayUUIDs: Set(blackoutHiddenDisplays.keys))
    }

    /// The source-only overlay counts displays Hide blacked out as covered.
    private func hiddenMirrorArguments(for source: DisplayRecord) throws -> [String]? {
        try preferences.hiddenMirrorOverlayArguments(
            for: source,
            hiddenDisplays: activeDisplays.filter { isBlackoutHidden($0.uuid) }
        )
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

    /// Why Hide can't start for this configuration right now, or nil when it can.
    func hideReadiness(
        for configuration: DisplayHideConfiguration,
        allowingCurrentOperation: Bool = false
    ) -> DisplayHideError? {
        if let failure = handoffInspectionFailure {
            return .recoveryBlocksHide("Couldn\u{2019}t check display recovery: \(failure)")
        }
        guard let status = handoffStatus else {
            return .recoveryBlocksHide("Display recovery status is unknown. Try again in a moment.")
        }
        if status.state == .busy {
            return .recoveryBlocksHide("Another display operation is running. Try again in a moment.")
        }
        if status.hasUnresolvedJournal {
            return .recoveryBlocksHide("Only one display can be removed at a time. Show the hidden display or finish its recovery first.")
        }
        if !allowingCurrentOperation, hideOperation.isBusy { return .actionInProgress }
        if displayLifecycleTransitioning { return .sleeping }
        if protectionQuiescencePending { return Self.automationStopping }
        if let failure = protectionQuiescenceFailure {
            return .protectionCleanup("Automation cleanup needs attention: \(failure) Choose Retry Automation Cleanup, then try again.")
        }
        guard configuration.enabled else {
            return .unavailable("Turn on Remove from desktop for this display first.")
        }
        guard let target = matchingDisplay(configuration.target) else {
            return .identityChanged("This display is disconnected or changed. Reconnect it, then try again; PanelCtl won\u{2019}t apply its settings to a different display.")
        }
        if isBlackoutHidden(target.uuid) {
            return .unavailable("This display is hidden. Show it first.")
        }
        if let reason = removalIneligibleReason(for: target) {
            return .unavailable(reason)
        }
        guard !isDisplayMirrored(target.id) else {
            return .unavailable("macOS is already mirroring this display. Turn off mirroring in System Settings \u{2192} Displays first.")
        }
        guard let sourceIdentity = configuration.source else {
            return .unavailable("Choose a display to mirror onto.")
        }
        guard let source = matchingDisplay(sourceIdentity) else {
            return .identityChanged("The display it mirrors onto is disconnected or changed. Choose it again.")
        }
        guard source.online, source.active, !source.asleep else {
            return .unavailable("The display it mirrors onto must be on and awake.")
        }
        guard !isBlackoutHidden(source.uuid) else {
            return .unavailable("The display it mirrors onto is hidden. Show it first.")
        }
        guard target.id != source.id else {
            return .unavailable("Choose a different display to mirror onto.")
        }
        return nil
    }

    func hideReadinessMessage(for configuration: DisplayHideConfiguration) -> String? {
        hideReadiness(for: configuration)?.localizedDescription
    }

    /// Why this display can't be removed from the desktop, or nil when it can.
    func removalIneligibleReason(for display: DisplayRecord) -> String? {
        if display.builtin {
            return "Built-in displays can\u{2019}t be removed from the desktop."
        }
        if display.main {
            return "The main display can\u{2019}t be removed from the desktop. To remove it, make another display the main display in System Settings \u{2192} Displays."
        }
        guard display.uuid.flatMap(UUID.init(uuidString:)) != nil else {
            return "This display has no stable ID, so PanelCtl can\u{2019}t remove it from the desktop."
        }
        guard display.active, display.online, !display.asleep,
              display.bounds.width > 0, display.bounds.height > 0 else {
            return "Wake this display to remove it from the desktop."
        }
        return nil
    }

    /// Hide removes a display from the desktop when Experimental features and
    /// its Remove from desktop switch are on; otherwise Hide blacks it out.
    func hideRemovesFromDesktop(_ display: DisplayRecord) -> Bool {
        guard experimentalFeaturesEnabled, let uuid = display.uuid,
              hidePreferences[uuid]?.enabled == true else { return false }
        return removalIneligibleReason(for: display) == nil
    }

    func isBlackoutHidden(_ uuid: String?) -> Bool {
        uuid.map { blackoutHiddenDisplays[$0.lowercased()] != nil } ?? false
    }

    /// Why Hide can't black out this display right now, or nil when it can.
    func blackoutReadiness(for display: DisplayRecord) -> DisplayHideError? {
        if hideOperation.isBusy { return .actionInProgress }
        if displayLifecycleTransitioning { return .sleeping }
        guard let uuid = display.uuid, UUID(uuidString: uuid) != nil,
              displays.filter({ $0.uuid?.caseInsensitiveCompare(uuid) == .orderedSame }).count == 1 else {
            return .unavailable("This display has no stable ID, so PanelCtl can\u{2019}t hide it.")
        }
        guard display.active, display.online, !display.asleep,
              display.bounds.width > 0, display.bounds.height > 0 else {
            return .unavailable("Wake this display to hide it.")
        }
        let journal = handoffStatus?.hasUnresolvedJournal == true ? handoffStatus : nil
        if journal?.target?.uuid.caseInsensitiveCompare(uuid) == .orderedSame {
            return .unavailable("PanelCtl removed this display from the desktop. Show it first.")
        }
        if isDisplayMirrored(display.id) {
            if journal?.source?.uuid.caseInsensitiveCompare(uuid) == .orderedSame {
                return .unavailable("PanelCtl is mirroring \(journal?.target?.name ?? "another display") onto this display. Show it first.")
            }
            return .unavailable("macOS is mirroring this display. Turn off mirroring in System Settings \u{2192} Displays first.")
        }
        let anotherStaysVisible = displays.contains { other in
            guard other.id != display.id, other.active, other.online, !other.asleep,
                  other.bounds.width > 0, other.bounds.height > 0,
                  !isBlackoutHidden(other.uuid) else { return false }
            // A display removed from the desktop shows the other computer.
            guard let target = journal?.target else { return true }
            return other.uuid?.caseInsensitiveCompare(target.uuid) != .orderedSame
        }
        guard anotherStaysVisible else {
            return .unavailable("PanelCtl keeps at least one display visible, so it won\u{2019}t hide this one.")
        }
        return nil
    }

    /// Current IDs of the hidden displays that are covered now.
    var coveredHiddenDisplayIDs: Set<UInt32> {
        Set(connectedHiddenDisplays.filter { !uncoveredHiddenDisplays.contains($0.value) }.keys)
    }

    /// Escape on a hidden display shows it; false when Hide didn't black it out.
    func showHiddenDisplay(at displayID: UInt32) -> Bool {
        guard let key = connectedHiddenDisplays[displayID] else { return false }
        show(targetUUID: key)
        return true
    }

    /// Connected hidden displays by current display ID. Sleeping displays stay
    /// covered, so they don't flash the desktop when they wake.
    private var connectedHiddenDisplays: [UInt32: String] {
        var connected: [UInt32: String] = [:]
        for key in blackoutHiddenDisplays.keys {
            let matches = displays.filter { $0.online && $0.uuid?.lowercased() == key }
            if matches.count == 1, let display = matches.first { connected[display.id] = key }
        }
        return connected
    }

    /// Covers each connected hidden display at its current frame.
    private func coverHiddenDisplays() {
        let connected = connectedHiddenDisplays
        let failed = coverDisplays(Set(connected.keys))
        uncoveredHiddenDisplays = Set(failed.compactMap { id in
            displays.contains { $0.id == id && $0.active && !$0.asleep } ? connected[id] : nil
        })
    }

    /// Re-covers hidden displays after a display change. A hidden display
    /// macOS now mirrors is shown, since its mirror would show the cover too,
    /// and once no other display is connected, every hidden display is shown.
    private func reconcileHiddenDisplays() {
        var shown: [String: String] = [:]
        if !blackoutHiddenDisplays.isEmpty, !displayLifecycleTransitioning {
            for (id, key) in connectedHiddenDisplays where isDisplayMirrored(id) {
                shown[key] = "Shown because macOS started mirroring it."
            }
            let stillHidden = Set(blackoutHiddenDisplays.keys).subtracting(shown.keys)
            if !stillHidden.isEmpty, !displays.contains(where: {
                $0.online && !stillHidden.contains($0.uuid?.lowercased() ?? "")
            }) {
                for key in stillHidden { shown[key] = "Shown because no other display was connected." }
            }
        }
        for (key, message) in shown {
            blackoutHiddenDisplays[key] = nil
            displayResults[key] = DisplayOperationResult(
                action: .hide, succeeded: false, message: message,
                inputMessage: nil, inputOutcome: nil, inputNeedsAttention: false
            )
        }
        coverHiddenDisplays()
        if !shown.isEmpty { hiddenDisplaysChanged() }
    }

    /// Automation restarts without the hidden displays and counts idle time anew.
    private func hiddenDisplaysChanged() {
        lastHideOrShowFinished = .now
        manualActivityDate = now()
        reconcileProtection(restartWatcher: true)
        onStatusChange?()
    }

    private func blackOut(targetUUID: String, completion: ((DisplayOperationResult) -> Void)?) {
        let matches = displays.filter { $0.uuid?.caseInsensitiveCompare(targetUUID) == .orderedSame }
        guard matches.count == 1, let display = matches.first else {
            refuse(.hide, targetUUID: targetUUID, error: DisplayHideError.unavailable(
                "This display is disconnected. Reconnect it, then try again."
            ), completion: completion)
            return
        }
        if let refusal = blackoutReadiness(for: display) {
            refuse(.hide, targetUUID: targetUUID, error: refusal, completion: completion)
            return
        }
        let key = targetUUID.lowercased()
        blackoutHiddenDisplays[key] = DisplayIdentitySnapshot(display)
        coverHiddenDisplays()
        guard !uncoveredHiddenDisplays.contains(key) else {
            blackoutHiddenDisplays[key] = nil
            coverHiddenDisplays()
            refuse(.hide, targetUUID: targetUUID, error: DisplayHideError.unavailable(
                "The display wasn\u{2019}t fully covered. Try again."
            ), completion: completion)
            return
        }
        let result = DisplayOperationResult(
            action: .hide, succeeded: true, message: "Hidden.",
            inputMessage: nil, inputOutcome: nil, inputNeedsAttention: false
        )
        displayResults[key] = result
        hiddenDisplaysChanged()
        completion?(result)
    }

    private func showBlackedOut(targetUUID: String, completion: ((DisplayOperationResult) -> Void)?) {
        let key = targetUUID.lowercased()
        blackoutHiddenDisplays[key] = nil
        coverHiddenDisplays()
        let result = DisplayOperationResult(
            action: .show, succeeded: true, message: "Shown.",
            inputMessage: nil, inputOutcome: nil, inputNeedsAttention: false
        )
        displayResults[key] = result
        hiddenDisplaysChanged()
        completion?(result)
    }

    /// Saved Hide settings for a display, or defaults for an eligible one.
    func hideConfiguration(for uuid: String) -> DisplayHideConfiguration? {
        hideDisplayConfigurations.first { $0.target.uuid.caseInsensitiveCompare(uuid) == .orderedSame }
    }

    /// Displays in arrangement order, plus a journaled display that is no longer connected.
    var displayTiles: [DisplayTile] {
        let journalTarget = handoffStatus?.hasUnresolvedJournal == true ? handoffStatus?.target : nil
        func isJournalTarget(_ display: DisplayRecord) -> Bool {
            guard let journalTarget, let uuid = display.uuid else { return false }
            return uuid.caseInsensitiveCompare(journalTarget.uuid) == .orderedSame
        }
        let present = displays
            .filter {
                ($0.active && $0.online && $0.bounds.width > 0 && $0.bounds.height > 0) || isJournalTarget($0)
            }
            .sorted { lhs, rhs in
                if lhs.bounds.x != rhs.bounds.x { return lhs.bounds.x < rhs.bounds.x }
                if lhs.bounds.y != rhs.bounds.y { return lhs.bounds.y < rhs.bounds.y }
                // A display hidden by mirroring shares its source's origin.
                if isJournalTarget(lhs) != isJournalTarget(rhs) { return isJournalTarget(rhs) }
                return lhs.id < rhs.id
            }
        var tiles = present.map { display in
            DisplayTile(
                id: display.uuid?.lowercased() ?? "display-\(display.id)",
                uuid: display.uuid,
                name: display.settingsName,
                status: tileStatus(for: display, isJournalTarget: isJournalTarget(display)),
                display: display
            )
        }
        if let journalTarget, !tiles.contains(where: { $0.id == journalTarget.uuid.lowercased() }) {
            tiles.append(DisplayTile(
                id: journalTarget.uuid.lowercased(),
                uuid: journalTarget.uuid,
                name: journalTarget.name,
                status: tileStatus(for: nil, isJournalTarget: true),
                display: nil
            ))
        }
        // A hidden display that's away stays hidden until Show.
        for (key, identity) in blackoutHiddenDisplays.sorted(by: { $0.key < $1.key })
        where !tiles.contains(where: { $0.id == key }) {
            tiles.append(DisplayTile(
                id: key, uuid: identity.uuid, name: identity.name ?? "Display \(identity.id)",
                status: .hidden, display: nil
            ))
        }
        // Number identical names in order, as macOS does.
        let names = tiles.map(\.name)
        for index in tiles.indices {
            let name = tiles[index].name
            if names.filter({ $0 == name }).count > 1 {
                tiles[index] = DisplayTile(
                    id: tiles[index].id, uuid: tiles[index].uuid,
                    name: "\(name) (\(names[...index].filter { $0 == name }.count))",
                    status: tiles[index].status, display: tiles[index].display
                )
            }
            setAction(of: &tiles[index])
        }
        return tiles
    }

    /// The tile with this ID, else the display that is hidden or needs recovery, else the first.
    func tile(selecting id: String?) -> DisplayTile? {
        let tiles = displayTiles
        let journalTargetID = handoffStatus?.hasUnresolvedJournal == true
            ? handoffStatus?.target?.uuid.lowercased() : nil
        return tiles.first { $0.id == id } ?? tiles.first { $0.id == journalTargetID } ?? tiles.first
    }

    /// Whether PanelCtl's hidden display can be shown: its saved layout is restorable.
    var canShowHiddenDisplay: Bool {
        guard handoffInspectionFailure == nil, let status = handoffStatus else { return false }
        return (status.state == .hidden || status.state == .recovery) && status.canShow
    }

    private static let automationStopping = DisplayHideError.recoveryBlocksAction(
        "PanelCtl is still stopping automation. Try again in a moment."
    )

    /// Why Show must wait, apart from the hidden display's own state.
    private var showWait: DisplayHideError? {
        if hideOperation.isBusy { return .actionInProgress }
        if displayLifecycleTransitioning { return .sleeping }
        if protectionQuiescencePending { return Self.automationStopping }
        return nil
    }

    private func setAction(of tile: inout DisplayTile) {
        switch tile.status {
        case .hiding, .showing, .busy:
            return
        case .hidden, .needsRecovery:
            if isBlackoutHidden(tile.uuid) {
                tile.action = .show
                return
            }
            guard canShowHiddenDisplay else { return }
            tile.action = .show
            tile.actionBlocker = showWait?.localizedDescription
        case .on, .blackedOut, .asleep, .mirrored, .unavailable:
            guard let display = tile.display else { return }
            tile.action = .hide
            if hideRemovesFromDesktop(display), let uuid = tile.uuid,
               let configuration = hideConfiguration(for: uuid) {
                tile.actionBlocker = hideReadinessMessage(for: configuration)
            } else {
                tile.actionBlocker = blackoutReadiness(for: display)?.localizedDescription
            }
        }
    }

    private func tileStatus(for display: DisplayRecord?, isJournalTarget: Bool) -> DisplayTile.Status {
        let uuid = isJournalTarget ? handoffStatus?.target?.uuid : display?.uuid
        switch hideOperation {
        case .hiding(let target) where uuid?.caseInsensitiveCompare(target) == .orderedSame:
            return .hiding
        case .showing(let target) where uuid?.caseInsensitiveCompare(target) == .orderedSame:
            return .showing
        default:
            break
        }
        if isBlackoutHidden(uuid) { return .hidden }
        if isJournalTarget, let status = handoffStatus {
            switch status.state {
            case .busy: return .busy
            case .hidden where status.canShow: return .hidden
            default: return .needsRecovery
            }
        }
        guard let display, display.active, display.online else { return .unavailable }
        if display.asleep { return .asleep }
        if blackedOutDisplayIDs.contains(display.id) { return .blackedOut }
        // The source of PanelCtl's mirror is still a normal display.
        let isJournalSource = handoffStatus?.hasUnresolvedJournal == true &&
            display.uuid.map { handoffStatus?.source?.uuid.caseInsensitiveCompare($0) == .orderedSame } == true
        if isDisplayMirrored(display.id), !isJournalSource { return .mirrored }
        return .on
    }

    /// A display recovery problem that needs the user; a healthy hidden display isn't one.
    var displayRecoveryProblem: String? {
        if let failure = handoffInspectionFailure {
            return "Couldn\u{2019}t check display recovery: \(failure)"
        }
        guard let status = handoffStatus else { return nil }
        switch status.state {
        case .none, .busy:
            return nil
        case .hidden where status.canShow:
            return nil
        case .hidden, .recovery, .unsupported:
            return status.reason ?? "\(status.target?.name ?? "A display") needs recovery."
        }
    }

    /// A recovery problem that no display shows, such as an inspection failure
    /// or a journal without a target display; Displays shows it above the displays.
    var pageRecoveryProblem: String? {
        guard let problem = displayRecoveryProblem,
              !displayTiles.contains(where: { $0.status == .needsRecovery }) else { return nil }
        return problem
    }

    /// What Show will do with the monitor input of the journaled display.
    var showReturnInputNote: String? {
        guard let status = handoffStatus, status.hasUnresolvedJournal else { return nil }
        let input = configuredReturnInput(for: status)
        if let warning = input.warning {
            return "Show won\u{2019}t switch the monitor input: \(warning)"
        }
        return input.value.map { "Show switches the monitor back to \(MonitorInput.name($0))." }
    }

    /// Turns Remove from desktop on or off for a display.
    func setHideEnabled(_ enabled: Bool, for display: DisplayRecord) {
        guard !hideConfigurationFrozen,
              isEligibleHideTarget(display),
              let uuid = display.uuid else { return }
        var updated = hidePreferences
        var configuration = updated[uuid] ?? DisplayHideConfiguration(target: DisplayIdentitySnapshot(display))
        guard matches(configuration.target, display) else { return }
        configuration.enabled = enabled
        // The main display is the default and the only hardware-qualified source.
        if enabled, configuration.source == nil,
           let main = sourceChoices(for: configuration).first(where: \.main) {
            configuration.source = DisplayIdentitySnapshot(main)
        }
        updated[uuid] = configuration
        hidePreferences = updated
        clearFailedResult(uuid)
    }

    func setHideSource(_ sourceUUID: String?, for targetUUID: String) {
        guard !hideConfigurationFrozen,
              let target = displays.first(where: {
                  $0.uuid?.caseInsensitiveCompare(targetUUID) == .orderedSame
              }),
              let uuid = target.uuid else { return }
        var updated = hidePreferences
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
        updated[uuid] = configuration
        hidePreferences = updated
        clearFailedResult(uuid)
    }

    /// Sets the input the monitor switches to on Hide. Nil switches nothing,
    /// on Show too; the input Show switches back to is detected, not chosen.
    func setHideSwitchInput(_ value: UInt8?, for targetUUID: String) {
        guard !hideConfigurationFrozen,
              let target = displays.first(where: { $0.uuid?.caseInsensitiveCompare(targetUUID) == .orderedSame }),
              let uuid = target.uuid else { return }
        var updated = hidePreferences
        var configuration = updated[uuid] ?? DisplayHideConfiguration(target: DisplayIdentitySnapshot(target))
        guard matches(configuration.target, target) else { return }
        configuration.awayInput = value
        var detected: UInt8?
        if case .detected(let macInput) = macInputDetections[uuid.lowercased()] { detected = macInput }
        configuration.returnInput = Self.returnInput(saved: configuration.returnInput, detected: detected, away: value)
        updated[uuid] = configuration
        hidePreferences = updated
        clearFailedResult(uuid)
    }

    /// The input Show switches back to: the detected Mac input, else the saved
    /// one, but never the input Hide switches to. It is kept while switching is
    /// off because Show uses it only when Hide switched.
    private static func returnInput(saved: UInt8?, detected: UInt8?, away: UInt8?) -> UInt8? {
        if let detected, detected != away { return detected }
        return saved == away ? nil : saved
    }

    /// A failed result describes settings that just changed, so it no longer applies.
    private func clearFailedResult(_ uuid: String) {
        // A switched monitor stays switched whatever the settings, so its undo command stays.
        if let result = displayResults[uuid.lowercased()], !result.succeeded, result.undoInputCommand == nil {
            displayResults[uuid.lowercased()] = nil
        }
    }

    /// This Mac's input on a display, as Settings shows it: the input read this
    /// session, else the one saved from an earlier reading. Unlike the input
    /// Show switches back to, it stays known when Hide is set to switch to it.
    func macInput(for targetUUID: String) -> UInt8? {
        if case .detected(let input)? = macInputDetections[targetUUID.lowercased()] { return input }
        return hidePreferences[targetUUID]?.returnInput
    }

    /// Reads, read-only over DDC, the input this Mac uses on the display and
    /// keeps it as the input Show switches back to.
    func detectMacInput(for targetUUID: String) {
        let key = targetUUID.lowercased()
        guard !hideConfigurationFrozen,
              let configuration = hidePreferences[targetUUID], configuration.enabled,
              let display = matchingDisplay(configuration.target),
              isEligibleHideTarget(display), !isDisplayMirrored(display.id) else { return }
        defer { onStatusChange?() }
        let reading: DDCInputReading
        do {
            reading = try checkDDCInput(coreIdentity(configuration.target))
        } catch {
            macInputDetections[key] = .unavailable(Self.sentence(error.localizedDescription))
            return
        }
        guard reading.displayID == configuration.target.id,
              reading.uuid.caseInsensitiveCompare(configuration.target.uuid) == .orderedSame,
              matches(configuration.target, display) else {
            macInputDetections[key] = .unavailable("The monitor answered as a different display. Reconnect it, then try again.")
            return
        }
        // Input 0 means the monitor doesn't know; Show would refuse it anyway.
        guard reading.current != 0 else {
            macInputDetections[key] = .unavailable("The monitor didn\u{2019}t report its current input.")
            return
        }
        guard reading.current != configuration.awayInput else {
            macInputDetections[key] = .onSwitchInput(reading.current)
            return
        }
        macInputDetections[key] = .detected(reading.current)
        if configuration.returnInput != reading.current {
            var updated = hidePreferences
            var saved = configuration
            saved.returnInput = reading.current
            updated[targetUUID] = saved
            hidePreferences = updated
        }
    }

    var controlDisplayOutcome: AppControlOutcome? {
        if hideOperation.isBusy || handoffStatus?.state == .busy { return .busy }
        if displayRecoveryProblem != nil { return .recoveryNeeded }
        if displayResults.values.contains(where: { $0.inputOutcome?.isPartial == true }) { return .partial }
        return nil
    }

    /// Every display with a UUID, as the Displays tab shows it.
    var controlDisplayStatuses: [AppControlDisplayStatus] {
        let recoveryNeeded = displayRecoveryProblem != nil
        return displayTiles.compactMap { tile in
            guard let uuid = tile.uuid else { return nil }
            return AppControlDisplayStatus(
                targetUUID: uuid,
                observedState: controlState(of: tile),
                operation: tile.status == .hiding ? "hiding" : tile.status == .showing ? "showing" : "idle",
                recoveryNeeded: recoveryNeeded,
                lastInputOutcome: displayResults[tile.id]?.inputOutcome
            )
        }
    }

    private func controlState(of tile: DisplayTile) -> String {
        if isBlackoutHidden(tile.uuid) { return "hidden-by-panelctl" }
        if handoffInspectionFailure != nil { return "unknown" }
        if let observation = handoffStatus?.observations.first(where: {
            $0.identity.uuid.caseInsensitiveCompare(tile.uuid ?? "") == .orderedSame
        }) {
            switch observation.state {
            case .separate: return "separate"
            case .hiddenByPanelCtl: return "hidden-by-panelctl"
            case .unavailable: return "unavailable"
            case .mirroredExternally: return "mirrored-externally"
            case .recoveryNeeded: return "recovery-needed"
            case .unsupportedRecovery: return "unsupported-recovery"
            case .unknown: return "unknown"
            }
        }
        guard let display = tile.display, display.online, display.active else { return "unavailable" }
        return isDisplayMirrored(display.id) ? "mirrored-externally" : "separate"
    }

    /// Runs Hide, Show or Toggle Hide for a script, like the display's Hide or
    /// Show button, and answers when it finishes. A request that can't run now
    /// is refused, never queued for later. The response includes only the
    /// requested display.
    func handleDisplayControlRequest(
        _ request: AppControlRequest,
        receivedAt: ContinuousClock.Instant = .now
    ) async -> AppControlResponse {
        func response(_ outcome: AppControlOutcome, _ summary: String,
                      detail: String? = nil, error: String? = nil) -> AppControlResponse {
            let ok = outcome == .done || outcome == .noOp
            return AppControlResponse(
                ok: ok, running: true, enabled: preferences.isEnabled,
                state: runtimeState.controlIdentifier, summary: summary, detail: detail,
                error: ok ? nil : error ?? summary, outcome: outcome,
                displays: controlDisplayStatuses.filter {
                    $0.targetUUID.caseInsensitiveCompare(request.targetUUID ?? "") == .orderedSame
                }
            )
        }
        guard request.protocolVersion == AppControlRequest.currentProtocol,
              request.command.isDisplayCommand, request.durationSeconds == nil,
              let uuid = request.targetUUID, UUID(uuidString: uuid) != nil else {
            return response(.refused, "Hide, Show and Toggle Hide need --display with a display UUID.")
        }
        guard !hideOperation.isBusy else {
            return response(.busy, DisplayHideError.actionInProgress.localizedDescription)
        }
        // Acting on a request that waited would act on a state its sender
        // didn't see; a second Toggle Hide would undo the first.
        if let finished = lastHideOrShowFinished, receivedAt < finished {
            return response(.busy, "Another Hide or Show finished while this request waited. Check the display, then try again.")
        }
        refreshDisplays()
        guard handoffStatus?.state != .busy else {
            return response(.busy, "Another display operation is running. Try again when it finishes.")
        }
        guard !displayLifecycleTransitioning else {
            return response(.refused, DisplayHideError.sleeping.localizedDescription)
        }
        let tile = displayTiles.first { $0.uuid?.caseInsensitiveCompare(uuid) == .orderedSame }
        let hidden = tile?.status == .hidden || tile?.status == .needsRecovery
        let action: DisplayTile.Action
        switch request.command {
        case .hide: action = .hide
        case .show: action = .show
        default: action = hidden ? .show : .hide
        }
        // While recovery is unresolved, scripts can only show a hidden display.
        if let problem = displayRecoveryProblem, !(action == .show && tile?.action == .show) {
            return response(.recoveryNeeded, problem)
        }
        guard let tile else {
            return response(.refused, "No connected display has this UUID. Copy the command again from PanelCtl Settings \u{2192} Displays.")
        }
        if action == .hide, tile.status == .hidden {
            return response(.noOp, "\(tile.name) is already hidden.")
        }
        if action == .show, !hidden {
            return response(.noOp, "\(tile.name) isn\u{2019}t hidden.")
        }
        guard tile.action == action, tile.actionBlocker == nil else {
            return response(.refused, tile.actionBlocker ?? "PanelCtl can\u{2019}t do that for \(tile.name) now.")
        }
        let result = await withCheckedContinuation { continuation in
            let finished: (DisplayOperationResult) -> Void = { continuation.resume(returning: $0) }
            if action == .hide {
                hide(targetUUID: uuid, completion: finished)
            } else {
                show(targetUUID: uuid, completion: finished)
            }
        }
        if result.succeeded {
            if result.inputOutcome?.isPartial == true {
                return response(.partial, result.message, detail: result.inputMessage, error: result.inputMessage)
            }
            return response(.done, result.message, detail: result.inputMessage)
        }
        let outcome: AppControlOutcome = displayRecoveryProblem != nil ? .recoveryNeeded
            : result.inputOutcome == nil ? .refused : .failed
        return response(outcome, result.message, detail: result.inputMessage)
    }

    func makeHideRequest(targetUUID: String) throws -> DisplayHideRequest {
        guard !hideOperation.isBusy else { throw DisplayHideError.actionInProgress }
        guard experimentalFeaturesEnabled else {
            throw DisplayHideError.unavailable("Turn on Experimental features in General to remove a display from the desktop.")
        }
        guard let configuration = hidePreferences[targetUUID] else {
            throw DisplayHideError.unavailable("Turn on Remove from desktop for this display first.")
        }
        if let refusal = hideReadiness(for: configuration) { throw refusal }
        guard let source = configuration.source else {
            throw DisplayHideError.unavailable("Choose a display to mirror onto.")
        }
        return hideRequest(target: configuration.target, source: source, configuration: configuration)
    }

    /// Hides a display right away in its style: blacked out, or removed from
    /// the desktop. The outcome is kept in `displayResults` and passed to `completion`.
    func hide(targetUUID: String, completion: ((DisplayOperationResult) -> Void)? = nil) {
        if isBlackoutHidden(targetUUID) {
            refuse(.hide, targetUUID: targetUUID, error: DisplayHideError.unavailable(
                "This display is already hidden."
            ), completion: completion)
            return
        }
        guard let display = displays.first(where: { $0.uuid?.caseInsensitiveCompare(targetUUID) == .orderedSame }),
              hideRemovesFromDesktop(display) else {
            blackOut(targetUUID: targetUUID, completion: completion)
            return
        }
        let request: DisplayHideRequest
        do {
            request = try makeHideRequest(targetUUID: targetUUID)
        } catch {
            refuse(.hide, targetUUID: targetUUID, error: error, completion: completion)
            return
        }
        displayResults[request.target.uuid.lowercased()] = nil
        hideOperation = .hiding(request.target.uuid)
        manualActivityDate = now()
        onStatusChange?()
        stopManagedProtection { [weak self] succeeded, message in
            Task { @MainActor in
                self?.finishHideAfterProtectionQuiescence(
                    request,
                    cleanupSucceeded: succeeded,
                    cleanupFailure: message,
                    completion: completion
                )
            }
        }
    }

    func makeShowRequest() throws -> DisplayShowRequest {
        if let showWait { throw showWait }
        refreshHandoffStatus()
        guard handoffInspectionFailure == nil,
              let handoffStatus,
              handoffStatus.state == .hidden || handoffStatus.state == .recovery else {
            throw DisplayHideError.recoveryBlocksAction(
                handoffInspectionFailure ?? handoffStatus?.reason ?? "No display is hidden by PanelCtl."
            )
        }
        guard handoffStatus.canShow else {
            throw DisplayHideError.recoveryBlocksAction(
                handoffStatus.reason ?? "PanelCtl can\u{2019}t restore the saved layout right now."
            )
        }
        let input = configuredReturnInput(for: handoffStatus)
        return DisplayShowRequest(status: handoffStatus, returnInput: input.value, returnInputWarning: input.warning)
    }

    /// Shows a hidden display right away. Refuses when the journal belongs to
    /// a different display, so a stale action never shows another one.
    func show(targetUUID: String, completion: ((DisplayOperationResult) -> Void)? = nil) {
        if isBlackoutHidden(targetUUID) {
            showBlackedOut(targetUUID: targetUUID, completion: completion)
            return
        }
        let request: DisplayShowRequest
        do {
            request = try makeShowRequest()
            guard request.status.target?.uuid.caseInsensitiveCompare(targetUUID) == .orderedSame else {
                throw DisplayHideError.recoveryBlocksAction("This display isn\u{2019}t hidden by PanelCtl.")
            }
        } catch {
            refuse(.show, targetUUID: targetUUID, error: error, completion: completion)
            return
        }
        displayResults[targetUUID.lowercased()] = nil
        hideOperation = .showing(targetUUID)
        onStatusChange?()
        stopManagedProtection { [weak self] succeeded, message in
            Task { @MainActor in
                self?.finishShowAfterProtectionQuiescence(
                    request,
                    cleanupSucceeded: succeeded,
                    cleanupFailure: message,
                    completion: completion
                )
            }
        }
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
        if !transitioning {
            reconcileHiddenDisplays()
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
        if protectionQuiescenceFailure != nil {
            retryAutomationCleanup()
            return
        }
        guard preferences.isEnabled else { return }
        reconcileProtection()
    }

    func retryAutomationCleanup() {
        guard !protectionQuiescencePending, !hideOperation.isBusy else { return }
        protectionQuiescencePending = true
        onStatusChange?()
        service.retryCleanup { [weak self] succeeded, message in
            guard let self else { return }
            self.protectionQuiescencePending = false
            if succeeded {
                self.protectionQuiescenceFailure = nil
                self.rearmProtectionAfterDisplayRecovery()
            } else {
                self.protectionQuiescenceFailure = message ?? self.protectionQuiescenceFailure ??
                    "Automation cleanup could not be verified."
            }
            self.onStatusChange?()
        }
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
                guard let overlayArguments = try hiddenMirrorArguments(for: hiddenOverlaySource) else {
                    throw DisplayHideError.recoveryBlocksAction("Add the journaled mirror source to the idle display list before using Black Out Now.")
                }
                arguments = overlayArguments
            } else {
                arguments = try protectionArguments()
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
        reconcileHiddenDisplays()
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

    /// Matches the helper: input extends the limit only while another
    /// display, neither the source nor hidden, stays usable.
    var hiddenMirrorOverlayResetsLimitOnInput: Bool {
        guard preferences.mode == .working || preferences.keepBlackoutOnInput,
              let source = selectedHiddenMirrorSource else { return false }
        return activeDisplays.contains { $0.id != source.id && !isBlackoutHidden($0.uuid) }
    }

    /// Matches the helper, which counts hidden displays as covered.
    private var resetsBlackoutLimitOnInput: Bool {
        guard (preferences.mode == .working || preferences.keepBlackoutOnInput),
              !preferences.allDisplays else {
            return false
        }
        let coveredDisplayIDs = Set(activeDisplays.compactMap { display -> UInt32? in
            guard let uuid = display.uuid,
                  isBlackoutHidden(uuid) || preferences.selectedDisplayUUIDs.contains(where: {
                      $0.caseInsensitiveCompare(uuid) == .orderedSame
                  }) else {
                return nil
            }
            return display.id
        })
        return coveredDisplayIDs.count < activeDisplays.count
    }

    private func reconcileProtection(restartWatcher: Bool = false) {
        if disconnectLease != nil || disconnectStatus?.resolved == false {
            service.disable()
            return
        }
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
                guard let arguments = try hiddenMirrorArguments(for: source) else {
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
                arguments: try protectionArguments(),
                restartForDisplayChange: rearm
            )
            if service.hasManagedProcess {
                protectionRearmRequired = false
            }
        } catch let error as ProtectionConfigurationError where error.waitsForDisplays {
            service.waitForDisplays(error.localizedDescription)
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
                      try hiddenMirrorArguments(for: source) != nil else {
                    return .disabled
                }
                return serviceState
            }
            _ = try protectionArguments()
            return serviceState
        } catch let error as ProtectionConfigurationError where error.waitsForDisplays {
            return .waitingForDisplays(error.localizedDescription)
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

    private func validatedSavedInput(_ value: UInt8?) -> (value: UInt8?, warning: String?) {
        guard let value else { return (nil, nil) }
        guard DDCInput.parseValue(String(value)) != nil else {
            return (nil, String(format: "the saved input code 0x%02X isn\u{2019}t valid. Choose the input again in Settings \u{2192} Displays.", value))
        }
        return (value, nil)
    }

    /// Show switches the input back only when Hide switched it.
    private func configuredReturnInput(for status: DisplayHandoffStatus) -> (value: UInt8?, warning: String?) {
        guard let target = status.target,
              let configuration = hidePreferences[target.uuid],
              configuration.awayInput != nil, configuration.returnInput != nil else { return (nil, nil) }
        guard configuration.target.uuid.caseInsensitiveCompare(target.uuid) == .orderedSame,
              configuration.target.id == target.id,
              configuration.target.vendor == target.vendor,
              configuration.target.model == target.model,
              configuration.target.serial == target.serial else {
            return (nil, "the saved input belongs to a different display.")
        }
        return validatedSavedInput(configuration.returnInput)
    }

    private func hideRequest(target: DisplayIdentitySnapshot, source: DisplayIdentitySnapshot,
                             configuration: DisplayHideConfiguration) -> DisplayHideRequest {
        let away = validatedSavedInput(configuration.awayInput)
        return DisplayHideRequest(target: target, source: source, awayInput: away.value, awayInputWarning: away.warning)
    }

    private func finishHideAfterProtectionQuiescence(
        _ request: DisplayHideRequest,
        cleanupSucceeded: Bool,
        cleanupFailure: String?,
        completion: ((DisplayOperationResult) -> Void)?
    ) {
        guard hideOperation == .hiding(request.target.uuid) else { return }
        let notAttempted = DisplayInputOutcome(
            state: request.awayInput == nil ? .notRequested : .notAttempted,
            requestedInput: request.awayInput
        )
        if !cleanupSucceeded {
            let failure = cleanupFailure ?? "Automation cleanup could not be verified."
            protectionQuiescenceFailure = failure
            hideOperation = .idle
            refreshHandoffStatus()
            reconcileProtection()
            finish(.hide, targetUUID: request.target.uuid, succeeded: false,
                   message: "Couldn\u{2019}t hide. PanelCtl couldn\u{2019}t confirm automation stopped, so it didn\u{2019}t change the display: \(failure)",
                   input: notAttempted, inputWarning: request.awayInputWarning, completion: completion)
            return
        }
        protectionQuiescenceFailure = nil
        var returnedInputOutcome: DisplayInputOutcome?
        do {
            displays = displayProvider()
            refreshHandoffStatus()
            guard let configuration = hidePreferences[request.target.uuid],
                  hideReadiness(for: configuration, allowingCurrentOperation: true) == nil,
                  let source = configuration.source,
                  request == hideRequest(target: configuration.target, source: source, configuration: configuration) else {
                throw DisplayHideError.identityChanged("The displays or Hide settings changed before Hide began. Try again.")
            }
            let inputOutcome = try hideDisplay(
                coreIdentity(request.target), coreIdentity(request.source), request.awayInput
            )
            returnedInputOutcome = inputOutcome
            refreshHandoffStatus()
            guard handoffStatus?.state == .hidden else {
                throw DisplayHideError.recoveryBlocksAction(
                    "PanelCtl couldn\u{2019}t confirm the display is hidden. Check its recovery details before trying again."
                )
            }
            hideOperation = .idle
            reconcileProtection()
            finish(.hide, targetUUID: request.target.uuid, succeeded: true, message: "Hidden.",
                   input: inputOutcome, inputWarning: request.awayInputWarning, completion: completion)
        } catch {
            refreshHandoffStatus()
            hideOperation = .idle
            rearmProtectionAfterDisplayRecovery()
            let outcome = returnedInputOutcome ?? (error as? DisplayHandoffOperationFailure)?.inputOutcome ?? notAttempted
            finish(.hide, targetUUID: request.target.uuid, succeeded: false,
                   message: "Couldn\u{2019}t hide. \(error.localizedDescription)",
                   input: outcome, inputWarning: request.awayInputWarning, completion: completion)
        }
    }

    private func finishShowAfterProtectionQuiescence(
        _ request: DisplayShowRequest,
        cleanupSucceeded: Bool,
        cleanupFailure: String?,
        completion: ((DisplayOperationResult) -> Void)?
    ) {
        guard case .showing(let targetUUID) = hideOperation else { return }
        let notAttempted = DisplayInputOutcome(
            state: request.returnInput == nil ? .notRequested : .notAttempted,
            requestedInput: request.returnInput
        )
        func notStarted(_ reason: String) {
            hideOperation = .idle
            reconcileProtection()
            finish(.show, targetUUID: targetUUID, succeeded: false, message: "Couldn\u{2019}t show. \(reason)",
                   input: notAttempted, inputWarning: request.returnInputWarning, completion: completion)
        }
        guard cleanupSucceeded else {
            let failure = cleanupFailure ?? "Automation cleanup could not be verified."
            protectionQuiescenceFailure = failure
            notStarted("PanelCtl couldn\u{2019}t confirm automation stopped, so it didn\u{2019}t change the display: \(failure)")
            return
        }
        protectionQuiescenceFailure = nil
        guard !displayLifecycleTransitioning else {
            notStarted(DisplayHideError.sleeping.localizedDescription)
            return
        }
        refreshHandoffStatus()
        guard handoffStatus?.hasUnresolvedJournal == true,
              handoffStatus?.canShow == true,
              handoffStatus?.journalID == request.status.journalID,
              handoffStatus?.target?.uuid == request.status.target?.uuid,
              handoffStatus?.source?.uuid == request.status.source?.uuid,
              let expectedJournalID = request.status.journalID else {
            notStarted("The displays changed before Show began. Try again.")
            return
        }
        var returnedInputOutcome: DisplayInputOutcome?
        do {
            let inputOutcome = try showDisplay(expectedJournalID, request.returnInput)
            returnedInputOutcome = inputOutcome
            refreshHandoffStatus()
            guard handoffStatus?.hasUnresolvedJournal != true,
                  handoffInspectionFailure == nil else {
                throw DisplayHideError.recoveryBlocksAction(
                    handoffStatus?.reason ?? handoffInspectionFailure ??
                        "PanelCtl couldn\u{2019}t confirm the display is back. Check its recovery details."
                )
            }
            hideOperation = .idle
            rearmProtectionAfterDisplayRecovery()
            finish(.show, targetUUID: targetUUID, succeeded: true, message: "Shown.",
                   input: inputOutcome, inputWarning: request.returnInputWarning, completion: completion)
        } catch {
            refreshHandoffStatus()
            hideOperation = .idle
            reconcileProtection()
            let outcome = returnedInputOutcome ?? (error as? DisplayHandoffOperationFailure)?.inputOutcome ?? notAttempted
            finish(.show, targetUUID: targetUUID, succeeded: false,
                   message: "Couldn\u{2019}t show. \(error.localizedDescription)",
                   input: outcome, inputWarning: request.returnInputWarning, completion: completion)
        }
    }

    private func finish(
        _ action: DisplayOperationResult.Action,
        targetUUID: String,
        succeeded: Bool,
        message: String,
        input: DisplayInputOutcome,
        inputWarning: String?,
        completion: ((DisplayOperationResult) -> Void)?
    ) {
        let line = inputResultLine(input, warning: inputWarning)
        let result = DisplayOperationResult(
            action: action,
            succeeded: succeeded,
            message: message,
            inputMessage: line?.text,
            inputOutcome: input,
            inputNeedsAttention: line?.needsAttention ?? false
        )
        displayResults[targetUUID.lowercased()] = result
        lastHideOrShowFinished = .now
        onStatusChange?()
        completion?(result)
    }

    /// Records a Hide or Show that didn't start. A refusal while another
    /// operation runs never replaces that operation's result.
    private func refuse(
        _ action: DisplayOperationResult.Action,
        targetUUID: String,
        error: Error,
        completion: ((DisplayOperationResult) -> Void)?
    ) {
        let result = DisplayOperationResult(
            action: action,
            succeeded: false,
            message: "Couldn\u{2019}t \(action == .hide ? "hide" : "show"). \(error.localizedDescription)",
            inputMessage: nil,
            inputOutcome: nil,
            inputNeedsAttention: false
        )
        if case .actionInProgress? = error as? DisplayHideError {
            completion?(result)
            return
        }
        displayResults[targetUUID.lowercased()] = result
        onStatusChange?()
        completion?(result)
    }

    private func inputResultLine(
        _ outcome: DisplayInputOutcome,
        warning: String?
    ) -> (text: String, needsAttention: Bool)? {
        let input = outcome.requestedInput.map(MonitorInput.name) ?? "the requested input"
        let detail = outcome.detail.map { " " + Self.sentence($0) } ?? ""
        switch outcome.state {
        case .notRequested:
            return warning.map { ("Didn\u{2019}t switch the monitor input: \($0)", true) }
        case .notAttempted:
            return outcome.requestedInput == nil ? nil : ("Didn\u{2019}t switch the monitor input.", false)
        case .skipped:
            return ("Couldn\u{2019}t switch the monitor input.\(detail) Use the monitor\u{2019}s buttons.", true)
        case .verified:
            return ("Switched the monitor to \(input).", false)
        case .alreadySelected:
            return ("The monitor was already on \(input).", false)
        case .unverified:
            return ("Asked the monitor to switch to \(input) but couldn\u{2019}t confirm it. Check the monitor and use its buttons if needed.", true)
        case .failed:
            return ("Couldn\u{2019}t switch the monitor to \(input).\(detail) Use the monitor\u{2019}s buttons.", true)
        }
    }

    /// Ends backend detail text with exactly one sentence terminator.
    private static func sentence(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = trimmed.last else { return "" }
        return ".!?".contains(last) ? trimmed : trimmed + "."
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
        refreshDisconnectStatus()
        if defaults.object(forKey: Self.snoozedUntilKey) != nil,
           snoozedUntil == nil {
            resumeProtection()
        }
    }

    // Private disconnect is a separate, manual operation, never a Hide style or
    // app-control command. Startup and timer refreshes inspect only; no recovery
    // writer runs without a user action (the independent lease helper is separate).
    var disconnectBlocker: String? {
        if !experimentalFeaturesEnabled { return "Turn on Experimental features in General first. That consent does not authorize disconnect." }
        if disconnectLease != nil || disconnectStatus?.resolved == false { return "Finish the retained disconnect lease or recovery first." }
        if preferences.isEnabled || service.hasManagedProcess || protectionQuiescencePending {
            return "Turn off automation and wait for its helper to stop before disconnecting."
        }
        if !blackoutHiddenDisplays.isEmpty || hideConfigurationFrozen || protectionQuiescenceFailure != nil {
            return "Show hidden displays and finish other display operations or recovery first."
        }
        return nil
    }

    func prepareDisconnect(_ uuid: String) {
        disconnectRequest = nil
        disconnectFailure = nil
        do {
            if let blocker = disconnectBlocker { throw RecoveryError.unsafe(blocker) }
            _ = try disconnectExecutable()
            disconnectRequest = try disconnectController.prepare(targetUUID: uuid)
            disconnectConsentPending = true
        } catch { disconnectFailure = error.localizedDescription }
    }

    func cancelDisconnect() {
        disconnectConsentPending = false
        disconnectRequest = nil
    }

    func confirmDisconnect() {
        disconnectConsentPending = false
        guard let request = disconnectRequest else { return }
        disconnectRequest = nil // Never persist or reuse consent, even on refusal.
        do {
            if let blocker = disconnectBlocker { throw RecoveryError.unsafe(blocker) }
            disconnectLease = try disconnectController.disconnect(request, consent: true, executable: disconnectExecutable())
        } catch { disconnectFailure = error.localizedDescription }
        refreshDisconnectStatus()
        refreshHandoffStatus()
        reconcileProtection()
    }

    func reconnectDisconnect(expectedJournalID: String? = nil) {
        disconnectFailure = nil
        do {
            if let expectedJournalID, expectedJournalID != disconnectStatus?.journalID {
                throw RecoveryError.unsafe("journal changed during confirmation; inspect and confirm again")
            }
            if let lease = disconnectLease {
                // EOF requests guarded recovery; journal polling establishes its
                // result. Do not race a second engine against the live helper.
                disconnectLease = nil
                try lease.reconnect()
            } else if let status = disconnectStatus, status.canReconnect {
                try disconnectController.reconnect(expectedJournalID: status.journalID)
            }
        } catch { disconnectFailure = error.localizedDescription }
        refreshDisconnectStatus()
        refreshHandoffStatus()
    }

    func refreshDisconnectStatus() {
        let previous = disconnectStatus
        do {
            disconnectStatus = try disconnectController.inspect()
            if disconnectStatus?.resolved == true { disconnectLease = nil }
        } catch { disconnectFailure = error.localizedDescription }
        if previous != disconnectStatus {
            refreshHandoffStatus()
            reconcileProtection()
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

private extension DisplayInputOutcome {
    /// An input result that scripts report as partial.
    var isPartial: Bool { [.failed, .skipped, .unverified, .notAttempted].contains(state) }
}
