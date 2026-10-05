import SwiftUI
import PanelCtlCore

struct ExperimentalDisconnectControls: View {
    @ObservedObject var model: AppModel
    let targetUUID: String?
    @State private var reconnectConsent = false
    @State private var reconnectJournalID: String?

    var body: some View {
        Section("Private disconnect · Experimental") {
            if let status = model.disconnectStatus {
                if status.resolved {
                    Text("Journal recovery verified. Confirm visible output; select the Mac DP input manually if needed.")
                    Text("Journal: \(status.journalPath)\nID: \(status.journalID)")
                        .font(.caption).textSelection(.enabled)
                } else if let presentation = presentation(status) {
                    ExperimentalDisconnectView(presentation: presentation)
                } else {
                    Text("Helper preparation did not record a target. Inspect the retained journal; do not guess an ID.")
                    Text("\(status.journalPath) · \(status.state)").font(.caption).textSelection(.enabled)
                }
                if let failure = status.failure { Text(failure).foregroundStyle(.orange).textSelection(.enabled) }
                if !status.resolved {
                    Button("Reconnect recorded display…") {
                        reconnectJournalID = status.journalID
                        reconnectConsent = true
                    }
                        .disabled(!status.canReconnect)
                    Text("If recovery is busy, wait for the helper, then inspect status. Never delete an unresolved journal. Global restoration, logout, reboot and physical replug need separate approval.")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("Inspect: panelctl recovery status").font(.caption.monospaced()).textSelection(.enabled)
                }
            } else {
                Text(ExperimentalDisconnectPresentation.qualificationReason)
                Text(ExperimentalDisconnectPresentation.distinction)
                Text(ExperimentalDisconnectPresentation.limitations)
                    .foregroundStyle(.secondary)
            }
            if let failure = model.disconnectFailure {
                Text(failure).foregroundStyle(.orange).textSelection(.enabled)
            }
            if let blocker = model.disconnectBlocker {
                Text(blocker).font(.caption).foregroundStyle(.secondary)
            }
            Button("Check selected display and review consent…") {
                if let targetUUID { model.prepareDisconnect(targetUUID) }
            }
            .disabled(targetUUID == nil || model.disconnectBlocker != nil)
            Link("Qualification evidence and recovery limits", destination: URL(string: "https://github.com/brettinternet/panelctl/blob/main/docs/display-disable.md#app-controls")!)
        }
        .alert("Disconnect this display for 15 seconds?", isPresented: $model.disconnectConsentPending) {
            Button("I confirm · Disconnect for 15 seconds", role: .destructive) { model.confirmDisconnect() }
            Button("Cancel", role: .cancel) { model.cancelDisconnect() }
        } message: {
            if let request = model.disconnectRequest {
                Text(Self.consentMessage(request))
            }
        }
        .alert("Request guarded reconnect?", isPresented: $reconnectConsent) {
            Button("Reconnect") {
                if let reconnectJournalID { model.reconnectDisconnect(expectedJournalID: reconnectJournalID) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Journal: \(reconnectJournalID ?? "unavailable"). Use only the retained journal target, even if absent from the display list. This may restore the saved topology; it cannot guarantee visible output or switch back to DP. No identity override, repeated private enable, global reset, logout or reboot. Keep the journal if recovery refuses.")
        }
    }

    static func consentMessage(_ request: DisplayDisconnectRequest) -> String {
        "Target: \(request.target.name) · \(request.target.detail)\nSurvivor: \(request.survivor.name) · \(request.survivor.detail)\n\nI confirm this is the recorded Dell unit with firmware M3T101 on USB-C@3/DP. I am present, the surviving physical screen is usable, and no other display or input changes will run during this session. I can select DP manually afterward and accept stopping there if recovery fails.\n\nOne 15-second session only, with a journal and independent watchdog. A helper or driver failure may prevent recovery. No indefinite hold, automatic DP return, DDC writes or future consent. Cancel changes nothing."
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
