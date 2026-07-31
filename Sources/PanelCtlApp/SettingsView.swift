import AppKit
import SwiftUI
import PanelCtlCore

struct SettingsView: View {
    @ObservedObject var model: AppModel

    private let idleOptions: [TimeInterval] = [60, 2 * 60, 5 * 60, 10 * 60, 15 * 60, 30 * 60, 60 * 60]
    private let followUpOptions: [TimeInterval] = [5 * 60, 15 * 60, 30 * 60, 60 * 60, 2 * 60 * 60]

    var body: some View {
        VStack(spacing: 12) {
            statusHeader
            automationSection
            displaysSection
            startupSection
            footer
        }
        .padding(16)
        .frame(width: 490)
        .controlSize(.small)
        .font(.system(size: 13))
        .alert(item: $model.notice) { notice in
            if notice.opensLoginItemSettings {
                return Alert(
                    title: Text(notice.title),
                    message: Text(notice.message),
                    primaryButton: .default(Text("Open System Settings")) {
                        model.openLoginItemSettings()
                    },
                    secondaryButton: .cancel()
                )
            }
            return Alert(
                title: Text(notice.title),
                message: Text(notice.message),
                dismissButton: .default(Text("OK"))
            )
        }
    }

    private var statusHeader: some View {
        HStack(spacing: 10) {
            Image(systemName: model.runtimeState.systemImage)
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(statusColor)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text("OLED Protection")
                    .font(.system(size: 15, weight: .semibold))
                Text(model.statusSummary)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Toggle(
                "Enabled",
                isOn: Binding(
                    get: { model.preferences.isEnabled },
                    set: model.setProtectionEnabled
                )
            )
            .toggleStyle(.switch)
        }
        .padding(11)
        .background(
            RoundedRectangle(cornerRadius: 9)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
        )
    }

    private var automationSection: some View {
        GroupBox("Automation") {
            VStack(spacing: 9) {
                settingRow("Black out after") {
                    durationPicker(
                        selection: preferenceBinding(\.idleSeconds),
                        options: idleOptions
                    )
                }
                settingRow("After blackout") {
                    Picker("", selection: preferenceBinding(\.followUpAction)) {
                        ForEach(FollowUpAction.allCases) { action in
                            Text(action.title).tag(action)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 205)
                }
                if model.preferences.followUpAction != .untilActivity {
                    settingRow(
                        model.preferences.followUpAction == .sleepDisplays
                            ? "Sleep after"
                            : "Restore after"
                    ) {
                        durationPicker(
                            selection: preferenceBinding(\.followUpSeconds),
                            options: followUpOptions
                        )
                    }
                }
                if model.preferences.followUpAction == .sleepDisplays {
                    Text("Sleep sleeps all displays.")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Divider()
                Toggle(
                    "Keep the Mac awake while protection is enabled",
                    isOn: preferenceBinding(\.caffeinate)
                )
                .frame(maxWidth: .infinity, alignment: .leading)
                Text("Caffeinate prevents idle system sleep while enabled; display sleep still works.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Divider()
                Toggle(
                    "Dim supported external displays during blackout",
                    isOn: preferenceBinding(\.dimDisplaysDuringBlackout)
                )
                .frame(maxWidth: .infinity, alignment: .leading)
                Text("Experimental · DDC support varies by monitor and connection. PanelCtl attempts restoration before blackout ends or displays sleep.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.top, 3)
        }
    }

    private var displaysSection: some View {
        GroupBox {
            VStack(spacing: 7) {
                HStack {
                    Toggle(
                        "All connected displays",
                        isOn: preferenceBinding(\.allDisplays)
                    )
                    Spacer()
                    Button("Refresh") {
                        model.refreshDisplays()
                    }
                }
                if model.preferences.allDisplays {
                    Text("Includes displays connected while protection is enabled.")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Divider()
                if displayRowCount == 0 {
                    Text("No active displays found.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 4)
                } else {
                    ScrollView(.vertical) {
                        LazyVStack(alignment: .leading, spacing: 7) {
                            ForEach(model.activeDisplays, id: \.id) { display in
                                displayRow(display)
                            }
                            ForEach(model.unavailableSelectedDisplayUUIDs, id: \.self) { uuid in
                                unavailableDisplayRow(uuid)
                            }
                        }
                    }
                    .frame(height: displayListHeight)
                }
                if let message = model.validationMessage {
                    Text(message)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.orange)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                } else if let message = model.runtimeState.errorMessage {
                    Text(message)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.orange)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.top, 3)
        } label: {
            Text("Displays")
        }
    }

    private var startupSection: some View {
        GroupBox("Startup") {
            VStack(alignment: .leading, spacing: 6) {
                Toggle(
                    "Launch PanelCtl at login",
                    isOn: Binding(
                        get: { model.launchAtLoginEnabled },
                        set: model.setLaunchAtLogin
                    )
                )
                Toggle(
                    "Show menu bar icon",
                    isOn: Binding(
                        get: { model.showMenuBarIcon },
                        set: model.setShowMenuBarIcon
                    )
                )
                Text("Closing this window does not stop protection. If the menu icon is hidden, open PanelCtl again to return here.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 3)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var footer: some View {
        HStack {
            Text("Version \(model.version)")
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
            Spacer()
            Link("View on GitHub", destination: AppModel.githubURL)
                .font(.system(size: 11.5))
            Button("Quit PanelCtl") {
                NSApp.terminate(nil)
            }
        }
        .padding(.horizontal, 2)
    }

    private func displayRow(_ display: DisplayRecord) -> some View {
        let uuid = display.uuid
        return Toggle(
            isOn: Binding(
                get: {
                    guard let uuid else { return false }
                    return model.preferences.selectedDisplayUUIDs.contains {
                        $0.caseInsensitiveCompare(uuid) == .orderedSame
                    }
                },
                set: { selected in
                    guard let uuid else { return }
                    var preferences = model.preferences
                    if selected {
                        preferences.selectedDisplayUUIDs.insert(uuid)
                    } else {
                        preferences.selectedDisplayUUIDs = preferences.selectedDisplayUUIDs.filter {
                            $0.caseInsensitiveCompare(uuid) != .orderedSame
                        }
                    }
                    model.preferences = preferences
                }
            )
        ) {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text(display.name ?? "Display \(display.index)")
                    Text(displayDetail(display))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
        }
        .disabled(model.preferences.allDisplays || uuid == nil)
    }

    private func displayDetail(_ display: DisplayRecord) -> String {
        var details = ["\(display.pixelWidth) × \(display.pixelHeight)"]
        if display.main { details.append("Main") }
        if display.builtin { details.append("Built-in") }
        if display.uuid == nil { details.append("Stable ID unavailable") }
        return details.joined(separator: " · ")
    }

    private func unavailableDisplayRow(_ uuid: String) -> some View {
        Toggle(
            isOn: Binding(
                get: {
                    model.preferences.selectedDisplayUUIDs.contains {
                        $0.caseInsensitiveCompare(uuid) == .orderedSame
                    }
                },
                set: { selected in
                    guard !selected else { return }
                    var preferences = model.preferences
                    preferences.selectedDisplayUUIDs = preferences.selectedDisplayUUIDs.filter {
                        $0.caseInsensitiveCompare(uuid) != .orderedSame
                    }
                    model.preferences = preferences
                }
            )
        ) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Unavailable display")
                Text("\(String(uuid.prefix(8)))… · reconnect or uncheck to remove")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
        .disabled(model.preferences.allDisplays)
    }

    private func durationPicker(
        selection: Binding<TimeInterval>,
        options: [TimeInterval]
    ) -> some View {
        Picker("", selection: selection) {
            ForEach(options, id: \.self) { seconds in
                Text(AppModel.durationLabel(seconds)).tag(seconds)
            }
        }
        .labelsHidden()
        .frame(width: 150)
    }

    private func settingRow<Content: View>(
        _ label: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack {
            Text(label)
            Spacer()
            content()
        }
    }

    private func preferenceBinding<Value>(
        _ keyPath: WritableKeyPath<ProtectionPreferences, Value>
    ) -> Binding<Value> {
        Binding(
            get: { model.preferences[keyPath: keyPath] },
            set: { value in
                var preferences = model.preferences
                preferences[keyPath: keyPath] = value
                model.preferences = preferences
            }
        )
    }

    private var statusColor: Color {
        switch model.runtimeState {
        case .failed: return .orange
        case .blackedOut, .sleeping, .starting, .waiting, .waitingForInput, .waitingForPlayback:
            return .accentColor
        case .snoozed: return .accentColor
        case .waitingForDisplays: return .orange
        case .disabled, .stopping: return .secondary
        }
    }

    private var displayRowCount: Int {
        model.activeDisplays.count + model.unavailableSelectedDisplayUUIDs.count
    }

    private var displayListHeight: CGFloat {
        CGFloat(min(displayRowCount, 4)) * 34
    }
}
