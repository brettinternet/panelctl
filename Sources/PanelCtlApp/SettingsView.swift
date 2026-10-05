import AppKit
import SwiftUI
import PanelCtlCore

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var navigation: SettingsNavigation

    var body: some View {
        VStack(spacing: 0) {
            // Displays shows recovery on the affected display; elsewhere the banner leads there.
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
