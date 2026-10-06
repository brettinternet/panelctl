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

private struct SleepHideResumeIntent {
    let journalID: String
    let baselineIdentity: String
    let journalRemovals: [DisplayHandoffRemoval]
    let removals: [DisplayHandoffRemoval]
}

@MainActor
final class AppModel: ObservableObject {
    static let githubURL = URL(string: "https://github.com/brettinternet/panelctl")!
    static let scriptingDocsURL = URL(string: "https://github.com/brettinternet/panelctl/blob/main/docs/usage.md#scripted-hide-and-show")!
    static let experimentalDocsURL = URL(string: "https://github.com/brettinternet/panelctl/blob/main/docs/display-hide-ux.md#experimental-features")!

    @Published var automationPreferences: AutomationPreferences {
        didSet {
            guard automationPreferences != oldValue else { return }
            if !ruleEnableRefusals.isEmpty { ruleEnableRefusals.removeAll() }
            saveAutomationPreferences()
            reconcileProtection()
            onStatusChange?()
        }
    }
    /// Compatibility facade for the pre-rule Settings form and its tests.
    /// It edits the first (migrated) rule while keeping global controls global.
    var preferences: ProtectionPreferences {
        get {
            var value = automationPreferences.rules.first?.settings ?? ProtectionPreferences()
            value.isEnabled = automationPreferences.isEnabled
            value.keepDisplaysAwake = automationPreferences.keepDisplaysAwake
            return value
        }
        set {
            var ruleSet = automationPreferences
            ruleSet.isEnabled = newValue.isEnabled
            ruleSet.keepDisplaysAwake = newValue.keepDisplaysAwake
            if !ruleSet.rules.isEmpty {
                var settings = newValue
                settings.isEnabled = false
                settings.keepDisplaysAwake = ruleSet.keepDisplaysAwake
                ruleSet.rules[0].settings = settings
            }
            automationPreferences = ruleSet
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
    @Published private(set) var displayActions: DisplayActionSet {
        didSet {
            guard displayActions != oldValue else { return }
            saveDisplayActions()
            onStatusChange?()
        }
    }
    @Published private(set) var displayActionStorageFailure: String?
    @Published private(set) var displayActionResults: [UUID: AppControlResponse] = [:]
    @Published private(set) var runningDisplayActionIDs: Set<UUID> = []
    @Published private(set) var runningDisplayAction: AppControlRunningAction?
    private var runningActionInterrupted = false
    private var preflightingDisplayAction = false
    private var lastDisplayActionFinished: ContinuousClock.Instant?
    private var deferredActionHiddenDisplayReconciliation = false
    private var deferredActionRecoveryReconciliation = false
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
    private var observedRuleStates: [UUID: ProtectionRuntimeState] = [:]
    private var ruleStateBeganAt: [UUID: Date] = [:]
    @Published private(set) var ruleEnableRefusals: [UUID: String] = [:]
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
    @Published private(set) var disconnectPreparationPending = false
    @Published private(set) var disconnectRequest: DisplayDisconnectRequest?
    @Published private(set) var disconnectStatus: DisplayDisconnectStatus?
    @Published private(set) var disconnectInspectionFailure: String?
    @Published private(set) var disconnectFailure: String?
    private var disconnectLease: DisplayDisconnectLease?
    private var disconnectAutomationPaused = false
    private var disconnectPauseCleanupPending = false
    private var disconnectPauseCleanupAttempted = false
    private var disconnectPreparationCancelled = false
    private var disconnectRecoveryBlocked = false
    var disconnectJournalPath: String { disconnectController.journalPath }
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
    private let sleepResumeHideDisplay: (DisplayHideIdentity, DisplayHideIdentity, DisplayHideWakeExpectation) throws -> DisplayInputOutcome
    private let showDisplay: (String, UInt8?) throws -> DisplayInputOutcome
    private let checkDDCInput: (DisplayHideIdentity) throws -> DDCInputReading
    private let coverDisplays: @MainActor (Set<UInt32>) -> Set<UInt32>
    private let quiesceProtection: ProtectionQuiesce?
    private let protectionCoordinator: ProtectionCoordinator
    private var snoozeTimer: Timer?
    private var manualActivityDate: Date?
    private var waitingForDisplayRuleIDs = Set<UUID>()
    private var protectionRearmRequired = false
    private var sleepHideResumeIntent: SleepHideResumeIntent?
    private var sleepLifecycleActive = false
    private var screensAwakeAfterSleep = false
    private var sleepWakeSettlement: Task<Void, Never>?
    private let displayWakeSettleDelay: TimeInterval
    private static let preferencesKey = "blackoutPreferences"
    private static let automationPreferencesKey = "automationRules"
    private static let hidePreferencesKey = "displayHidePreferences"
    /// Versioned separately so older binaries keep writing only the legacy key.
    static let displayActionsKey = "displayActions.v2"
    static let legacyDisplayActionsKey = "displayActions"
    private static let showMenuBarIconKey = "showMenuBarIcon"
    private static let experimentalFeaturesKey = "experimentalFeaturesEnabled"
    private static let snoozedUntilKey = "snoozedUntil"
    private static let cleanupFailureKey = "automationCleanupFailure"
    private static let disconnectRecoveryBlockedKey = "disconnectRecoveryBlocked"
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
        sleepResumeHideDisplay: @escaping (DisplayHideIdentity, DisplayHideIdentity, DisplayHideWakeExpectation) throws -> DisplayInputOutcome = { target, source, expectation in
            try DisplayHideController().hide(target: target, source: source, awayInput: nil,
                                             wakeExpectation: expectation)
        },
        showDisplay: @escaping (String, UInt8?) throws -> DisplayInputOutcome = { key, input in
            let pieces = key.split(separator: "|", maxSplits: 1).map(String.init)
            if pieces.count == 2 {
                return try DisplayHideController().show(expectedJournalID: pieces[0], targetUUID: pieces[1], returnInput: input)
            }
            return try DisplayHideController().show(expectedJournalID: key, returnInput: input)
        },
        checkDDCInput: @escaping (DisplayHideIdentity) throws -> DDCInputReading = {
            try DisplayHideController().checkInputAvailability(target: $0)
        },
        coverDisplays: (@MainActor (Set<UInt32>) -> Set<UInt32>)? = nil,
        quiesceProtection: ProtectionQuiesce? = nil,
        protectionService: ProtectionService? = nil,
        protectionCoordinator injectedProtectionCoordinator: ProtectionCoordinator? = nil,
        disconnectController: DisplayDisconnectController = DisplayDisconnectController(),
        disconnectExecutable: @escaping @MainActor () throws -> URL = ProtectionService.helperExecutableURL,
        displayWakeSettleDelay: TimeInterval = 1
    ) {
        self.defaults = defaults
        self.disconnectController = disconnectController
        self.disconnectExecutable = disconnectExecutable
        self.disconnectRecoveryBlocked = defaults.bool(forKey: Self.disconnectRecoveryBlockedKey)
        if self.disconnectRecoveryBlocked {
            self.disconnectAutomationPaused = true
            self.disconnectInspectionFailure = "A previous disconnect recovery is still unresolved. Its journal must be readable and verified before automation can resume."
        }
        self.displayWakeSettleDelay = displayWakeSettleDelay.isFinite ? min(max(0, displayWakeSettleDelay), 10) : 1
        self.displayProvider = displayProvider
        self.now = now
        self.idleSecondsProvider = idleSecondsProvider
        self.sleepDisplays = sleepDisplays
        self.isDisplayMirrored = isDisplayMirrored
        self.inspectHandoff = inspectHandoff
        self.hideDisplay = hideDisplay
        self.sleepResumeHideDisplay = sleepResumeHideDisplay
        self.showDisplay = showDisplay
        self.checkDDCInput = checkDDCInput
        self.coverDisplays = coverDisplays ?? HiddenDisplayOverlays().cover
        self.quiesceProtection = quiesceProtection
        self.showMenuBarIcon = defaults.object(forKey: Self.showMenuBarIconKey) as? Bool ?? true
        self.experimentalFeaturesEnabled = defaults.bool(forKey: Self.experimentalFeaturesKey)
        let loadedHidePreferences = defaults.data(forKey: Self.hidePreferencesKey)
            .flatMap { try? JSONDecoder().decode(DisplayHidePreferences.self, from: $0) }
        self.hidePreferences = loadedHidePreferences ?? DisplayHidePreferences()
        let upgradedActions = defaults.data(forKey: Self.displayActionsKey)
        let legacyActions = defaults.data(forKey: Self.legacyDisplayActionsKey)
        let actionData = upgradedActions ?? legacyActions
        if let actionData {
            do {
                self.displayActions = try JSONDecoder().decode(DisplayActionSet.self, from: actionData)
                self.displayActionStorageFailure = nil
            } catch {
                self.displayActions = DisplayActionSet()
                self.displayActionStorageFailure = "Saved Actions could not be read and were preserved. Do not edit them with this build. (\(error.localizedDescription))"
            }
        } else {
            self.displayActions = DisplayActionSet()
            self.displayActionStorageFailure = nil
        }
        let displays = displayProvider()
        let loadedRuleSet: AutomationPreferences
        if let stored = defaults.data(forKey: Self.automationPreferencesKey) {
            loadedRuleSet = (try? JSONDecoder().decode(AutomationPreferences.self, from: stored))
                ?? AutomationPreferences.migrate(legacyData: nil, displays: displays)
        } else {
            loadedRuleSet = AutomationPreferences.migrate(
                legacyData: defaults.data(forKey: Self.preferencesKey),
                displays: displays
            )
        }
        var ruleSet = loadedRuleSet
        for index in ruleSet.rules.indices {
            ruleSet.rules[index].settings.selectedDisplayUUIDs = Set(
                ruleSet.rules[index].settings.selectedDisplayUUIDs.map { $0.uppercased() }
            )
            ruleSet.rules[index].settings.isEnabled = false
            ruleSet.rules[index].settings.keepDisplaysAwake = ruleSet.keepDisplaysAwake
        }

        self.automationPreferences = ruleSet
        self.displays = displays
        launchAtLoginEnabled = LaunchAtLogin.isEnabled
        protectionCoordinator = injectedProtectionCoordinator ?? ProtectionCoordinator(
            initialCleanupFailure: defaults.string(forKey: Self.cleanupFailureKey),
            initialService: protectionService
        )
        protectionQuiescenceFailure = defaults.string(forKey: Self.cleanupFailureKey) ??
            protectionCoordinator.unresolvedCleanupFailure
        protectionCoordinator.onStateChange = { [weak self] in
            guard let self else { return }
            if let cleanupFailure = self.protectionCoordinator.unresolvedCleanupFailure {
                let newlyFailed = self.protectionQuiescenceFailure == nil
                self.protectionQuiescenceFailure = cleanupFailure
                // One rule's unresolved cleanup blocks every rule: stop siblings.
                if newlyFailed, self.protectionCoordinator.hasManagedProcess {
                    DispatchQueue.main.async { [weak self] in self?.reconcileProtection() }
                }
            }
            self.blackedOutDisplayIDs = self.protectionCoordinator.blackedOutDisplayIDs
            self.runtimeState = self.aggregateRuntimeState
            let waitingRuleIDs = Set(self.automationPreferences.rules.compactMap { rule -> UUID? in
                if case .waitingForDisplays = self.protectionCoordinator.runtimeState(
                    for: rule.id,
                    automationEnabled: self.automationPreferences.isEnabled,
                    snoozedUntil: self.snoozedUntil
                ) { return rule.id }
                return nil
            })
            if waitingRuleIDs != self.waitingForDisplayRuleIDs {
                self.waitingForDisplayRuleIDs = waitingRuleIDs
                if !waitingRuleIDs.isEmpty {
                    DispatchQueue.main.async { [weak self] in self?.refreshDisplays() }
                }
            }
        }
        protectionCoordinator.onMembershipChange = { [weak self] ids in
            self?.blackedOutDisplayIDs = ids
        }
        saveAutomationPreferences()
        defaults.set(showMenuBarIcon, forKey: Self.showMenuBarIconKey)
        refreshHandoffStatus()
        refreshDisconnectStatus()
        let storedSnooze = defaults.object(forKey: Self.snoozedUntilKey) as? Date
        if let storedSnooze, storedSnooze > now(), ruleSet.isEnabled {
            runtimeState = .snoozed(storedSnooze)
        } else if !disconnectAutomationPaused {
            defaults.removeObject(forKey: Self.snoozedUntilKey)
        }
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
        let removals = handoffStatus?.removals.filter(\.isUnresolved) ?? []
        let recoveredTargets = removals.map(\.target) + (removals.isEmpty ? [handoffStatus?.target].compactMap { $0 } : [])
        for target in recoveredTargets where !seen.contains(target.uuid.lowercased()) {
            let targetIdentity = DisplayIdentitySnapshot(
                uuid: target.uuid, id: target.id, name: target.name,
                vendor: target.vendor, model: target.model, serial: target.serial
            )
            let source = removals.first(where: { $0.target.uuid.caseInsensitiveCompare(target.uuid) == .orderedSame })?.source
                ?? (removals.isEmpty ? handoffStatus?.source : nil)
            let sourceIdentity = source.map {
                DisplayIdentitySnapshot(uuid: $0.uuid, id: $0.id, name: $0.name,
                                        vendor: $0.vendor, model: $0.model, serial: $0.serial)
            }
            result.append(hidePreferences[target.uuid] ?? DisplayHideConfiguration(
                target: targetIdentity, source: sourceIdentity
            ))
            seen.insert(target.uuid.lowercased())
        }
        return result
    }

    var protectionPausedForDisplayRecovery: Bool {
        handoffStatus?.hasUnresolvedJournal == true || handoffInspectionFailure != nil ||
            protectionQuiescencePending || protectionQuiescenceFailure != nil || hideOperation.isBusy
    }

    /// Exact source identities in the verified session. Sleep does not
    /// invalidate them for cover reconciliation.
    private var journalVerifiedHiddenMirrorSources: [DisplayRecord] {
        guard handoffInspectionFailure == nil,
              let status = handoffStatus, status.state == .hidden,
              status.canShow, status.mirrorTopologyVerified, status.journalID != nil else { return [] }
        let sources = status.removals.filter(\.isUnresolved).map(\.source)
        let requested = sources.isEmpty ? status.source.map { [$0] } ?? [] : sources
        var seen = Set<String>()
        var result: [DisplayRecord] = []
        for source in requested where seen.insert(source.uuid.lowercased()).inserted {
            let matches = activeDisplays.filter { $0.uuid?.caseInsensitiveCompare(source.uuid) == .orderedSame }
            guard matches.count == 1, let display = matches.first,
                  display.id == source.id, display.vendor == source.vendor,
                  display.model == source.model, display.serial == source.serial,
                  display.online, display.active else { return [] }
            result.append(display)
        }
        return result
    }

    private var journalVerifiedHiddenMirrorSource: DisplayRecord? {
        journalVerifiedHiddenMirrorSources.first
    }

    var verifiedHiddenMirrorSources: [DisplayRecord] {
        guard !protectionQuiescencePending, protectionQuiescenceFailure == nil,
              !hideOperation.isBusy, !displayLifecycleTransitioning else { return [] }
        return journalVerifiedHiddenMirrorSources.filter { !$0.asleep }
    }

    var verifiedHiddenMirrorSource: DisplayRecord? { verifiedHiddenMirrorSources.first }

    var selectedHiddenMirrorSources: [DisplayRecord] {
        let sources = verifiedHiddenMirrorSources
        guard !sources.isEmpty, sources.count == journalVerifiedHiddenMirrorSources.count else { return [] }
        return sources.filter { source in
            guard let uuid = source.uuid, !isBlackoutHidden(uuid) else { return false }
            return automationPreferences.rules.contains { $0.isEnabled && ruleTargets($0, uuid: uuid) }
        }
    }

    var selectedHiddenMirrorSource: DisplayRecord? { selectedHiddenMirrorSources.first }

    var hiddenMirrorOverlayPolicyEligible: Bool {
        protectionPausedForDisplayRecovery && automationPreferences.isEnabled &&
            snoozedUntil == nil && !hiddenOverlayRuleIDs.isEmpty
    }

    private var hiddenOverlayRuleIDs: Set<UUID> {
        guard automationPreferences.isEnabled, snoozedUntil == nil,
              protectionQuiescenceFailure == nil, !protectionQuiescencePending,
              !hideOperation.isBusy, !displayLifecycleTransitioning else { return [] }
        let sources = verifiedHiddenMirrorSources
        guard !sources.isEmpty,
              sources.count == journalVerifiedHiddenMirrorSources.count else { return [] }
        var result = Set<UUID>()
        for rule in automationPreferences.rules where rule.isEnabled && !hasEnabledConflict(rule) {
            let sources = verifiedHiddenMirrorSources.filter { source in
                guard let uuid = source.uuid else { return false }
                return ruleTargets(rule, uuid: uuid) && !isBlackoutHidden(uuid)
            }
            guard (try? hiddenMirrorArguments(
                      for: sources,
                      settings: rule.settings,
                      otherRuleDisplays: hiddenMirrorSiblingDisplays(for: rule)
                  )) != nil else { continue }
            result.insert(rule.id)
        }
        return result
    }

    private func hasEnabledConflict(_ rule: ProtectionRule) -> Bool {
        guard rule.isEnabled else { return false }
        return automationPreferences.rules.contains { other in
            guard other.id != rule.id, other.isEnabled else { return false }
            if rule.settings.allDisplays || other.settings.allDisplays { return true }
            return rule.settings.selectedDisplayUUIDs.contains { uuid in
                other.settings.selectedDisplayUUIDs.contains {
                    $0.caseInsensitiveCompare(uuid) == .orderedSame
                }
            }
        }
    }

    var automationBlockingDisplayIDs: Set<UInt32> {
        automationPreferences.rules.reduce(into: Set<UInt32>()) { result, rule in
            guard rule.isEnabled,
                  rule.settings.mode == .blocking || hiddenOverlayRuleIDs.contains(rule.id) else { return }
            result.formUnion(protectionCoordinator.blackedOutDisplayIDs(forRule: rule.id))
        }
    }

    func effectiveBlackoutMode(for rule: ProtectionRule) -> BlackoutMode {
        hiddenOverlayRuleIDs.contains(rule.id) ? .blocking : rule.settings.mode
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
        if hiddenMirrorOverlayPolicyEligible {
            let targets = automationPreferences.rules.filter { hiddenOverlayRuleIDs.contains($0.id) }
                .flatMap { remainingOverlayDisplays(for: $0.settings) }
            let names = Dictionary(grouping: targets, by: \.id).values.compactMap(\.first)
                .sorted { $0.id < $1.id }.map { $0.name ?? "Display \($0.id)" }.joined(separator: ", ")
            switch runtimeState {
            case .blackedOut:
                return "Desktop hidden · \(names) blacked out by automation"
            case .starting:
                return "Desktop hidden · automation starting on \(names)"
            case .waiting:
                return "Desktop hidden · automation watching \(names)"
            case .waitingForInput:
                return "Desktop hidden · automation waiting for fresh activity on \(names)"
            case .waitingForPlayback:
                return "Desktop hidden · automation paused for media or camera activity on \(names)"
            case .sleeping:
                return "Desktop hidden · automation paused while displays sleep"
            case .stopping:
                return "Desktop hidden · automation is stopping on \(names)"
            case .disconnectPaused:
                return "Desktop hidden · automation is paused for Full disconnect"
            case .waitingForDisplays(let message):
                return "Desktop hidden · automation waiting for displays: \(message)"
            case .failed(let message):
                return "Desktop hidden · automation failed on \(names): \(message)"
            case .disabled:
                return "Desktop hidden · automation is off on \(names)"
            case .snoozed:
                return "Automation paused while desktop is hidden"
            }
        }
        if let source = verifiedHiddenMirrorSource {
            let name = source.name ?? "Display \(source.id)"
            if isBlackoutHidden(source.uuid) {
                return "Automation suspended while hidden · \(name) is blacked out by Hide"
            }
            if preferences.isEnabled && snoozedUntil == nil {
                return "Automation suspended while hidden · \(name) is not in the idle display list"
            }
            if snoozedUntil != nil { return "Automation paused while desktop is hidden" }
            return "Automation off while desktop is hidden"
        }
        return "Automation suspended until display recovery finishes"
    }

    var hideConfigurationFrozen: Bool {
        disconnectAutomationPaused || disconnectInspectionFailure != nil ||
            disconnectLease != nil || disconnectStatus?.resolved == false ||
            handoffStatus?.hasUnresolvedJournal == true || handoffInspectionFailure != nil ||
            hideOperation.isBusy || displayLifecycleTransitioning
    }

    func hideConfigurationFrozen(for targetUUID: String) -> Bool {
        disconnectAutomationPaused || disconnectInspectionFailure != nil ||
            disconnectLease != nil || disconnectStatus?.resolved == false ||
            displayLifecycleTransitioning ||
            (hideOperation.targetUUID?.caseInsensitiveCompare(targetUUID) == .orderedSame) ||
            isJournalTarget(targetUUID)
    }

    func isJournalTarget(_ uuid: String?) -> Bool {
        guard let uuid, let status = handoffStatus, status.hasUnresolvedJournal else { return false }
        return status.removal(for: uuid) != nil ||
            status.target?.uuid.caseInsensitiveCompare(uuid) == .orderedSame
    }

    var unavailableSelectedDisplayUUIDs: [String] {
        unavailableSelectedDisplayUUIDs(for: preferences)
    }

    func unavailableSelectedDisplayUUIDs(for settings: ProtectionPreferences) -> [String] {
        guard !settings.allDisplays else { return [] }
        let available = Set(activeDisplays.compactMap(\.uuid).map { $0.uppercased() })
        return settings.selectedDisplayUUIDs
            .map { $0.uppercased() }
            .filter { !available.contains($0) }
            .sorted()
    }

    var validationMessage: String? {
        for rule in automationPreferences.rules where rule.isEnabled {
            let result = ProtectionRuleValidator.validate(
                rule, in: automationPreferences, displays: displays,
                hiddenUUIDs: Set(blackoutHiddenDisplays.keys)
            )
            if let reason = result.blockingReason ?? result.waitingReason { return reason }
        }
        return nil
    }

    func makeNewProtectionRule() -> ProtectionRule {
        let existingNames = Set(automationPreferences.rules.map { $0.name.lowercased() })
        var name = "New Rule"
        var suffix = 2
        while existingNames.contains(name.lowercased()) {
            name = "New Rule \(suffix)"
            suffix += 1
        }
        var settings = ProtectionPreferences()
        settings.selectedDisplayUUIDs = []
        settings.didChooseDisplays = true
        settings.followUpAction = .untilActivity
        settings.keepDisplaysAwake = automationPreferences.keepDisplaysAwake
        return ProtectionRule(name: name, isEnabled: true, settings: settings)
    }

    func makeNewDisplayAction(selectedDisplayID: String? = nil) -> DisplayAction {
        let existingNames = Set(displayActions.actions.map {
            $0.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        })
        var name = "New Action"
        var suffix = 2
        while existingNames.contains(name.lowercased()) {
            name = "New Action \(suffix)"
            suffix += 1
        }
        var target: DisplayIdentitySnapshot?
        if let selectedDisplayID,
           let display = activeDisplays.first(where: { $0.uuid?.caseInsensitiveCompare(selectedDisplayID) == .orderedSame }),
           let uuid = display.uuid, UUID(uuidString: uuid) != nil {
            target = DisplayIdentitySnapshot(display)
        }
        return DisplayAction(name: name, target: target)
    }

    func makeNewDisplayActionStep(excluding action: DisplayAction? = nil) -> DisplayActionStep {
        let used = Set((action?.steps.compactMap(\.target?.uuid) ?? []).map { $0.lowercased() })
        let display = activeDisplays.first { record in
            guard let uuid = record.uuid, UUID(uuidString: uuid) != nil else { return false }
            return !used.contains(uuid.lowercased())
        }
        return DisplayActionStep(target: display.map(DisplayIdentitySnapshot.init))
    }

    func displayActionValidation(for draft: DisplayAction, replacing existingID: UUID? = nil) -> String? {
        displayActionValidationError(for: draft, replacing: existingID)?.localizedDescription
    }

    private func displayActionValidationError(
        for draft: DisplayAction, replacing existingID: UUID?
    ) -> DisplayActionValidationError? {
        if let displayActionStorageFailure { return .storedActionsUnavailable(displayActionStorageFailure) }
        let name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return .invalidName }
        guard !displayActions.actions.contains(where: { $0.id != existingID && $0.id != draft.id &&
            $0.name.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare(name) == .orderedSame
        }) else {
            return .duplicateName(name)
        }
        if let existingID {
            guard draft.id == existingID, displayActions.actions.contains(where: { $0.id == existingID }) else {
                return .duplicateIdentity
            }
            if runningDisplayAction?.id == existingID {
                return .actionInProgress(runningDisplayAction?.name ?? draft.name)
            }
        } else if displayActions.actions.contains(where: { $0.id == draft.id }) {
            return .duplicateIdentity
        }
        guard (1...8).contains(draft.steps.count) else { return .invalidStepCount }
        let previous = existingID.flatMap { id in displayActions.actions.first(where: { $0.id == id }) }
        var seen = Set<String>()
        for (offset, step) in draft.steps.enumerated() {
            let number = offset + 1
            guard let target = step.target else { return .missingTarget(number) }
            guard UUID(uuidString: target.uuid) != nil else { return .invalidTarget(number) }
            guard seen.insert(target.uuid.lowercased()).inserted else {
                return .duplicateDisplay(DisplayActionPresentation.displayName(for: target, displays: displays))
            }
            if step.effect == .removeFromDesktop {
                let previousStep = previous?.steps.first(where: {
                    $0.effect == .removeFromDesktop &&
                        $0.target?.uuid.caseInsensitiveCompare(target.uuid) == .orderedSame
                })
                let unchangedReview = previousStep?.reviewedRemoval == step.reviewedRemoval
                if !experimentalFeaturesEnabled, !unchangedReview {
                    return .experimentalFeaturesRequired(number)
                }
                if experimentalFeaturesEnabled,
                   let reason = displayActionRemovalSetupReason(for: target.uuid) {
                    return .removalSetupUnavailable(number, reason)
                }
            }
        }
        return staticDisplayActionConflict(in: draft)
    }

    private func staticDisplayActionConflict(in action: DisplayAction) -> DisplayActionValidationError? {
        var hidden = Set<String>()
        var removalSources: [String: String] = [:]
        for (offset, step) in action.steps.enumerated() {
            guard let target = step.target else { continue }
            let targetKey = target.uuid.lowercased()
            if step.effect == .removeFromDesktop {
                let setup = experimentalFeaturesEnabled && displayActionRemovalSetupReason(for: target.uuid) == nil
                    ? currentReviewedRemovalSetup(for: target.uuid)
                    : step.reviewedRemoval
                guard let source = setup?.sourceUUID else {
                    return .removalSetupUnavailable(offset + 1, "Choose a mirror source in Displays first.")
                }
                let sourceKey = source.lowercased()
                if hidden.contains(sourceKey) {
                    let sourceName = displays.first(where: { $0.uuid?.lowercased() == sourceKey })?.settingsName ?? source
                    return .staticConflict(offset + 1, "its mirror source \(sourceName) is hidden by an earlier step.")
                }
                if removalSources.values.contains(targetKey) {
                    return .staticConflict(offset + 1, "this display is a mirror source for an earlier Remove step.")
                }
                removalSources[targetKey] = sourceKey
            }
            switch step.effect {
            case .blackOut, .removeFromDesktop:
                hidden.insert(targetKey)
            case .show:
                hidden.remove(targetKey)
                removalSources.removeValue(forKey: targetKey)
            }
        }
        return nil
    }

    func saveDisplayAction(_ draft: DisplayAction, replacing existingID: UUID? = nil) throws {
        var candidate = draft
        candidate.name = candidate.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if let error = displayActionValidationError(for: candidate, replacing: existingID) { throw error }
        // Validation guarantees a usable current setup when Experimental is on;
        // with it off, only an unchanged accepted setup reaches this point and is kept.
        if experimentalFeaturesEnabled {
            for index in candidate.steps.indices where candidate.steps[index].effect == .removeFromDesktop {
                guard let target = candidate.steps[index].target else { continue }
                candidate.steps[index].reviewedRemoval = currentReviewedRemovalSetup(for: target.uuid)
            }
        }
        var updated = displayActions
        if let existingID {
            guard let index = updated.actions.firstIndex(where: { $0.id == existingID }) else {
                throw DisplayActionValidationError.duplicateIdentity
            }
            updated.actions[index] = candidate
        } else {
            updated.actions.append(candidate)
        }
        displayActions = updated
    }

    func deleteDisplayAction(id: UUID) {
        guard runningDisplayAction?.id != id, displayActionStorageFailure == nil else { return }
        var updated = displayActions
        guard let index = updated.actions.firstIndex(where: { $0.id == id }) else { return }
        updated.actions.remove(at: index)
        displayActions = updated
    }

    func currentReviewedRemovalSetup(for targetUUID: String) -> ReviewedRemovalSetup {
        let configuration = hidePreferences[targetUUID]
        return ReviewedRemovalSetup(
            removeEnabled: configuration?.enabled == true,
            sourceUUID: configuration?.source?.uuid,
            awayInput: configuration?.awayInput
        )
    }

    private func manualActionValidationFailure(_ action: DisplayAction, stepIndex: Int? = nil) -> String? {
        guard let saved = displayActions.actions.first(where: { $0.id == action.id }),
              saved.steps == action.steps else {
            return "This action changed before it could run. Review it in Settings → Automations, then try again."
        }
        let indices = stepIndex.map { [$0] } ?? Array(action.steps.indices)
        for offset in indices {
            guard action.steps.indices.contains(offset) else { return "This action changed before it could run." }
            let step = action.steps[offset]
            guard let target = step.target, matchingDisplay(target) != nil else {
                return "Step \(offset + 1): This display is disconnected or changed. Reconnect that exact display."
            }
            if step.effect == .removeFromDesktop {
                guard experimentalFeaturesEnabled else {
                    return "Step \(offset + 1): Turn on Experimental features in General to remove a display from the desktop."
                }
                guard step.reviewedRemoval != nil,
                      displayActionReviewChange(for: action, stepIndex: offset) == nil else {
                    return "Step \(offset + 1): Displays setup changed since review. Save this action to accept the change."
                }
            }
            if step.effect != .show, let problem = displayRecoveryProblem {
                return "Step \(offset + 1): Display recovery needs attention. Review it in Displays before hiding another display. \(problem)"
            }
        }
        return nil
    }

    func displayActionReviewChange(for action: DisplayAction, stepIndex: Int = 0) -> DisplayActionReviewChange? {
        guard action.steps.indices.contains(stepIndex) else { return nil }
        let step = action.steps[stepIndex]
        guard step.effect == .removeFromDesktop,
              let reviewed = step.reviewedRemoval,
              let target = step.target else { return nil }
        return DisplayActionPresentation.setupChange(
            from: reviewed,
            to: currentReviewedRemovalSetup(for: target.uuid),
            displays: displays
        )
    }

    func displayActionRemovalSetupReason(for targetUUID: String) -> String? {
        guard experimentalFeaturesEnabled else {
            return "Turn on Experimental features in General to choose Remove from desktop."
        }
        guard let configuration = hidePreferences[targetUUID], configuration.enabled else {
            return "Turn on Remove from desktop for this display in Settings → Displays first."
        }
        guard configuration.source != nil else {
            return "Choose a mirror source for this display in Settings → Displays first."
        }
        return nil
    }

    func displayActionRunBlocker(for action: DisplayAction) -> String? {
        if let displayActionStorageFailure { return displayActionStorageFailure }
        guard (1...8).contains(action.steps.count) else { return DisplayActionValidationError.invalidStepCount.localizedDescription }
        var hiddenBlackouts = Set(blackoutHiddenDisplays.keys)
        let unresolvedRemovals = unresolvedHandoffRemovals
        var hiddenRemovals = Set(unresolvedRemovals.map { $0.target.uuid.lowercased() })
        var sources = Dictionary(uniqueKeysWithValues: unresolvedRemovals.map {
            ($0.target.uuid.lowercased(), $0.source.uuid.lowercased())
        })
        for (index, step) in action.steps.enumerated() {
            guard let blocker = displayActionStepRunBlocker(
                action: action, step: step, index: index,
                projectedBlackouts: hiddenBlackouts,
                projectedRemovals: hiddenRemovals,
                projectedSources: sources
            ) else {
                guard let key = step.target?.uuid.lowercased() else { return "Step \(index + 1): Choose a display." }
                switch step.effect {
                case .blackOut: hiddenBlackouts.insert(key)
                case .removeFromDesktop:
                    hiddenRemovals.insert(key)
                    if let source = step.reviewedRemoval?.sourceUUID { sources[key] = source.lowercased() }
                case .show:
                    hiddenBlackouts.remove(key)
                    hiddenRemovals.remove(key)
                    sources.removeValue(forKey: key)
                }
                continue
            }
            return blocker
        }
        return nil
    }

    private func displayActionStepRunBlocker(
        action: DisplayAction,
        step: DisplayActionStep,
        index: Int,
        projectedBlackouts: Set<String>? = nil,
        projectedRemovals: Set<String>? = nil,
        projectedSources: [String: String]? = nil,
        actionLeaseID: UUID? = nil
    ) -> String? {
        let prefix = "Step \(index + 1): "
        guard let target = step.target else { return prefix + "Choose a display." }
        guard UUID(uuidString: target.uuid) != nil else { return prefix + "This action has no stable display UUID." }
        guard let display = matchingDisplay(target) else { return prefix + "Unavailable: Display not connected or identity changed." }
        if step.effect == .removeFromDesktop {
            guard experimentalFeaturesEnabled else { return prefix + "Turn on Experimental features in General to remove a display from the desktop." }
            guard step.reviewedRemoval != nil else { return prefix + "Save the current Displays setup before running this step." }
            if displayActionReviewChange(for: action, stepIndex: index) != nil {
                return prefix + "Displays setup changed since review. Save this Action to accept the change."
            }
        }
        if hideOperation.isBusy { return prefix + DisplayHideError.actionInProgress.localizedDescription }
        if runningDisplayAction != nil, runningDisplayAction?.id != actionLeaseID {
            return displayActionBusyMessage
        }
        if handoffStatus?.state == .busy { return prefix + DisplayHideError.actionInProgress.localizedDescription }
        if displayLifecycleTransitioning { return prefix + DisplayHideError.sleeping.localizedDescription }
        if protectionQuiescencePending { return prefix + Self.automationStopping.localizedDescription }
        if let failure = protectionQuiescenceFailure {
            return prefix + "Automation cleanup needs attention. Choose Retry Automation Cleanup, then try again. (\(failure))"
        }
        if disconnectAutomationPaused || disconnectInspectionFailure != nil ||
            disconnectLease != nil || disconnectStatus?.resolved == false {
            return prefix + "Full disconnect is pausing automation or awaiting verified recovery. Finish it first."
        }

        let uuid = target.uuid.lowercased()
        let hiddenBlackout = projectedBlackouts ?? Set(blackoutHiddenDisplays.keys)
        let hiddenRemoved = projectedRemovals ?? Set(unresolvedHandoffRemovals.map { $0.target.uuid.lowercased() })
        switch step.effect {
        case .show:
            if hiddenBlackout.contains(uuid) { return nil }
            if hiddenRemoved.contains(uuid) {
                if isRemovedDisplay(uuid) {
                    do { _ = try makeShowRequest(targetUUID: target.uuid, actionLeaseID: actionLeaseID, refreshStatus: false) }
                    catch { return prefix + error.localizedDescription }
                } else if projectedRemovals?.contains(uuid) != true {
                    return prefix + "The removed display is not verified for Show. Review it in Displays."
                }
                return nil
            }
            if let problem = displayRecoveryProblem {
                return prefix + problem
            }
            return nil
        case .blackOut:
            if hiddenRemoved.contains(uuid) { return prefix + "Already hidden by Remove from desktop. Show it first." }
            if let problem = displayRecoveryProblem {
                return prefix + "Display recovery needs attention: \(problem)"
            }
            if let blocker = blackoutReadiness(
                for: display, projectedBlackouts: hiddenBlackout, projectedRemovals: hiddenRemoved,
                actionLeaseID: actionLeaseID
            ) {
                return prefix + blocker.localizedDescription
            }
            if hiddenBlackout.contains(uuid) { return nil }
            return nil
        case .removeFromDesktop:
            if hiddenBlackout.contains(uuid) { return prefix + "Already hidden by Black out. Show it first." }
            if let problem = displayRecoveryProblem {
                return prefix + "Display recovery needs attention: \(problem)"
            }
            if hiddenRemoved.contains(uuid) {
                guard isVerifiedRemovedDisplay(target.uuid) else {
                    return prefix + "Display recovery is not verified. Review it in Displays before repeating Remove from desktop."
                }
                guard let configuration = hideConfiguration(for: target.uuid) else {
                    return prefix + "Turn on Remove from desktop for this display in Settings → Displays first."
                }
                if let blocker = hideReadiness(
                    for: configuration, projectedBlackouts: hiddenBlackout,
                    projectedRemovals: hiddenRemoved, projectedSources: projectedSources,
                    actionLeaseID: actionLeaseID, allowVerifiedRemovalNoOp: true
                ) {
                    return prefix + blocker.localizedDescription
                }
                return nil
            }
            guard let configuration = hideConfiguration(for: target.uuid) else {
                return prefix + "Turn on Remove from desktop for this display in Settings → Displays first."
            }
            guard configuration.target == target,
                  let reviewed = step.reviewedRemoval,
                  reviewed == currentReviewedRemovalSetup(for: target.uuid) else {
                return prefix + "Displays setup changed since review. Save this Action to accept the change."
            }
            if let blocker = hideReadiness(
                for: configuration,
                projectedBlackouts: hiddenBlackout,
                projectedRemovals: hiddenRemoved,
                projectedSources: projectedSources,
                actionLeaseID: actionLeaseID
            ) {
                return prefix + blocker.localizedDescription
            }
            return nil
        }
    }

    var displayActionBusyMessage: String {
        guard let runningDisplayAction else { return DisplayHideError.actionInProgress.localizedDescription }
        return "Action “\(runningDisplayAction.name)” is running step \(runningDisplayAction.currentStep) of \(runningDisplayAction.totalSteps). Try again when it finishes."
    }

    var controlRunningDisplayAction: AppControlRunningAction? {
        guard let runningDisplayAction else { return nil }
        return AppControlRunningAction(
            id: runningDisplayAction.id, name: Self.bounded(runningDisplayAction.name),
            currentStep: runningDisplayAction.currentStep, totalSteps: runningDisplayAction.totalSteps
        )
    }

    func displayActionStatus(for action: DisplayAction) -> String {
        if let run = runningDisplayAction, run.id == action.id {
            return "Running step \(run.currentStep) of \(run.totalSteps)…"
        }
        if let displayActionStorageFailure { return displayActionStorageFailure }
        if let blocker = displayActionRunBlocker(for: action) { return blocker }
        guard !action.steps.isEmpty else { return "This Action has no steps." }
        return "Ready"
    }

    private func protectionRuleAdmissionValidation(
        _ candidate: ProtectionRule,
        in proposed: AutomationPreferences
    ) -> ProtectionRuleValidation {
        let hiddenUUIDs = Set(blackoutHiddenDisplays.keys)
        let candidateValidation = ProtectionRuleValidator.validate(
            candidate, in: proposed, displays: displays, hiddenUUIDs: hiddenUUIDs
        )
        guard candidate.isEnabled,
              candidateValidation.blockingReason == nil,
              candidateValidation.nameBlockingReason == nil else {
            return candidateValidation
        }

        for affectedRule in proposed.rules where affectedRule.id != candidate.id && affectedRule.isEnabled {
            guard let previousRule = automationPreferences.rule(namedID: affectedRule.id), previousRule.isEnabled else {
                continue
            }
            let previousValidation = ProtectionRuleValidator.validate(
                previousRule, in: automationPreferences, displays: displays, hiddenUUIDs: hiddenUUIDs
            )
            guard previousValidation.blockingReason == nil else { continue }

            let nextValidation = ProtectionRuleValidator.validate(
                affectedRule, in: proposed, displays: displays, hiddenUUIDs: hiddenUUIDs
            )
            guard let reason = nextValidation.blockingReason else { continue }
            let message = "“\(candidate.name)” would block “\(affectedRule.name)”: \(reason)"
            return ProtectionRuleValidation(
                blockingReason: message,
                waitingReason: candidateValidation.waitingReason,
                arguments: nil,
                nameBlockingReason: candidateValidation.nameBlockingReason
            )
        }
        return candidateValidation
    }

    func protectionRuleValidation(
        for draft: ProtectionRule,
        replacing existingID: UUID? = nil
    ) -> ProtectionRuleValidation {
        var candidate = draft
        candidate.name = candidate.name.trimmingCharacters(in: .whitespacesAndNewlines)
        var proposed = automationPreferences
        if let existingID {
            guard candidate.id == existingID,
                  let index = proposed.rules.firstIndex(where: { $0.id == existingID }) else {
                let reason = ProtectionConfigurationError.duplicateRuleIdentity.localizedDescription
                return ProtectionRuleValidation(blockingReason: reason, waitingReason: nil, arguments: nil)
            }
            proposed.rules[index] = candidate
        } else {
            guard !proposed.rules.contains(where: { $0.id == candidate.id }) else {
                let reason = ProtectionConfigurationError.duplicateRuleIdentity.localizedDescription
                return ProtectionRuleValidation(blockingReason: reason, waitingReason: nil, arguments: nil)
            }
            proposed.rules.append(candidate)
        }
        return protectionRuleAdmissionValidation(candidate, in: proposed)
    }

    func saveProtectionRule(
        _ draft: ProtectionRule,
        replacing existingID: UUID? = nil
    ) throws {
        var candidate = draft
        candidate.name = candidate.name.trimmingCharacters(in: .whitespacesAndNewlines)
        candidate.settings.isEnabled = false
        candidate.settings.keepDisplaysAwake = automationPreferences.keepDisplaysAwake
        var proposed = automationPreferences
        if let existingID {
            guard candidate.id == existingID,
                  let index = proposed.rules.firstIndex(where: { $0.id == existingID }) else {
                throw ProtectionConfigurationError.duplicateRuleIdentity
            }
            proposed.rules[index] = candidate
        } else {
            guard !proposed.rules.contains(where: { $0.id == candidate.id }) else {
                throw ProtectionConfigurationError.duplicateRuleIdentity
            }
            proposed.rules.append(candidate)
        }
        let validation = protectionRuleAdmissionValidation(candidate, in: proposed)
        if let nameReason = validation.nameBlockingReason {
            if candidate.name.isEmpty { throw ProtectionConfigurationError.invalidRuleName }
            throw ProtectionConfigurationError.ruleConflict(nameReason)
        }
        if candidate.isEnabled, let blockingReason = validation.blockingReason {
            throw ProtectionConfigurationError.ruleConflict(blockingReason)
        }
        automationPreferences = proposed
    }

    func setProtectionRuleEnabled(_ enabled: Bool, id: UUID) {
        guard let index = automationPreferences.rules.firstIndex(where: { $0.id == id }) else { return }
        var candidate = automationPreferences.rules[index]
        ruleEnableRefusals[id] = nil
        guard candidate.isEnabled != enabled else { return }
        candidate.isEnabled = enabled
        if enabled {
            var proposed = automationPreferences
            proposed.rules[index] = candidate
            let validation = protectionRuleAdmissionValidation(candidate, in: proposed)
            if let reason = validation.blockingReason {
                ruleEnableRefusals[id] = reason
                onStatusChange?()
                return
            }
        }
        var proposed = automationPreferences
        proposed.rules[index] = candidate
        automationPreferences = proposed
    }

    func deleteProtectionRule(id: UUID) {
        var proposed = automationPreferences
        guard let index = proposed.rules.firstIndex(where: { $0.id == id }) else { return }
        proposed.rules.remove(at: index)
        automationPreferences = proposed
    }

    func setKeepDisplaysAwake(_ enabled: Bool) {
        guard automationPreferences.keepDisplaysAwake != enabled else { return }
        var proposed = automationPreferences
        proposed.keepDisplaysAwake = enabled
        for index in proposed.rules.indices {
            proposed.rules[index].settings.keepDisplaysAwake = enabled
        }
        automationPreferences = proposed
    }

    func protectionRuleRowStatus(for rule: ProtectionRule) -> ProtectionRuleRowStatus {
        let validation = ProtectionRuleValidator.validate(
            rule, in: automationPreferences, displays: displays,
            hiddenUUIDs: Set(blackoutHiddenDisplays.keys)
        )
        var state = runtimeState(for: rule)
        if rule.isEnabled, protectionPausedForDisplayRecovery,
           protectionRuleNeedsDisplayReview(rule),
           let reason = displayRecoveryProblem {
            state = .failed(reason)
        } else if rule.isEnabled, protectionPausedForDisplayRecovery,
                  !hiddenOverlayRuleIDs.contains(rule.id),
                  protectionRuleNeedsDisplayReview(rule), handoffStatus?.hasUnresolvedJournal == true {
            state = .failed("Automation is paused while a display is removed.")
        }
        let status = ProtectionRulePresentation.status(
            for: rule,
            state: state,
            validation: validation,
            enableRefusal: ruleEnableRefusals[rule.id],
            displays: displays,
            effectiveMode: effectiveBlackoutMode(for: rule)
        )
        guard status.blockedReason == nil else { return status }
        switch state {
        case .starting, .waiting, .blackedOut, .waitingForInput, .waitingForPlayback:
            let overlay = hiddenOverlayRuleIDs.contains(rule.id)
            let targets = overlay ? remainingOverlayDisplays(for: rule.settings) : displays.filter {
                guard let uuid = $0.uuid else { return false }
                return $0.active && $0.online && !$0.asleep && ruleTargets(rule, uuid: uuid) && !isBlackoutHidden(uuid)
            }
            let targetUUIDs = Set(targets.compactMap(\.uuid).map { $0.lowercased() })
            // All displays ignores any stale saved selection.
            let candidates = rule.settings.allDisplays
                ? Set(displays.compactMap(\.uuid).map { $0.lowercased() })
                : Set(rule.settings.selectedDisplayUUIDs.map { $0.lowercased() })
            let skipped = candidates.subtracting(targetUUIDs).count
            var details: [String] = []
            if skipped > 0 {
                details.append("on " + targets.map(\.settingsName).joined(separator: ", "))
                details.append("skipping \(skipped) unavailable or hidden display\(skipped == 1 ? "" : "s")")
            }
            if overlay, rule.settings.followUpAction == .sleepDisplays {
                details.append("sleep paused while a display is removed; restores overlay instead")
            }
            return .init(text: ([status.text] + details).joined(separator: " · "), blockedReason: nil)
        default: return status
        }
    }

    func protectionRuleNeedsDisplayReview(_ rule: ProtectionRule) -> Bool {
        if displayRecoveryProblem != nil { return true }
        for uuid in rule.settings.selectedDisplayUUIDs {
            if isRemovedDisplay(uuid) || isBlackoutHidden(uuid) { return true }
            if displayResults[uuid.lowercased()]?.message.localizedCaseInsensitiveContains(
                "couldn’t confirm automation stopped"
            ) == true { return true }
        }
        if rule.settings.allDisplays, protectionQuiescenceFailure != nil {
            return displayResults.values.contains {
                $0.message.localizedCaseInsensitiveContains("couldn’t confirm automation stopped")
            }
        }
        return false
    }

    func protectionRuleReviewDisplayUUID(_ rule: ProtectionRule) -> String? {
        let reviewable = handoffStatus?.removals.filter(\.isUnresolved).map { $0.target.uuid } ?? []
        for uuid in rule.settings.selectedDisplayUUIDs.sorted() {
            if reviewable.contains(where: { $0.caseInsensitiveCompare(uuid) == .orderedSame }) ||
                isBlackoutHidden(uuid) || displayResults[uuid.lowercased()]?.message.localizedCaseInsensitiveContains(
                    "couldn’t confirm automation stopped"
                ) == true {
                return uuid
            }
        }
        return handoffStatus?.target?.uuid
    }

    /// Automation skips displays Hide blacked out.
    private func protectionArguments() throws -> [String] {
        guard let rule = automationPreferences.rules.first else {
            throw ProtectionConfigurationError.noSelection
        }
        let result = ProtectionRuleValidator.validate(
            rule, in: automationPreferences, displays: displays,
            hiddenUUIDs: Set(blackoutHiddenDisplays.keys)
        )
        if let reason = result.blockingReason ?? result.waitingReason {
            throw ProtectionConfigurationError.ruleConflict(reason)
        }
        return try rule.settings.commandArguments(
            for: displays,
            hiddenDisplayUUIDs: Set(blackoutHiddenDisplays.keys),
            ruleID: rule.id
        )
    }

    /// During a verified removal, only bounded window overlays may run.
    /// Removed targets, ambiguous identities and unrelated mirror sets never qualify.
    private func remainingOverlayDisplays(for settings: ProtectionPreferences) -> [DisplayRecord] {
        let sources = Set(verifiedHiddenMirrorSources.map(\.id))
        return activeDisplays.filter { display in
            guard let uuid = display.uuid, UUID(uuidString: uuid) != nil,
                  display.online, !display.asleep,
                  display.bounds.width > 0, display.bounds.height > 0,
                  !isRemovedDisplay(uuid), !isBlackoutHidden(uuid),
                  displays.filter({ $0.uuid?.caseInsensitiveCompare(uuid) == .orderedSame }).count == 1,
                  displays.filter({ $0.id == display.id }).count == 1,
                  settings.allDisplays || settings.selectedDisplayUUIDs.contains(where: {
                      $0.caseInsensitiveCompare(uuid) == .orderedSame
                  }) else { return false }
            return sources.contains(display.id) || !isDisplayMirrored(display.id)
        }
    }

    /// Overlays count displays Hide blacked out as covered.
    private func hiddenMirrorArguments(
        for sources: [DisplayRecord],
        settings: ProtectionPreferences,
        otherRuleDisplays: [DisplayRecord] = []
    ) throws -> [String]? {
        try settings.hiddenMirrorOverlayArguments(
            for: sources,
            additionalDisplays: remainingOverlayDisplays(for: settings).filter { display in
                !sources.contains(where: { $0.id == display.id })
            },
            hiddenDisplays: activeDisplays.filter { isBlackoutHidden($0.uuid) },
            otherRuleDisplays: otherRuleDisplays
        )
    }

    private func hiddenMirrorSiblingDisplays(for rule: ProtectionRule) -> [DisplayRecord] {
        let siblingUUIDs = Set(automationPreferences.rules
            .filter { $0.id != rule.id && $0.isEnabled && !$0.settings.allDisplays }
            .flatMap(\.settings.selectedDisplayUUIDs)
            .map { $0.lowercased() })
        return activeDisplays.filter { display in
            display.uuid.map { siblingUUIDs.contains($0.lowercased()) } == true
        }
    }

    private func ruleTargets(_ rule: ProtectionRule, uuid: String) -> Bool {
        rule.settings.allDisplays || rule.settings.selectedDisplayUUIDs.contains {
            $0.caseInsensitiveCompare(uuid) == .orderedSame
        }
    }

    func identityIsCurrent(_ identity: DisplayIdentitySnapshot) -> Bool {
        matchingDisplay(identity) != nil
    }

    func sourceChoices(for configuration: DisplayHideConfiguration) -> [DisplayRecord] {
        guard !configuration.target.uuid.isEmpty else { return [] }
        return activeDisplays.filter { display in
            guard let uuid = display.uuid else { return false }
            return display.online && display.active && !display.asleep &&
                uuid.caseInsensitiveCompare(configuration.target.uuid) != .orderedSame &&
                !isRemovedDisplay(uuid) && !isBlackoutHidden(uuid) &&
                (!isDisplayMirrored(display.id) || journalVerifiedHiddenMirrorSources.contains(where: { $0.id == display.id }))
        }
    }

    /// Why Hide can't start for this configuration right now, or nil when it can.
    func hideReadiness(
        for configuration: DisplayHideConfiguration,
        allowingCurrentOperation: Bool = false,
        projectedBlackouts: Set<String>? = nil,
        projectedRemovals: Set<String>? = nil,
        projectedSources: [String: String]? = nil,
        actionLeaseID: UUID? = nil,
        allowVerifiedRemovalNoOp: Bool = false
    ) -> DisplayHideError? {
        if runningDisplayAction != nil, runningDisplayAction?.id != actionLeaseID {
            return .recoveryBlocksAction(displayActionBusyMessage)
        }
        if disconnectAutomationPaused || disconnectInspectionFailure != nil {
            return .recoveryBlocksAction("Full disconnect is pausing automation or awaiting verified recovery.")
        }
        if let failure = handoffInspectionFailure {
            return .recoveryBlocksHide("Couldn\u{2019}t check display recovery: \(failure)")
        }
        guard let status = handoffStatus else {
            return .recoveryBlocksHide("Display recovery status is unknown. Try again in a moment.")
        }
        if status.state == .busy {
            return .recoveryBlocksHide("Another display operation is running. Try again in a moment.")
        }
        if status.hasUnresolvedJournal, status.state != .hidden {
            return .recoveryBlocksHide("Display recovery needs attention. Resolve it before starting another removal.")
        }
        if !allowingCurrentOperation, hideOperation.isBusy { return .actionInProgress }
        if displayLifecycleTransitioning { return .sleeping }
        if protectionQuiescencePending { return Self.automationStopping }
        if let failure = protectionQuiescenceFailure {
            _ = failure // Shown with its retry; repeating it here would duplicate it.
            return .protectionCleanup("Automation cleanup needs attention. Choose Retry Automation Cleanup, then try again.")
        }
        guard configuration.enabled else {
            return .unavailable("Turn on Remove from desktop for this display first.")
        }
        guard let target = matchingDisplay(configuration.target) else {
            return .identityChanged("This display is disconnected or changed. Reconnect it, then try again; PanelCtl won\u{2019}t apply its settings to a different display.")
        }
        guard let targetUUID = target.uuid else {
            return .identityChanged("This display no longer has its stable ID. Review it in Displays.")
        }
        let hiddenBlackouts = projectedBlackouts ?? Set(blackoutHiddenDisplays.keys)
        var hiddenRemovals = projectedRemovals ?? Set(unresolvedHandoffRemovals.map { $0.target.uuid.lowercased() })
        let verifiedRemovalNoOp = allowVerifiedRemovalNoOp && isVerifiedRemovedDisplay(targetUUID)
        if hiddenBlackouts.contains(targetUUID.lowercased()) {
            return .unavailable("This display is hidden. Show it first.")
        }
        if hiddenRemovals.contains(targetUUID.lowercased()) {
            guard verifiedRemovalNoOp else {
                return .unavailable("PanelCtl removed this display from the desktop. Show it first.")
            }
            hiddenRemovals.remove(targetUUID.lowercased())
        }
        let projectedMirrorSources = projectedSources?.values.contains(targetUUID.lowercased()) == true
        let liveMirrorSourceStillProjected = projectedSources == nil && isMirrorSource(targetUUID)
        if projectedMirrorSources || liveMirrorSourceStillProjected {
            return .unavailable("Another removed display mirrors onto this display. Show that display first.")
        }
        if !verifiedRemovalNoOp {
            if let reason = removalIneligibleReason(for: target) {
                return .unavailable(reason)
            }
            let targetMirrorReleasedByProjection = projectedSources != nil && isMirrorSource(targetUUID) &&
                projectedSources?.values.contains(targetUUID.lowercased()) != true
            guard !isDisplayMirrored(target.id) || targetMirrorReleasedByProjection else {
                return .unavailable("macOS is already mirroring this display. Turn off mirroring in System Settings \u{2192} Displays first.")
            }
        }
        guard let sourceIdentity = configuration.source else {
            return .unavailable("Choose a display to mirror onto.")
        }
        guard let source = matchingDisplay(sourceIdentity) else {
            return .identityChanged("The display it mirrors onto is disconnected or changed. Choose it again.")
        }
        guard let sourceUUID = source.uuid else {
            return .identityChanged("The display it mirrors onto no longer has its stable ID. Choose it again.")
        }
        guard source.online, source.active, !source.asleep else {
            return .unavailable("The display it mirrors onto must be on and awake.")
        }
        guard !hiddenBlackouts.contains(sourceUUID.lowercased()) else {
            return .unavailable("The display it mirrors onto is hidden. Show it first.")
        }
        guard !hiddenRemovals.contains(sourceUUID.lowercased()) else {
            return .unavailable("The display it mirrors onto is removed. Show it first.")
        }
        let sourceMirrorReleasedByProjection = projectedSources != nil && isMirrorSource(sourceUUID) &&
            projectedSources?.values.contains(sourceUUID.lowercased()) != true
        if isDisplayMirrored(source.id), !journalVerifiedHiddenMirrorSources.contains(where: { $0.id == source.id }),
           !sourceMirrorReleasedByProjection {
            return .unavailable("macOS is already mirroring this display. Choose a separate display as the mirror source.")
        }
        let visibleAfterHide = activeDisplays.filter { other in
            guard let uuid = other.uuid?.lowercased() else { return false }
            return other.id != target.id && !hiddenRemovals.contains(uuid) && !hiddenBlackouts.contains(uuid)
        }
        guard !visibleAfterHide.isEmpty else {
            return .unavailable("PanelCtl keeps at least one visible display, so it won’t remove this one.")
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

    func isRemovedDisplay(_ uuid: String?) -> Bool {
        uuid.flatMap { handoffStatus?.removal(for: $0) } != nil
    }

    private func isVerifiedRemovedDisplay(_ uuid: String?) -> Bool {
        guard handoffInspectionFailure == nil, let status = handoffStatus,
              status.state == .hidden, status.canShow, status.mirrorTopologyVerified,
              let uuid, let removal = status.removal(for: uuid) else { return false }
        return removal.isUnresolved && removal.state == "mirrored" && removal.canShow && removal.topologyVerified
    }

    private var unresolvedHandoffRemovals: [DisplayHandoffRemoval] {
        guard let status = handoffStatus else { return [] }
        let removals = status.removals.filter(\.isUnresolved)
        if !removals.isEmpty { return removals }
        guard status.hasUnresolvedJournal, let target = status.target,
              let removal = status.removal(for: target.uuid) else { return [] }
        return [removal]
    }

    private func isMirrorSource(_ uuid: String?) -> Bool {
        guard let uuid else { return false }
        return unresolvedHandoffRemovals.contains {
            $0.source.uuid.caseInsensitiveCompare(uuid) == .orderedSame
        }
    }

    /// Why Hide can't black out this display right now, or nil when it can.
    func blackoutReadiness(
        for display: DisplayRecord,
        projectedBlackouts: Set<String>? = nil,
        projectedRemovals: Set<String>? = nil,
        actionLeaseID: UUID? = nil
    ) -> DisplayHideError? {
        if hideOperation.isBusy { return .actionInProgress }
        if runningDisplayAction != nil, runningDisplayAction?.id != actionLeaseID {
            return .recoveryBlocksAction(displayActionBusyMessage)
        }
        // Disconnect preparation, consent and recovery exclude other display changes.
        if disconnectAutomationPaused || disconnectInspectionFailure != nil ||
            disconnectLease != nil || disconnectStatus?.resolved == false {
            return .unavailable("Full disconnect is pausing automation or awaiting verified recovery.")
        }
        if displayLifecycleTransitioning { return .sleeping }
        guard let uuid = display.uuid, UUID(uuidString: uuid) != nil,
              displays.filter({ $0.uuid?.caseInsensitiveCompare(uuid) == .orderedSame }).count == 1 else {
            return .unavailable("This display has no stable ID, so PanelCtl can\u{2019}t hide it.")
        }
        guard display.active, display.online, !display.asleep,
              display.bounds.width > 0, display.bounds.height > 0 else {
            return .unavailable("Wake this display to hide it.")
        }
        let hiddenBlackouts = projectedBlackouts ?? Set(blackoutHiddenDisplays.keys)
        let hiddenRemovals = projectedRemovals ?? Set(unresolvedHandoffRemovals.map { $0.target.uuid.lowercased() })
        if hiddenRemovals.contains(uuid.lowercased()) {
            return .unavailable("PanelCtl removed this display from the desktop. Show it first.")
        }
        let verifiedSource = journalVerifiedHiddenMirrorSources.contains { $0.id == display.id }
        if isDisplayMirrored(display.id), !verifiedSource {
            if isMirrorSource(uuid) {
                return .unavailable("PanelCtl’s removal source needs recovery. Review display recovery before covering it.")
            }
            return .unavailable("macOS is mirroring this display. Turn off mirroring in System Settings \u{2192} Displays first.")
        }
        let anotherStaysVisible = activeDisplays.contains { other in
            guard let otherUUID = other.uuid?.lowercased() else { return false }
            return other.id != display.id && !other.asleep &&
                !hiddenRemovals.contains(otherUUID) && !hiddenBlackouts.contains(otherUUID)
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
    /// macOS now mirrors is shown unless it is a verified PanelCtl removal source.
    /// Once no other non-removed display is connected, every hidden display is shown.
    @discardableResult
    private func reconcileHiddenDisplays() -> Bool {
        var shown: [String: String] = [:]
        if !blackoutHiddenDisplays.isEmpty, !displayLifecycleTransitioning {
            for (id, key) in connectedHiddenDisplays
            where isDisplayMirrored(id) && !journalVerifiedHiddenMirrorSources.contains(where: { $0.id == id }) {
                shown[key] = "Shown because macOS started mirroring it."
            }
            let stillHidden = Set(blackoutHiddenDisplays.keys).subtracting(shown.keys)
            var removedTargetUUIDs = Set(handoffStatus?.removals.filter(\.isUnresolved).map { $0.target.uuid.lowercased() } ?? [])
            if removedTargetUUIDs.isEmpty, handoffStatus?.hasUnresolvedJournal == true,
               let targetUUID = handoffStatus?.target?.uuid.lowercased() {
                removedTargetUUIDs.insert(targetUUID)
            }
            if !stillHidden.isEmpty, !activeDisplays.contains(where: {
                !$0.asleep && !stillHidden.contains($0.uuid?.lowercased() ?? "") &&
                    !removedTargetUUIDs.contains($0.uuid?.lowercased() ?? "")
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
        guard !shown.isEmpty else { return false }
        hiddenDisplaysChanged()
        return true
    }

    /// Automation restarts without the hidden displays and counts idle time anew.
    private func hiddenDisplaysChanged() {
        lastHideOrShowFinished = .now
        manualActivityDate = now()
        if !protectionQuiescencePending { reconcileProtection(restartWatcher: true) }
        onStatusChange?()
    }

    private func reconcileDeferredActionHiddenDisplays() -> Bool {
        guard deferredActionHiddenDisplayReconciliation,
              runningDisplayAction == nil, !displayLifecycleTransitioning else { return false }
        deferredActionHiddenDisplayReconciliation = false
        return reconcileHiddenDisplays()
    }

    private func finishDisplayActionLease() {
        let recoveryReconciliationDeferred = deferredActionRecoveryReconciliation
        deferredActionRecoveryReconciliation = false
        if recoveryReconciliationDeferred {
            let recoveryUnresolved = handoffStatus?.hasUnresolvedJournal == true || handoffInspectionFailure != nil
            if recoveryUnresolved {
                if hideOperation.isBusy {
                    deferredActionRecoveryReconciliation = true
                } else {
                    quiesceForExternalRecovery()
                }
                _ = reconcileDeferredActionHiddenDisplays()
                lastDisplayActionFinished = .now
                return
            }
            let hiddenDisplaysReconciled = reconcileDeferredActionHiddenDisplays()
            if !hiddenDisplaysReconciled, hideOperation == .idle {
                rearmProtectionAfterDisplayRecovery()
            }
            lastDisplayActionFinished = .now
            return
        }
        // Helpers stayed stopped across steps; reconcile automation once for the final state.
        if !reconcileDeferredActionHiddenDisplays(), !protectionQuiescencePending {
            reconcileProtection()
        }
        lastDisplayActionFinished = .now
    }

    private func blackOut(
        targetUUID: String,
        manualAction: DisplayAction? = nil,
        manualActionStepIndex: Int? = nil,
        actionLeaseID: UUID? = nil,
        completion: ((DisplayOperationResult) -> Void)?
    ) {
        guard runningDisplayAction == nil || runningDisplayAction?.id == actionLeaseID else {
            refuse(.hide, targetUUID: targetUUID, error: DisplayHideError.recoveryBlocksAction(displayActionBusyMessage), completion: completion)
            return
        }
        // Menu and Settings actions may arrive before a topology notification.
        if actionLeaseID == nil {
            displays = displayProvider()
            refreshHandoffStatus()
        }
        if let manualAction, let reason = manualActionValidationFailure(manualAction, stepIndex: manualActionStepIndex) {
            refuse(.hide, targetUUID: targetUUID, error: DisplayHideError.identityChanged(reason), completion: completion)
            return
        }
        let matches = displays.filter { $0.uuid?.caseInsensitiveCompare(targetUUID) == .orderedSame }
        guard matches.count == 1, let display = matches.first else {
            refuse(.hide, targetUUID: targetUUID, error: DisplayHideError.unavailable(
                "This display is disconnected. Reconnect it, then try again."
            ), completion: completion)
            return
        }
        if let refusal = blackoutReadiness(for: display, actionLeaseID: actionLeaseID) {
            refuse(.hide, targetUUID: targetUUID, error: refusal, completion: completion)
            return
        }
        let identity = DisplayIdentitySnapshot(display)
        if actionLeaseID == nil,
           journalVerifiedHiddenMirrorSources.contains(where: { $0.id == display.id }),
           protectionCoordinator.hasManagedProcess || protectionQuiescencePending || hiddenMirrorOverlayPolicyEligible {
            hideOperation = .hiding(targetUUID)
            onStatusChange?()
            stopManagedProtection { [weak self] succeeded, message in
                Task { @MainActor in
                    guard let self, self.hideOperation == .hiding(targetUUID) else { return }
                    guard succeeded else {
                        self.hideOperation = .idle
                        let failure = message ?? "Automation cleanup could not be verified."
                        self.protectionQuiescenceFailure = failure
                        self.reconcileProtection()
                        self.refuse(.hide, targetUUID: targetUUID, error: DisplayHideError.protectionCleanup(
                            "Automation cleanup needs attention: \(failure)"
                        ), completion: completion)
                        return
                    }
                    self.protectionQuiescenceFailure = nil
                    self.displays = self.displayProvider()
                    self.refreshHandoffStatus()
                    self.hideOperation = .idle
                    if let manualAction, let reason = self.manualActionValidationFailure(manualAction, stepIndex: manualActionStepIndex) {
                        self.reconcileProtection()
                        self.refuse(.hide, targetUUID: targetUUID, error: DisplayHideError.identityChanged(reason), completion: completion)
                        return
                    }
                    guard let current = self.matchingDisplay(identity) else {
                        self.reconcileProtection()
                        self.refuse(.hide, targetUUID: targetUUID, error: DisplayHideError.identityChanged(
                            "This display changed before Hide began. Try again."
                        ), completion: completion)
                        return
                    }
                    if let refusal = self.blackoutReadiness(for: current) {
                        self.reconcileProtection()
                        self.refuse(.hide, targetUUID: targetUUID, error: refusal, completion: completion)
                        return
                    }
                    self.coverWithBlackOut(targetUUID: targetUUID, display: current, completion: completion)
                }
            }
            return
        }
        coverWithBlackOut(targetUUID: targetUUID, display: display, completion: completion)
    }

    private func coverWithBlackOut(
        targetUUID: String,
        display: DisplayRecord,
        completion: ((DisplayOperationResult) -> Void)?
    ) {
        let key = targetUUID.lowercased()
        blackoutHiddenDisplays[key] = DisplayIdentitySnapshot(display)
        coverHiddenDisplays()
        guard !uncoveredHiddenDisplays.contains(key) else {
            blackoutHiddenDisplays[key] = nil
            coverHiddenDisplays()
            reconcileProtection()
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

    /// Displays in arrangement order, plus every journaled display that is no longer connected.
    var displayTiles: [DisplayTile] {
        let removals = handoffStatus?.removals.filter(\.isUnresolved) ?? []
        let journalTargets = removals.map(\.target) +
            (removals.isEmpty && handoffStatus?.hasUnresolvedJournal == true
                ? [handoffStatus?.target].compactMap { $0 } : [])
        func isJournalTarget(_ display: DisplayRecord) -> Bool {
            guard let uuid = display.uuid else { return false }
            return journalTargets.contains { $0.uuid.caseInsensitiveCompare(uuid) == .orderedSame }
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
        for journalTarget in journalTargets where !tiles.contains(where: { $0.id == journalTarget.uuid.lowercased() }) {
            tiles.append(DisplayTile(
                id: journalTarget.uuid.lowercased(), uuid: journalTarget.uuid,
                name: journalTarget.name,
                status: tileStatus(for: nil, isJournalTarget: true, journalTargetUUID: journalTarget.uuid),
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
        let journalTargetIDs = handoffStatus?.removals.filter(\.isUnresolved).map { $0.target.uuid.lowercased() } ?? []
        let fallbackTarget = handoffStatus?.hasUnresolvedJournal == true ? handoffStatus?.target?.uuid.lowercased() : nil
        return tiles.first { $0.id == id } ?? tiles.first { journalTargetIDs.contains($0.id) } ??
            tiles.first { $0.id == fallbackTarget } ?? tiles.first
    }

    /// Whether PanelCtl's hidden display can be shown: its saved layout is restorable.
    var canShowHiddenDisplay: Bool {
        guard handoffInspectionFailure == nil, let status = handoffStatus,
              status.state == .hidden || status.state == .recovery else { return false }
        let unresolved = status.removals.filter(\.isUnresolved)
        if unresolved.isEmpty { return status.canShow }
        return unresolved.allSatisfy(\.canShow)
    }

    private static let automationStopping = DisplayHideError.recoveryBlocksAction(
        "PanelCtl is still stopping automation. Try again in a moment."
    )

    /// Why Show must wait, apart from the hidden display's own state.
    private func showWait(actionLeaseID: UUID? = nil) -> DisplayHideError? {
        if hideOperation.isBusy { return .actionInProgress }
        if runningDisplayAction != nil, runningDisplayAction?.id != actionLeaseID {
            return .recoveryBlocksAction(displayActionBusyMessage)
        }
        if disconnectAutomationPaused || disconnectInspectionFailure != nil {
            return .recoveryBlocksAction("Full disconnect is pausing automation or awaiting verified recovery.")
        }
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
            guard let uuid = tile.uuid, let removal = handoffStatus?.removal(for: uuid) else { return }
            guard removal.canShow || canAttemptGuardedRecoveryShow(removal) else { return }
            tile.action = .show
            tile.actionBlocker = showWait()?.localizedDescription
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

    private func tileStatus(for display: DisplayRecord?, isJournalTarget: Bool,
                            journalTargetUUID: String? = nil) -> DisplayTile.Status {
        let uuid = display?.uuid ?? (isJournalTarget ? journalTargetUUID ?? handoffStatus?.target?.uuid : nil)
        switch hideOperation {
        case .hiding(let target) where uuid?.caseInsensitiveCompare(target) == .orderedSame:
            return .hiding
        case .showing(let target) where uuid?.caseInsensitiveCompare(target) == .orderedSame:
            return .showing
        default:
            break
        }
        if isBlackoutHidden(uuid) { return .hidden }
        if isJournalTarget, let uuid, let removal = handoffStatus?.removal(for: uuid) {
            if removal.state == "mirrored", removal.topologyVerified, removal.canShow { return .hidden }
            return .needsRecovery
        }
        if isJournalTarget, handoffStatus?.state == .busy { return .busy }
        if isJournalTarget { return .needsRecovery }
        guard let display, display.active, display.online else { return .unavailable }
        if display.asleep { return .asleep }
        if blackedOutDisplayIDs.contains(display.id) { return .blackedOut }
        // The source of PanelCtl's mirror is still a normal display.
        let isJournalSource = display.uuid.map { isMirrorSource($0) } == true &&
            journalVerifiedHiddenMirrorSources.contains(where: { $0.id == display.id })
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
        showReturnInputNote(for: handoffStatus?.target?.uuid)
    }

    func showReturnInputNote(for targetUUID: String?) -> String? {
        guard let status = handoffStatus, status.hasUnresolvedJournal,
              let removalStatus = targetUUID.flatMap({ status.removal(for: $0) }) else { return nil }
        let input = configuredReturnInput(for: removalStatus.target)
        if let warning = input.warning {
            return "Show won\u{2019}t switch the monitor input: \(warning)"
        }
        return input.value.map { "Show switches the monitor back to \(MonitorInput.name($0))." }
    }

    /// Turns Remove from desktop on or off for a display.
    func setHideEnabled(_ enabled: Bool, for display: DisplayRecord) {
        guard let targetUUID = display.uuid,
              !hideConfigurationFrozen(for: targetUUID),
              isEligibleHideTarget(display),
              let uuid = display.uuid else { return }
        var updated = hidePreferences
        var configuration = updated[uuid] ?? DisplayHideConfiguration(target: DisplayIdentitySnapshot(display))
        guard matches(configuration.target, display) else { return }
        configuration.enabled = enabled
        // Preserve the existing main-source default for non-main targets; a main target requires an explicit source.
        if enabled, !display.main, configuration.source == nil,
           let main = sourceChoices(for: configuration).first(where: \.main) {
            configuration.source = DisplayIdentitySnapshot(main)
        }
        updated[uuid] = configuration
        hidePreferences = updated
        clearFailedResult(uuid)
    }

    func setHideSource(_ sourceUUID: String?, for targetUUID: String) {
        guard !hideConfigurationFrozen(for: targetUUID),
              let target = displays.first(where: {
                  $0.uuid?.caseInsensitiveCompare(targetUUID) == .orderedSame
              }),
              let uuid = target.uuid else { return }
        var updated = hidePreferences
        var configuration = updated[uuid] ?? DisplayHideConfiguration(target: DisplayIdentitySnapshot(target))
        guard matches(configuration.target, target) else { return }
        if let sourceUUID {
            guard let source = activeDisplays.first(where: { candidate in
                candidate.uuid?.caseInsensitiveCompare(sourceUUID) == .orderedSame &&
                    candidate.id != target.id && !candidate.asleep && !isRemovedDisplay(candidate.uuid) &&
                    !isBlackoutHidden(candidate.uuid) &&
                    (!isDisplayMirrored(candidate.id) || journalVerifiedHiddenMirrorSources.contains(where: { $0.id == candidate.id }))
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
        guard !hideConfigurationFrozen(for: targetUUID),
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

    func canDismissInputWarning(for targetUUID: String) -> Bool {
        guard !hideOperation.isBusy, displayRecoveryProblem == nil,
              let result = displayResults[targetUUID.lowercased()] else { return false }
        return result.succeeded && result.inputNeedsAttention && !result.inputWarningDismissed
    }

    /// Acknowledge a past input warning, not a repair or a new display operation.
    func dismissInputWarning(for targetUUID: String) {
        guard canDismissInputWarning(for: targetUUID) else { return }
        displayResults[targetUUID.lowercased()]?.inputWarningDismissed = true
        onStatusChange?()
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
        guard !hideConfigurationFrozen(for: targetUUID),
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
        return displayTiles.compactMap { tile in
            guard let uuid = tile.uuid else { return nil }
            let state = controlState(of: tile)
            let recoveryNeeded = ["recovery-needed", "unsupported-recovery", "unknown"].contains(state) ||
                handoffStatus?.removal(for: uuid)?.canShow == false
            return AppControlDisplayStatus(
                targetUUID: uuid,
                observedState: state,
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
            case .hiddenByPanelCtl:
                if let uuid = tile.uuid, let removal = handoffStatus?.removal(for: uuid), !removal.canShow {
                    return "recovery-needed"
                }
                return "hidden-by-panelctl"
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
        if request.command == .runAction {
            return await handleDisplayActionControlRequest(request, receivedAt: receivedAt)
        }
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
              request.actionID == nil,
              let uuid = request.targetUUID, UUID(uuidString: uuid) != nil else {
            return response(.refused, "Hide, Show and Toggle Hide need --display with a display UUID.")
        }
        if runningDisplayAction != nil {
            return response(.busy, displayActionBusyMessage)
        }
        guard !hideOperation.isBusy else {
            return response(.busy, DisplayHideError.actionInProgress.localizedDescription)
        }
        // Acting on a request that waited would act on a state its sender
        // didn't see; a second Toggle Hide would undo the first.
        if let finished = lastHideOrShowFinished, receivedAt < finished {
            return response(.busy, "Another Hide or Show finished while this request waited. Check the display, then try again.")
        }
        if let finished = lastDisplayActionFinished, receivedAt < finished {
            return response(.busy, "A named Action finished while this request waited. Check the displays, then try again.")
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

    private func handleDisplayActionControlRequest(
        _ request: AppControlRequest,
        receivedAt: ContinuousClock.Instant
    ) async -> AppControlResponse {
        guard request.protocolVersion == AppControlRequest.currentProtocol,
              request.command == .runAction, request.durationSeconds == nil,
              request.targetUUID == nil, let actionID = request.actionID else {
            return AppControlResponse(
                ok: false, running: true, enabled: automationPreferences.isEnabled,
                state: runtimeState.controlIdentifier,
                summary: "Run Action needs --action with an action UUID.",
                error: "Run Action needs --action with an action UUID.", outcome: .refused
            )
        }
        return await withCheckedContinuation { continuation in
            runDisplayAction(id: actionID, receivedAt: receivedAt) { response in
                continuation.resume(returning: response)
            }
        }
    }

    func runDisplayAction(
        id: UUID,
        receivedAt: ContinuousClock.Instant = .now,
        completion: ((AppControlResponse) -> Void)? = nil
    ) {
        var acquiredActionLease = false
        func refuse(_ outcome: AppControlOutcome, _ message: String,
                    for action: DisplayAction? = nil, atStep requestedStep: Int = 0) {
            if acquiredActionLease, runningDisplayAction?.id == id {
                runningDisplayAction = nil
                runningDisplayActionIDs.remove(id)
                runningActionInterrupted = false
                acquiredActionLease = false
                finishDisplayActionLease()
            }
            let targetUUIDs = action?.steps.compactMap { $0.target?.uuid } ?? []
            let isMultiStepAction = (action?.steps.count ?? 1) > 1
            let stepResults = action?.steps.enumerated().compactMap { offset, step -> AppControlActionStepResult? in
                guard let uuid = step.target?.uuid else { return nil }
                return AppControlActionStepResult(
                    index: offset + 1, targetUUID: uuid, effect: step.effect.rawValue,
                    outcome: offset == requestedStep ? outcome : .notRun,
                    desktopSummary: offset == requestedStep
                        ? (isMultiStepAction ? Self.boundedActionStepText(message) : Self.bounded(message))
                        : "Not run."
                )
            }
            let response = AppControlResponse(
                ok: false, running: true, enabled: automationPreferences.isEnabled,
                state: runtimeState.controlIdentifier, summary: Self.bounded(message), error: Self.bounded(message),
                outcome: outcome,
                displays: Self.actionDisplayStatuses(
                    controlDisplayStatuses, targetUUIDs: targetUUIDs,
                    includeInputEvidence: action?.steps.count == 1
                ),
                steps: stepResults
            )
            if runningDisplayAction?.id != id { displayActionResults[id] = response }
            onStatusChange?()
            completion?(response)
        }

        guard let action = displayActions.actions.first(where: { $0.id == id }) else {
            refuse(.refused, "No saved display action has ID \(id.uuidString). Edit Actions in Settings → Automations.")
            return
        }
        if runningDisplayAction != nil || hideOperation.isBusy || handoffStatus?.state == .busy {
            refuse(.busy, displayActionBusyMessage, for: action)
            return
        }
        if let finished = lastHideOrShowFinished, receivedAt < finished {
            refuse(.busy, "Another display operation finished while this request waited. Check the displays, then try again.", for: action)
            return
        }
        if let actionFinished = lastDisplayActionFinished, receivedAt < actionFinished {
            refuse(.busy, "A named Action finished while this request waited. Check the displays, then try again.", for: action)
            return
        }

        runningDisplayActionIDs.insert(id)
        runningActionInterrupted = false
        runningDisplayAction = AppControlRunningAction(id: id, name: action.name, currentStep: 1, totalSteps: action.steps.count)
        acquiredActionLease = true
        onStatusChange?()

        // Read one fresh topology and journal snapshot without reconciling helpers.
        preflightingDisplayAction = true
        displays = displayProvider()
        refreshHandoffStatus()
        preflightingDisplayAction = false
        guard let currentAction = displayActions.actions.first(where: { $0.id == id }),
              currentAction == action else {
            refuse(.refused, "This action changed before it could run. Review it in Settings → Automations, then try again.", for: action)
            return
        }
        guard (1...8).contains(action.steps.count) else {
            refuse(.refused, DisplayActionValidationError.invalidStepCount.localizedDescription, for: action)
            return
        }

        var projectedBlackouts = Set(blackoutHiddenDisplays.keys)
        var projectedRemovals = Set(handoffStatus?.removals.filter(\.isUnresolved).map { $0.target.uuid.lowercased() } ?? [])
        var projectedSources = Dictionary(uniqueKeysWithValues: (handoffStatus?.removals.filter(\.isUnresolved) ?? []).map {
            ($0.target.uuid.lowercased(), $0.source.uuid.lowercased())
        })
        var noOpSteps = Set<Int>()
        for (offset, step) in action.steps.enumerated() {
            guard let uuid = step.target?.uuid else {
                refuse(.refused, "Step \(offset + 1): Choose a display.", for: action, atStep: offset)
                return
            }
            if let blocker = displayActionStepRunBlocker(
                action: action, step: step, index: offset,
                projectedBlackouts: projectedBlackouts,
                projectedRemovals: projectedRemovals,
                projectedSources: projectedSources,
                actionLeaseID: id
            ) {
                let outcome: AppControlOutcome = hideOperation.isBusy || handoffStatus?.state == .busy ? .busy
                    : blocker.localizedCaseInsensitiveContains("recovery") || blocker.localizedCaseInsensitiveContains("journal") ? .recoveryNeeded : .refused
                refuse(outcome, blocker, for: action, atStep: offset)
                return
            }
            let key = uuid.lowercased()
            let isNoOp: Bool
            switch step.effect {
            case .blackOut: isNoOp = projectedBlackouts.contains(key)
            case .removeFromDesktop: isNoOp = projectedRemovals.contains(key) && isVerifiedRemovedDisplay(uuid)
            case .show: isNoOp = !projectedBlackouts.contains(key) && !projectedRemovals.contains(key)
            }
            if isNoOp { noOpSteps.insert(offset) }
            switch step.effect {
            case .blackOut:
                projectedBlackouts.insert(key)
            case .removeFromDesktop:
                projectedRemovals.insert(key)
                if let source = step.reviewedRemoval?.sourceUUID { projectedSources[key] = source.lowercased() }
            case .show:
                projectedBlackouts.remove(key)
                projectedRemovals.remove(key)
                projectedSources.removeValue(forKey: key)
            }
        }

        let targetUUIDs = action.steps.compactMap { $0.target?.uuid }
        let wouldWrite = noOpSteps.count != action.steps.count
        guard !runningActionInterrupted, !displayLifecycleTransitioning else {
            refuse(.refused, "Displays are sleeping or changing; the run was interrupted.", for: action)
            return
        }

        var stepResults: [AppControlActionStepResult] = []
        var changedAnyDisplay = false
        var stoppingOutcome: AppControlOutcome?
        var stoppingAtIndex: Int?

        func finishRun() {
            guard self.runningDisplayAction?.id == id else { return }
            let aggregate: AppControlOutcome
            if stepResults.contains(where: { $0.outcome == .recoveryNeeded }) {
                aggregate = .recoveryNeeded
            } else if changedAnyDisplay && stepResults.count < action.steps.count ||
                        (changedAnyDisplay && stepResults.contains(where: { ![.done, .noOp].contains($0.outcome) })) {
                aggregate = .partial
            } else if stepResults.count == action.steps.count && stepResults.allSatisfy({ $0.outcome == .noOp }) {
                aggregate = .noOp
            } else if stepResults.count == action.steps.count && stepResults.allSatisfy({ [.done, .noOp].contains($0.outcome) }) {
                aggregate = stepResults.contains(where: { $0.outcome == .done }) ? .done : .noOp
            } else {
                aggregate = stoppingOutcome ?? .failed
            }
            let summary: String
            if action.steps.count == 1, let onlyStep = stepResults.first,
               [.done, .partial, .noOp].contains(aggregate) {
                summary = onlyStep.desktopSummary
            } else if let stoppingAtIndex {
                let stopped = stepResults.first(where: { $0.index == stoppingAtIndex })
                summary = "Action stopped at Step \(stoppingAtIndex) of \(action.steps.count): \(stopped?.desktopSummary ?? "the step did not complete")"
            } else {
                summary = aggregate == .done ? "Action completed; steps ran in order." :
                    aggregate == .noOp ? "Action is already at the requested state." : "Action ended with \(aggregate.rawValue)."
            }
            let detailText = stepResults.compactMap { step in
                step.inputDetail.map { "Step \(step.index): \($0)" }
            }.joined(separator: "\n")
            let detail = detailText.isEmpty ? nil : detailText
            let matchingStatuses = Self.actionDisplayStatuses(
                self.controlDisplayStatuses, targetUUIDs: targetUUIDs,
                includeInputEvidence: action.steps.count == 1
            )
            let response = AppControlResponse(
                ok: aggregate == .done || aggregate == .noOp,
                running: true, enabled: self.automationPreferences.isEnabled,
                state: self.runtimeState.controlIdentifier, summary: Self.bounded(summary),
                detail: detail.map(Self.bounded),
                error: aggregate == .done || aggregate == .noOp ? nil : Self.bounded(detail ?? summary),
                outcome: aggregate, displays: matchingStatuses, steps: stepResults,
                runningAction: nil
            )
            self.runningDisplayAction = nil
            self.runningActionInterrupted = false
            acquiredActionLease = false
            self.runningDisplayActionIDs.remove(id)
            self.finishDisplayActionLease()
            self.displayActionResults[id] = response
            self.onStatusChange?()
            completion?(response)
        }

        func appendNotRun(from index: Int) {
            for offset in index..<action.steps.count {
                guard let uuid = action.steps[offset].target?.uuid else { continue }
                stepResults.append(AppControlActionStepResult(
                    index: offset + 1, targetUUID: uuid, effect: action.steps[offset].effect.rawValue,
                    outcome: .notRun, desktopSummary: "Not run."
                ))
            }
        }

        func runStep(_ offset: Int) {
            guard offset < action.steps.count else { finishRun(); return }
            guard self.runningDisplayAction?.id == id else { return }
            self.runningDisplayAction = AppControlRunningAction(
                id: id, name: action.name, currentStep: offset + 1, totalSteps: action.steps.count
            )
            self.onStatusChange?()
            if self.runningActionInterrupted || self.displayLifecycleTransitioning {
                let uuid = action.steps[offset].target?.uuid ?? ""
                let message = "Step \(offset + 1): Displays are sleeping or changing; the run was interrupted."
                stepResults.append(AppControlActionStepResult(index: offset + 1, targetUUID: uuid,
                    effect: action.steps[offset].effect.rawValue, outcome: .refused,
                    desktopSummary: message))
                stoppingOutcome = .refused
                stoppingAtIndex = offset + 1
                appendNotRun(from: offset + 1)
                finishRun()
                return
            }

            // Each step begins with one fresh display and recovery observation.
            self.displays = self.displayProvider()
            self.refreshHandoffStatus()
            let step = action.steps[offset]
            guard let uuid = step.target?.uuid else {
                stoppingOutcome = .refused
                stoppingAtIndex = offset + 1
                appendNotRun(from: offset)
                finishRun()
                return
            }
            if let blocker = self.displayActionStepRunBlocker(
                action: action, step: step, index: offset, actionLeaseID: id
            ) {
                let outcome: AppControlOutcome = self.displayLifecycleTransitioning ? .refused
                    : blocker.localizedCaseInsensitiveContains("recovery") ? .recoveryNeeded : .refused
                stepResults.append(AppControlActionStepResult(index: offset + 1, targetUUID: uuid,
                    effect: step.effect.rawValue, outcome: outcome,
                    desktopSummary: action.steps.count > 1 ? Self.boundedActionStepText(blocker) : Self.bounded(blocker)))
                stoppingOutcome = outcome
                stoppingAtIndex = offset + 1
                appendNotRun(from: offset + 1)
                finishRun()
                return
            }
            let alreadyAtDesiredState: Bool
            switch step.effect {
            case .blackOut: alreadyAtDesiredState = self.isBlackoutHidden(uuid)
            case .removeFromDesktop: alreadyAtDesiredState = self.isVerifiedRemovedDisplay(uuid)
            case .show: alreadyAtDesiredState = !self.isBlackoutHidden(uuid) && !self.isRemovedDisplay(uuid)
            }
            if alreadyAtDesiredState {
                let name = step.target.map { DisplayActionPresentation.displayName(for: $0, displays: self.displays) } ?? uuid
                let summary: String
                switch step.effect {
                case .blackOut: summary = "\(name) is already blacked out."
                case .removeFromDesktop: summary = "\(name) is already removed from the desktop."
                case .show: summary = "\(name) isn’t hidden."
                }
                stepResults.append(AppControlActionStepResult(index: offset + 1, targetUUID: uuid,
                    effect: step.effect.rawValue, outcome: .noOp,
                    desktopSummary: action.steps.count > 1 ? Self.boundedActionStepText(summary) : Self.bounded(summary)))
                runStep(offset + 1)
                return
            }
            guard wouldWrite else {
                // Preflight found nothing to change, so helpers were never quiesced; don't write now.
                let message = "Step \(offset + 1): Display state changed after the Action was checked. Review the displays, then run it again."
                stepResults.append(AppControlActionStepResult(index: offset + 1, targetUUID: uuid,
                    effect: step.effect.rawValue, outcome: .refused,
                    desktopSummary: action.steps.count > 1 ? Self.boundedActionStepText(message) : Self.bounded(message)))
                stoppingOutcome = .refused
                stoppingAtIndex = offset + 1
                appendNotRun(from: offset + 1)
                finishRun()
                return
            }

            let complete: (DisplayOperationResult) -> Void = { result in
                let resultOutcome: AppControlOutcome
                if result.succeeded {
                    resultOutcome = result.inputOutcome?.isPartial == true ? .partial : .done
                    changedAnyDisplay = true
                } else if self.displayRecoveryProblem != nil {
                    resultOutcome = .recoveryNeeded
                } else {
                    resultOutcome = result.inputOutcome == nil ? .refused : .failed
                }
                let desktop = action.steps.count > 1
                    ? Self.boundedActionStepText(result.message)
                    : Self.bounded(result.message)
                let input = result.inputMessage.map {
                    action.steps.count > 1 ? Self.boundedActionStepText($0) : Self.bounded($0)
                }
                stepResults.append(AppControlActionStepResult(
                    index: offset + 1, targetUUID: uuid, effect: step.effect.rawValue,
                    outcome: resultOutcome, desktopSummary: Self.bounded(desktop),
                    inputOutcome: result.inputOutcome?.state, inputDetail: input
                ))
                if resultOutcome == .done || resultOutcome == .noOp {
                    if self.runningActionInterrupted || self.displayLifecycleTransitioning {
                        stoppingOutcome = .partial
                        stoppingAtIndex = offset + 1
                        appendNotRun(from: offset + 1)
                        finishRun()
                    } else {
                        runStep(offset + 1)
                    }
                } else {
                    stoppingOutcome = resultOutcome
                    stoppingAtIndex = offset + 1
                    appendNotRun(from: offset + 1)
                    finishRun()
                }
            }
            switch step.effect {
            case .blackOut:
                self.hide(targetUUID: uuid, style: .blackOut, manualAction: action,
                          manualActionStepIndex: offset, actionLeaseID: id, completion: complete)
            case .removeFromDesktop:
                self.hide(targetUUID: uuid, style: .removeFromDesktop, manualAction: action,
                          manualActionStepIndex: offset, actionLeaseID: id, completion: complete)
            case .show:
                self.show(targetUUID: uuid, actionLeaseID: id, completion: complete)
            }
        }

        if wouldWrite {
            self.protectionQuiescencePending = true
            self.onStatusChange?()
            self.stopManagedProtection { succeeded, message in
                Task { @MainActor in
                    self.protectionQuiescencePending = false
                    guard self.runningDisplayAction?.id == id else { return }
                    guard succeeded else {
                        let failure = message ?? "Automation cleanup could not be verified."
                        self.protectionQuiescenceFailure = failure
                        let first = action.steps[0]
                        let uuid = first.target?.uuid ?? ""
                        stepResults.append(AppControlActionStepResult(
                            index: 1, targetUUID: uuid, effect: first.effect.rawValue,
                            outcome: .failed,
                            desktopSummary: Self.bounded("Automation cleanup needs attention: \(failure)")
                        ))
                        stoppingOutcome = .failed
                        stoppingAtIndex = 1
                        appendNotRun(from: 1)
                        finishRun()
                        return
                    }
                    self.protectionQuiescenceFailure = nil
                    runStep(0)
                }
            }
        } else {
            runStep(0)
        }
    }

    private static func bounded(_ text: String) -> String { bounded(text, byteLimit: 120) }

    private static func boundedActionStepText(_ text: String) -> String { bounded(text, byteLimit: 64) }

    private static func bounded(_ text: String, byteLimit: Int) -> String {
        let safeText = String(text.unicodeScalars.map { scalar -> String in
            if CharacterSet.controlCharacters.contains(scalar) || scalar == "\\" || scalar == "\"" {
                return " "
            }
            return String(scalar)
        }.joined())
        guard safeText.utf8.count > byteLimit else { return safeText }
        var result = ""
        for scalar in safeText.unicodeScalars {
            guard result.utf8.count + scalar.utf8.count + 3 <= byteLimit else { break }
            result.unicodeScalars.append(scalar)
        }
        return result + "…"
    }

    private static func actionDisplayStatuses(
        _ statuses: [AppControlDisplayStatus],
        targetUUIDs: [String],
        includeInputEvidence: Bool
    ) -> [AppControlDisplayStatus] {
        targetUUIDs.map { targetUUID in
            if let status = statuses.first(where: {
                $0.targetUUID.caseInsensitiveCompare(targetUUID) == .orderedSame
            }) {
                return AppControlDisplayStatus(
                    targetUUID: status.targetUUID,
                    observedState: status.observedState,
                    operation: status.operation,
                    recoveryNeeded: status.recoveryNeeded,
                    lastInputOutcome: includeInputEvidence ? status.lastInputOutcome.map(Self.boundedInputOutcome) : nil
                )
            }
            return AppControlDisplayStatus(
                targetUUID: targetUUID,
                observedState: "unavailable",
                operation: "idle",
                recoveryNeeded: false,
                lastInputOutcome: nil
            )
        }
    }

    private static func boundedInputOutcome(_ outcome: DisplayInputOutcome) -> DisplayInputOutcome {
        DisplayInputOutcome(
            state: outcome.state,
            requestedInput: outcome.requestedInput,
            observedInput: outcome.observedInput,
            detail: outcome.detail.map(Self.bounded),
            recoveryCommand: outcome.recoveryCommand.map(Self.bounded)
        )
    }

    func makeHideRequest(targetUUID: String, actionLeaseID: UUID? = nil) throws -> DisplayHideRequest {
        guard !hideOperation.isBusy else { throw DisplayHideError.actionInProgress }
        guard runningDisplayAction == nil || runningDisplayAction?.id == actionLeaseID else {
            throw DisplayHideError.actionInProgress
        }
        guard experimentalFeaturesEnabled else {
            throw DisplayHideError.unavailable("Turn on Experimental features in General to remove a display from the desktop.")
        }
        guard let configuration = hidePreferences[targetUUID] else {
            throw DisplayHideError.unavailable("Turn on Remove from desktop for this display first.")
        }
        if let refusal = hideReadiness(for: configuration, actionLeaseID: actionLeaseID) { throw refusal }
        guard let source = configuration.source else {
            throw DisplayHideError.unavailable("Choose a display to mirror onto.")
        }
        return hideRequest(target: configuration.target, source: source, configuration: configuration)
    }

    /// Hides a display right away in its style: blacked out, or removed from
    /// the desktop. The outcome is kept in `displayResults` and passed to `completion`.
    func hide(
        targetUUID: String,
        style: DisplayHideStyle = .configured,
        manualAction: DisplayAction? = nil,
        manualActionStepIndex: Int? = nil,
        actionLeaseID: UUID? = nil,
        completion: ((DisplayOperationResult) -> Void)? = nil
    ) {
        guard runningDisplayAction == nil || runningDisplayAction?.id == actionLeaseID else {
            refuse(.hide, targetUUID: targetUUID, error: DisplayHideError.recoveryBlocksAction(displayActionBusyMessage), completion: completion)
            return
        }
        cancelPendingSleepHideResume()
        if isBlackoutHidden(targetUUID) {
            refuse(.hide, targetUUID: targetUUID, error: DisplayHideError.unavailable(
                "This display is already hidden."
            ), completion: completion)
            return
        }
        guard let display = displays.first(where: { $0.uuid?.caseInsensitiveCompare(targetUUID) == .orderedSame }) else {
            if style == .removeFromDesktop {
                refuse(.hide, targetUUID: targetUUID, error: DisplayHideError.identityChanged(
                    "This display is disconnected or changed. Reconnect that exact display."
                ), completion: completion)
            } else {
                blackOut(targetUUID: targetUUID, manualAction: manualAction,
                         manualActionStepIndex: manualActionStepIndex, actionLeaseID: actionLeaseID,
                         completion: completion)
            }
            return
        }
        let removesFromDesktop: Bool
        switch style {
        case .configured:
            removesFromDesktop = hideRemovesFromDesktop(display)
        case .blackOut:
            removesFromDesktop = false
        case .removeFromDesktop:
            removesFromDesktop = true
        }
        guard removesFromDesktop else {
            blackOut(targetUUID: targetUUID, manualAction: manualAction,
                     manualActionStepIndex: manualActionStepIndex, actionLeaseID: actionLeaseID,
                     completion: completion)
            return
        }
        let request: DisplayHideRequest
        do {
            request = try makeHideRequest(targetUUID: targetUUID, actionLeaseID: actionLeaseID)
        } catch {
            refuse(.hide, targetUUID: targetUUID, error: error, completion: completion)
            return
        }
        displayResults[request.target.uuid.lowercased()] = nil
        hideOperation = .hiding(request.target.uuid)
        manualActivityDate = now()
        onStatusChange?()
        let finish: (Bool, String?) -> Void = { [weak self] succeeded, message in
            Task { @MainActor in
                self?.finishHideAfterProtectionQuiescence(
                    request,
                    manualAction: manualAction,
                    manualActionStepIndex: manualActionStepIndex,
                    actionLeaseID: actionLeaseID,
                    cleanupSucceeded: succeeded,
                    cleanupFailure: message,
                    completion: completion
                )
            }
        }
        if actionLeaseID != nil { finish(true, nil) }
        else { stopManagedProtection(completion: finish) }
    }

    func makeShowRequest(
        targetUUID: String? = nil,
        actionLeaseID: UUID? = nil,
        refreshStatus: Bool = true
    ) throws -> DisplayShowRequest {
        if let showWait = showWait(actionLeaseID: actionLeaseID) { throw showWait }
        if refreshStatus { refreshHandoffStatus() }
        guard handoffInspectionFailure == nil,
              let handoffStatus,
              handoffStatus.state == .hidden || handoffStatus.state == .recovery else {
            throw DisplayHideError.recoveryBlocksAction(
                handoffInspectionFailure ?? handoffStatus?.reason ?? "No display is hidden by PanelCtl."
            )
        }
        guard let target = targetUUID ?? handoffStatus.target?.uuid,
              let removal = handoffStatus.removal(for: target) else {
            throw DisplayHideError.recoveryBlocksAction("This display isn’t hidden by PanelCtl.")
        }
        guard removal.canShow || canAttemptGuardedRecoveryShow(removal) else {
            throw DisplayHideError.recoveryBlocksAction(
                removal.reason ?? "PanelCtl can’t restore this display right now."
            )
        }
        let input = configuredReturnInput(for: removal.target)
        return DisplayShowRequest(status: handoffStatus, targetUUID: removal.target.uuid,
                                  returnInput: input.value, returnInputWarning: input.warning)
    }

    /// Shows a hidden display right away. Refuses when the journal belongs to
    /// a different display, so a stale action never shows another one.
    func show(targetUUID: String, actionLeaseID: UUID? = nil,
              completion: ((DisplayOperationResult) -> Void)? = nil) {
        guard runningDisplayAction == nil || runningDisplayAction?.id == actionLeaseID else {
            refuse(.show, targetUUID: targetUUID, error: DisplayHideError.recoveryBlocksAction(displayActionBusyMessage), completion: completion)
            return
        }
        cancelPendingSleepHideResume()
        if isBlackoutHidden(targetUUID) {
            showBlackedOut(targetUUID: targetUUID, completion: completion)
            return
        }
        let request: DisplayShowRequest
        do {
            request = try makeShowRequest(
                targetUUID: targetUUID, actionLeaseID: actionLeaseID,
                refreshStatus: actionLeaseID == nil
            )
            guard request.targetUUID.caseInsensitiveCompare(targetUUID) == .orderedSame else {
                throw DisplayHideError.recoveryBlocksAction("This display isn\u{2019}t hidden by PanelCtl.")
            }
        } catch {
            refuse(.show, targetUUID: targetUUID, error: error, completion: completion)
            return
        }
        displayResults[targetUUID.lowercased()] = nil
        hideOperation = .showing(targetUUID)
        onStatusChange?()
        let finish: (Bool, String?) -> Void = { [weak self] succeeded, message in
            Task { @MainActor in
                self?.finishShowAfterProtectionQuiescence(
                    request,
                    actionLeaseID: actionLeaseID,
                    cleanupSucceeded: succeeded,
                    cleanupFailure: message,
                    completion: completion
                )
            }
        }
        if actionLeaseID != nil { finish(true, nil) }
        else { stopManagedProtection(completion: finish) }
    }

    func beginDisplaySleepTransition() {
        sleepWakeSettlement?.cancel()
        sleepWakeSettlement = nil
        screensAwakeAfterSleep = false
        if !sleepLifecycleActive {
            sleepLifecycleActive = true
            sleepHideResumeIntent = runningDisplayAction == nil ? captureSleepHideResumeIntent() : nil
        }
        setDisplayLifecycleTransitioning(true)
    }

    /// A system-wake notification is not proof that displays have finished
    /// waking. Only screensDidWake starts the bounded settle period.
    func displayWakeObserved(screensAwake: Bool) {
        setDisplayLifecycleTransitioning(true)
        refreshDisplays(restartWatcher: true)
        guard sleepLifecycleActive else {
            setDisplayLifecycleTransitioning(false)
            return
        }
        if screensAwake {
            screensAwakeAfterSleep = true
            scheduleSleepWakeSettlement()
        } else if screensAwakeAfterSleep {
            // Out-of-order duplicate notifications restart, never shorten, the settle window.
            scheduleSleepWakeSettlement()
        }
    }

    func displayConfigurationChanged(restartWatcher: Bool) {
        setDisplayLifecycleTransitioning(true)
        refreshDisplays(restartWatcher: restartWatcher)
        if sleepLifecycleActive {
            if screensAwakeAfterSleep { scheduleSleepWakeSettlement() }
        } else {
            setDisplayLifecycleTransitioning(false)
        }
    }

    func cancelPendingSleepHideResume() {
        // Keep wake settlement alive so lifecycle gates clear, but discard the
        // intent before any scheduled re-hide can run.
        sleepHideResumeIntent = nil
    }

    func setDisplayLifecycleTransitioning(_ transitioning: Bool) {
        guard displayLifecycleTransitioning != transitioning else { return }
        displayLifecycleTransitioning = transitioning
        if transitioning, runningDisplayAction != nil { runningActionInterrupted = true }
        if handoffStatus?.hasUnresolvedJournal == true {
            if transitioning {
                protectionRearmRequired = true
                if runningDisplayAction == nil { protectionCoordinator.disable() }
            } else {
                reconcileProtection(restartWatcher: true)
            }
        }
        if !transitioning {
            if runningDisplayAction == nil {
                deferredActionHiddenDisplayReconciliation = false
                reconcileHiddenDisplays()
            } else {
                deferredActionHiddenDisplayReconciliation = true
            }
            if protectionRearmRequired, handoffStatus?.hasUnresolvedJournal != true,
               handoffInspectionFailure == nil, !protectionQuiescencePending,
               protectionQuiescenceFailure == nil {
                rearmProtectionAfterDisplayRecovery()
            }
        }
        onStatusChange?()
    }

    func refreshHandoffStatus() {
        let previous = handoffStatus
        let previousFailure = handoffInspectionFailure
        let wasUnresolved = previous?.hasUnresolvedJournal == true || previousFailure != nil
        let actionRunActive = runningDisplayAction != nil || preflightingDisplayAction
        handoffInspectionFailure = nil
        handoffStatus = inspectHandoff()
        handoffInspectionFailure = handoffStatus?.inspectionFailure
        let isUnresolved = handoffStatus?.hasUnresolvedJournal == true || handoffInspectionFailure != nil
        if preflightingDisplayAction, isUnresolved != wasUnresolved {
            deferredActionRecoveryReconciliation = true
        }
        let enteredHidden = handoffStatus?.state == .hidden && !wasUnresolved
        if enteredHidden {
            manualActivityDate = now()
            protectionRearmRequired = true
        }
        if !actionRunActive && isUnresolved && !wasUnresolved && !hideOperation.isBusy {
            quiesceForExternalRecovery()
        } else if !actionRunActive && !isUnresolved && wasUnresolved,
                  !protectionQuiescencePending,
                  protectionQuiescenceFailure == nil {
            if displayLifecycleTransitioning {
                protectionRearmRequired = true
            } else {
                rearmProtectionAfterDisplayRecovery()
            }
        }
        if previous != handoffStatus || previousFailure != handoffInspectionFailure {
            onStatusChange?()
            if !actionRunActive && !protectionQuiescencePending && isUnresolved {
                reconcileProtection()
            }
        }
    }

    private func captureSleepHideResumeIntent() -> SleepHideResumeIntent? {
        guard handoffInspectionFailure == nil, let status = handoffStatus,
              status.state == .hidden, status.mirrorTopologyVerified,
              let journalID = status.journalID, let baselineIdentity = status.baselineIdentity else { return nil }
        var journalRemovals = status.removals
        var removals = journalRemovals.filter(\.isUnresolved)
        if removals.isEmpty, let target = status.target,
           let removal = status.removal(for: target.uuid) {
            removals = [removal]
        }
        if journalRemovals.isEmpty { journalRemovals = removals }
        guard !removals.isEmpty,
              removals.allSatisfy({ $0.state == "mirrored" && $0.canShow && $0.topologyVerified }) else { return nil }
        return SleepHideResumeIntent(journalID: journalID, baselineIdentity: baselineIdentity,
                                     journalRemovals: journalRemovals, removals: removals)
    }

    private func scheduleSleepWakeSettlement() {
        sleepWakeSettlement?.cancel()
        sleepWakeSettlement = Task { [weak self] in
            guard let self else { return }
            let delay = UInt64(self.displayWakeSettleDelay * 1_000_000_000)
            if delay > 0 { try? await Task.sleep(nanoseconds: delay) }
            guard !Task.isCancelled else { return }
            self.finishSleepWakeSettlement()
        }
    }

    private func finishSleepWakeSettlement() {
        guard sleepLifecycleActive, screensAwakeAfterSleep else { return }
        sleepWakeSettlement = nil
        displays = displayProvider()
        refreshHandoffStatus()
        if let intent = sleepHideResumeIntent {
            resumeSleepHideIntent(intent)
        }
        sleepHideResumeIntent = nil
        sleepLifecycleActive = false
        screensAwakeAfterSleep = false
        setDisplayLifecycleTransitioning(false)
    }

    private func resumeSleepHideIntent(_ intent: SleepHideResumeIntent) {
        guard !hideOperation.isBusy, !protectionQuiescencePending,
              protectionQuiescenceFailure == nil, handoffInspectionFailure == nil,
              let status = handoffStatus,
              status.journalID == intent.journalID,
              status.baselineIdentity == intent.baselineIdentity,
              status.journalIdentity != nil, status.observedTopologyIdentity != nil,
              sameSleepRemovalIdentities(intent.journalRemovals, in: status),
              intent.removals.allSatisfy({ removal in
                  matchesPresentDisplay(removal.target) && matchesAwakeDisplay(removal.source)
              }) else {
            recordSleepResumeFailure(intent.removals.first, reason: "The exact journal, baseline, display identities, or awake lifecycle no longer match. No automatic Show, re-hide, or DDC input replay was attempted.")
            return
        }

        // If macOS kept the verified mirror topology, there is nothing to reapply.
        if status.state == .hidden {
            guard sleepRemovalsStillHidden(intent.journalRemovals, in: status) else {
                recordSleepResumeFailure(intent.removals.first, reason: "The mirror topology no longer verifies after wake. Inspect recovery before continuing.")
                return
            }
            return
        }
        guard status.state == .none,
              sleepRemovalsMatchRestoredBaseline(intent.journalRemovals, in: status) else {
            recordSleepResumeFailure(intent.removals.first, reason: status.reason ?? "Recovery inspection did not verify the saved baseline. Inspect recovery before continuing.")
            return
        }

        hideOperation = .hiding(intent.removals[0].target.uuid)
        onStatusChange?()
        var applied: [DisplayHandoffRemoval] = []
        defer {
            hideOperation = .idle
            onStatusChange?()
        }
        for removal in intent.removals {
            guard !Task.isCancelled, displayLifecycleTransitioning,
                  matchesAwakeDisplay(removal.target), matchesAwakeDisplay(removal.source) else {
                recordSleepResumeFailure(removal, reason: "The display lifecycle or exact target/source identity changed during wake recovery.")
                return
            }
            let target = coreIdentity(removal.target)
            let source = coreIdentity(removal.source)
            guard let status = handoffStatus,
                  let journalID = status.journalID,
                  let journalIdentity = status.journalIdentity,
                  let baselineIdentity = status.baselineIdentity,
                  let observedTopologyIdentity = status.observedTopologyIdentity else {
                recordSleepResumeFailure(removal, reason: "The guarded journal expectation is unavailable after wake.")
                return
            }
            let expectation = DisplayHideWakeExpectation(
                journalID: journalID, journalIdentity: journalIdentity,
                baselineIdentity: baselineIdentity,
                observedTopologyIdentity: observedTopologyIdentity,
                target: target, source: source
            )
            do {
                _ = try sleepResumeHideDisplay(target, source, expectation)
                applied.append(removal)
                displays = displayProvider()
                refreshHandoffStatus()
                guard resumedRemovalsMatch(applied, baselineIdentity: intent.baselineIdentity) else {
                    recordSleepResumeFailure(removal, reason: "The guarded Hide did not verify the expected public-mirror session. The journal is retained; inspect recovery before continuing.")
                    return
                }
            } catch {
                displays = displayProvider()
                refreshHandoffStatus()
                recordSleepResumeFailure(removal, reason: error.localizedDescription)
                return
            }
        }
    }

    private func sameSleepRemovalIdentities(_ expected: [DisplayHandoffRemoval],
                                            in status: DisplayHandoffStatus) -> Bool {
        guard status.removals.count == expected.count else { return false }
        return expected.allSatisfy { wanted in
            guard let actual = status.removals.first(where: { $0.id == wanted.id }) else { return false }
            return sameSleepDisplayIdentity(actual.target, wanted.target) &&
                sameSleepDisplayIdentity(actual.source, wanted.source)
        }
    }

    private func sleepRemovalsStillHidden(_ expected: [DisplayHandoffRemoval],
                                          in status: DisplayHandoffStatus) -> Bool {
        guard sameSleepRemovalIdentities(expected, in: status) else { return false }
        return expected.allSatisfy { wanted in
            guard let actual = status.removals.first(where: { $0.id == wanted.id }) else { return false }
            if wanted.isUnresolved {
                return actual.isUnresolved && actual.state == "mirrored" && actual.canShow && actual.topologyVerified
            }
            return !actual.isUnresolved && actual.state == wanted.state
        }
    }

    private func sleepRemovalsMatchRestoredBaseline(_ expected: [DisplayHandoffRemoval],
                                                    in status: DisplayHandoffStatus) -> Bool {
        sameSleepRemovalIdentities(expected, in: status) && status.removals.allSatisfy {
            !$0.isUnresolved && $0.state == "restored"
        }
    }

    private func matchesPresentDisplay(_ identity: DisplayHandoffIdentity) -> Bool {
        let matches = displays.filter { $0.uuid?.caseInsensitiveCompare(identity.uuid) == .orderedSame }
        guard matches.count == 1, let display = matches.first else { return false }
        return display.id == identity.id && display.vendor == identity.vendor && display.model == identity.model &&
            display.serial == identity.serial && display.online && !display.asleep
    }

    private func matchesAwakeDisplay(_ identity: DisplayHandoffIdentity) -> Bool {
        guard matchesPresentDisplay(identity),
              let display = displays.first(where: { $0.uuid?.caseInsensitiveCompare(identity.uuid) == .orderedSame }) else {
            return false
        }
        return display.active
    }

    private func resumedRemovalsMatch(_ expected: [DisplayHandoffRemoval], baselineIdentity: String) -> Bool {
        guard let status = handoffStatus, handoffInspectionFailure == nil,
              status.state == .hidden, status.baselineIdentity == baselineIdentity,
              status.removals.filter(\.isUnresolved).count == expected.count else { return false }
        return expected.allSatisfy { wanted in
            guard let actual = status.removals.first(where: {
                $0.target.uuid.caseInsensitiveCompare(wanted.target.uuid) == .orderedSame
            }) else { return false }
            return actual.isUnresolved && actual.state == "mirrored" && actual.canShow && actual.topologyVerified &&
                sameSleepDisplayIdentity(actual.target, wanted.target) &&
                sameSleepDisplayIdentity(actual.source, wanted.source)
        }
    }

    private func sameSleepDisplayIdentity(_ lhs: DisplayHandoffIdentity, _ rhs: DisplayHandoffIdentity) -> Bool {
        lhs.uuid.caseInsensitiveCompare(rhs.uuid) == .orderedSame && lhs.id == rhs.id &&
            lhs.vendor == rhs.vendor && lhs.model == rhs.model && lhs.serial == rhs.serial
    }

    private func recordSleepResumeFailure(_ removal: DisplayHandoffRemoval?, reason: String) {
        guard let removal else { return }
        let key = removal.target.uuid.lowercased()
        displayResults[key] = DisplayOperationResult(
            action: .hide, succeeded: false,
            message: "PanelCtl didn’t re-hide this display after waking. \(reason) Open System Settings → Displays to correct the layout, then inspect recovery.",
            inputMessage: nil, inputOutcome: nil, inputNeedsAttention: true
        )
        onStatusChange?()
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
        if !blackedOutDisplayIDs.isEmpty { return "rectangle.fill" }
        if disconnectAutomationPaused {
            return disconnectInspectionFailure != nil || protectionQuiescenceFailure != nil
                ? "exclamationmark.triangle.fill" : "pause.circle.fill"
        }
        return runtimeState.systemImage
    }

    var statusSummary: String {
        if disconnectAutomationPaused {
            if let failure = disconnectInspectionFailure {
                return "Automation paused · disconnect recovery needs attention: \(failure)"
            }
            if let failure = protectionQuiescenceFailure {
                return "Automation paused · cleanup needs attention: \(failure)"
            }
            if disconnectPreparationPending || disconnectPauseCleanupPending {
                return "Automation paused · stopping helpers and verifying cleanup"
            }
            if disconnectStatus?.resolved == false {
                return "Automation paused · waiting for verified disconnect recovery"
            }
            if let until = snoozedUntil {
                return "Automation paused for Full disconnect · snoozed until \(Self.expiryFormatter.string(from: until))"
            }
            return "Automation paused for Full disconnect · preferences and snooze unchanged"
        }
        if protectionPausedForDisplayRecovery { return hiddenMirrorProtectionSummary }
        let enabledRules = automationPreferences.rules.filter(\.isEnabled)
        if let failure = protectionQuiescenceFailure {
            return ProtectionRuntimeState.failed(failure).label
        }
        if !automationPreferences.isEnabled { return ProtectionRuntimeState.disabled.label }
        if let until = snoozedUntil {
            let label = ProtectionRuntimeState.snoozed(until).label
            if let remaining = secondsRemaining, let action = nextAction {
                return "\(label) until \(Self.expiryFormatter.string(from: until)) · \(Self.countdownLabel(remaining)) to \(action)"
            }
            return label
        }
        guard !enabledRules.isEmpty else { return "No rules on" }
        if enabledRules.count == 1 {
            return singleRuleStatusSummary(enabledRules[0])
        }
        let states = enabledRules.map { (rule: $0, state: runtimeState(for: $0)) }
        let topState = states.map(\.state).min { Self.statePriority($0) < Self.statePriority($1) } ?? runtimeState
        let label = Self.statusLabel(for: topState, rule: states.first { $0.state == topState }?.rule)
        let peers = states.filter { Self.sameStateCategory($0.state, topState) }
        let suffix = peers.count == 1 ? peers[0].rule.name : "\(peers.count) rules"
        let base = "\(label) · \(suffix)"
        if let remaining = secondsRemaining, let action = nextAction {
            return "\(base) · \(Self.countdownLabel(remaining)) to \(action)"
        }
        return base
    }

    var statusDetail: String? {
        for rule in automationPreferences.rules where rule.isEnabled {
            let state = runtimeState(for: rule)
            if case .failed(let reason) = state { return reason }
            if case .waitingForDisplays(let reason) = state { return reason }
        }
        return runtimeState.detailMessage
    }

    var controlRuleStatuses: [AppControlRuleStatus] {
        automationPreferences.rules.map { rule in
            let state = runtimeState(for: rule)
            let targetUUIDs = rule.settings.allDisplays
                ? activeDisplays.compactMap(\.uuid).sorted()
                : rule.settings.selectedDisplayUUIDs.sorted()
            let timer = ruleTimer(for: rule, state: state)
            return AppControlRuleStatus(
                id: rule.id, name: rule.name, enabled: rule.isEnabled,
                state: state.controlIdentifier, summary: state.label,
                detail: state.detailMessage, displays: targetUUIDs,
                nextAction: timer?.action ?? nil, secondsRemaining: timer?.remaining ?? nil
            )
        }
    }

    private func singleRuleStatusSummary(_ rule: ProtectionRule) -> String {
        let state = runtimeState(for: rule)
        let label = Self.statusLabel(for: state, rule: rule)
        if !blackedOutDisplayIDs.isEmpty, state != .blackedOut {
            if let timer = ruleTimer(for: rule, state: state),
               let remaining = timer.remaining, let action = timer.action {
                return "Empty-display blackout active · \(Self.countdownLabel(remaining)) to \(action)"
            }
            return "Empty-display blackout active · \(state.label)"
        }
        if let timer = ruleTimer(for: rule, state: state),
           let remaining = timer.remaining, let action = timer.action {
            if case .snoozed(let until) = state {
                return "\(label) until \(Self.expiryFormatter.string(from: until)) · \(Self.countdownLabel(remaining)) to \(action)"
            }
            return "\(label) · \(Self.countdownLabel(remaining)) to \(action)"
        }
        return label
    }

    private static func statusLabel(for state: ProtectionRuntimeState, rule: ProtectionRule?) -> String {
        state == .blackedOut && rule?.settings.mode == .working ? "Dimming active" : state.label
    }

    private static func sameStateCategory(_ lhs: ProtectionRuntimeState, _ rhs: ProtectionRuntimeState) -> Bool {
        switch (lhs, rhs) {
        case (.failed, .failed), (.waitingForDisplays, .waitingForDisplays),
             (.snoozed, .snoozed): return true
        default: return lhs == rhs
        }
    }

    private static func statePriority(_ state: ProtectionRuntimeState) -> Int {
        switch state {
        case .failed: return 0
        case .blackedOut: return 1
        case .sleeping: return 2
        case .waitingForPlayback: return 3
        case .waitingForDisplays: return 4
        case .waitingForInput: return 5
        case .waiting: return 6
        case .starting: return 7
        case .stopping: return 8
        case .disabled, .snoozed, .disconnectPaused: return 9
        }
    }

    func setProtectionEnabled(_ enabled: Bool) {
        guard runningDisplayAction == nil else { return }
        cancelSnooze()
        if preferences.isEnabled == enabled {
            reconcileProtection()
        } else {
            preferences.isEnabled = enabled
        }
    }

    func retryProtection() {
        guard runningDisplayAction == nil else { return }
        if protectionQuiescenceFailure != nil {
            retryAutomationCleanup()
            return
        }
        guard preferences.isEnabled else { return }
        // Explicit retry relaunches helpers that exited with unchanged arguments.
        reconcileProtection(restartWatcher: true)
    }

    func retryAutomationCleanup() {
        guard runningDisplayAction == nil, !protectionQuiescencePending, !hideOperation.isBusy else { return }
        protectionQuiescencePending = true
        onStatusChange?()
        protectionCoordinator.retryCleanup { [weak self] succeeded, message in
            guard let self else { return }
            self.protectionQuiescencePending = false
            if succeeded {
                self.protectionQuiescenceFailure = nil
                if self.disconnectAutomationPaused { self.disconnectPauseCleanupAttempted = true }
                self.rearmProtectionAfterDisplayRecovery()
                self.releaseDisconnectAutomationPauseIfSafe()
            } else {
                self.protectionQuiescenceFailure = message ?? self.protectionQuiescenceFailure ??
                    "Automation cleanup could not be verified."
            }
            self.onStatusChange?()
        }
    }

    func blackoutNow() throws {
        guard runningDisplayAction == nil else { throw RecoveryError.unsafe(displayActionBusyMessage) }
        guard !disconnectAutomationPaused, disconnectInspectionFailure == nil else {
            throw RecoveryError.unsafe("Automation is paused during Full disconnect and verified recovery.")
        }
        guard automationPreferences.rules.contains(where: \.isEnabled) else {
            throw ProtectionConfigurationError.noEnabledRules
        }
        let wasSnoozed = cancelSnooze()
        displays = displayProvider()
        if wasSnoozed { manualActivityDate = now() }
        if !automationPreferences.isEnabled {
            var ruleSet = automationPreferences
            ruleSet.isEnabled = true
            automationPreferences = ruleSet
        }
        reconcileProtection()
        _ = try protectionCoordinator.sendControl(.blackoutNow)
    }

    @discardableResult
    func restoreBlackout() throws -> Bool {
        if runningDisplayAction != nil { return false }
        if disconnectAutomationPaused || disconnectInspectionFailure != nil { return false }
        if protectionPausedForDisplayRecovery && !hiddenMirrorOverlayPolicyEligible { return false }
        guard snoozedUntil == nil, automationPreferences.isEnabled,
              automationPreferences.rules.contains(where: \.isEnabled),
              protectionCoordinator.canReceiveControl else { return false }
        let restored = try protectionCoordinator.sendControl(.restore)
        if restored { manualActivityDate = now() }
        return restored
    }

    func sleepAllNow() throws {
        guard runningDisplayAction == nil else { throw RecoveryError.unsafe(displayActionBusyMessage) }
        guard !disconnectAutomationPaused, disconnectInspectionFailure == nil else {
            throw RecoveryError.unsafe("Display actions are paused during Full disconnect and verified recovery.")
        }
        let wasSnoozed = cancelSnooze()
        if wasSnoozed {
            reconcileProtection()
        }
        try sleepDisplays()
    }

    func snooze(for duration: TimeInterval) {
        guard runningDisplayAction == nil else { return }
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
        guard runningDisplayAction == nil else { return }
        let wasSnoozed = defaults.object(forKey: Self.snoozedUntilKey) != nil
        cancelSnooze()
        guard preferences.isEnabled else { return }
        if wasSnoozed {
            manualActivityDate = now()
        }
        reconcileProtection()
    }

    func refreshDisplays(restartWatcher: Bool = false) {
        if restartWatcher, runningDisplayAction != nil { runningActionInterrupted = true }
        displays = displayProvider()
        refreshHandoffStatus()
        if runningDisplayAction != nil {
            runtimeState = aggregateRuntimeState
            onStatusChange?()
            return
        }
        reconcileHiddenDisplays()
        reconcileProtection(restartWatcher: restartWatcher)
        runtimeState = aggregateRuntimeState
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
        protectionCoordinator.shutdown(completion: completion)
    }

    var snoozedUntil: Date? {
        guard let date = defaults.object(forKey: Self.snoozedUntilKey) as? Date,
              date > now() else {
            return nil
        }
        return date
    }

    var nextAction: String? { soonestRuleTimer?.action }
    var secondsRemaining: Int? { soonestRuleTimer?.remaining }

    private var soonestRuleTimer: (action: String?, remaining: Int?)? {
        let timers = automationPreferences.rules.filter(\.isEnabled).compactMap { rule in
            ruleTimer(for: rule, state: runtimeState(for: rule))
        }.filter { $0.action != nil && $0.remaining != nil }
        return timers.min { ($0.remaining ?? Int.max) < ($1.remaining ?? Int.max) }
    }

    private var stateBeganAt: Date?

    private func runtimeState(for rule: ProtectionRule) -> ProtectionRuntimeState {
        guard rule.isEnabled else { return .disabled }
        if disconnectAutomationPaused {
            if let protectionQuiescenceFailure { return .failed(protectionQuiescenceFailure) }
            if let disconnectInspectionFailure { return .failed(disconnectInspectionFailure) }
            return automationPreferences.isEnabled ? .disconnectPaused : .disabled
        }
        let state = protectionCoordinator.runtimeState(
            for: rule.id,
            automationEnabled: automationPreferences.isEnabled,
            snoozedUntil: snoozedUntil
        )
        if protectionPausedForDisplayRecovery && !hiddenOverlayRuleIDs.contains(rule.id) {
            switch state {
            case .failed, .waitingForDisplays: break
            default: return .disabled
            }
        }
        if observedRuleStates[rule.id] != state {
            observedRuleStates[rule.id] = state
            if case .blackedOut = state { ruleStateBeganAt[rule.id] = now() }
            else { ruleStateBeganAt[rule.id] = nil }
        }
        return state
    }

    private var aggregateRuntimeState: ProtectionRuntimeState {
        if let failure = protectionQuiescenceFailure { return .failed(failure) }
        if let disconnectInspectionFailure { return .failed(disconnectInspectionFailure) }
        guard automationPreferences.isEnabled else { return .disabled }
        if disconnectAutomationPaused { return .disconnectPaused }
        if let until = snoozedUntil { return .snoozed(until) }
        let states = automationPreferences.rules.filter(\.isEnabled).map { runtimeState(for: $0) }
        guard !states.isEmpty else { return .waiting }
        return states.min { Self.statePriority($0) < Self.statePriority($1) } ?? .waiting
    }

    private func ruleTimer(
        for rule: ProtectionRule,
        state: ProtectionRuntimeState
    ) -> (action: String?, remaining: Int?)? {
        let settings = rule.settings
        let action: String?
        switch state {
        case .snoozed:
            action = "resume"
        case .waiting:
            action = settings.mode == .working ? "dim" : "blackout"
        case .blackedOut:
            if hiddenOverlayRuleIDs.contains(rule.id) {
                action = "restore overlay"
            } else {
                switch settings.followUpAction {
                case .restore: action = "restore"
                case .sleepDisplays: action = "sleep"
                case .untilActivity: action = nil
                }
            }
        default:
            action = nil
        }
        guard let action else { return nil }

        let remaining: TimeInterval
        switch state {
        case .snoozed(let until):
            remaining = until.timeIntervalSince(now())
        case .waiting:
            var idle = idleSecondsProvider() ?? 0
            if let manualActivityDate {
                idle = min(idle, max(0, now().timeIntervalSince(manualActivityDate)))
            }
            remaining = settings.idleSeconds - idle
        case .blackedOut:
            guard let beganAt = ruleStateBeganAt[rule.id] ?? stateBeganAt else { return nil }
            let elapsed = now().timeIntervalSince(beganAt)
            let inputElapsed = idleSecondsProvider() ?? elapsed
            if hiddenOverlayRuleIDs.contains(rule.id) {
                let timeout = min(
                    settings.followUpAction == .untilActivity ? 24 * 60 * 60 : settings.followUpSeconds,
                    24 * 60 * 60
                )
                remaining = timeout - (hiddenMirrorOverlayResetsLimitOnInput(rule)
                    ? min(elapsed, inputElapsed) : elapsed)
            } else {
                remaining = settings.followUpSeconds - (resetsBlackoutLimitOnInput(rule)
                    ? min(elapsed, inputElapsed) : elapsed)
            }
        default:
            return nil
        }
        return (action, max(0, Int(ceil(remaining))))
    }

    /// Input extends an overlay's timer only while another visible display stays usable.
    var hiddenMirrorOverlayResetsLimitOnInput: Bool {
        automationPreferences.rules.contains { hiddenMirrorOverlayResetsLimitOnInput($0) }
    }

    private func hiddenMirrorOverlayResetsLimitOnInput(_ rule: ProtectionRule) -> Bool {
        guard rule.settings.mode == .working || rule.settings.keepBlackoutOnInput else { return false }
        let sourceIDs = Set(remainingOverlayDisplays(for: rule.settings).map(\.id))
        let coveredIDs = sourceIDs.union(hiddenMirrorSiblingDisplays(for: rule).map(\.id))
        return !sourceIDs.isEmpty && activeDisplays.contains {
            !coveredIDs.contains($0.id) && !isRemovedDisplay($0.uuid) && !isBlackoutHidden($0.uuid)
        }
    }

    /// Matches helper coverage, including sibling rules and real hidden displays.
    private func resetsBlackoutLimitOnInput(_ rule: ProtectionRule) -> Bool {
        let settings = rule.settings
        guard (settings.mode == .working || settings.keepBlackoutOnInput), !settings.allDisplays else {
            return false
        }
        let siblings = Set(automationPreferences.rules.filter { $0.id != rule.id && $0.isEnabled }
            .flatMap { $0.settings.allDisplays ? [] : Array($0.settings.selectedDisplayUUIDs) })
        let coveredIDs = Set(activeDisplays.compactMap { display -> UInt32? in
            guard let uuid = display.uuid,
                  isBlackoutHidden(uuid) || settings.selectedDisplayUUIDs.contains(where: {
                      $0.caseInsensitiveCompare(uuid) == .orderedSame
                  }) || siblings.contains(where: { $0.caseInsensitiveCompare(uuid) == .orderedSame }) else {
                return nil
            }
            return display.id
        })
        return coveredIDs.count < activeDisplays.count
    }

    private func reconcileProtection(restartWatcher: Bool = false) {
        guard runningDisplayAction == nil else { return }
        var validations: [UUID: ProtectionRuleValidation] = [:]
        var arguments: [UUID: [String]] = [:]
        let hiddenUUIDs = Set(blackoutHiddenDisplays.keys)
        for rule in automationPreferences.rules {
            validations[rule.id] = ProtectionRuleValidator.validate(
                rule, in: automationPreferences, displays: displays, hiddenUUIDs: hiddenUUIDs
            )
        }

        let canRun = automationPreferences.isEnabled && snoozedUntil == nil &&
            protectionQuiescenceFailure == nil && !protectionQuiescencePending &&
            hideOperation == .idle && !displayLifecycleTransitioning &&
            !disconnectAutomationPaused && disconnectInspectionFailure == nil &&
            !disconnectRecoveryBlocked && disconnectLease == nil && disconnectStatus?.resolved != false
        if canRun {
            if protectionPausedForDisplayRecovery {
                for rule in automationPreferences.rules where hiddenOverlayRuleIDs.contains(rule.id) {
                    let sources = verifiedHiddenMirrorSources.filter { source in
                        guard let uuid = source.uuid else { return false }
                        return ruleTargets(rule, uuid: uuid) && !isBlackoutHidden(uuid)
                    }
                    let built: [String]?
                    do {
                        built = try hiddenMirrorArguments(
                            for: sources,
                            settings: rule.settings,
                            otherRuleDisplays: hiddenMirrorSiblingDisplays(for: rule)
                        )
                    }
                    catch { continue }
                    guard var overlay = built else { continue }
                    overlay += ["--panelctl-rule", rule.id.uuidString]
                    arguments[rule.id] = overlay
                    validations[rule.id] = ProtectionRuleValidation(
                        blockingReason: nil, waitingReason: nil, arguments: overlay
                    )
                }
            } else {
                for rule in automationPreferences.rules where rule.isEnabled {
                    if let validation = validations[rule.id], validation.isRunnable,
                       let ruleArguments = validation.arguments {
                        arguments[rule.id] = ruleArguments
                    }
                }
            }
        }
        protectionCoordinator.reconcile(
            ruleSet: automationPreferences,
            validations: validations,
            arguments: arguments,
            forceRestart: restartWatcher || protectionRearmRequired
        )
        runtimeState = aggregateRuntimeState
        if !arguments.isEmpty && protectionCoordinator.hasManagedProcess {
            protectionRearmRequired = false
        }
    }

    private func stopManagedProtection(completion: @escaping (Bool, String?) -> Void) {
        if let quiesceProtection {
            quiesceProtection(completion)
        } else {
            protectionCoordinator.disableForDisplayHide(completion: completion)
        }
    }

    private func quiesceForExternalRecovery() {
        protectionQuiescencePending = true
        onStatusChange?()
        stopManagedProtection { [weak self] succeeded, message in
            Task { @MainActor in
                guard let self else { return }
                self.protectionQuiescencePending = false
                if self.disconnectAutomationPaused { self.disconnectPauseCleanupAttempted = true }
                self.protectionQuiescenceFailure = succeeded
                    ? nil
                    : (message ?? "Automation cleanup could not be verified.")
                let hiddenDisplaysReconciled = self.reconcileDeferredActionHiddenDisplays()
                if !hiddenDisplaysReconciled {
                    if self.handoffStatus?.hasUnresolvedJournal != true,
                       self.handoffInspectionFailure == nil,
                       self.hideOperation == .idle,
                       self.protectionQuiescenceFailure == nil {
                        self.rearmProtectionAfterDisplayRecovery()
                    } else {
                        self.reconcileProtection()
                    }
                }
                self.releaseDisconnectAutomationPauseIfSafe()
                self.onStatusChange?()
            }
        }
    }

    private func rearmProtectionAfterDisplayRecovery() {
        guard !disconnectAutomationPaused,
              disconnectStatus?.resolved != false,
              disconnectInspectionFailure == nil,
              !disconnectRecoveryBlocked,
              handoffStatus?.hasUnresolvedJournal != true,
              handoffInspectionFailure == nil,
              protectionQuiescenceFailure == nil else {
            reconcileProtection()
            return
        }
        manualActivityDate = now()
        protectionRearmRequired = true
        reconcileProtection(restartWatcher: true)
    }

    private func saveAutomationPreferences() {
        guard let data = try? JSONEncoder().encode(automationPreferences) else { return }
        defaults.set(data, forKey: Self.automationPreferencesKey)
    }

    private func saveHidePreferences() {
        guard let data = try? JSONEncoder().encode(hidePreferences) else { return }
        defaults.set(data, forKey: Self.hidePreferencesKey)
    }

    private func saveDisplayActions() {
        guard let data = try? JSONEncoder().encode(displayActions) else { return }
        defaults.set(data, forKey: Self.displayActionsKey)
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

    private func coreIdentity(_ identity: DisplayHandoffIdentity) -> DisplayHideIdentity {
        DisplayHideIdentity(
            uuid: identity.uuid,
            displayID: identity.id,
            name: identity.name,
            vendor: identity.vendor,
            model: identity.model,
            serial: identity.serial
        )
    }

    private func canAttemptGuardedRecoveryShow(_ removal: DisplayHandoffRemoval) -> Bool {
        guard let status = handoffStatus, status.state == .recovery,
              status.inspectionFailure == nil, status.journalID != nil,
              status.removals.contains(where: { $0.id == removal.id && $0.isUnresolved }),
              matchesPresentDisplay(removal.target), matchesPresentDisplay(removal.source),
              matchesAwakeDisplay(removal.source) else { return false }
        return true
    }

    private func isEligibleHideTarget(_ display: DisplayRecord) -> Bool {
        display.active && display.online && !display.asleep &&
            !display.builtin &&
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
    private func configuredReturnInput(for target: DisplayHandoffIdentity) -> (value: UInt8?, warning: String?) {
        guard let configuration = hidePreferences[target.uuid],
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
        manualAction: DisplayAction? = nil,
        manualActionStepIndex: Int? = nil,
        actionLeaseID: UUID? = nil,
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
            if let manualAction, let reason = manualActionValidationFailure(manualAction, stepIndex: manualActionStepIndex) {
                throw DisplayHideError.identityChanged(reason)
            }
            guard let configuration = hidePreferences[request.target.uuid],
                  hideReadiness(for: configuration, allowingCurrentOperation: true, actionLeaseID: actionLeaseID) == nil,
                  let source = configuration.source,
                  request == hideRequest(target: configuration.target, source: source, configuration: configuration) else {
                throw DisplayHideError.identityChanged("The displays or Hide settings changed before Hide began. Try again.")
            }
            let inputOutcome = try hideDisplay(
                coreIdentity(request.target), coreIdentity(request.source), request.awayInput
            )
            returnedInputOutcome = inputOutcome
            displays = displayProvider()
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
        actionLeaseID: UUID? = nil,
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
        let capturedRemoval = request.status.removal(for: request.targetUUID)
        let currentRemoval = handoffStatus?.removal(for: request.targetUUID)
        let canAttemptGuardedRecovery = currentRemoval.map(canAttemptGuardedRecoveryShow) == true
        guard handoffStatus?.hasUnresolvedJournal == true,
              currentRemoval?.canShow == true || canAttemptGuardedRecovery,
              capturedRemoval?.id == currentRemoval?.id,
              handoffStatus?.journalID == request.status.journalID,
              let expectedJournalID = request.status.journalID else {
            notStarted("The displays changed before Show began. Try again.")
            return
        }
        var returnedInputOutcome: DisplayInputOutcome?
        do {
            let showKey = request.status.removals.count > 1
                ? "\(expectedJournalID)|\(request.targetUUID)" : expectedJournalID
            let inputOutcome = try showDisplay(showKey, request.returnInput)
            returnedInputOutcome = inputOutcome
            displays = displayProvider()
            refreshHandoffStatus()
            guard let currentStatus = handoffStatus, handoffInspectionFailure == nil else {
                throw DisplayHideError.recoveryBlocksAction(
                    handoffInspectionFailure ?? "PanelCtl couldn’t confirm this display is back. Check its recovery details."
                )
            }
            let selectedStillRemoved = currentStatus.removal(for: request.targetUUID) != nil
            let selectedRestored = currentStatus.removals.contains(where: {
                $0.target.uuid.caseInsensitiveCompare(request.targetUUID) == .orderedSame &&
                    !$0.isUnresolved && $0.state == "restored"
            })
            let sameSession = currentStatus.journalID == request.status.journalID || !currentStatus.hasUnresolvedJournal
            guard !selectedStillRemoved, sameSession,
                  (!currentStatus.hasUnresolvedJournal || selectedRestored) else {
                throw DisplayHideError.recoveryBlocksAction(
                    currentStatus.reason ?? "PanelCtl couldn’t confirm this display is back. Check its recovery details."
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
        reconcileProtection()
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
           snoozedUntil == nil, !disconnectAutomationPaused {
            resumeProtection()
        }
    }

    // Private disconnect is a separate, manual operation, never a Hide style or
    // app-control command. Inspection and startup never run private recovery.
    private var disconnectEligibilityBlocker: String? {
        if runningDisplayAction != nil { return displayActionBusyMessage }
        if !experimentalFeaturesEnabled { return "Turn on Experimental features in General first." }
        if let disconnectInspectionFailure {
            return "Disconnect recovery cannot be inspected; automation remains paused. Check `panelctl recovery status` and preserve \(disconnectJournalPath). (\(disconnectInspectionFailure))"
        }
        if disconnectLease != nil || disconnectStatus?.resolved == false {
            return "Finish the current disconnect recovery first."
        }
        if let protectionQuiescenceFailure {
            return "Automation cleanup needs attention. Choose Retry Automation Cleanup, then try again. (\(protectionQuiescenceFailure))"
        }
        if protectionQuiescencePending || disconnectPauseCleanupPending {
            return "Waiting for automation cleanup to finish\u{2026}"
        }
        if !blackoutHiddenDisplays.isEmpty || handoffStatus?.hasUnresolvedJournal == true ||
            handoffInspectionFailure != nil || hideOperation.isBusy || displayLifecycleTransitioning {
            return "Show hidden displays and finish recovery first."
        }
        return nil
    }

    var disconnectBlocker: String? {
        if let blocker = disconnectEligibilityBlocker { return blocker }
        if disconnectPreparationPending { return "Stopping automation and verifying cleanup before consent."
        }
        if disconnectRequest != nil || disconnectConsentPending { return "Confirm or cancel the current disconnect."
        }
        if disconnectAutomationPaused { return "Automation is paused until disconnect recovery is verified."
        }
        return nil
    }

    func prepareDisconnect(_ uuid: String) {
        guard runningDisplayAction == nil else { disconnectFailure = displayActionBusyMessage; return }
        disconnectRequest = nil
        disconnectConsentPending = false
        disconnectFailure = nil
        do {
            if let blocker = disconnectBlocker { throw RecoveryError.unsafe(blocker) }
            _ = try disconnectExecutable()
            disconnectAutomationPaused = true
            disconnectPreparationPending = true
            disconnectPreparationCancelled = false
            protectionRearmRequired = true
            runtimeState = aggregateRuntimeState
            onStatusChange?()
            stopForDisconnect { [weak self] succeeded, message in
                self?.finishDisconnectPreparation(
                    uuid: uuid,
                    succeeded: succeeded,
                    message: message
                )
            }
        } catch { disconnectFailure = error.localizedDescription }
    }

    private func stopForDisconnect(completion: @escaping (Bool, String?) -> Void) {
        disconnectPauseCleanupPending = true
        disconnectPauseCleanupAttempted = true
        stopManagedProtection { [weak self] succeeded, message in
            Task { @MainActor in
                guard let self else { return }
                self.disconnectPauseCleanupPending = false
                completion(succeeded, message)
                self.runtimeState = self.aggregateRuntimeState
                self.onStatusChange?()
                self.releaseDisconnectAutomationPauseIfSafe()
            }
        }
    }

    private func finishDisconnectPreparation(
        uuid: String,
        succeeded: Bool,
        message: String?
    ) {
        guard disconnectPreparationPending else { return }
        if !succeeded {
            let failure = message ?? "Automation cleanup could not be verified."
            protectionQuiescenceFailure = failure
            disconnectFailure = "Automation cleanup needs attention: \(failure)"
            disconnectPreparationPending = false
            runtimeState = aggregateRuntimeState
            onStatusChange?()
            return
        }
        protectionQuiescenceFailure = nil
        if disconnectPreparationCancelled {
            disconnectPreparationPending = false
            disconnectPreparationCancelled = false
            releaseDisconnectAutomationPauseIfSafe()
            return
        }

        refreshDisconnectStatus()
        if let blocker = disconnectEligibilityBlocker {
            disconnectPreparationPending = false
            disconnectFailure = blocker
            releaseDisconnectAutomationPauseIfSafe()
            return
        }
        do {
            disconnectRequest = try disconnectController.prepare(targetUUID: uuid)
            disconnectConsentPending = true
        } catch {
            disconnectFailure = error.localizedDescription
            refreshDisconnectStatus()
        }
        disconnectPreparationPending = false
        runtimeState = aggregateRuntimeState
        onStatusChange?()
        releaseDisconnectAutomationPauseIfSafe()
    }

    func cancelDisconnect() {
        disconnectConsentPending = false
        disconnectRequest = nil
        if disconnectPreparationPending {
            disconnectPreparationCancelled = true
            onStatusChange?()
            return
        }
        releaseDisconnectAutomationPauseIfSafe()
    }

    func confirmDisconnect() {
        guard runningDisplayAction == nil else { disconnectFailure = displayActionBusyMessage; return }
        disconnectConsentPending = false
        guard let request = disconnectRequest else { return }
        disconnectRequest = nil // Never persist or reuse consent, even on refusal.
        do {
            guard disconnectAutomationPaused, !disconnectPreparationPending,
                  !disconnectPauseCleanupPending else {
                throw RecoveryError.unsafe("Automation cleanup is not complete; select and confirm again.")
            }
            if let blocker = disconnectEligibilityBlocker { throw RecoveryError.unsafe(blocker) }
            guard !protectionCoordinator.hasManagedProcess else {
                throw RecoveryError.unsafe("Automation helpers are still stopping; wait for cleanup to finish.")
            }
            disconnectLease = try disconnectController.disconnect(request, consent: true, executable: disconnectExecutable())
        } catch { disconnectFailure = error.localizedDescription }
        refreshDisconnectStatus()
        refreshHandoffStatus()
        reconcileProtection()
        releaseDisconnectAutomationPauseIfSafe()
    }

    func reconnectDisconnect(expectedJournalID: String? = nil) {
        guard runningDisplayAction == nil else { disconnectFailure = displayActionBusyMessage; return }
        disconnectFailure = nil
        do {
            if let disconnectInspectionFailure {
                throw RecoveryError.unsafe("disconnect recovery is unreadable; inspect \(disconnectJournalPath) and run `panelctl recovery status` first: \(disconnectInspectionFailure)")
            }
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
        releaseDisconnectAutomationPauseIfSafe()
    }

    func refreshDisconnectStatus() {
        let previous = disconnectStatus
        let previousInspectionFailure = disconnectInspectionFailure
        do {
            let observed = try disconnectController.inspect()
            // A readable public-only journal is not missing private evidence.
            let journalMissing = observed == nil ? try !disconnectController.journalExists() : false
            if observed == nil, previous?.resolved == false || (disconnectRecoveryBlocked && journalMissing) {
                throw RecoveryError.unsafe("disconnect recovery journal is missing; verified recovery cannot be established")
            }
            disconnectStatus = observed
            disconnectInspectionFailure = nil
            if observed?.resolved ?? true {
                disconnectRecoveryBlocked = false
                defaults.set(false, forKey: Self.disconnectRecoveryBlockedKey)
                if observed != nil { disconnectLease = nil }
            } else if observed != nil {
                disconnectRecoveryBlocked = true
                defaults.set(true, forKey: Self.disconnectRecoveryBlockedKey)
                holdDisconnectAutomationPause()
            }
        } catch {
            disconnectInspectionFailure = error.localizedDescription
            disconnectRecoveryBlocked = true
            defaults.set(true, forKey: Self.disconnectRecoveryBlockedKey)
            holdDisconnectAutomationPause()
        }
        let retryBlockedHandoffInspection = disconnectAutomationPaused && disconnectInspectionFailure == nil &&
            disconnectStatus?.resolved != false &&
            (handoffInspectionFailure != nil || handoffStatus?.hasUnresolvedJournal == true)
        if previous != disconnectStatus || previousInspectionFailure != disconnectInspectionFailure {
            refreshHandoffStatus()
            reconcileProtection()
        } else if retryBlockedHandoffInspection {
            // Recovery may hold the handoff journal lock briefly after the disconnect
            // journal verifies, or during a cancelled disconnect with no journal. Retry read-only inspection on countdown ticks so a
            // cached busy result cannot strand automation stopped indefinitely.
            refreshHandoffStatus()
        }
        releaseDisconnectAutomationPauseIfSafe()
    }

    private func holdDisconnectAutomationPause() {
        disconnectAutomationPaused = true
        protectionRearmRequired = true
        guard !disconnectPauseCleanupAttempted,
              !disconnectPauseCleanupPending, !protectionQuiescencePending else {
            runtimeState = aggregateRuntimeState
            onStatusChange?()
            return
        }
        stopForDisconnect { [weak self] succeeded, message in
            guard let self else { return }
            self.protectionQuiescenceFailure = succeeded
                ? nil
                : (message ?? "Automation cleanup could not be verified.")
            self.runtimeState = self.aggregateRuntimeState
            self.onStatusChange?()
        }
        runtimeState = aggregateRuntimeState
        onStatusChange?()
    }

    private func releaseDisconnectAutomationPauseIfSafe() {
        guard disconnectAutomationPaused,
              !disconnectPreparationPending,
              !disconnectPauseCleanupPending,
              !disconnectConsentPending,
              disconnectRequest == nil,
              disconnectLease == nil,
              disconnectStatus?.resolved != false,
              disconnectInspectionFailure == nil,
              !disconnectRecoveryBlocked,
              handoffStatus?.hasUnresolvedJournal != true,
              handoffInspectionFailure == nil,
              !protectionQuiescencePending,
              protectionQuiescenceFailure == nil,
              !protectionCoordinator.hasManagedProcess else { return }
        disconnectAutomationPaused = false
        disconnectPauseCleanupAttempted = false
        disconnectPreparationCancelled = false
        if let storedSnooze = defaults.object(forKey: Self.snoozedUntilKey) as? Date,
           storedSnooze <= now() {
            defaults.removeObject(forKey: Self.snoozedUntilKey)
        }
        rearmProtectionAfterDisplayRecovery()
        runtimeState = aggregateRuntimeState
        onStatusChange?()
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

    nonisolated static func durationLabel(_ seconds: TimeInterval) -> String {
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
