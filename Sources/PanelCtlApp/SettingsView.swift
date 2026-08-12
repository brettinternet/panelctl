import AppKit
import SwiftUI
import PanelCtlCore

private enum SettingsDestination: Hashable, CaseIterable {
    case automation
    case displays
    case startup
}

private final class DropdownPickerTarget: NSObject {
    var onChange: (Int) -> Void = { _ in }

    @objc func selectionChanged(_ sender: NSPopUpButton) {
        onChange(sender.indexOfSelectedItem)
    }
}

private struct DropdownPicker<Value: Hashable>: NSViewRepresentable {
    @Binding var selection: Value
    let options: [(Value, String)]

    func makeCoordinator() -> DropdownPickerTarget {
        DropdownPickerTarget()
    }

    func makeNSView(context: Context) -> NSPopUpButton {
        let button = NSPopUpButton()
        button.controlSize = .small
        button.target = context.coordinator
        button.action = #selector(DropdownPickerTarget.selectionChanged(_:))
        button.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return button
    }

    func updateNSView(_ button: NSPopUpButton, context: Context) {
        let titles = options.map(\.1)
        if button.itemTitles != titles {
            button.removeAllItems()
            button.addItems(withTitles: titles)
        }
        if let index = options.firstIndex(where: { $0.0 == selection }) {
            button.selectItem(at: index)
        }
        context.coordinator.onChange = { index in
            guard options.indices.contains(index) else { return }
            selection = options[index].0
        }
    }
}

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @State private var selection: SettingsDestination? = .automation

    private let idleOptions: [TimeInterval] = [60, 2 * 60, 5 * 60, 10 * 60, 15 * 60, 30 * 60, 60 * 60]
    private let followUpOptions: [TimeInterval] = [5 * 60, 15 * 60, 30 * 60, 60 * 60, 2 * 60 * 60]

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                List(selection: $selection) {
                    ForEach(SettingsDestination.allCases, id: \.self) { destination in
                        destinationLabel(destination)
                            .padding(.vertical, 2)
                            .tag(destination)
                    }
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)

                sidebarFooter
                    .padding(12)
            }
            .frame(width: 180)

            Divider()
            VStack(spacing: 0) {
                statusHeader
                    .padding(.top, 16)
                    .padding(.horizontal, 16)

                ScrollView(.vertical) {
                    destinationSection
                        .padding(.top, 12)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 16)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
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

    @ViewBuilder
    private func destinationLabel(_ destination: SettingsDestination) -> some View {
        switch destination {
        case .automation:
            Label("Automation", systemImage: "clock")
        case .displays:
            Label("Displays", systemImage: "display.2")
        case .startup:
            Label("Startup", systemImage: "power")
        }
    }

    @ViewBuilder
    private var destinationSection: some View {
        switch selection ?? .automation {
        case .automation:
            automationSection
        case .displays:
            displaysSection
        case .startup:
            startupSection
        }
    }

    private var statusHeader: some View {
        HStack(spacing: 10) {
            Image(systemName: model.statusSystemImage)
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
                if let message = model.validationMessage ?? model.runtimeState.errorMessage {
                    Text(message)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.orange)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
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
        VStack(alignment: .leading, spacing: 12) {
            Text("Automation")
                .font(.system(size: 14, weight: .semibold))
                .padding(.bottom, 4)
            settingRow("Display treatment") {
                    dropdownPicker(
                        selection: preferenceBinding(\.mode),
                        options: [
                            (.blocking, "Blackout"),
                            (.working, "Working dimming")
                        ]
                    )
                }
                if model.preferences.mode == .working {
                    Toggle(
                        "Black overlay",
                        isOn: preferenceBinding(\.workingOverlayEnabled)
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)
                    if model.preferences.workingOverlayEnabled {
                        settingRow("Overlay darkness") {
                            percentageStepper(
                                selection: preferenceBinding(\.workingOverlayOpacityPercent),
                                range: 1...100
                            )
                        }
                    }
                    Text("Input passes through dimmed displays. PanelCtl leaves the pointer visible and keeps your current app focused.")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Activity restarts Restore or Sleep for partial selections. Full-display safety limits stay fixed. Restore from the menu or CLI.")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                settingRow(
                    model.preferences.mode == .working ? "Dim after" : "Black out after"
                ) {
                    durationPicker(
                        selection: preferenceBinding(\.idleSeconds),
                        options: idleOptions
                    )
                }
                settingRow(
                    model.preferences.mode == .working ? "After dimming" : "After blackout"
                ) {
                    dropdownPicker(
                        selection: preferenceBinding(\.followUpAction),
                        options: FollowUpAction.allCases.map {
                            ($0, followUpTitle($0))
                        }
                    )
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
                    Text("Sleeps all displays.")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if model.preferences.followUpAction == .sleepDisplays {
                    Divider()
                    Toggle(
                        "Use PanelCtl’s display sleep timer",
                        isOn: preferenceBinding(\.keepDisplaysAwake)
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Text("Keeps displays awake until the configured sleep time; macOS may sleep the Mac sooner. This assertion applies to all displays.")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Divider()
                Toggle(
                    "Also black out empty displays",
                    isOn: preferenceBinding(\.blackoutEmptyDisplays)
                )
                .frame(maxWidth: .infinity, alignment: .leading)
                Text("Restores when a window or the pointer enters; re-blacks after 1 second empty.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                if model.preferences.mode == .blocking {
                    Divider()
                    Toggle(
                        "Keep blacked-out displays black during activity",
                        isOn: preferenceBinding(\.keepBlackoutOnInput)
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Text("While another display remains usable, activity restarts the Restore or Sleep timer. When every display is blacked out, the timer remains fixed. Press Escape with the pointer on a blacked display to restore.")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Divider()
                Toggle(
                    "Defer when another app keeps the display awake",
                    isOn: preferenceBinding(\.deferBlackoutDuringPlayback)
                )
                .frame(maxWidth: .infinity, alignment: .leading)
                Text("System-wide detection commonly includes playback, presentations, and screen sharing.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                Toggle(
                    "Also defer while a camera is in use",
                    isOn: preferenceBinding(\.deferBlackoutWhileCameraInUse)
                )
                .frame(maxWidth: .infinity, alignment: .leading)
                Text("Useful for calls whose apps do not keep the display awake. Detection is system-wide and does not access camera video.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                Divider()
                Toggle(
                    "Hardware brightness",
                    isOn: preferenceBinding(\.hardwareDimmingEnabled)
                )
                .frame(maxWidth: .infinity, alignment: .leading)
                if model.preferences.hardwareDimmingEnabled {
                    settingRow("Target brightness") {
                        percentageStepper(
                            selection: preferenceBinding(\.hardwareBrightnessPercent),
                            range: 0...100
                        )
                    }
                }
                Text("Experimental · DDC support varies by monitor and connection. PanelCtl only lowers brightness and restores the captured value.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Hardware dimming applies to inactivity and Blackout Now cycles, not empty-display-only blackouts.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var displaysSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Displays")
                .font(.system(size: 14, weight: .semibold))
                .padding(.bottom, 4)
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
                LazyVStack(alignment: .leading, spacing: 9) {
                    ForEach(model.activeDisplays, id: \.id) { display in
                        displayRow(display)
                    }
                    ForEach(model.unavailableSelectedDisplayUUIDs, id: \.self) { uuid in
                        unavailableDisplayRow(uuid)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var startupSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Startup")
                .font(.system(size: 14, weight: .semibold))
                .padding(.bottom, 4)
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
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var sidebarFooter: some View {
        VStack(alignment: .leading, spacing: 2) {
            Button {
                NSApp.terminate(nil)
            } label: {
                Text("Quit")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.vertical, 4)

            Text(model.version)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .padding(.top, 8)
            Link("View on GitHub", destination: AppModel.githubURL)
                .font(.system(size: 11.5))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
        dropdownPicker(
            selection: selection,
            options: options.map {
                ($0, AppModel.durationLabel($0))
            }
        )
    }

    private func dropdownPicker<Value: Hashable>(
        selection: Binding<Value>,
        options: [(Value, String)]
    ) -> some View {
        DropdownPicker(selection: selection, options: options)
            .frame(maxWidth: .infinity)
    }

    private func percentageStepper(
        selection: Binding<Int>,
        range: ClosedRange<Int>
    ) -> some View {
        Stepper(
            value: selection,
            in: range,
            step: 5
        ) {
            Text("\(selection.wrappedValue)%")
                .monospacedDigit()
        }
        .frame(width: 120)
    }

    private func followUpTitle(_ action: FollowUpAction) -> String {
        switch action {
        case .untilActivity:
            if model.preferences.mode == .working {
                return "Stay dim until restored"
            }
            if model.preferences.keepBlackoutOnInput {
                return "Stay black until restored"
            }
            return action.title
        case .restore, .sleepDisplays:
            return action.title
        }
    }

    private func settingRow<Content: View>(
        _ label: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(spacing: 12) {
            Text(label)
                .frame(maxWidth: .infinity, alignment: .leading)
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
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

}
