import AppKit
import SwiftUI
import PanelCtlCore

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

struct DisplaySettingsView: View {
    @ObservedObject var model: AppModel
    @State private var inputDrafts: [String: String] = [:]
    @State private var inputValidationErrors: [String: String] = [:]

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 12) {
                // Recovery never depends on the Experimental flag.
                displayRecoveryCard
                if model.experimentalFeaturesEnabled {
                    hideDisplaySection
                } else {
                    connectedDisplays
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var connectedDisplays: some View {
        VStack(alignment: .leading, spacing: 8) {
            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    if model.activeDisplays.isEmpty {
                        Text("No active displays found.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(model.activeDisplays, id: \.id) { display in
                        HStack(spacing: 10) {
                            Image(systemName: display.builtin ? "laptopcomputer" : "display")
                                .foregroundStyle(.secondary)
                                .frame(width: 22)
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(display.settingsName)
                                Text(display.settingsDetail)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Text("To remove a display from the desktop, turn on Experimental features in General.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
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
            Text("Idle and empty-display rules control blackout/dimming, not Hide or monitor inputs. While hidden, only the verified selected mirror source may receive an overlay; its target also appears black on the Mac input. Brightness dimming and automatic follow-up Sleep are suspended. Launch at login never hides or shows a desktop.")
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if model.hideDisplayConfigurations.isEmpty {
                Text("No eligible external desktop is available to configure. Connect an awake, active, non-main external display, then Refresh.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(alignment: .leading, spacing: 10) {
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
                Text("Automation: \(model.automationSelectionState(for: configuration))")
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
}
