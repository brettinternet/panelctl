import AppKit
import SwiftUI

struct GeneralSettingsView: View {
    @ObservedObject var model: AppModel

    static let experimentalConsentTitle = "Turn on experimental features?"
    static let experimentalConsentMessage = "Hide can then remove a display from the desktop by mirroring it, and switch the monitor\u{2019}s input. Windows move and resolution, refresh rate or HDR can change until Show. Tested with one monitor setup only. Show stays available if you turn this off."

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
                SectionFooter("With the menu bar icon hidden, open PanelCtl again to return here.")
            }

            Section {
                Toggle(isOn: Binding(
                    get: { model.experimentalFeaturesEnabled },
                    set: model.setExperimentalFeaturesEnabled
                )) {
                    Text("Experimental features")
                    Text("Remove from desktop, input switching and private disconnect.")
                }
                Link("Learn more", destination: AppModel.experimentalDocsURL)
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
