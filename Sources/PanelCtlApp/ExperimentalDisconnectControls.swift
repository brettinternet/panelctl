import SwiftUI
import PanelCtlCore

struct ExperimentalDisconnectControls: View {
    @ObservedObject var model: AppModel
    let targetUUID: String?
    @State private var reconnectConsent = false
    @State private var reconnectJournalID: String?

    /// Shown for the qualified display with Experimental on, and whenever a
    /// disconnect journal exists so reconnect stays reachable.
    static func isVisible(model: AppModel, targetUUID: String?) -> Bool {
        model.disconnectStatus != nil || (model.experimentalFeaturesEnabled
            && targetUUID?.caseInsensitiveCompare(DisplayDisconnectController.qualifiedDisplayUUID) == .orderedSame)
    }

    var body: some View {
        Section {
            if let status = model.disconnectStatus {
                if status.resolved {
                    Text("Reconnected. If the screen stays dark, switch the monitor to DisplayPort.")
                } else if let presentation = presentation(status) {
                    ExperimentalDisconnectView(presentation: presentation)
                } else {
                    Text("The helper stopped before recording a display. Check recovery status; don\u{2019}t guess a display.")
                    Text("\(status.journalPath) · \(status.state)").font(.caption).textSelection(.enabled)
                    if let failure = status.failure { Text(failure).foregroundStyle(.orange).textSelection(.enabled) }
                }
                if !status.resolved {
                    Button("Reconnect…") {
                        reconnectJournalID = status.journalID
                        reconnectConsent = true
                    }
                    .disabled(!status.canReconnect)
                }
            }
            if let failure = model.disconnectFailure {
                Text(failure).foregroundStyle(.orange).textSelection(.enabled)
            }
            if model.disconnectStatus?.resolved != false, model.experimentalFeaturesEnabled {
                disconnectRow
            }
        } header: {
            Text("Full disconnect · Experimental")
        } footer: {
            SectionFooter(ExperimentalDisconnectPresentation.summary, learnMore: ExperimentalDisconnectPresentation.docsURL)
        }
        .alert("Disconnect for 15 seconds?", isPresented: $model.disconnectConsentPending) {
            Button("Disconnect", role: .destructive) { model.confirmDisconnect() }
            Button("Cancel", role: .cancel) { model.cancelDisconnect() }
        } message: {
            if let request = model.disconnectRequest {
                Text(Self.consentMessage(request))
            }
        }
        .alert("Reconnect the display?", isPresented: $reconnectConsent) {
            Button("Reconnect") {
                if let reconnectJournalID { model.reconnectDisconnect(expectedJournalID: reconnectJournalID) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("PanelCtl restores the display recorded in its recovery journal. If the screen stays dark, switch the monitor to DisplayPort.")
        }
    }

    /// One row: what the action does (or what blocks it) beside the action itself.
    /// When Automation is the blocker, offer to turn it off in place.
    private var disconnectRow: some View {
        let blocker = model.disconnectBlocker
        return HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Unplug for 15 seconds")
                Group {
                    if let blocker {
                        Text("\(Image(systemName: "lock")) \(blocker)")
                    } else {
                        Text("macOS treats this display as unplugged, then PanelCtl reconnects it.")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if blocker != nil, model.preferences.isEnabled {
                Button("Turn Off Automation") { model.setProtectionEnabled(false) }
            } else {
                Button("Disconnect…") {
                    if let targetUUID { model.prepareDisconnect(targetUUID) }
                }
                .disabled(targetUUID == nil || blocker != nil)
            }
        }
    }

    /// Consent is one-use and per operation; it confirms what PanelCtl can't read.
    static func consentMessage(_ request: DisplayDisconnectRequest) -> String {
        "\(request.target.name) turns off for 15 seconds; \(request.survivor.name) stays on.\n\nContinue only if this is the tested Dell (firmware M3T101) on USB-C@3 DisplayPort, you\u{2019}re at this Mac, and you can switch the monitor back to DisplayPort by hand. A helper or driver failure can prevent the automatic reconnect."
    }

    private func presentation(_ status: DisplayDisconnectStatus) -> ExperimentalDisconnectPresentation? {
        guard let target = status.target else { return nil }
        let phase: ExperimentalDisconnectPresentation.Phase
        if status.state == "needsAttention" {
            phase = status.trigger == "helper-error" ? .helperFailed : .reconnectFailed
        } else if status.state == "restoring" { phase = .watchdogRecovery }
        else { phase = .leased }
        let elapsed = max(0, min(3600, model.countdownDate.timeIntervalSince(status.createdAt)))
        let duration = status.deadline?.timeIntervalSince(status.createdAt) ?? 15
        return .init(syntheticSession: .init(phase: phase,
            target: .init(uuid: target.uuid, id: target.displayID, name: target.name,
                          vendor: target.vendor, model: target.model, serial: target.serial),
            journalID: status.journalID, journalPath: status.journalPath,
            targetEnumerable: model.displays.contains { $0.uuid?.caseInsensitiveCompare(target.uuid) == .orderedSame },
            leaseSeconds: Int(duration), elapsedSeconds: Int(elapsed), failure: status.failure), isSynthetic: false)
    }
}
