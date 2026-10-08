import AppKit
import SwiftUI
import PanelCtlCore

struct DisplaySettingsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var navigation: SettingsNavigation
    /// Input codes being typed while "Other…" is chosen, by tile ID.
    @State private var customInputs: [String: String] = [:]

    var body: some View {
        let tiles = model.displayTiles
        let selected = model.tile(selecting: navigation.selectedDisplayID)
        VStack(spacing: 0) {
            DisplayArrangement(
                tiles: tiles,
                selectedID: selected?.id,
                attentionIDs: Set(model.displayResults.filter(\.value.needsAttention).keys)
            ) { navigation.selectedDisplayID = $0 }
            Form {
                if let failure = model.protectionQuiescenceFailure {
                    Section {
                        HStack(alignment: .firstTextBaseline) {
                            resultLabel(failure, attention: true)
                            Spacer(minLength: 8)
                            Button("Retry Automation Cleanup", action: model.retryAutomationCleanup)
                                .disabled(model.protectionQuiescencePending || model.hideOperation.isBusy)
                        }
                    }
                }
                let pageProblem = model.pageRecoveryProblem
                if let pageProblem {
                    pageRecoverySection(pageProblem)
                }
                if let selected {
                    summarySection(selected)
                    keepWindowsOffSection(selected)
                    hideSection(selected, tiles: tiles)
                    if pageProblem == nil, isJournalTarget(selected), let status = model.handoffStatus {
                        Section {
                            recoveryDetails(status, targetUUID: selected.uuid)
                        }
                    }
                    scriptSection(selected)
                } else {
                    Section {
                        Text("No displays found.")
                            .foregroundStyle(.secondary)
                    }
                }
                if ExperimentalDisconnectControls.isVisible(model: model, targetUUID: selected?.uuid) {
                    ExperimentalDisconnectControls(model: model, targetUUID: selected?.uuid)
                }
            }
            .formStyle(.grouped)
            .disclosureGroupStyle(FullRowDisclosureGroupStyle())
            // Another display is another page: replace its controls instead of
            // animating one display's settings into the next.
            .id(selected?.id)
        }
    }

    // MARK: Summary

    private func summarySection(_ tile: DisplayTile) -> some View {
        Section {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(tile.name)
                        .font(.headline)
                    Text(stateLine(tile))
                        .foregroundStyle(tile.status == .needsRecovery ? Color.orange : Color.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                primaryAction(tile)
            }
            if let result = model.displayResults[tile.id] {
                if !result.succeeded {
                    resultLabel(result.message, attention: true)
                    if result.message.hasPrefix("PanelCtl didn’t re-hide this display after waking.") {
                        Button("Open Displays Settings") { openDisplaysSettings() }
                    }
                }
                if let input = result.inputMessage, !result.inputWarningDismissed {
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        resultLabel(input, attention: result.inputNeedsAttention)
                        if model.canDismissInputWarning(for: tile.id) {
                            Spacer(minLength: 0)
                            Button("Dismiss") { model.dismissInputWarning(for: tile.id) }
                                .accessibilityLabel("Dismiss input warning for \(tile.name)")
                                .help("Hide this warning without changing the monitor input.")
                        }
                    }
                }
                if let command = result.undoInputCommand {
                    CommandCopyRow("Undo input switch", command: command)
                }
            }
            if let note = actionNote(tile) {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func stateLine(_ tile: DisplayTile) -> String {
        switch tile.status {
        case .on:
            return tile.display.map { "On · \($0.settingsDetail)" } ?? "On"
        case .hidden where model.isBlackoutHidden(tile.uuid):
            if tile.display == nil {
                return "Disconnected · blacked out again when it reconnects"
            }
            if model.uncoveredHiddenDisplays.contains(tile.id) {
                return "Hidden, but PanelCtl couldn\u{2019}t cover it. It tries again when displays change."
            }
            return "Blacked out until you show it"
        case .hidden:
            let source = tile.uuid.flatMap { model.handoffStatus?.removal(for: $0)?.source.name }
            return "Removed from the desktop · mirrored onto \(source ?? "another display")"
        case .hiding:
            return "Removing from the desktop…"
        case .showing:
            return "Showing…"
        case .blackedOut:
            return "Blacked out by automation"
        case .asleep:
            return "Asleep"
        case .mirrored:
            return "Mirrored by macOS"
        case .busy:
            return "Another display operation is running."
        case .unavailable:
            return "Disconnected"
        case .needsRecovery:
            return model.displayRecoveryProblem ?? "Needs recovery."
        }
    }

    @ViewBuilder
    private func primaryAction(_ tile: DisplayTile) -> some View {
        if [.hiding, .showing, .busy].contains(tile.status) {
            ProgressView()
                .controlSize(.small)
        } else if let action = tile.action, let uuid = tile.uuid {
            let title = action == .hide ? "Hide" : tile.status == .needsRecovery ? "Restore" : "Show"
            Button(title) {
                if action == .hide {
                    model.hide(targetUUID: uuid)
                } else {
                    model.show(targetUUID: uuid)
                }
            }
            .disabled(tile.actionBlocker != nil)
            .accessibilityLabel("\(title) \(tile.name)")
        } else if tile.status == .needsRecovery {
            // Display changes are checked automatically; this is for fixes made elsewhere.
            Button("Check Again") { model.refreshDisplays() }
                .accessibilityLabel("Check \(tile.name) again")
        }
    }

    /// Why the action can't run, or what it will do.
    private func actionNote(_ tile: DisplayTile) -> String? {
        if let blocker = tile.actionBlocker { return blocker }
        switch tile.action {
        case .show? where model.isBlackoutHidden(tile.uuid):
            return tile.display == nil ? nil : "Or point at it and press Esc."
        case .show?:
            return model.showReturnInputNote(for: tile.uuid)
        case .hide?:
            guard let display = tile.display, !model.hideRemovesFromDesktop(display) else { return nil }
            return "Hide blacks out this display until you show it."
        case nil:
            return nil
        }
    }

    private func resultLabel(_ text: String, attention: Bool) -> some View {
        Label {
            Text(text)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: attention ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .foregroundStyle(attention ? Color.orange : Color.green)
        }
    }

    // MARK: Keep windows off

    @ViewBuilder
    private func keepWindowsOffSection(_ tile: DisplayTile) -> some View {
        if let uuid = tile.uuid, UUID(uuidString: uuid) != nil {
            let display = tile.display
            let hidden = model.isBlackoutHidden(uuid)
            let removes = display.map { model.hideRemovesFromDesktop($0) } ?? false
            if hidden || !removes {
                let configuration = model.hideConfiguration(for: uuid)
                let cover = model.keepWindowsOffCovers[uuid.lowercased()]
                let enabled = hidden ? cover.map { !$0.pausedByUser } ?? false : configuration?.keepWindowsOff != nil
                Section {
                    if hidden {
                        Toggle(isOn: Binding(
                            get: { enabled },
                            set: { model.setHiddenKeepWindowsOff($0, for: uuid) }
                        )) {
                            Text("Keep windows off")
                            Text("Applies to this hide only.")
                        }
                        .accessibilityLabel("Keep windows off \(tile.name) while hidden")
                    } else {
                        let destinations = model.windowMoveDestinationChoices(for: uuid)
                        let selectedDestination = configuration?.keepWindowsOff?.destination ?? .automatic
                        Toggle(isOn: Binding(
                            get: { enabled },
                            set: { model.setKeepWindowsOffEnabled($0, for: uuid) }
                        )) {
                            Text("Also keep windows off")
                            Text("When you hide this display, move new and returning windows to another display.")
                        }
                        .disabled(!enabled && (display.map { !$0.active || !$0.online || $0.asleep } ?? true))
                        .accessibilityLabel("Also keep windows off \(tile.name) when hidden")
                        if enabled {
                            Picker("Move to", selection: Binding(
                                get: { self.destinationKey(selectedDestination) },
                                set: { value in self.selectKeepWindowsOffDestination(value, targetUUID: uuid, choices: destinations) }
                            )) {
                                Text("Automatic").tag("automatic")
                                ForEach(destinations, id: \.id) { destination in
                                    Text(destination.main ? "\(destination.settingsName) (main display)" : destination.settingsName)
                                        .tag(destination.uuid?.lowercased() ?? "")
                                }
                                if case .display(let saved) = selectedDestination,
                                   !destinations.contains(where: { $0.uuid?.caseInsensitiveCompare(saved.uuid) == .orderedSame }) {
                                    Text("\(saved.presentationName) (unavailable)").tag(saved.uuid.lowercased())
                                }
                            }
                        }
                    }
                    if enabled || cover != nil {
                        if model.windowMovePermissionState != .granted {
                            WindowMovePermissionRow(model: model)
                        }
                        if let status = model.keepWindowsOffStatuses[tile.id] {
                            Text(status.description)
                                .font(.caption)
                                .foregroundStyle(status.reason == nil || cover?.pausedByUser == true ? Color.secondary : Color.orange)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                } header: {
                    Text("Windows")
                } footer: {
                    SectionFooter("Moves supported windows on the desktop currently showing on this display; other desktops are left unchanged. Showing the display won’t move windows back. Automation blackouts never move windows.")
                }
            }
        }
    }

    private func destinationKey(_ destination: MoveWindowsDestination) -> String {
        switch destination {
        case .automatic: return "automatic"
        case .display(let identity): return identity.uuid.lowercased()
        }
    }

    private func selectKeepWindowsOffDestination(_ value: String, targetUUID: String, choices: [DisplayRecord]) {
        guard value != "automatic" else {
            model.setKeepWindowsOffDestination(.automatic, for: targetUUID)
            return
        }
        guard let display = choices.first(where: { $0.uuid?.caseInsensitiveCompare(value) == .orderedSame }) else { return }
        model.setKeepWindowsOffDestination(.display(DisplayIdentityReference(display)), for: targetUUID)
    }

    // MARK: Hide setup

    @ViewBuilder
    private func hideSection(_ tile: DisplayTile, tiles: [DisplayTile]) -> some View {
        if !isJournalTarget(tile), let display = tile.display {
            let reason = model.removalIneligibleReason(for: display)
            if !model.experimentalFeaturesEnabled {
                if reason == nil {
                    Section {
                        LabeledContent {
                            Button("Open General") { navigation.tab = .general }
                        } label: {
                            Text("Remove from desktop")
                            Text("Experimental. Turn on in General.")
                        }
                    } header: {
                        Text("Hide")
                    }
                }
            } else {
                let configuration = tile.uuid.flatMap(model.hideConfiguration)
                let frozen = tile.uuid.map(model.hideConfigurationFrozen(for:)) ?? true
                Section {
                    Toggle(isOn: Binding(
                        get: { reason == nil && configuration?.enabled == true },
                        set: { model.setHideEnabled($0, for: display) }
                    )) {
                        Text("Remove from desktop")
                        Text("Mirror onto another display instead of blacking it out.")
                    }
                    .disabled(reason != nil || frozen)
                    .accessibilityLabel("Remove \(tile.name) from desktop")
                    if reason == nil, let configuration, configuration.enabled, let uuid = tile.uuid {
                        sourcePicker(configuration, uuid: uuid, tiles: tiles)
                            .disabled(frozen)
                        // Before the input choice, so the other computer's input is easy to pick.
                        macInputRow(tileID: tile.id, uuid: uuid, frozen: frozen)
                        Group {
                            inputPicker(configuration, tileID: tile.id, uuid: uuid)
                            if inputChoice(configuration, tileID: tile.id) == .other {
                                customInputField(configuration, tileID: tile.id, uuid: uuid)
                            }
                        }
                        .disabled(frozen)
                    }
                } header: {
                    Text("Hide")
                } footer: {
                    if let footer = hideFooter(configuration, reason: reason, tileID: tile.id, isMain: display.main) {
                        SectionFooter(footer)
                    }
                }
            }
        }
    }

    private func sourcePicker(
        _ configuration: DisplayHideConfiguration,
        uuid: String,
        tiles: [DisplayTile]
    ) -> some View {
        let choices = model.sourceChoices(for: configuration)
        let saved = configuration.source
        let savedIsChoice = saved.map { saved in
            model.identityIsCurrent(saved) &&
                choices.contains { $0.uuid?.caseInsensitiveCompare(saved.uuid) == .orderedSame }
        } ?? false
        func name(_ display: DisplayRecord) -> String {
            let tileName = tiles.first { $0.id == display.uuid?.lowercased() }?.name ?? display.settingsName
            return display.main ? "\(tileName) (main display)" : tileName
        }
        return Picker("Mirror onto", selection: Binding(
            get: { saved?.uuid.lowercased() ?? "" },
            set: { model.setHideSource($0.isEmpty ? nil : $0, for: uuid) }
        )) {
            if saved == nil {
                Text("Choose a display").tag("")
            }
            ForEach(choices, id: \.id) { choice in
                Text(name(choice)).tag(choice.uuid?.lowercased() ?? "")
            }
            if let saved, !savedIsChoice {
                Text("\(saved.presentationName) (unavailable)").tag(saved.uuid.lowercased())
            }
        }
    }

    private enum InputChoice: Hashable {
        case none
        case input(UInt8)
        case other
    }

    private func inputChoice(_ configuration: DisplayHideConfiguration, tileID: String) -> InputChoice {
        if customInputs[tileID] != nil { return .other }
        guard let away = configuration.awayInput else { return .none }
        return MonitorInput.common.contains { $0.value == away } ? .input(away) : .other
    }

    private func inputPicker(_ configuration: DisplayHideConfiguration, tileID: String, uuid: String) -> some View {
        Picker("Switch monitor to", selection: Binding(
            get: { inputChoice(configuration, tileID: tileID) },
            set: { choice in
                switch choice {
                case .none:
                    customInputs[tileID] = nil
                    model.setHideSwitchInput(nil, for: uuid)
                case .input(let value):
                    customInputs[tileID] = nil
                    model.setHideSwitchInput(value, for: uuid)
                case .other:
                    customInputs[tileID] = configuration.awayInput.map { String(format: "0x%02X", $0) } ?? ""
                }
            }
        )) {
            Text("Don’t switch").tag(InputChoice.none)
            ForEach(MonitorInput.common, id: \.value) { input in
                Text(input.name).tag(InputChoice.input(input.value))
            }
            Text("Other…").tag(InputChoice.other)
        }
    }

    private func customInputField(_ configuration: DisplayHideConfiguration, tileID: String, uuid: String) -> some View {
        let text = customInputs[tileID] ?? configuration.awayInput.map { String(format: "0x%02X", $0) } ?? ""
        return VStack(alignment: .leading, spacing: 4) {
            TextField("Input code", text: Binding(
                get: { text },
                set: { newValue in
                    customInputs[tileID] = newValue
                    // Text that isn't a code turns switching off instead of keeping the last code.
                    model.setHideSwitchInput(DDCInput.parseValue(newValue.trimmingCharacters(in: .whitespaces)), for: uuid)
                }
            ), prompt: Text("0x1B"))
            if DDCInput.parseValue(text.trimmingCharacters(in: .whitespaces)) == nil {
                Text("Enter a code from 1 to 255, like 27 or 0x1B. Until then, Hide doesn\u{2019}t switch the input.")
                    .font(.caption)
                    .foregroundStyle(text.isEmpty ? Color.secondary : Color.orange)
            }
        }
    }

    /// Reads the Mac's input once per session when shown, even when Hide
    /// doesn't switch inputs; never writes.
    private func macInputRow(tileID: String, uuid: String, frozen: Bool) -> some View {
        LabeledContent("This Mac’s input") {
            HStack(spacing: 8) {
                Text(model.macInput(for: uuid).map(MonitorInput.name) ?? "Unknown")
                switch model.macInputDetections[tileID] {
                case .unavailable?, .onSwitchInput?:
                    Button("Detect Again") { model.detectMacInput(for: uuid) }
                        .disabled(frozen)
                case .detected?, nil:
                    EmptyView()
                }
            }
        }
        .task(id: "\(tileID)|\(frozen)") {
            if !frozen, model.macInputDetections[tileID] == nil {
                model.detectMacInput(for: uuid)
            }
        }
    }

    private func hideFooter(_ configuration: DisplayHideConfiguration?, reason: String?, tileID: String,
                            isMain: Bool) -> String? {
        if let reason { return reason }
        if model.hideConfigurationFrozen(for: configuration?.target.uuid ?? ""),
           model.handoffStatus?.removal(for: configuration?.target.uuid ?? "") != nil {
            return "Show this display to change its removal settings."
        }
        let mainDisplayNote = "macOS decides where the menu bar, Dock, windows and Spaces go when the main display is mirrored; the main display may stay, move to the source or move elsewhere. Observe the result."
        guard let configuration, configuration.enabled else { return isMain ? mainDisplayNote : nil }
        var lines: [String] = []
        if let away = configuration.awayInput {
            let awayName = MonitorInput.name(away)
            let detection = model.macInputDetections[tileID]
            if detection == .detected(away) {
                lines.append("\(awayName) is this Mac’s input. Choose your other computer’s input.")
            } else {
                if detection == .onSwitchInput(away) {
                    lines.append("The monitor is already on \(awayName). If that’s this Mac, choose your other computer’s input.")
                } else if case .unavailable(let why)? = detection {
                    lines.append("Couldn’t read this Mac’s input: \(why)")
                }
                if let back = configuration.returnInput {
                    lines.append("Show switches back to \(MonitorInput.name(back)).")
                } else {
                    lines.append("After Show, switch back with the monitor’s buttons.")
                }
            }
        }
        if isMain {
            lines.append(mainDisplayNote)
        } else {
            lines.append("Windows move off this display while it\u{2019}s hidden.")
        }
        return lines.joined(separator: " ")
    }

    // MARK: Scripts

    /// The command that runs this display's Hide or Show, using the CLI inside
    /// the app so it works without PATH setup.
    @ViewBuilder
    private func scriptSection(_ tile: DisplayTile) -> some View {
        if let uuid = tile.uuid, let cli = try? ProtectionService.helperExecutableURL() {
            Section {
                CommandCopyRow(command: AppControlCommand.toggleHide.commandLine(executable: cli.path, displayUUID: uuid),
                               accessibilityLabel: "Copy display command")
            } header: {
                Text("Command")
            } footer: {
                SectionFooter("For scripts or other apps. Use hide or show to set one state.",
                              learnMore: AppModel.scriptingDocsURL)
            }
        }
    }

    // MARK: Recovery

    /// A recovery problem that no display tile shows.
    private func pageRecoverySection(_ problem: String) -> some View {
        Section {
            Label {
                Text("Display recovery needs attention")
                Text(problem)
                    .textSelection(.enabled)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
            Button("Check Again") { model.refreshDisplays() }
            if let status = model.handoffStatus {
                recoveryDetails(status)
            }
        }
    }

    private func recoveryDetails(_ status: DisplayHandoffStatus, targetUUID: String? = nil) -> some View {
        DisclosureGroup("Recovery details") {
            if status.state == .recovery {
                Text("If a guarded Restore is refused, keep the journal, correct mirroring and arrangement in System Settings → Displays, then Check Again.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Open Displays Settings") { openDisplaysSettings() }
                    Button("Check Again") { model.refreshDisplays() }
                }
            }
            CommandCopyRow("Journal", command: status.journalPath)
            if let selected = targetUUID.flatMap({ status.removal(for: $0) }) {
                removalDetails(selected)
                let command = "panelctl recovery restore --display \(shellQuote(selected.target.uuid)) --journal \(shellQuote(status.journalPath))"
                CommandCopyRow("Recovery command", command: command)
            } else if !status.removals.isEmpty {
                ForEach(status.removals.filter(\.isUnresolved)) { removal in
                    removalDetails(removal)
                    let command = "panelctl recovery restore --display \(shellQuote(removal.target.uuid)) --journal \(shellQuote(status.journalPath))"
                    CommandCopyRow("Restore \(removal.target.name)", command: command)
                }
                CommandCopyRow("Status command", command: status.inspectionCommand)
            } else {
                if let target = status.target {
                    LabeledContent("Hidden display") {
                        Text("\(target.name)\n\(target.identityDetail)").textSelection(.enabled)
                    }
                }
                if let source = status.source {
                    LabeledContent("Mirrored onto") {
                        Text("\(source.name)\n\(source.identityDetail)").textSelection(.enabled)
                    }
                }
                let command = status.state == .unsupported || status.inspectionFailure != nil
                    ? status.inspectionCommand : status.recoveryCommand ?? status.inspectionCommand
                CommandCopyRow("Recovery command", command: command)
            }
        }
    }

    private func removalDetails(_ removal: DisplayHandoffRemoval) -> some View {
        Group {
            LabeledContent("Hidden display") {
                Text("\(removal.target.name)\n\(removal.target.identityDetail)").textSelection(.enabled)
            }
            LabeledContent("Mirrored onto") {
                Text("\(removal.source.name)\n\(removal.source.identityDetail)").textSelection(.enabled)
            }
            if let reason = removal.reason {
                Text(reason).foregroundStyle(.orange).textSelection(.enabled)
            }
        }
    }

    private func openDisplaysSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.Displays-Settings.extension") else { return }
        NSWorkspace.shared.open(url)
    }

    private func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    // MARK: Helpers

    private func isJournalTarget(_ tile: DisplayTile) -> Bool {
        model.isJournalTarget(tile.uuid)
    }
}

/// Displays as screens in arrangement order, like System Settings → Displays.
private struct DisplayArrangement: View {
    let tiles: [DisplayTile]
    let selectedID: String?
    let attentionIDs: Set<String>
    let select: (String) -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            strip
            ScrollView(.horizontal, showsIndicators: false) {
                strip
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 18)
        .padding(.bottom, 4)
    }

    private var strip: some View {
        HStack(alignment: .top, spacing: 18) {
            ForEach(tiles) { tile in
                DisplayTileButton(
                    tile: tile,
                    selected: tile.id == selectedID,
                    attention: attentionIDs.contains(tile.id)
                ) {
                    select(tile.id)
                }
            }
        }
        .frame(maxWidth: .infinity)
    }
}

private struct DisplayTileButton: View {
    let tile: DisplayTile
    let selected: Bool
    let attention: Bool
    let action: () -> Void

    private static let height: CGFloat = 54

    var body: some View {
        let width = (Self.height * tile.aspectRatio).rounded()
        Button(action: action) {
            VStack(spacing: 6) {
                screen
                    .frame(width: width, height: Self.height)
                VStack(spacing: 1) {
                    Text(tile.name)
                        .font(.caption.weight(selected ? .semibold : .regular))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(tile.status.label)
                        .font(.caption2)
                        .foregroundStyle(tile.status == .needsRecovery || attention ? Color.orange : Color.secondary)
                }
                .frame(width: max(width, 128))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(tile.name)
        .accessibilityLabel("\(tile.name), \(tile.status.label)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var screen: some View {
        let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
        return shape
            .fill(fill)
            .overlay(alignment: .top) {
                if tile.isMain {
                    // macOS marks the main display with a menu bar.
                    Rectangle()
                        .fill(Color.white.opacity(0.75))
                        .frame(height: 6)
                }
            }
            .overlay { symbol }
            .clipShape(shape)
            .overlay(alignment: .topTrailing) {
                if attention, tile.status != .needsRecovery {
                    Image(systemName: "exclamationmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.orange)
                        .background(Circle().fill(Color.white).padding(2))
                        .padding(4)
                }
            }
            .overlay(
                shape.strokeBorder(
                    selected ? Color.accentColor : Color.secondary.opacity(0.45),
                    style: StrokeStyle(lineWidth: selected ? 2.5 : 1, dash: tile.status == .unavailable ? [4, 3] : [])
                )
            )
    }

    private var fill: AnyShapeStyle {
        switch tile.status {
        case .hidden, .blackedOut:
            return AnyShapeStyle(Color.black)
        case .needsRecovery:
            return AnyShapeStyle(Color.orange.opacity(0.22))
        case .unavailable:
            return AnyShapeStyle(Color.clear)
        case .asleep:
            return AnyShapeStyle(Color.secondary.opacity(0.25))
        case .on, .hiding, .showing, .mirrored, .busy:
            return AnyShapeStyle(LinearGradient(
                colors: [Color.accentColor.opacity(0.6), Color.accentColor.opacity(0.28)],
                startPoint: .top,
                endPoint: .bottom
            ))
        }
    }

    @ViewBuilder
    private var symbol: some View {
        switch tile.status {
        case .hiding, .showing, .busy:
            ProgressView()
                .controlSize(.small)
        case .hidden:
            Image(systemName: "eye.slash")
                .foregroundStyle(Color.white.opacity(0.85))
        case .needsRecovery:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Color.orange)
        case .asleep:
            Image(systemName: "moon.zzz.fill")
                .foregroundStyle(.secondary)
        case .mirrored:
            Image(systemName: "rectangle.on.rectangle")
                .foregroundStyle(Color.white.opacity(0.9))
        case .on, .blackedOut, .unavailable:
            EmptyView()
        }
    }
}
