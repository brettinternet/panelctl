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
    var accessibilityLabel: String? = nil

    func makeCoordinator() -> DropdownPickerTarget {
        DropdownPickerTarget()
    }

    func makeNSView(context: Context) -> NSPopUpButton {
        let button = NSPopUpButton()
        if let accessibilityLabel {
            button.setAccessibilityLabel(accessibilityLabel)
        }
        button.target = context.coordinator
        button.action = #selector(DropdownPickerTarget.selectionChanged(_:))
        button.setContentHuggingPriority(.defaultLow, for: .horizontal)
        button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return button
    }

    func updateNSView(_ button: NSPopUpButton, context: Context) {
        if let accessibilityLabel {
            button.setAccessibilityLabel(accessibilityLabel)
        }
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

private final class InputCodeFieldTarget: NSObject, NSTextFieldDelegate {
    var onChange: (String) -> Void = { _ in }

    func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSTextField else { return }
        onChange(field.stringValue)
    }
}

private struct InputCodeField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let accessibilityLabel: String

    func makeCoordinator() -> InputCodeFieldTarget {
        InputCodeFieldTarget()
    }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.placeholderString = placeholder
        field.isBordered = true
        field.isBezeled = true
        field.bezelStyle = .roundedBezel
        field.setAccessibilityLabel(accessibilityLabel)
        field.delegate = context.coordinator
        context.coordinator.onChange = { text = $0 }
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        field.setAccessibilityLabel(accessibilityLabel)
        if field.stringValue != text {
            field.stringValue = text
        }
        context.coordinator.onChange = { text = $0 }
    }
}

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @State private var selection: SettingsDestination?
    @State private var inputDrafts: [String: String] = [:]
    @State private var inputValidationErrors: [String: String] = [:]

    init(model: AppModel) {
        self.model = model
        _selection = State(initialValue: model.protectionPausedForDisplayRecovery ? .displays : .automation)
    }

    private let idleOptions: [TimeInterval] = [60, 2 * 60, 5 * 60, 10 * 60, 15 * 60, 30 * 60, 60 * 60]
    private let followUpOptions: [TimeInterval] = [5 * 60, 15 * 60, 30 * 60, 60 * 60, 2 * 60 * 60]

    var body: some View {
        GeometryReader { geometry in
            let isCompact = geometry.size.width < 560

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
                .frame(width: isCompact ? 140 : 180)
                .background {
                    Rectangle()
                        .fill(.regularMaterial)
                        .ignoresSafeArea()
                }

                Divider()

                VStack(spacing: 0) {
                    if model.protectionPausedForDisplayRecovery {
                        recoveryBanner
                            .padding(.top, 12)
                            .padding(.horizontal, 16)
                    }
                    statusHeader(isCompact: isCompact)
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
        }
        .onChange(of: model.displayRecoveryFocusRequest) { _ in
            selection = .displays
        }
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

    private var recoveryBanner: some View {
        GroupBox {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Display recovery needs attention")
                        .font(.headline)
                    Text(model.handoffStatus?.hasUnresolvedJournal == true || model.handoffInspectionFailure != nil
                        ? "App-managed protection is paused while the shared display journal is unresolved."
                        : model.protectionQuiescenceFailure.map { "Protection cleanup needs attention: \($0)" }
                            ?? "App-managed protection is paused during the confirmed display operation.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Button("Review display recovery…") {
                    model.requestDisplayRecoveryFocus()
                }
                .accessibilityLabel("Review display recovery")
            }
        }
    }

    private func destinationLabel(_ destination: SettingsDestination) -> some View {
        let title: String
        let systemImage: String
        switch destination {
        case .automation:
            title = "Automation"
            systemImage = "clock"
        case .displays:
            title = "Displays"
            systemImage = "display.2"
        case .startup:
            title = "Startup"
            systemImage = "power"
        }

        return HStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 16))
                .frame(width: 26, height: 22)
                .accessibilityHidden(true)
            Text(title)
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

    private func statusHeader(isCompact: Bool) -> some View {
        GroupBox {
            HStack(spacing: 10) {
                if isCompact {
                    Text("Enabled")
                        .font(.headline)
                    Spacer()
                    Toggle(
                        "",
                        isOn: Binding(
                            get: { model.preferences.isEnabled },
                            set: model.setProtectionEnabled
                        )
                    )
                    .labelsHidden()
                    .toggleStyle(.switch)
                } else {
                    Image(systemName: model.statusSystemImage)
                        .font(.title2.weight(.medium))
                        .foregroundStyle(statusColor)
                        .frame(width: 28)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("OLED Protection")
                            .font(.headline)
                        Text(model.statusSummary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        if let message = model.validationMessage ?? model.protectionQuiescenceFailure ?? model.runtimeState.errorMessage {
                            Text(message)
                                .font(.caption2)
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
            }
        }
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
                    Text("Keeps displays awake until the configured sleep time while your screen is unlocked; macOS may sleep the Mac sooner. This assertion applies to all displays.")
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
            displayRecoveryCard
            Text("OLED protection displays")
                .font(.system(size: 12, weight: .semibold))
            HStack {
                Toggle(
                    "All connected displays",
                    isOn: preferenceBinding(\.allDisplays)
                )
                Spacer()
                Button("Refresh") {
                    model.refreshDisplays()
                }
                .accessibilityLabel("Refresh display inventory and recovery status")
            }
            if model.preferences.allDisplays {
                Text("Includes displays connected while protection is enabled.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
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
            Divider()
            hideDisplaySection
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var displayRecoveryCard: some View {
        if let status = model.handoffStatus, status.hasUnresolvedJournal {
            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Recovery needed · shared display journal")
                        .font(.headline)
                    if let target = status.target {
                        Text("Captured target: \(target.name) · \(target.identityDetail)")
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let source = status.source {
                        Text("Captured mirror source: \(source.name) · \(source.identityDetail)")
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let reason = status.reason {
                        Text(reason)
                            .foregroundStyle(.orange)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Text("Journal: \(status.journalPath)")
                        .font(.caption)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    if status.state == .unsupported {
                        Text(status.inspectionCommand)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    } else if let command = status.recoveryCommand {
                        Text("After reviewing the journal, explicit CLI recovery is available: \(command)")
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    HStack {
                        if status.state == .hidden || status.state == .recovery {
                            Button("Show \(status.target?.name ?? "desktop")…") { model.requestShow() }
                                .disabled(!status.canShow || model.hideOperation.isBusy || model.displayLifecycleTransitioning)
                                .accessibilityLabel("Show captured display desktop")
                        } else {
                            Button("Review display recovery…") {
                                model.requestDisplayRecoveryFocus()
                            }
                        }
                        Button("Refresh") { model.refreshDisplays() }
                    }
                    if !status.canShow, status.state != .unsupported,
                       let refusal = status.reason {
                        Text("Show is unavailable: \(refusal)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .id("display-recovery-card")
        } else if let failure = model.handoffInspectionFailure {
            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Display recovery status unavailable")
                        .font(.headline)
                    Text(failure)
                        .foregroundStyle(.orange)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Journal: \(DisplayHandoff.defaultJournalPath)")
                        .font(.caption)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Refresh") { model.refreshDisplays() }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .id("display-recovery-card")
        }
    }

    private var hideDisplaySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Hide a desktop · Experimental")
                .font(.system(size: 12, weight: .semibold))
            Text("Experimental · mirror hide removes a separate desktop by mirroring another display. The Mac signal stays on and the monitor may show the mirrored picture. Resolution, refresh rate, and HDR may change. Show restores the saved public layout and modes, not HDR, color profiles, rotation, windows, or Spaces. Optional input switching uses DDC only when configured; otherwise use the monitor buttons. Saving settings makes no topology or DDC requests; Check DDC availability is an explicit read-only input check and does not prove switching support.")
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("Idle and empty-display rules control blackout/dimming, not Hide or monitor inputs. Launch at login never hides or shows a desktop.")
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if model.hideDisplayConfigurations.isEmpty {
                Text("No eligible external desktop is available to configure. Connect an awake, active, non-main external display, then Refresh.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(model.hideDisplayConfigurations, id: \.target.uuid) { configuration in
                        hideDisplayCard(configuration)
                    }
                }
            }
        }
    }

    private func hideDisplayCard(_ configuration: DisplayHideConfiguration) -> some View {
        let target = configuration.target
        let matchingDisplay = model.displays.first {
            $0.uuid?.caseInsensitiveCompare(target.uuid) == .orderedSame
        }
        let identityIsCurrent = model.identityIsCurrent(target)
        let frozen = model.hideConfigurationFrozen || model.displayLifecycleTransitioning
        let journalOwnsTarget = model.handoffStatus?.hasUnresolvedJournal == true &&
            model.handoffStatus?.target?.uuid.caseInsensitiveCompare(target.uuid) == .orderedSame
        let readiness = model.hideReadinessMessage(for: configuration)
        var sourceOptions: [(String, String)] = [("", "Choose a display…")]
        for source in model.sourceChoices(for: configuration) {
            let identity = DisplayIdentitySnapshot(source)
            sourceOptions.append((identity.uuid, "\(source.name ?? "Display \(source.id)") · \(identity.identityDetail)"))
        }
        if let saved = configuration.source,
           !sourceOptions.contains(where: { $0.0.caseInsensitiveCompare(saved.uuid) == .orderedSame }) {
            sourceOptions.append((saved.uuid, "\(saved.name ?? "Display \(saved.id)") · Unavailable · \(saved.identityDetail)"))
        }

        return GroupBox {
            VStack(alignment: .leading, spacing: 7) {
                Text("\(target.name ?? "Display \(target.id)") · \(target.identityDetail)")
                    .font(.system(size: 11, weight: .semibold))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Desktop: \(model.observedDesktopState(for: configuration))")
                    .accessibilityLabel("Desktop state: \(model.observedDesktopState(for: configuration))")
                Text("OLED protection: \(model.protectionSelectionState(for: configuration))")
                Toggle(
                    "Enable experimental hide for this display",
                    isOn: Binding(
                        get: { configuration.enabled },
                        set: { enabled in
                            if let matchingDisplay {
                                model.setHideEnabled(enabled, for: matchingDisplay)
                            }
                        }
                    )
                )
                .disabled(frozen || !identityIsCurrent)
                .accessibilityLabel("Enable experimental hide for \(target.name ?? target.uuid)")
                settingRow("Mirror source") {
                    DropdownPicker(
                        selection: Binding(
                            get: { configuration.source?.uuid ?? "" },
                            set: { value in
                                model.setHideSource(value.isEmpty ? nil : value, for: target.uuid)
                            }
                        ),
                        options: sourceOptions,
                        accessibilityLabel: "Mirror source for \(target.name ?? target.uuid)"
                    )
                    .accessibilityLabel("Mirror source for \(target.name ?? target.uuid)")
                    .disabled(frozen || !identityIsCurrent)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                if configuration.enabled {
                    settingRow("Other computer input (on Hide)") {
                        InputCodeField(
                            text: inputBinding(configuration, onHide: true),
                            placeholder: "Off — use monitor buttons",
                            accessibilityLabel: "Other computer input on Hide for \(target.name ?? target.uuid)"
                        )
                        .disabled(frozen || !identityIsCurrent)
                    }
                    settingRow("Mac input (on Show)") {
                        InputCodeField(
                            text: inputBinding(configuration, onHide: false),
                            placeholder: "Off — use monitor buttons",
                            accessibilityLabel: "Mac input on Show for \(target.name ?? target.uuid)"
                        )
                        .disabled(frozen || !identityIsCurrent)
                    }
                    Text("Use dp1 = 0x0F, dp2 = 0x10, hdmi1 = 0x11, hdmi2 = 0x12, any decimal/0x code from 1–255, or leave Off. DDC is optional; monitor buttons always remain available.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    ForEach([true, false], id: \.self) { onHide in
                        if let error = inputValidationErrors[inputDraftKey(configuration, onHide: onHide)] {
                            Text(error)
                                .font(.caption)
                                .foregroundStyle(.orange)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Button("Check DDC availability") {
                        model.checkDDCInputAvailability(for: target.uuid)
                    }
                    .disabled(frozen || !identityIsCurrent)
                    .accessibilityLabel("Check DDC availability for \(target.name ?? target.uuid)")
                    Text(model.ddcInputAvailabilityMessage(for: configuration))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if case .hiding(let uuid) = model.hideOperation,
                   uuid.caseInsensitiveCompare(target.uuid) == .orderedSame {
                    Text("Hiding…")
                        .accessibilityLabel("Hiding \(target.name ?? target.uuid) desktop")
                } else if case .showing(let uuid) = model.hideOperation,
                          uuid.caseInsensitiveCompare(target.uuid) == .orderedSame {
                    Text("Showing…")
                        .accessibilityLabel("Showing \(target.name ?? target.uuid) desktop")
                } else if !journalOwnsTarget, !model.hideOperation.isBusy {
                    Button("Hide \(target.name ?? "display")…") {
                        model.requestHide(targetUUID: target.uuid)
                    }
                    .disabled(readiness != nil || frozen)
                    .accessibilityLabel("Hide \(target.name ?? target.uuid) desktop")
                }
                if let readiness, !journalOwnsTarget {
                    Text(readiness)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !identityIsCurrent {
                    Text("This saved identity is unavailable or changed. Settings remain attached to its UUID and will not bind to a similar display.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !frozen, model.hasHideConfiguration(targetUUID: target.uuid) {
                    Button("Remove hide configuration") {
                        model.removeHideConfiguration(targetUUID: target.uuid)
                    }
                    .accessibilityLabel("Remove hide configuration for \(target.name ?? target.uuid)")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func inputDraftKey(_ configuration: DisplayHideConfiguration, onHide: Bool) -> String {
        "\(configuration.target.uuid.lowercased()):\(onHide ? "away" : "return")"
    }

    private func inputBinding(_ configuration: DisplayHideConfiguration, onHide: Bool) -> Binding<String> {
        let key = inputDraftKey(configuration, onHide: onHide)
        let savedValue = onHide ? configuration.awayInput : configuration.returnInput
        return Binding(
            get: {
                if let draft = inputDrafts[key] { return draft }
                guard let savedValue else { return "" }
                return DDCInput.namedValues.first(where: { $0.value == savedValue })?.name ?? String(savedValue)
            },
            set: { value in
                inputDrafts[key] = value
                let error = onHide
                    ? model.setHideAwayInput(value, for: configuration.target.uuid)
                    : model.setHideReturnInput(value, for: configuration.target.uuid)
                if let error {
                    inputValidationErrors[key] = error
                } else {
                    inputDrafts.removeValue(forKey: key)
                    inputValidationErrors.removeValue(forKey: key)
                }
            }
        )
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
                Text("Closing this window does not stop protection. If the menu icon is hidden, reopen PanelCtl to return here and review display recovery. Launch at login does not hide or show desktops.")
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
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.top, 8)
            Link("View on GitHub", destination: AppModel.githubURL)
                .font(.caption)
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
            .frame(width: 220)
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
        VStack(alignment: .leading, spacing: 5) {
            Text(label)
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
