import AppKit
import Foundation
import PanelCtlCore

struct AppNotice: Identifiable, Equatable {
    let id = UUID()
    let title: String
    let message: String
    let opensLoginItemSettings: Bool
}

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
    @Published private(set) var launchAtLoginEnabled: Bool
    @Published var notice: AppNotice?
    @Published private(set) var countdownDate = Date()

    var onStatusChange: (() -> Void)?

    private let defaults: UserDefaults
    private let displayProvider: () -> [DisplayRecord]
    private let now: () -> Date
    private let idleSecondsProvider: () -> TimeInterval?
    private let sleepDisplays: () throws -> Void
    private let service: ProtectionService
    private var snoozeTimer: Timer?
    private var manualActivityDate: Date?
    private static let preferencesKey = "blackoutPreferences"
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
        sleepDisplays: @escaping () throws -> Void = DisplaySleepController.sleep
    ) {
        self.defaults = defaults
        self.displayProvider = displayProvider
        self.now = now
        self.idleSecondsProvider = idleSecondsProvider
        self.sleepDisplays = sleepDisplays
        self.showMenuBarIcon = defaults.object(forKey: Self.showMenuBarIconKey) as? Bool ?? true
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
        savePreferences()
        defaults.set(showMenuBarIcon, forKey: Self.showMenuBarIconKey)
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

    var statusSummary: String {
        if let secondsRemaining, let nextAction {
            switch runtimeState {
            case .snoozed(let until):
                return "\(runtimeState.label) until \(Self.expiryFormatter.string(from: until)) · \(Self.countdownLabel(secondsRemaining)) to \(nextAction)"
            default:
                return "\(runtimeState.label) · \(Self.countdownLabel(secondsRemaining)) to \(nextAction)"
            }
        }
        switch runtimeState {
        default:
            return runtimeState.label
        }
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

    func refreshDisplays() {
        displays = displayProvider()
        if preferences.isEnabled {
            reconcileProtection()
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
            return "blackout"
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
        guard preferences.keepBlackoutOnInput, !preferences.allDisplays else {
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

    private func reconcileProtection() {
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
            service.run(arguments: try preferences.commandArguments(for: displays))
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

    private func savePreferences() {
        guard let data = try? JSONEncoder().encode(preferences) else { return }
        defaults.set(data, forKey: Self.preferencesKey)
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
