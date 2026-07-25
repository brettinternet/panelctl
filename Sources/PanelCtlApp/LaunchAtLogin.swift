import ServiceManagement
import Foundation

enum LaunchAtLoginResult: Equatable {
    case enabled
    case disabled
    case requiresApproval
    case failed(String)
}

enum LaunchAtLogin {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static func setEnabled(_ enabled: Bool) -> LaunchAtLoginResult {
        let service = SMAppService.mainApp
        if enabled, service.status != .enabled, !isInApplicationsFolder {
            return .failed("Move PanelCtl.app to Applications before enabling Launch at Login.")
        }
        do {
            if enabled {
                if service.status == .enabled { return .enabled }
                if service.status == .requiresApproval { return .requiresApproval }
                try service.register()
            } else {
                if service.status == .notRegistered { return .disabled }
                try service.unregister()
            }
        } catch {
            if enabled && service.status == .requiresApproval {
                return .requiresApproval
            }
            return .failed(error.localizedDescription)
        }

        if enabled {
            return service.status == .enabled ? .enabled : .requiresApproval
        }
        return service.status == .notRegistered
            ? .disabled
            : .failed("macOS still reports PanelCtl as a login item.")
    }

    static func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    private static var isInApplicationsFolder: Bool {
        let bundlePath = Bundle.main.bundleURL.standardizedFileURL.path
        let userApplications = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications", isDirectory: true)
            .path + "/"
        return bundlePath.hasPrefix("/Applications/") ||
            bundlePath.hasPrefix(userApplications)
    }
}
