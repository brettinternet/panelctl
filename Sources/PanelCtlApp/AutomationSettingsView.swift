import SwiftUI
import PanelCtlCore

struct AutomationSettingsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var navigation: SettingsNavigation
    @State private var editor: RuleEditorPresentation?
    @State private var actionEditor: DisplayActionEditorPresentation?

    init(model: AppModel, navigation: SettingsNavigation, initialEditor: RuleEditorPresentation? = nil) {
        self.model = model
        self.navigation = navigation
        _editor = State(initialValue: initialEditor)
    }

    var body: some View {
        Form {
            Section {
                Toggle(isOn: Binding(
                    get: { model.automationPreferences.isEnabled },
                    set: model.setProtectionEnabled
                )) {
                    Text("Automation")
                    Text(model.statusSummary)
                }
                if let problem = model.protectionQuiescenceFailure {
                    Label {
                        Text(problem).textSelection(.enabled)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                    }
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                }
                if model.protectionQuiescenceFailure != nil {
                    Button("Retry Automation Cleanup", action: model.retryAutomationCleanup)
                        .disabled(model.protectionQuiescencePending || model.hideOperation.isBusy)
                }
                if let until = model.snoozedUntil {
                    HStack {
                        Text("Paused until \(until.formatted(date: .omitted, time: .shortened))")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Resume", action: model.resumeProtection)
                    }
                }
                if model.automationPreferences.rules.isEmpty {
                    Text("No rules.")
                        .foregroundStyle(.secondary)
                }
                ForEach(model.automationPreferences.rules) { rule in
                    ruleRow(rule)
                }
                Button("Add Rule…") {
                    editor = RuleEditorPresentation(rule: model.makeNewProtectionRule(), isNew: true)
                }
            } header: {
                Text("Rules")
            } footer: {
                SectionFooter("Rules run on their own when you’re idle. Each display can be in only one rule that’s on.")
            }

            Section {
                if model.displayActions.actions.isEmpty {
                    Text("No actions.")
                        .foregroundStyle(.secondary)
                }
                ForEach(model.displayActions.actions) { action in
                    displayActionRow(action)
                }
                Button("Add Action…") {
                    actionEditor = DisplayActionEditorPresentation(
                        action: model.makeNewDisplayAction(selectedDisplayID: navigation.selectedDisplayID),
                        isNew: true
                    )
                }
            } header: {
                Text("Actions")
            } footer: {
                SectionFooter("Run an action here, or from scripts or other apps. Actions never run on their own.")
            }

            if model.automationPreferences.rules.contains(where: { $0.settings.followUpAction == .sleepDisplays }) {
                Section("Display sleep") {
                    Toggle(isOn: Binding(
                        get: { model.automationPreferences.keepDisplaysAwake },
                        set: model.setKeepDisplaysAwake
                    )) {
                        Text("Use PanelCtl’s display sleep timer")
                        Text("Keeps all displays awake until PanelCtl sleeps them while your screen is unlocked. macOS may still sleep the Mac sooner.")
                    }
                }
            }
        }
        .formStyle(.grouped)
        .sheet(item: $editor) { presentation in
            ProtectionRuleEditor(
                model: model,
                rule: presentation.rule,
                existingID: presentation.isNew ? nil : presentation.rule.id,
                isNew: presentation.isNew
            )
        }
        .sheet(item: $actionEditor) { presentation in
            DisplayActionEditor(
                model: model,
                navigation: navigation,
                action: presentation.action,
                existingID: presentation.isNew ? nil : presentation.action.id,
                isNew: presentation.isNew
            )
        }
    }

    private func displayActionRow(_ action: DisplayAction) -> some View {
        let blocker = model.displayActionRunBlocker(for: action)
        let status = model.displayActionStatus(for: action)
        let running = model.runningDisplayActionIDs.contains(action.id)
        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Text(action.name)
                    .font(.body.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 4)
                Button("Edit…") {
                    actionEditor = DisplayActionEditorPresentation(action: action, isNew: false)
                }
                .accessibilityLabel("Edit \(action.name)")
                Button("Run") {
                    model.runDisplayAction(id: action.id)
                }
                .disabled(blocker != nil || running)
                .accessibilityLabel("Run \(action.name)")
            }
            Text(DisplayActionPresentation.summary(for: action, displays: model.displays))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .truncationMode(.tail)
                .fixedSize(horizontal: false, vertical: true)
            rowStatus(status, warning: blocker != nil && !running)
            if let result = model.displayActionResults[action.id] {
                // A plain success is already reflected by the status line.
                if result.outcome != .done, result.summary != status {
                    rowStatus(result.summary, warning: result.outcome == .recoveryNeeded)
                }
                if let detail = result.detail {
                    Text(detail)
                        .foregroundStyle(result.outcome == .partial ? Color.orange : Color.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if result.outcome == .recoveryNeeded {
                    Text("Recovery needed. Review the affected display in Displays.")
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.vertical, 3)
    }

    private func ruleRow(_ rule: ProtectionRule) -> some View {
        let status = model.protectionRuleRowStatus(for: rule)
        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Text(rule.name)
                    .font(.body.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 4)
                Button("Edit…") {
                    editor = RuleEditorPresentation(rule: rule, isNew: false)
                }
                .accessibilityLabel(ProtectionRulePresentation.editAccessibilityLabel(for: rule.name))
                Toggle(isOn: Binding(
                    get: { model.automationPreferences.rule(namedID: rule.id)?.isEnabled ?? false },
                    set: { model.setProtectionRuleEnabled($0, id: rule.id) }
                )) {
                    EmptyView()
                }
                .labelsHidden()
                .accessibilityLabel(ProtectionRulePresentation.ruleSwitchAccessibilityLabel(for: rule.name))
            }
            Text(ProtectionRulePresentation.summary(for: rule, displays: model.displays))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .truncationMode(.tail)
                .fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .top, spacing: 8) {
                rowStatus(status.text, warning: status.isBlocked)
                Spacer(minLength: 4)
                if model.protectionRuleNeedsDisplayReview(rule) {
                    Button("Review in Displays…") {
                        navigation.showDisplays(selecting: model.protectionRuleReviewDisplayUUID(rule))
                    }
                    .accessibilityLabel("Review in Displays")
                }
            }
        }
        .padding(.vertical, 3)
    }

    @ViewBuilder
    private func rowStatus(_ text: String, warning: Bool) -> some View {
        if warning {
            Label {
                Text(text).textSelection(.enabled)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
            }
            .foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true)
        } else {
            Text(text)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct RuleEditorPresentation: Identifiable {
    let rule: ProtectionRule
    let isNew: Bool
    var id: UUID { rule.id }

    init(rule: ProtectionRule, isNew: Bool) {
        self.rule = rule
        self.isNew = isNew
    }
}

struct DisplayActionEditorPresentation: Identifiable {
    let action: DisplayAction
    let isNew: Bool
    var id: UUID { action.id }
}

struct DisplayActionEditor: View {
    @ObservedObject var model: AppModel
    @ObservedObject var navigation: SettingsNavigation
    @Environment(\.dismiss) private var dismiss
    @State private var draft: DisplayAction
    @State private var confirmingDelete = false
    @State private var saveFailure: String?
    @State private var copyConfirmation = false

    private let existingID: UUID?
    private let isNew: Bool

    init(model: AppModel, navigation: SettingsNavigation, action: DisplayAction,
         existingID: UUID?, isNew: Bool) {
        self.model = model
        self.navigation = navigation
        self.existingID = existingID
        self.isNew = isNew
        _draft = State(initialValue: action)
    }

    private var validation: String? {
        saveFailure ?? model.displayActionValidation(for: draft, replacing: existingID)
    }

    private var canSave: Bool { validation == nil }

    /// Shown inline under Remove from desktop, once a display is chosen.
    private var removalSetupReason: String? {
        guard draft.effect == .removeFromDesktop, let target = draft.target else { return nil }
        return model.displayActionRemovalSetupReason(for: target.uuid)
    }

    /// The validation below the form, without repeating the inline setup reason.
    private var validationMessage: String? {
        guard let validation else { return nil }
        if removalSetupReason != nil, saveFailure == nil,
           validation == removalSetupReason ||
            validation == DisplayActionValidationError.experimentalFeaturesRequired.localizedDescription {
            return nil
        }
        return validation
    }

    private var commandLine: String? {
        guard let executable = try? ProtectionService.helperExecutableURL() else { return nil }
        return AppControlCommand.runAction.commandLine(executable: executable.path, actionID: draft.id)
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField("Name", text: $draft.name)
                        .onSubmit { save() }
                }

                Section {
                    Picker("Display", selection: Binding(
                        get: { draft.target?.uuid ?? "" },
                        set: { selectDisplay($0) }
                    )) {
                        Text("Choose a display").tag("")
                        ForEach(stableDisplays, id: \.id) { display in
                            if let uuid = display.uuid {
                                Text(display.settingsName).tag(uuid)
                            }
                        }
                        if let target = draft.target,
                           !stableDisplays.contains(where: { $0.uuid?.caseInsensitiveCompare(target.uuid) == .orderedSame }) {
                            Text("\(DisplayActionPresentation.displayName(for: target, displays: model.displays)) (unavailable)")
                                .tag(target.uuid)
                        }
                    }

                    Picker("Effect", selection: Binding(
                        get: { draft.effect },
                        set: { effect in
                            draft.effect = effect
                            if effect != .removeFromDesktop { draft.reviewedRemoval = nil }
                            saveFailure = nil
                        }
                    )) {
                        ForEach(DisplayActionEffect.allCases) { effect in
                            Text(effect.title).tag(effect)
                        }
                    }

                    if draft.effect == .removeFromDesktop {
                        let configuration = draft.target.flatMap { model.hidePreferences[$0.uuid] }
                        LabeledContent("Mirror onto", value: sourceName(configuration?.source?.uuid))
                        LabeledContent("Switch monitor to", value: configuration?.awayInput.map(MonitorInput.name) ?? "Don’t switch")

                        if draft.target != nil,
                           let change = model.displayActionReviewChange(for: draft) {
                            Label(change.message, systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                                .fixedSize(horizontal: false, vertical: true)
                                .textSelection(.enabled)
                        }
                        if let removalSetupReason {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(removalSetupReason)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                                if model.experimentalFeaturesEnabled {
                                    Button("Set Up in Displays…") {
                                        let uuid = draft.target?.uuid
                                        dismiss()
                                        DispatchQueue.main.async { navigation.showDisplays(selecting: uuid) }
                                    }
                                }
                            }
                        }
                    }
                } footer: {
                    if draft.effect == .removeFromDesktop {
                        SectionFooter("Mirror onto and Switch monitor to are set in Displays.")
                    }
                }

                Section {
                    if let commandLine {
                        HStack(alignment: .top, spacing: 8) {
                            Text(commandLine)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 4)
                            Button(copyConfirmation ? "Copied" : "Copy") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(commandLine, forType: .string)
                                copyConfirmation = true
                            }
                            .accessibilityLabel("Copy action command")
                        }
                    } else {
                        Text("The bundled panelctl command is unavailable in this build.")
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Command")
                } footer: {
                    SectionFooter("Use in scripts or other apps. PanelCtl must be running.")
                }
            }
            .formStyle(.grouped)

            if let validationMessage {
                Label(validationMessage, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 18)
                    .padding(.top, 8)
            }

            HStack {
                if existingID != nil {
                    Button("Delete Action…") { confirmingDelete = true }
                        .accessibilityLabel("Delete Action")
                    Spacer()
                } else {
                    Spacer()
                }
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
        }
        .frame(width: 520, height: 520)
        .alert("Delete “\(draft.name)”?", isPresented: $confirmingDelete) {
            Button("Delete", role: .destructive) {
                if let existingID { model.deleteDisplayAction(id: existingID) }
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Scripts that run its command will stop working. The display’s current state doesn’t change.")
        }
    }

    private var stableDisplays: [DisplayRecord] {
        model.activeDisplays.filter { display in
            guard let uuid = display.uuid else { return false }
            return UUID(uuidString: uuid) != nil
        }
    }

    private func selectDisplay(_ uuid: String) {
        guard let display = stableDisplays.first(where: { $0.uuid?.caseInsensitiveCompare(uuid) == .orderedSame }) else {
            return
        }
        draft.target = DisplayIdentitySnapshot(display)
        if draft.effect == .removeFromDesktop { draft.reviewedRemoval = nil }
        saveFailure = nil
    }

    private func sourceName(_ uuid: String?) -> String {
        guard let uuid else { return "Not configured" }
        return model.displays.first(where: { $0.uuid?.caseInsensitiveCompare(uuid) == .orderedSame })?.settingsName
            ?? "\(uuid.prefix(8))… (unavailable)"
    }

    private func save() {
        do {
            try model.saveDisplayAction(draft, replacing: existingID)
            dismiss()
        } catch {
            saveFailure = error.localizedDescription
        }
    }
}

struct ProtectionRuleEditor: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @FocusState private var nameFocused: Bool
    @State private var draft: ProtectionRule
    @State private var confirmingDelete = false
    @State private var saveFailure: String?

    private let existingID: UUID?
    private let isNew: Bool
    private static let idleOptions: [TimeInterval] = [60, 2 * 60, 5 * 60, 10 * 60, 15 * 60, 30 * 60, 60 * 60]
    private static let followUpOptions: [TimeInterval] = [5 * 60, 15 * 60, 30 * 60, 60 * 60, 2 * 60 * 60]

    init(model: AppModel, rule: ProtectionRule, existingID: UUID?, isNew: Bool) {
        self.model = model
        self.existingID = existingID
        self.isNew = isNew
        _draft = State(initialValue: rule)
    }

    private var validation: ProtectionRuleValidation {
        model.protectionRuleValidation(for: draft, replacing: existingID)
    }

    private var canSave: Bool { validation.allowsSave(isEnabled: draft.isEnabled) }

    private var blockingMessage: String? {
        if let saveFailure { return saveFailure }
        if let nameReason = validation.nameBlockingReason { return nameReason }
        return draft.isEnabled ? validation.blockingReason : nil
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField("Name", text: $draft.name)
                        .focused($nameFocused)
                        .onSubmit { save() }
                    Toggle("On", isOn: $draft.isEnabled)
                }

                Section("When") {
                    durationPicker("Start after", selection: setting(\.idleSeconds), options: Self.idleOptions)
                    Toggle(isOn: setting(\.blackoutEmptyDisplays)) {
                        Text("Also black out empty displays")
                        Text("A selected display with no windows goes black after 1 second and comes back when a window or the pointer arrives.")
                    }
                }

                Section {
                    Toggle("All displays", isOn: setting(\.allDisplays))
                    ForEach(model.activeDisplays, id: \.id) { display in
                        displayRow(display)
                    }
                    ForEach(model.unavailableSelectedDisplayUUIDs(for: draft.settings), id: \.self) { uuid in
                        unavailableDisplayRow(uuid)
                    }
                } header: {
                    Text("Displays")
                } footer: {
                    if draft.settings.allDisplays {
                        SectionFooter("Includes displays you connect later.")
                    } else if model.activeDisplays.isEmpty {
                        SectionFooter("No active displays found.")
                    }
                }

                Section("Effect") {
                    Picker("Effect", selection: setting(\.mode)) {
                        Text("Black out").tag(BlackoutMode.blocking)
                        Text("Dim").tag(BlackoutMode.working)
                    }
                    if draft.settings.mode == .working {
                        Toggle("Dark overlay", isOn: setting(\.workingOverlayEnabled))
                        if draft.settings.workingOverlayEnabled {
                            percentStepper("Darkness", selection: setting(\.workingOverlayOpacityPercent), range: 1...100)
                        }
                    }
                }

                Section {
                    Picker("Afterward", selection: setting(\.followUpAction)) {
                        ForEach(FollowUpAction.allCases) { action in
                            Text(followUpTitle(action)).tag(action)
                        }
                    }
                    if draft.settings.followUpAction != .untilActivity {
                        durationPicker(
                            draft.settings.followUpAction == .sleepDisplays ? "Sleep after" : "Restore after",
                            selection: setting(\.followUpSeconds),
                            options: Self.followUpOptions
                        )
                    }
                    if draft.settings.mode == .blocking {
                        Toggle(isOn: setting(\.keepBlackoutOnInput)) {
                            Text("Keep displays black during activity")
                            Text("Activity on another display restarts the Afterward timer instead of restoring. Press Escape with the pointer on a black display to restore it.")
                        }
                    }
                } header: {
                    Text("Afterward")
                } footer: {
                    if draft.settings.followUpAction == .sleepDisplays {
                        SectionFooter("Sleeps every display, including displays in other rules.")
                    }
                }

                Section("Pause while") {
                    Toggle(isOn: setting(\.deferBlackoutDuringPlayback)) {
                        Text("An app keeps the display awake")
                        Text("Usually video, presentations or screen sharing.")
                    }
                    Toggle(isOn: setting(\.deferBlackoutWhileCameraInUse)) {
                        Text("A camera is in use")
                        Text("For calls in apps that don’t keep the display awake. PanelCtl never accesses video.")
                    }
                }

                Section("Advanced") {
                    Toggle(isOn: setting(\.hardwareDimmingEnabled)) {
                        Text("Lower hardware brightness")
                        Text("Experimental. Uses DDC, which not every monitor supports, and restores the captured brightness. Applies to idle and Black Out Now, not empty displays.")
                    }
                    if draft.settings.hardwareDimmingEnabled {
                        percentStepper("Brightness", selection: setting(\.hardwareBrightnessPercent), range: 0...100)
                    }
                }
            }
            .formStyle(.grouped)

            if let blockingMessage {
                Label {
                    Text(blockingMessage).textSelection(.enabled)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                }
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 18)
                .padding(.top, 8)
            } else if let waitingReason = validation.waitingReason {
                Label(waitingReason, systemImage: "info.circle")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 18)
                    .padding(.top, 8)
            }

            HStack {
                if existingID != nil {
                    Button("Delete Rule…") { confirmingDelete = true }
                        .accessibilityLabel("Delete Rule")
                    Spacer()
                } else {
                    Spacer()
                }
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
        }
        .frame(width: 520, height: 700)
        .alert("Delete “\(draft.name)”?", isPresented: $confirmingDelete) {
            Button("Delete", role: .destructive) {
                if let existingID { model.deleteProtectionRule(id: existingID) }
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Any blackout or dimming from this rule ends. Hidden displays stay hidden.")
        }
        .onAppear {
            guard isNew else { return }
            DispatchQueue.main.async { nameFocused = true }
        }
    }

    private func save() {
        do {
            try model.saveProtectionRule(draft, replacing: existingID)
            dismiss()
        } catch {
            saveFailure = error.localizedDescription
        }
    }

    private func displayRow(_ display: DisplayRecord) -> some View {
        let uuid = display.uuid
        return Toggle(isOn: Binding(
            get: {
                guard let uuid else { return false }
                return draft.settings.allDisplays || draft.settings.selectedDisplayUUIDs.contains {
                    $0.caseInsensitiveCompare(uuid) == .orderedSame
                }
            },
            set: { selected in
                guard let uuid else { return }
                var settings = draft.settings
                if selected {
                    settings.selectedDisplayUUIDs.insert(uuid)
                } else {
                    settings.selectedDisplayUUIDs = settings.selectedDisplayUUIDs.filter {
                        $0.caseInsensitiveCompare(uuid) != .orderedSame
                    }
                }
                draft.settings = settings
            }
        )) {
            Text(display.settingsName)
            Text(displaySubtitle(for: display))
        }
        .disabled(draft.settings.allDisplays || uuid == nil)
    }

    private func displaySubtitle(for display: DisplayRecord) -> String {
        guard let uuid = display.uuid,
              let other = ProtectionRuleValidator.conflictingEnabledRule(
                for: draft,
                in: model.automationPreferences,
                sharing: uuid
              ) else { return display.settingsDetail }
        return "Also in “\(other.name)”"
    }

    private func unavailableDisplayRow(_ uuid: String) -> some View {
        Toggle(isOn: Binding(
            get: {
                draft.settings.selectedDisplayUUIDs.contains {
                    $0.caseInsensitiveCompare(uuid) == .orderedSame
                }
            },
            set: { selected in
                guard !selected else { return }
                var settings = draft.settings
                settings.selectedDisplayUUIDs = settings.selectedDisplayUUIDs.filter {
                    $0.caseInsensitiveCompare(uuid) != .orderedSame
                }
                draft.settings = settings
            }
        )) {
            Text("Unavailable display")
            Text("\(String(uuid.prefix(8)))… · reconnect it, or turn off to forget it")
        }
        .accessibilityLabel("Forget unavailable display \(String(uuid.prefix(8)))")
    }

    private func durationPicker(
        _ title: String,
        selection: Binding<TimeInterval>,
        options: [TimeInterval]
    ) -> some View {
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
            if draft.settings.mode == .working {
                return "Stay dim until restored"
            }
            if draft.settings.keepBlackoutOnInput {
                return "Stay black until restored"
            }
            return action.title
        case .restore, .sleepDisplays:
            return action.title
        }
    }

    private func setting<Value>(
        _ keyPath: WritableKeyPath<ProtectionPreferences, Value>
    ) -> Binding<Value> {
        Binding(
            get: { draft.settings[keyPath: keyPath] },
            set: { value in
                var settings = draft.settings
                settings[keyPath: keyPath] = value
                draft.settings = settings
            }
        )
    }
}
