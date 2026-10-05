import AppKit
import SwiftUI

struct GeneralSettingsView: View {
    @ObservedObject var model: AppModel

    static let experimentalConsentTitle = "Turn on experimental features?"
    static let experimentalConsentMessage = "PanelCtl can then remove a display from your desktop by mirroring it onto another display, and optionally switch the monitor to another input. Windows on that display move, and resolution, refresh rate or HDR can change until you show it again. This has been tested with only one monitor setup. PanelCtl keeps a recovery journal, and Show stays available even if you turn this off later."

    var body: some View {
        Form {
            Section {
                Toggle("Launch at login", isOn: Binding(
                    get: { model.launchAtLoginEnabled },
                    set: model.setLaunchAtLogin
                ))
                Toggle("Show menu bar icon", isOn: Binding(
                    get: { model.showMenuBarIcon },
                    set: model.setShowMenuBarIcon
                ))
            } footer: {
                Text("Closing Settings doesn’t stop automation. If the menu bar icon is hidden, open PanelCtl again to return here. Launching at login never hides or shows a display.")
            }

            Section {
                Toggle(isOn: Binding(
                    get: { model.experimentalFeaturesEnabled },
                    set: model.setExperimentalFeaturesEnabled
                )) {
                    Text("Experimental features")
                    Text("Remove a display from the desktop by mirroring it, with optional monitor input switching.")
                }
                Link("Learn more about experimental features", destination: AppModel.experimentalDocsURL)
            }

            Section {
                LabeledContent("Version") {
                    Text(model.version)
                        .textSelection(.enabled)
                }
                Link("View on GitHub", destination: AppModel.githubURL)
                Button("Quit PanelCtl") {
                    NSApp.terminate(nil)
                }
            }
        }
        .formStyle(.grouped)
        .alert(Self.experimentalConsentTitle, isPresented: $model.experimentalConsentPending) {
            Button("Turn On") {
                model.acceptExperimentalConsent()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(Self.experimentalConsentMessage)
        }
    }
}
