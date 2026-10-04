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
    @Published private(set) var countdownDate = Date()

    var onStatusChange: (() -> Void)?

    private let defaults: UserDefaults
    private let displayProvider: () -> [DisplayRecord]
    private let now: () -> Date
    private let idleSecondsProvider: () -> TimeInterval?
    private let sleepDisplays: () throws -> Void
    private let isDisplayMirrored: (UInt32) -> Bool
    private let inspectHandoff: () -> DisplayHandoffStatus
    private let hideDisplay: (DisplayHideIdentity, DisplayHideIdentity) throws -> Void
    private let showDisplay: (String) throws -> Void
    private let quiesceProtection: ProtectionQuiesce?
    private let service: ProtectionService
    private var snoozeTimer: Timer?
    private var manualActivityDate: Date?
    private var protectionRearmRequired = false
    private static let preferencesKey = "blackoutPreferences"
    private static let hidePreferencesKey = "displayHidePreferences"
    private static let showMenuBarIconKey = "showMenuBarIcon"
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
        hideDisplay: @escaping (DisplayHideIdentity, DisplayHideIdentity) throws -> Void = { try DisplayHideController().hide(target: $0, source: $1) },
        showDisplay: @escaping (String) throws -> Void = { try DisplayHideController().show(expectedJournalID: $0) },
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
        self.quiesceProtection = quiesceProtection
        self.showMenuBarIcon = defaults.object(forKey: Self.showMenuBarIconKey) as? Bool ?? true
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
        guard !protectionPausedForDisplayRecovery else { return [] }
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

    func protectionSelectionState(for configuration: DisplayHideConfiguration) -> String {
        if preferences.allDisplays { return "Selected by OLED protection" }
        let selected = preferences.selectedDisplayUUIDs.contains {
            $0.caseInsensitiveCompare(configuration.target.uuid) == .orderedSame
        }
        return selected ? "Selected for OLED protection" : "Not selected for OLED protection"
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

    func removeHideConfiguration(targetUUID: String) {
        guard !hideConfigurationFrozen else { return }
        var updated = hidePreferences
        updated.remove(uuid: targetUUID)
        hidePreferences = updated
    }

    func hasHideConfiguration(targetUUID: String) -> Bool {
        hidePreferences[targetUUID] != nil
    }

    func makeHideRequest(targetUUID: String) throws -> DisplayHideRequest {
        guard !hideOperation.isBusy else { throw DisplayHideError.actionInProgress }
        guard !displayLifecycleTransitioning else { throw DisplayHideError.sleeping }
        guard protectionQuiescenceFailure == nil else {
            throw DisplayHideError.protectionCleanup(protectionQuiescenceFailure ?? "Protection cleanup needs attention.")
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
        return DisplayHideRequest(target: configuration.target, source: source)
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

    func makeShowRequest() throws -> DisplayHandoffStatus {
        guard !hideOperation.isBusy else { throw DisplayHideError.actionInProgress }
        guard !displayLifecycleTransitioning else { throw DisplayHideError.sleeping }
        guard !protectionQuiescencePending else {
            throw DisplayHideError.recoveryBlocksAction("PanelCtl is still stopping protection before display recovery. Wait, then Refresh.")
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
        return handoffStatus
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

    func confirmShow(_ request: DisplayHandoffStatus, acknowledged: Bool) {
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
            guard current.journalID == request.journalID,
                  current.target?.uuid == request.target?.uuid,
                  current.source?.uuid == request.source?.uuid else {
                throw DisplayHideError.recoveryBlocksAction("The recovery journal changed while confirmation was open. Refresh and review its captured target/source before Show.")
            }
        } catch {
            presentDisplayError("Show not started", error: error)
            return
        }

        hideOperation = .showing(request.target?.uuid ?? "")
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

    var onRequestHide: ((DisplayHideRequest) -> Void)?
    var onRequestShow: ((DisplayHandoffStatus) -> Void)?
    var onShowCompletion: ((Bool) -> Void)?

    func requestDisplayRecoveryFocus() {
        displayRecoveryFocusRequest &+= 1
    }

    func setDisplayLifecycleTransitioning(_ transitioning: Bool) {
        guard displayLifecycleTransitioning != transitioning else { return }
        displayLifecycleTransitioning = transitioning
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
        if isUnresolved && !wasUnresolved && !hideOperation.isBusy {
            quiesceForExternalRecovery()
        } else if !isUnresolved && wasUnresolved,
                  !protectionQuiescencePending,
                  protectionQuiescenceFailure == nil {
            rearmProtectionAfterDisplayRecovery()
        }
        if previous != handoffStatus || previousFailure != handoffInspectionFailure {
            onStatusChange?()
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
            return "Protection paused for hidden desktop/recovery"
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
        guard !protectionPausedForDisplayRecovery else {
            throw DisplayHideError.recoveryBlocksAction(
                "Blackout Now is paused while a desktop is hidden or display recovery is unresolved. Show or resolve display recovery first."
            )
        }
        let wasSnoozed = cancelSnooze()
        displays = displayProvider()
        let arguments: [String]
        do {
            arguments = try preferences.commandArguments(for: displays)
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
        guard !protectionPausedForDisplayRecovery else { return false }
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
            guard preferences.followUpAction != .untilActivity,
                  let stateBeganAt else { return nil }
            let elapsed = now().timeIntervalSince(stateBeganAt)
            let inputElapsed = idleSecondsProvider() ?? elapsed
            remaining = preferences.followUpSeconds - (
                resetsBlackoutLimitOnInput ? min(elapsed, inputElapsed) : elapsed
            )
        default:
            return nil
        }
        return max(0, Int(ceil(remaining)))
    }

    private var stateBeganAt: Date?

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
            service.disable()
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
        if protectionPausedForDisplayRecovery { return .disabled }
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
                    : (message ?? "Protection cleanup could not be verified.")
                if self.handoffStatus?.hasUnresolvedJournal != true,
                   self.handoffInspectionFailure == nil,
                   self.hideOperation == .idle,
                   self.protectionQuiescenceFailure == nil {
                    self.rearmProtectionAfterDisplayRecovery()
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

    private func finishHideAfterProtectionQuiescence(
        _ request: DisplayHideRequest,
        cleanupSucceeded: Bool,
        cleanupFailure: String?
    ) {
        guard hideOperation == .hiding(request.target.uuid) else { return }
        if !cleanupSucceeded {
            let failure = cleanupFailure ?? "Protection cleanup could not be verified."
            protectionQuiescenceFailure = failure
            hideOperation = .idle
            refreshHandoffStatus()
            reconcileProtection()
            presentDisplayError(
                "Hide not started",
                error: DisplayHideError.protectionCleanup("PanelCtl could not confirm that blackout/dimming cleanup finished: \(failure) No desktop change was attempted; inspect protection status and try again only after it is clear.")
            )
            onStatusChange?()
            return
        }
        protectionQuiescenceFailure = nil
        do {
            displays = displayProvider()
            refreshHandoffStatus()
            guard let configuration = hidePreferences[request.target.uuid],
                  hideReadinessMessage(for: configuration, allowingCurrentOperation: true) == nil,
                  let source = configuration.source,
                  request == DisplayHideRequest(target: configuration.target, source: source) else {
                throw DisplayHideError.identityChanged("The target, source, inventory, or saved configuration changed before Hide began. Review Displays and confirm again.")
            }
            try hideDisplay(coreIdentity(request.target), coreIdentity(request.source))
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
                message: "\(request.target.name ?? request.target.uuid) is hidden by mirroring \(request.source.name ?? request.source.uuid). The Mac signal remains on; modes/HDR may change. While recovery is unresolved, PanelCtl protection stays paused.",
                opensLoginItemSettings: false
            )
        } catch {
            refreshHandoffStatus()
            hideOperation = .idle
            rearmProtectionAfterDisplayRecovery()
            presentDisplayError("Could not hide the desktop", error: error)
        }
        onStatusChange?()
    }

    private func finishShowAfterProtectionQuiescence(
        _ request: DisplayHandoffStatus,
        cleanupSucceeded: Bool,
        cleanupFailure: String?
    ) {
        guard case .showing = hideOperation else { return }
        if cleanupSucceeded {
            protectionQuiescenceFailure = nil
        } else {
            protectionQuiescenceFailure = cleanupFailure ?? "Protection cleanup could not be verified."
        }
        guard !displayLifecycleTransitioning else {
            hideOperation = .idle
            reconcileProtection()
            onShowCompletion?(false)
            presentDisplayError("Show paused", error: DisplayHideError.sleeping)
            onStatusChange?()
            return
        }
        refreshHandoffStatus()
        guard handoffStatus?.hasUnresolvedJournal == true,
              handoffStatus?.canShow == true,
              handoffStatus?.journalID == request.journalID,
              handoffStatus?.target?.uuid == request.target?.uuid,
              handoffStatus?.source?.uuid == request.source?.uuid,
              let expectedJournalID = request.journalID else {
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
        do {
            try showDisplay(expectedJournalID)
            refreshHandoffStatus()
            guard handoffStatus?.hasUnresolvedJournal != true,
                  handoffInspectionFailure == nil else {
                throw DisplayHideError.recoveryBlocksAction(
                    handoffStatus?.reason ?? handoffInspectionFailure ?? "Show returned, but the journal could not be verified resolved. Keep the journal and inspect the recovery details."
                )
            }
            hideOperation = .idle
            rearmProtectionAfterDisplayRecovery()
            notice = AppNotice(
                title: "Desktop restored",
                message: protectionQuiescenceFailure.map {
                    "The journaled public layout and modes were restored and verified, but protection cleanup still needs attention: \($0) PanelCtl protection remains paused. HDR, color profiles, rotation, windows, and Spaces are not restored. Select the Mac input manually if needed."
                } ?? "The journaled public display layout and modes were restored and verified. HDR, color profiles, rotation, windows, and Spaces are not restored. Select the Mac input manually if needed.",
                opensLoginItemSettings: false
            )
            onShowCompletion?(true)
        } catch {
            refreshHandoffStatus()
            hideOperation = .idle
            reconcileProtection()
            onShowCompletion?(false)
            presentDisplayError("Could not show the journaled desktop", error: error)
        }
        onStatusChange?()
    }

    private func presentDisplayError(_ title: String, error: Error) {
        notice = AppNotice(
            title: title,
            message: error.localizedDescription,
            opensLoginItemSettings: false
        )
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
