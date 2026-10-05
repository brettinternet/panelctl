import SwiftUI
import PanelCtlCore

struct AutomationSettingsView: View {
    @ObservedObject var model: AppModel

    private static let idleOptions: [TimeInterval] = [60, 2 * 60, 5 * 60, 10 * 60, 15 * 60, 30 * 60, 60 * 60]
    private static let followUpOptions: [TimeInterval] = [5 * 60, 15 * 60, 30 * 60, 60 * 60, 2 * 60 * 60]

    var body: some View {
        Form {
            Section {
                Toggle(isOn: Binding(
                    get: { model.preferences.isEnabled },
                    set: model.setProtectionEnabled
                )) {
                    Text("Automation")
                    Text(model.statusSummary)
                }
                if let problem = model.protectionQuiescenceFailure ?? model.validationMessage ?? model.runtimeState.errorMessage {
                    Label(problem, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if model.protectionQuiescenceFailure != nil {
                    Button("Retry Automation Cleanup", action: model.retryAutomationCleanup)
                        .disabled(model.protectionQuiescencePending || model.hideOperation.isBusy)
                }
            }

            Section {
                Picker("Action", selection: preference(\.mode)) {
                    Text("Black out").tag(BlackoutMode.blocking)
                    Text("Dim").tag(BlackoutMode.working)
                }
                durationPicker("Start after", selection: preference(\.idleSeconds), options: Self.idleOptions)
                if model.preferences.mode == .working {
                    Toggle("Dark overlay", isOn: preference(\.workingOverlayEnabled))
                    if model.preferences.workingOverlayEnabled {
                        percentStepper("Darkness", selection: preference(\.workingOverlayOpacityPercent), range: 1...100)
                    }
                }
                Picker("Afterward", selection: preference(\.followUpAction)) {
                    ForEach(FollowUpAction.allCases) { action in
                        Text(followUpTitle(action)).tag(action)
                    }
                }
                if model.preferences.followUpAction != .untilActivity {
                    durationPicker(
                        model.preferences.followUpAction == .sleepDisplays ? "Sleep after" : "Restore after",
                        selection: preference(\.followUpSeconds),
                        options: Self.followUpOptions
                    )
                }
                if model.preferences.mode == .blocking {
                    Toggle(isOn: preference(\.keepBlackoutOnInput)) {
                        Text("Keep displays black during activity")
                        Text("Activity on another display restarts the Afterward timer instead of restoring. Press Escape with the pointer on a black display to restore it.")
                    }
                }
            } header: {
                Text("When idle")
            } footer: {
                if model.preferences.mode == .working {
                    SectionFooter("Dimmed displays stay usable: clicks pass through, the pointer stays visible and your current app keeps focus.")
                }
            }

            Section {
                Toggle("All displays", isOn: preference(\.allDisplays))
                ForEach(model.activeDisplays, id: \.id) { display in
                    displayRow(display)
                }
                ForEach(model.unavailableSelectedDisplayUUIDs, id: \.self) { uuid in
                    unavailableDisplayRow(uuid)
                }
            } header: {
                Text("Displays")
            } footer: {
                if model.preferences.allDisplays {
                    SectionFooter("Includes displays you connect later.")
                } else if model.activeDisplays.isEmpty {
                    SectionFooter("No active displays found.")
                }
            }

            Section {
                Toggle(isOn: preference(\.blackoutEmptyDisplays)) {
                    Text("Also black out empty displays")
                    Text("A selected display with no windows goes black after 1 second and comes back when a window or the pointer arrives.")
                }
            }

            Section("Pause while") {
                Toggle(isOn: preference(\.deferBlackoutDuringPlayback)) {
                    Text("An app keeps the display awake")
                    Text("Usually video, presentations or screen sharing.")
                }
                Toggle(isOn: preference(\.deferBlackoutWhileCameraInUse)) {
                    Text("A camera is in use")
                    Text("For calls in apps that don’t keep the display awake. PanelCtl never accesses video.")
                }
            }

            Section("Advanced") {
                Toggle(isOn: preference(\.hardwareDimmingEnabled)) {
                    Text("Lower hardware brightness")
                    Text("Experimental. Uses DDC, which not every monitor supports, and restores the captured brightness. Applies to idle and Black Out Now, not empty displays.")
                }
                if model.preferences.hardwareDimmingEnabled {
                    percentStepper("Brightness", selection: preference(\.hardwareBrightnessPercent), range: 0...100)
                }
                if model.preferences.followUpAction == .sleepDisplays {
                    Toggle(isOn: preference(\.keepDisplaysAwake)) {
                        Text("Use PanelCtl’s display sleep timer")
                        Text("Keeps all displays awake until PanelCtl sleeps them while your screen is unlocked. macOS may still sleep the Mac sooner.")
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func displayRow(_ display: DisplayRecord) -> some View {
        let uuid = display.uuid
        return Toggle(isOn: Binding(
            get: {
                guard let uuid else { return false }
                return model.preferences.allDisplays || model.preferences.selectedDisplayUUIDs.contains {
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
        )) {
            Text(display.settingsName)
            Text(display.settingsDetail)
        }
        .disabled(model.preferences.allDisplays || uuid == nil)
    }

    private func unavailableDisplayRow(_ uuid: String) -> some View {
        Toggle(isOn: Binding(
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
        )) {
            Text("Unavailable display")
            Text("\(String(uuid.prefix(8)))… · reconnect it, or turn off to forget it")
        }
    }

    private func durationPicker(
        _ title: String,
        selection: Binding<TimeInterval>,
        options: [TimeInterval]
    ) -> some View {
        // Keep a value saved outside the presets (for example by an older
        // version) selectable instead of showing an empty picker.
        let values = options.contains(selection.wrappedValue)
            ? options
            : (options + [selection.wrappedValue]).sorted()
        return Picker(title, selection: selection) {
            ForEach(values, id: \.self) { value in
                Text(AppModel.durationLabel(value)).tag(value)
            }
        }
    }

    private func percentStepper(
        _ title: String,
        selection: Binding<Int>,
        range: ClosedRange<Int>
    ) -> some View {
        LabeledContent(title) {
            Stepper(value: selection, in: range, step: 5) {
                Text("\(selection.wrappedValue)%")
                    .monospacedDigit()
            }
        }
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

    private func preference<Value>(
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
}
