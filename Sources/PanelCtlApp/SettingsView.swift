import AppKit
import SwiftUI
import PanelCtlCore

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var navigation: SettingsNavigation

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
                AutomationSettingsView(model: model)
            case .general:
                GeneralSettingsView(model: model)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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

/// A note under a Settings section. Built with an SDK before macOS 26, a plain
/// footer is right-aligned body text, so it gets the newer left-aligned style
/// explicitly.
struct SectionFooter: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
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
