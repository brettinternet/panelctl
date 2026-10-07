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
                .disabled(model.runningDisplayAction != nil)
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
                        .disabled(model.runningDisplayAction != nil || model.protectionQuiescencePending || model.hideOperation.isBusy)
                }
                if let until = model.snoozedUntil {
                    HStack {
                        Text("Paused until \(until.formatted(date: .omitted, time: .shortened))")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Resume", action: model.resumeProtection)
                            .disabled(model.runningDisplayAction != nil)
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
                SectionFooter("Rules run on their own when you’re idle. Run now runs just one rule once, even when it’s off or paused, without enabling its automatic trigger. It uses the rule’s effects and Restore or Sleep follow-up, unlike Hide (until Show) or Actions (ordered display steps). Each display can be in only one rule that’s on.")
            }

            Section {
                if let failure = model.displayActionStorageFailure {
                    Label(failure, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                if model.displayActions.actions.isEmpty && model.displayActionStorageFailure == nil {
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
                .disabled(model.displayActionStorageFailure != nil)
            } header: {
                Text("Actions")
            } footer: {
                SectionFooter("Run an Action here, or from scripts or other apps. Steps run in order and stop at the first problem; earlier changes stay in place. Actions never run on their own.")
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
        let result = model.displayActionResults[action.id]
        let stepResults = DisplayActionPresentation.alignedStepResults(for: action, steps: result?.steps)
        let currentStep = model.runningDisplayAction.flatMap { $0.id == action.id ? $0.currentStep : nil }
        return VStack(alignment: .leading, spacing: 8) {
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
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(action.steps.enumerated()), id: \.offset) { offset, step in
                    actionStepRow(
                        step, number: offset + 1, numbered: action.steps.count > 1,
                        result: stepResults?[offset], isRunning: currentStep == offset + 1
                    )
                }
            }
            if let status {
                rowStatus(status, warning: blocker != nil && !running)
            }
            if let result {
                // Each step already shows its own result and any problem.
                let stepShowsProblem = stepResults?.contains(where: DisplayActionPresentation.stepNeedsAttention) ?? false
                if result.outcome != .done, result.summary != status, !stepShowsProblem {
                    rowStatus(result.summary, warning: result.outcome == .recoveryNeeded)
                }
                if stepResults == nil, let steps = result.steps, !steps.isEmpty {
                    // The Action changed since this run, so its results can't sit beside the current steps.
                    Text("Last run")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    ForEach(steps, id: \.index) { step in
                        actionStepResult(step)
                    }
                }
                if let detail = result.detail, result.steps == nil {
                    Text(detail)
                        .foregroundStyle(result.outcome == .partial ? Color.orange : Color.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func actionStepRow(
        _ step: DisplayActionStep,
        number: Int,
        numbered: Bool,
        result: AppControlActionStepResult?,
        isRunning: Bool
    ) -> some View {
        let parts = DisplayActionPresentation.stepParts(for: step, displays: model.displays)
        let attention = result.map(DisplayActionPresentation.stepNeedsAttention) ?? false
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: numbered ? "\(number).circle.fill" : stepSymbol(step.effect))
                .foregroundStyle(.secondary)
                .frame(width: 16)
                .accessibilityLabel("Step \(number)")
                .accessibilityHidden(!numbered)
            VStack(alignment: .leading, spacing: 2) {
                Text(parts.title)
                if let detail = parts.detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let result, attention {
                    stepResultLines(result, attention: true)
                        .font(.caption)
                        .padding(.top, 2)
                }
            }
            Spacer(minLength: 4)
            if isRunning {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Running")
            } else if let result {
                stepResultIcon(result, attention: attention)
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func stepSymbol(_ effect: DisplayActionEffect) -> String {
        switch effect {
        case .show: return "eye"
        case .blackOut, .removeFromDesktop: return "eye.slash"
        }
    }

    private func stepResultIcon(_ step: AppControlActionStepResult, attention: Bool) -> some View {
        let symbol: String
        let color: Color
        if attention {
            (symbol, color) = ("exclamationmark.triangle.fill", .orange)
        } else {
            switch step.outcome {
            case .noOp: (symbol, color) = ("checkmark.circle", .secondary)
            case .notRun: (symbol, color) = ("minus.circle", .secondary)
            default: (symbol, color) = ("checkmark.circle.fill", .green)
            }
        }
        let description = stepResultDescription(step)
        return Image(systemName: symbol)
            .foregroundStyle(color)
            .help(description)
            .accessibilityLabel("Last run: \(description)")
    }

    private func stepResultDescription(_ step: AppControlActionStepResult) -> String {
        var parts = ["\(desktopStateText(for: step)): \(desktopDetail(for: step))"]
        if let input = step.inputOutcome {
            parts.append("Input \(input.rawValue)\(step.inputDetail.map { ": \($0)" } ?? "")")
        } else if let inputDetail = step.inputDetail {
            parts.append("Input: \(inputDetail)")
        }
        return parts.joined(separator: "\n")
    }

    /// Fallback for results that no longer line up with the Action's steps.
    private func actionStepResult(_ step: AppControlActionStepResult) -> some View {
        let attention = DisplayActionPresentation.stepNeedsAttention(step)
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "\(step.index).circle.fill")
                .foregroundStyle(.secondary)
                .frame(width: 16)
                .accessibilityHidden(true)
            stepResultLines(step, attention: attention)
            Spacer(minLength: 4)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Step \(step.index) last run")
    }

    @ViewBuilder
    private func stepResultLines(_ step: AppControlActionStepResult, attention: Bool) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            rowStatus("\(desktopStateText(for: step)) · \(desktopDetail(for: step))", warning: attention)
            if let input = step.inputOutcome {
                rowStatus("Input: \(input.rawValue)\(step.inputDetail.map { " · \($0)" } ?? "")",
                          warning: attention)
            } else if let inputDetail = step.inputDetail {
                rowStatus("Input: \(inputDetail)", warning: true)
            }
            if step.outcome == .recoveryNeeded {
                Button("Review in Displays…") { navigation.showDisplays(selecting: step.targetUUID) }
                    .accessibilityLabel("Review Step \(step.index) recovery in Displays")
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func desktopDetail(for step: AppControlActionStepResult) -> String {
        let reasonPrefix = "Step \(step.index): "
        return step.desktopSummary.hasPrefix(reasonPrefix)
            ? String(step.desktopSummary.dropFirst(reasonPrefix.count)) : step.desktopSummary
    }

    private func desktopStateText(for step: AppControlActionStepResult) -> String {
        switch step.outcome {
        case .done: return "Done"
        case .noOp: return "Already in state"
        case .notRun: return "Not run"
        case .partial where step.inputOutcome != nil: return "Done"
        default: return "Stopped"
        }
    }

    private func ruleRow(_ rule: ProtectionRule) -> some View {
        let status = model.protectionRuleRowStatus(for: rule)
        let summary = ProtectionRulePresentation.summaryParts(for: rule, displays: model.displays)
        let settings = rule.settings
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(rule.name)
                        .font(.body.weight(.semibold))
                        .accessibilityAddTraits(.isHeader)
                    ruleStatusLine(status)
                }
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
            VStack(alignment: .leading, spacing: 4) {
                factLine("timer", summary.trigger)
                factLine(settings.allDisplays || settings.selectedDisplayUUIDs.count > 1 ? "display.2" : "display",
                         summary.targets)
                factLine(afterwardSymbol(settings.followUpAction), summary.afterward)
                ForEach(status.details, id: \.self) { detail in
                    factLine("info.circle", detail)
                }
            }
            HStack {
                Button("Run now") {
                    Task { await model.runProtectionRule(id: rule.id) }
                }
                .disabled(model.protectionRuleRunBlocker(id: rule.id) != nil)
                .accessibilityLabel("Run \(rule.name) once")
            }
            if let message = model.protectionRuleRunStatus(id: rule.id) {
                rowStatus(message, warning: model.controlRunningRule?.id != rule.id &&
                    (model.protectionRuleRunResults[rule.id]?.ok == false || model.protectionRuleRunBlocker(id: rule.id) != nil))
            }
            if model.protectionRuleNeedsDisplayReview(rule) {
                Button("Review in Displays…") {
                    navigation.showDisplays(selecting: model.protectionRuleReviewDisplayUUID(rule))
                }
                .accessibilityLabel("Review in Displays")
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func ruleStatusLine(_ status: ProtectionRuleRowStatus) -> some View {
        if status.isBlocked {
            rowStatus(status.headline, warning: true)
                .font(.subheadline)
        } else {
            HStack(spacing: 5) {
                Circle()
                    .fill(statusColor(status.tone))
                    .frame(width: 7, height: 7)
                    .accessibilityHidden(true)
                Text(status.headline)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func statusColor(_ tone: ProtectionRuleRowStatus.Tone) -> Color {
        switch tone {
        case .off: return .secondary.opacity(0.5)
        case .waiting: return .yellow
        case .active: return .green
        case .attention: return .orange
        }
    }

    private func afterwardSymbol(_ action: FollowUpAction) -> String {
        switch action {
        case .untilActivity: return "cursorarrow.motionlines"
        case .restore: return "arrow.uturn.backward"
        case .sleepDisplays: return "moon.zzz"
        }
    }

    private func factLine(_ symbol: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol)
                .frame(width: 16)
                .accessibilityHidden(true)
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)
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
    var editingActionIsRunning: Bool {
        guard let existingID else { return false }
        return existingID == model.runningDisplayAction?.id
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
                } header: {
                    Text("Name")
                }

                Section {
                    ForEach(Array(draft.steps.indices), id: \.self) { index in
                        stepEditor(index)
                    }
                    HStack {
                        Button("Add Step") { addStep() }
                            .accessibilityLabel("Add step \(draft.steps.count + 1)")
                            .disabled(draft.steps.count >= 8)
                        if draft.steps.count >= 8 {
                            Text("An Action can have at most 8 steps.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("Steps")
                } footer: {
                    SectionFooter("Each display can appear only once. Steps run in order and stop at the first problem; earlier changes stay in place.")
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
                    SectionFooter("Run only in the running app. Check app status after an uncertain result.")
                }
            }
            .formStyle(.grouped)

            if let validation {
                Label(validation, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 18)
                    .padding(.top, 8)
                    .textSelection(.enabled)
            }

            HStack {
                if existingID != nil {
                    Button("Delete Action…") { confirmingDelete = true }
                        .accessibilityLabel("Delete Action")
                        .disabled(editingActionIsRunning)
                    Spacer()
                } else {
                    Spacer()
                }
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave || editingActionIsRunning)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
        }
        .frame(minWidth: 420, idealWidth: 520, maxWidth: 680, minHeight: 480, idealHeight: 560, maxHeight: 700)
        .alert("Delete “\(draft.name)”?", isPresented: $confirmingDelete) {
            Button("Delete", role: .destructive) {
                if let existingID { model.deleteDisplayAction(id: existingID) }
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Scripts that run its command will stop working. The displays’ current state and recovery evidence don’t change.")
        }
    }

    @ViewBuilder
    private func stepEditor(_ index: Int) -> some View {
        let number = index + 1
        let step = draft.steps[index]
        Text("Step \(number)")
            .font(.headline)
            .accessibilityAddTraits(.isHeader)
        Picker("Display", selection: Binding(
            get: { step.target?.uuid ?? "" },
            set: { selectDisplay($0, at: index) }
        )) {
            Text("Choose a display").tag("")
            ForEach(availableDisplays(for: index), id: \.id) { display in
                if let uuid = display.uuid { Text(display.automationChoiceLabel).tag(uuid) }
            }
            if let target = step.target,
               !stableDisplays.contains(where: { $0.uuid?.caseInsensitiveCompare(target.uuid) == .orderedSame }) {
                Text("\(DisplayActionPresentation.displayName(for: target, displays: model.displays)) (unavailable)")
                    .tag(target.uuid)
            }
        }
        .accessibilityLabel("Step \(number) display")

        Picker("Effect", selection: Binding(
            get: { step.effect },
            set: { effect in
                updateStep(at: index) { current in
                    current.effect = effect
                    if effect != .removeFromDesktop { current.reviewedRemoval = nil }
                    else if step.effect != .removeFromDesktop { current.reviewedRemoval = nil }
                }
            }
        )) {
            ForEach(DisplayActionEffect.allCases) { effect in Text(effect.title).tag(effect) }
        }
        .accessibilityLabel("Step \(number) effect")

        if step.effect == .removeFromDesktop {
            removalDetails(step, index: index)
        }
        HStack(spacing: 10) {
            Button("Move Up") { moveStep(from: index, to: index - 1) }
                .accessibilityLabel("Move step \(number) up")
                .disabled(index == 0)
            Button("Move Down") { moveStep(from: index, to: index + 1) }
                .accessibilityLabel("Move step \(number) down")
                .disabled(index == draft.steps.count - 1)
            Button("Remove Step", role: .destructive) { removeStep(at: index) }
                .accessibilityLabel("Remove step \(number)")
                .disabled(draft.steps.count == 1)
        }
        .buttonStyle(.borderless)
        .padding(.vertical, 3)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Step \(number) ordering controls")
    }

    @ViewBuilder
    private func removalDetails(_ step: DisplayActionStep, index: Int) -> some View {
        let configuration = step.target.flatMap { model.hidePreferences[$0.uuid] }
        LabeledContent("Mirror onto", value: sourceName(configuration?.source?.uuid))
        LabeledContent("Switch monitor to", value: configuration?.awayInput.map(MonitorInput.name) ?? "Don’t switch")
        if let change = model.displayActionReviewChange(for: draft, stepIndex: index) {
            Label("Step \(index + 1): \(change.message)", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        if let uuid = step.target?.uuid,
           let reason = model.displayActionRemovalSetupReason(for: uuid) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Step \(index + 1): \(reason)")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if model.experimentalFeaturesEnabled {
                    Button("Set Up in Displays…") {
                        dismiss()
                        DispatchQueue.main.async { navigation.showDisplays(selecting: uuid) }
                    }
                    .accessibilityLabel("Set Up step \(index + 1) in Displays")
                }
            }
        }
    }

    private var stableDisplays: [DisplayTile] {
        model.automationDisplayChoices.filter { model.automationDisplayIdentity(for: $0) != nil }
    }

    private func availableDisplays(for index: Int) -> [DisplayTile] {
        let current = draft.steps[index].target?.uuid.lowercased()
        let used = Set(draft.steps.enumerated().compactMap { offset, step in
            offset == index ? nil : step.target?.uuid.lowercased()
        })
        return stableDisplays.filter { display in
            guard let uuid = display.uuid?.lowercased() else { return false }
            return !used.contains(uuid) || uuid == current
        }
    }

    private func selectDisplay(_ uuid: String, at index: Int) {
        guard draft.steps.indices.contains(index) else { return }
        let display = stableDisplays.first(where: { $0.uuid?.caseInsensitiveCompare(uuid) == .orderedSame })
        updateStep(at: index) { step in
            step.target = display.flatMap { model.automationDisplayIdentity(for: $0) }
            step.reviewedRemoval = nil
        }
    }

    private func updateStep(at index: Int, _ update: (inout DisplayActionStep) -> Void) {
        guard draft.steps.indices.contains(index) else { return }
        update(&draft.steps[index])
        saveFailure = nil
    }

    private func addStep() {
        guard draft.steps.count < 8 else { return }
        draft.steps.append(model.makeNewDisplayActionStep(excluding: draft))
        saveFailure = nil
    }

    private func moveStep(from index: Int, to destination: Int) {
        guard draft.steps.indices.contains(index), draft.steps.indices.contains(destination) else { return }
        let step = draft.steps.remove(at: index)
        draft.steps.insert(step, at: destination)
        saveFailure = nil
    }

    private func removeStep(at index: Int) {
        guard draft.steps.count > 1, draft.steps.indices.contains(index) else { return }
        draft.steps.remove(at: index)
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
    @State private var copyConfirmation = false
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

    private var commandLine: String? {
        guard let executable = try? ProtectionService.helperExecutableURL() else { return nil }
        return AppControlCommand.runRule.commandLine(executable: executable.path, ruleID: draft.id)
    }

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
                    ForEach(model.automationDisplayChoices) { display in
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
                    } else if model.automationDisplayChoices.isEmpty {
                        SectionFooter("No displays found.")
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
                        Text("Experimental. Uses DDC, which not every monitor supports, and restores the captured brightness. Applies to idle and one-shot Rule runs, not empty displays.")
                    }
                    if draft.settings.hardwareDimmingEnabled {
                        percentStepper("Brightness", selection: setting(\.hardwareBrightnessPercent), range: 0...100)
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
                            .accessibilityLabel("Copy rule command")
                        }
                    } else {
                        Text("The bundled panelctl command is unavailable in this build.")
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Command")
                } footer: {
                    SectionFooter("Runs the saved rule once in the running app. Save changes before running.")
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

    private func displayRow(_ display: DisplayTile) -> some View {
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
            Text(display.automationChoiceLabel)
            Text(displaySubtitle(for: display))
        }
        .disabled(draft.settings.allDisplays || uuid == nil)
    }

    private func displaySubtitle(for display: DisplayTile) -> String {
        guard let uuid = display.uuid,
              let other = ProtectionRuleValidator.conflictingEnabledRule(
                for: draft,
                in: model.automationPreferences,
                sharing: uuid
              ) else { return display.display?.settingsDetail ?? display.status.label }
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
