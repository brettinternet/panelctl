import AppKit
import SwiftUI
import PanelCtlCore

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var navigation: SettingsNavigation

    var body: some View {
        VStack(spacing: 0) {
            // The Displays tab shows recovery itself; elsewhere the banner leads there.
            if model.protectionPausedForDisplayRecovery, navigation.tab != .displays {
                recoveryBanner
                    .padding([.top, .horizontal], 16)
            }
            switch navigation.tab {
            case .displays:
                DisplaySettingsView(model: model)
            case .automation:
                AutomationSettingsView(model: model)
            case .general:
                GeneralSettingsView(model: model)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: model.displayRecoveryFocusRequest) { _ in
            navigation.tab = .displays
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
                    Text(model.handoffStatus?.state == .hidden
                        ? "Desktop hidden · Show remains explicit"
                        : "Display recovery needs attention")
                        .font(.headline)
                    Text(model.handoffStatus?.hasUnresolvedJournal == true || model.handoffInspectionFailure != nil
                        ? model.hiddenMirrorProtectionSummary
                        : model.protectionQuiescenceFailure.map { "Automation cleanup needs attention: \($0)" }
                            ?? "Automation is suspended during the display operation.")
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
