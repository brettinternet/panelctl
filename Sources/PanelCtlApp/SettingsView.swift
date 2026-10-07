import AppKit
import SwiftUI
import PanelCtlCore

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var navigation: SettingsNavigation

    private enum PresentedAlert: Identifiable {
        case experimentalConsent
        case notice(AppNotice)

        var id: String {
            switch self {
            case .experimentalConsent: return "experimental-consent"
            case .notice(let notice): return notice.id.uuidString
            }
        }
    }

    // A parent notice alert can suppress a nested consent alert on macOS 15.
    // Present both through one binding; consent takes precedence over notices.
    private var presentedAlert: Binding<PresentedAlert?> {
        let alert: PresentedAlert? = model.experimentalConsentPending
            ? .experimentalConsent : model.notice.map { .notice($0) }
        return Binding(
            get: { alert },
            set: { value in
                guard case nil = value else { return }
                switch alert {
                case .experimentalConsent?:
                    model.experimentalConsentPending = false
                case .notice(let notice)?:
                    if model.notice?.id == notice.id { model.notice = nil }
                case nil:
                    break
                }
            }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            // Displays shows recovery itself, on the affected display or above the
            // displays; elsewhere the banner leads there.
            if let problem = model.displayRecoveryProblem, navigation.tab != .displays {
                recoveryBanner(problem)
                    .padding([.top, .horizontal], 16)
            }
            switch navigation.tab {
            case .displays:
                DisplaySettingsView(model: model, navigation: navigation)
            case .automation:
                AutomationSettingsView(model: model, navigation: navigation)
            case .general:
                GeneralSettingsView(model: model)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .alert(item: presentedAlert) { alert in
            switch alert {
            case .experimentalConsent:
                return Alert(
                    title: Text(GeneralSettingsView.experimentalConsentTitle),
                    message: Text(GeneralSettingsView.experimentalConsentMessage),
                    primaryButton: .default(Text("Turn On")) {
                        model.acceptExperimentalConsent()
                    },
                    secondaryButton: .cancel()
                )
            case .notice(let notice):
                return noticeAlert(notice)
            }
        }
    }

    private func noticeAlert(_ notice: AppNotice) -> Alert {
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

    private func recoveryBanner(_ problem: String) -> some View {
        GroupBox {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Display recovery needs attention")
                        .font(.headline)
                    Text(problem)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Button("Review…") {
                    navigation.showDisplays(selecting: model.handoffStatus?.target?.uuid)
                }
                .accessibilityLabel("Review display recovery")
            }
        }
    }
}

/// A command or path the user can read, select and copy, with an optional title.
struct CommandCopyRow: View {
    let title: String?
    let command: String
    let accessibilityLabel: String
    @State private var copied = false

    init(_ title: String? = nil, command: String, accessibilityLabel: String? = nil) {
        self.title = title
        self.command = command
        self.accessibilityLabel = accessibilityLabel ?? "Copy \(title?.lowercased() ?? "command")"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let title {
                Text(title)
            }
            HStack(alignment: .top, spacing: 8) {
                Text(command)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                Button(copied ? "Copied" : "Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(command, forType: .string)
                    copied = true
                }
                .accessibilityLabel(accessibilityLabel)
            }
        }
        .onChange(of: command) { _ in copied = false }
    }
}

/// A note under a Settings section. Built with an SDK before macOS 26, a plain
/// footer is right-aligned body text, so it gets the newer left-aligned style
/// explicitly.
struct SectionFooter: View {
    let text: String
    let learnMore: URL?

    /// Long explanations belong in the linked docs, not the footer.
    init(_ text: String, learnMore: URL? = nil) {
        self.text = text
        self.learnMore = learnMore
    }

    var body: some View {
        var footer = AttributedString(text)
        if let learnMore {
            var link = AttributedString("Learn more")
            link.link = learnMore
            footer += AttributedString(" ") + link
        }
        return Text(footer)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension DisplayRecord {
    var settingsName: String { name ?? "Display \(index)" }

    var settingsDetail: String {
        var details = ["\(pixelWidth) × \(pixelHeight)"]
        if main { details.append("Main") }
        if builtin { details.append("Built-in") }
        if uuid == nil { details.append("Stable ID unavailable") }
        return details.joined(separator: " · ")
    }
}
