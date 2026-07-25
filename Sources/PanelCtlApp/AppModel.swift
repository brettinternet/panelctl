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
                onStatusChange?()
            }
        }
    }
    @Published private(set) var launchAtLoginEnabled: Bool
    @Published var notice: AppNotice?

    var onStatusChange: (() -> Void)?

    private let defaults: UserDefaults
    private let displayProvider: () -> [DisplayRecord]
    private let service: ProtectionService
    private static let preferencesKey = "blackoutPreferences"
    private static let showMenuBarIconKey = "showMenuBarIcon"

    init(
        defaults: UserDefaults = .standard,
        displayProvider: @escaping () -> [DisplayRecord] = { DisplayInventory.records() }
    ) {
        self.defaults = defaults
        self.displayProvider = displayProvider
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
        switch runtimeState {
        case .waiting:
            return "\(runtimeState.label) · \(Self.durationLabel(preferences.idleSeconds))"
        default:
            return runtimeState.label
        }
    }

    func setProtectionEnabled(_ enabled: Bool) {
        preferences.isEnabled = enabled
    }

    func retryProtection() {
        guard preferences.isEnabled else { return }
        reconcileProtection()
    }

    func blackoutNow() throws {
        displays = displayProvider()
        let arguments = try preferences.commandArguments(for: displays)
        if !preferences.isEnabled {
            preferences.isEnabled = true
        }
        service.run(arguments: arguments)
        try service.sendControl(.blackoutNow)
    }

    @discardableResult
    func restoreBlackout() throws -> Bool {
        guard preferences.isEnabled, service.canReceiveControl else {
            return false
        }
        return try service.sendControl(.restore)
    }

    func refreshDisplays() {
        displays = displayProvider()
        if preferences.isEnabled, !service.hasManagedProcess {
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
        service.shutdown(completion: completion)
    }

    private func reconcileProtection() {
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
        guard preferences.isEnabled else { return serviceState }
        switch serviceState {
        case .starting, .waiting, .blackedOut, .sleeping:
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

    static func durationLabel(_ seconds: TimeInterval) -> String {
        if seconds >= 3600, seconds.truncatingRemainder(dividingBy: 3600) == 0 {
            let hours = Int(seconds / 3600)
            return "\(hours) \(hours == 1 ? "hour" : "hours")"
        }
        let minutes = Int(seconds / 60)
        return "\(minutes) \(minutes == 1 ? "minute" : "minutes")"
    }
}
