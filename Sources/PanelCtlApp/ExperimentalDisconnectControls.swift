import SwiftUI
import PanelCtlCore

struct ExperimentalDisconnectControls: View {
    @ObservedObject var model: AppModel
    let targetUUID: String?
    @State private var reconnectConsent = false
    @State private var reconnectJournalID: String?

    /// Shown for every selected display with Experimental on, and whenever a
    /// disconnect journal exists so reconnect stays reachable.
    static func isVisible(model: AppModel, targetUUID: String?) -> Bool {
        model.disconnectStatus != nil || model.disconnectInspectionFailure != nil ||
            (model.experimentalFeaturesEnabled && targetUUID != nil)
    }

    var body: some View {
        Section {
            if let failure = model.disconnectInspectionFailure {
                Text("Disconnect recovery is unreadable or unavailable. Automation remains paused; no recovery write was attempted.")
                Text("\(model.disconnectJournalPath)").font(.caption).textSelection(.enabled)
                Text(failure).foregroundStyle(.orange).textSelection(.enabled)
                Button("Reconnect…") {}.disabled(true)
                LabeledContent("Inspect recovery") {
                    Text("panelctl recovery status").font(.callout.monospaced()).textSelection(.enabled)
                }
            }
            if let status = model.disconnectStatus {
                if status.resolved {
                    Text("Reconnected. Automation resumes only if enabled and not snoozed, with a fresh countdown. If the screen stays dark, select this Mac’s input on the monitor.")
                } else if let presentation = presentation(status) {
                    Text("Automation is paused without changing preferences or snooze until recovery is verified.")
                        .font(.caption).foregroundStyle(.secondary)
                    ExperimentalDisconnectView(presentation: presentation)
                } else {
                    Text("The helper stopped before recording a display. Automation stays paused. Check recovery status; don\u{2019}t guess a display.")
                    Text("\(status.journalPath) · \(status.state)").font(.caption).textSelection(.enabled)
                    if let failure = status.failure { Text(failure).foregroundStyle(.orange).textSelection(.enabled) }
                }
                if !status.resolved {
                    Button("Reconnect…") {
                        reconnectJournalID = status.journalID
                        reconnectConsent = true
                    }
                    .disabled(!status.canReconnect || model.disconnectInspectionFailure != nil)
                }
            }
            if let failure = model.disconnectFailure {
                Text(failure).foregroundStyle(.orange).textSelection(.enabled)
            }
            if model.disconnectPreparationPending {
                HStack(alignment: .center, spacing: 12) {
                    Text("Stopping automation and verifying cleanup before consent. Preferences and snooze stay unchanged.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Button("Cancel") { model.cancelDisconnect() }
                }
            } else if model.disconnectRequest != nil {
                Text("Automation stays paused until you cancel or recovery is verified.")
                    .font(.caption).foregroundStyle(.secondary)
            } else if model.disconnectStatus?.resolved != false,
                      model.disconnectInspectionFailure == nil,
                      model.experimentalFeaturesEnabled {
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
            Text("PanelCtl restores the display recorded in its recovery journal. If the screen stays dark, select this Mac’s input on the monitor.")
        }
    }

    /// One row: what the action does (or what blocks it) beside the action itself.
    private var disconnectRow: some View {
        let blocker = model.disconnectBlocker ?? targetBlocker
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 12) {
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
                Button("Disconnect…") {
                    if let targetUUID { model.prepareDisconnect(targetUUID) }
                }
                .disabled(targetUUID == nil || blocker != nil)
            }
            if model.protectionQuiescenceFailure != nil {
                Button("Retry Automation Cleanup", action: model.retryAutomationCleanup)
                    .disabled(model.protectionQuiescencePending)
            }
        }
    }

    private var targetBlocker: String? {
        guard let targetUUID,
              let display = model.displays.first(where: { $0.uuid?.caseInsensitiveCompare(targetUUID) == .orderedSame }) else {
            return "Select a connected display with a stable identity."
        }
        if display.builtin { return "Built-in displays cannot be disconnected." }
        if display.main { return "The main display cannot be disconnected. Choose another main display first." }
        if !display.active || !display.online { return "Select an active, connected display." }
        return nil
    }

    /// Consent is one-use and per operation; it confirms what PanelCtl can't read.
    static func consentMessage(_ request: DisplayDisconnectRequest) -> String {
        "\(request.target.name) disconnects for 15 seconds; \(request.survivor.name) stays on.\n\nAutomation pauses without changing preferences or snooze. Automatic reconnect may fail and require manual recovery. Continue only if you\u{2019}re at this Mac and the other screen is usable. Don’t unplug displays or change inputs during the test."
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
