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
                let pageProblem = model.pageRecoveryProblem
                if let pageProblem {
                    pageRecoverySection(pageProblem)
                }
                if let selected {
                    summarySection(selected)
                    hideSection(selected, tiles: tiles)
                    if pageProblem == nil, isJournalTarget(selected), let status = model.handoffStatus {
                        Section {
                            recoveryDetails(status)
                        }
                    }
                    scriptSection(selected)
                } else {
                    Section {
                        Text("No displays found.")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)
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
                }
                if let input = result.inputMessage {
                    resultLabel(input, attention: result.inputNeedsAttention)
                }
                if let command = result.undoInputCommand {
                    copyRow("Undo input switch", command, monospaced: true)
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
            return "Removed from the desktop · mirrored onto \(model.handoffStatus?.source?.name ?? "another display")"
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
            let title = action == .hide ? "Hide" : "Show"
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
            return tile.display == nil ? nil : "To show it from the keyboard, point at it and press Esc."
        case .show?:
            return model.showReturnInputNote
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
                            Text("Experimental. Turn on Experimental features in General to use it.")
                        }
                    } header: {
                        Text("Hide")
                    }
                }
            } else {
                let configuration = tile.uuid.flatMap(model.hideConfiguration)
                let frozen = model.hideConfigurationFrozen
                Section {
                    Toggle(isOn: Binding(
                        get: { reason == nil && configuration?.enabled == true },
                        set: { model.setHideEnabled($0, for: display) }
                    )) {
                        Text("Remove from desktop")
                        Text("Experimental. Hide mirrors this display onto another so windows move off it, instead of blacking it out.")
                    }
                    .disabled(reason != nil || frozen)
                    .accessibilityLabel("Remove \(tile.name) from desktop")
                    if reason == nil, let configuration, configuration.enabled, let uuid = tile.uuid {
                        Group {
                            sourcePicker(configuration, uuid: uuid, tiles: tiles)
                            inputPicker(configuration, tileID: tile.id, uuid: uuid)
                            if inputChoice(configuration, tileID: tile.id) == .other {
                                customInputField(configuration, tileID: tile.id, uuid: uuid)
                            }
                        }
                        .disabled(frozen)
                        if configuration.awayInput != nil {
                            macInputRow(configuration, tileID: tile.id, uuid: uuid, frozen: frozen)
                        }
                    }
                } header: {
                    Text("Hide")
                } footer: {
                    if let footer = hideFooter(configuration, reason: reason, tileID: tile.id) {
                        Text(footer)
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
                Text("\(saved.name ?? "Display \(saved.id)") (disconnected)").tag(saved.uuid.lowercased())
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

    /// Reads the Mac's input once per session when shown; never writes.
    private func macInputRow(
        _ configuration: DisplayHideConfiguration,
        tileID: String,
        uuid: String,
        frozen: Bool
    ) -> some View {
        LabeledContent("This Mac’s input") {
            HStack(spacing: 8) {
                Text(configuration.returnInput.map(MonitorInput.name) ?? "Unknown")
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

    private func hideFooter(_ configuration: DisplayHideConfiguration?, reason: String?, tileID: String) -> String? {
        if let reason { return reason }
        if model.hideConfigurationFrozen, model.handoffStatus?.hasUnresolvedJournal == true {
            return "Show the hidden display to change these settings."
        }
        guard let configuration, configuration.enabled else { return nil }
        var lines: [String] = []
        if let away = configuration.awayInput {
            let awayName = MonitorInput.name(away)
            switch model.macInputDetections[tileID] {
            case .detected(let current) where current == away, .onSwitchInput(let current) where current == away:
                lines.append("The monitor is on \(awayName) now, the input Hide switches to. If that’s this Mac’s input, choose the input your other computer uses.")
            case .unavailable(let why):
                lines.append("Couldn’t read this Mac’s input: \(why)")
            default:
                break
            }
            if let back = configuration.returnInput {
                lines.append("Hide switches the monitor to \(awayName), and Show switches it back to \(MonitorInput.name(back)).")
            } else {
                lines.append("Hide switches the monitor to \(awayName). After Show, switch it back with the monitor’s buttons.")
            }
        }
        lines.append("Windows move to the other display, and resolution or refresh rate can change until you show it again.")
        return lines.joined(separator: " ")
    }

    // MARK: Scripts

    /// The command that runs this display's Hide or Show, using the CLI inside
    /// the app so it works without PATH setup.
    @ViewBuilder
    private func scriptSection(_ tile: DisplayTile) -> some View {
        if let uuid = tile.uuid, let cli = try? ProtectionService.helperExecutableURL() {
            Section {
                copyRow("Command", AppControlCommand.toggleHide.commandLine(executable: cli.path, displayUUID: uuid),
                        monospaced: true)
            } header: {
                Text("Scripts")
            } footer: {
                Text("Hides or shows this display, like its Hide or Show button. Use it in a Stream Deck or Shortcuts action that runs a shell command. To set one state, replace toggle-hide with hide or show.")
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

    private func recoveryDetails(_ status: DisplayHandoffStatus) -> some View {
        DisclosureGroup("Recovery details") {
            copyRow("Journal", status.journalPath)
            if let target = status.target {
                LabeledContent("Hidden display") {
                    Text("\(target.name)\n\(target.identityDetail)")
                        .textSelection(.enabled)
                }
            }
            if let source = status.source {
                LabeledContent("Mirrored onto") {
                    Text("\(source.name)\n\(source.identityDetail)")
                        .textSelection(.enabled)
                }
            }
            let command = status.state == .unsupported || status.inspectionFailure != nil
                ? status.inspectionCommand
                : status.recoveryCommand ?? status.inspectionCommand
            copyRow("Recovery command", command, monospaced: true)
        }
    }

    private func copyRow(_ title: String, _ value: String, monospaced: Bool = false) -> some View {
        LabeledContent(title) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(value)
                    .font(monospaced ? .callout.monospaced() : .callout)
                    .textSelection(.enabled)
                    // A command that wraps reads left to right.
                    .multilineTextAlignment(monospaced ? .leading : .trailing)
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(value, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .help("Copy")
                .accessibilityLabel("Copy \(title.lowercased())")
            }
        }
    }

    // MARK: Helpers

    private func isJournalTarget(_ tile: DisplayTile) -> Bool {
        guard let status = model.handoffStatus, status.hasUnresolvedJournal,
              let target = status.target else { return false }
        return target.uuid.lowercased() == tile.id
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
                        .foregroundStyle(Color.orange)
                        .background(Circle().fill(Color.white).padding(2))
                        .offset(x: 5, y: -5)
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
