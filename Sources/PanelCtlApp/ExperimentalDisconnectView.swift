import SwiftUI

/// Presentation only. No writer, helper, persisted consent, or production
/// qualification override exists here. TASK-20 owns the eventual provider adapter.
struct ExperimentalDisconnectPresentation: Equatable {
    enum Phase: CaseIterable {
        case consent, leased, refused, helperFailed, watchdogRecovery, reconnectFailed
    }

    struct SyntheticSession: Equatable {
        let phase: Phase
        let target: DisplayIdentitySnapshot
        let journalID: String
        let journalPath: String
        let targetEnumerable: Bool
        let leaseSeconds: Int
        let elapsedSeconds: Int
        let failure: String?
    }

    static let qualificationReason = "Unavailable — hardware recovery qualification is required. No configuration is qualified for app disconnect."
    static let distinction = "Private disconnect would remove the Mac display signal for a bounded session. It is not mirror Hide (the signal stays on), blackout (an overlay), display sleep, or DDC input selection. No alternative runs automatically."
    static let limitations = "No indefinite disconnect. Helper readiness is not a recovery guarantee; sleep, helper death, or driver failure can prevent timely recovery. Hardware recovery and monitor input switching are not proven."

    let syntheticSession: SyntheticSession?
    static let production = Self(syntheticSession: nil)
    var canDisconnect: Bool { false }
    var canReconnect: Bool { false }

    var title: String {
        guard let session = syntheticSession else { return "Disconnect a display · Experimental" }
        switch session.phase {
        case .consent: return "Review scoped consent"
        case .leased: return "Bounded disconnect lease"
        case .refused: return "Disconnect refused"
        case .helperFailed: return "Recovery helper failed"
        case .watchdogRecovery: return "Watchdog recovery pending verification"
        case .reconnectFailed: return "Reconnect failed · attention required"
        }
    }

    var leaseIsValid: Bool {
        guard let session = syntheticSession else { return false }
        return (1...60).contains(session.leaseSeconds) && session.elapsedSeconds >= 0
    }

    var remainingSeconds: Int? {
        guard let session = syntheticSession, leaseIsValid else { return nil }
        return max(0, session.leaseSeconds - session.elapsedSeconds)
    }

    var detail: String {
        guard let session = syntheticSession else { return Self.qualificationReason }
        guard leaseIsValid else { return "Refused: lease must be 1–60 seconds with valid elapsed time. No disconnect or reconnect is authorized." }
        switch session.phase {
        case .consent:
            return "Consent is limited to this captured external target and one \(session.leaseSeconds)-second session with another verified usable physical screen. It does not authorize future sessions, launch-at-login actions, DDC writes, or automatic fallback. Cancel leaves the display unchanged."
        case .leased:
            if remainingSeconds == 0 {
                return "Lease expired. Do not extend or disconnect again. Inspect the retained journal and helper result; expiration is not proof of reconnect."
            }
            return "\(remainingSeconds ?? 0) of \(session.leaseSeconds) seconds remaining in this synthetic lease. The independent watchdog would request guarded recovery at expiry; no renewal or indefinite hold is offered."
        case .refused:
            return "Identity ambiguous: do not guess a display ID or substitute a currently enumerated display. Inspect the retained identity and connector evidence before any separately approved recovery."
        case .helperFailed:
            return "Helper readiness or health failed. Do not disconnect. If a commit may have occurred, keep the journal unresolved and inspect its completion evidence; a missing helper is not successful recovery."
        case .watchdogRecovery:
            return "The watchdog requested guarded recovery after lease expiry or parent loss. Reconnect is not verified. Keep the journal unresolved until identity and restoration verification succeed."
        case .reconnectFailed:
            return "Reconnect could not be verified. Preserve the journal and inspect the failure. No guessed IDs, repeated private writes, global reset, logout, or reboot will run automatically."
        }
    }

    var evidence: String? {
        guard let session = syntheticSession else { return nil }
        return "Captured target: \(session.target.name ?? session.target.uuid) · \(session.target.identityDetail)\nTarget: \(session.targetEnumerable ? "enumerable (not identity proof)" : "not enumerable; retained identity only")\nJournal: \(session.journalPath)\nJournal ID: \(session.journalID)\nUnresolved evidence is retained across app relaunch. This preview never resolves, deletes, or rewrites it."
    }
}

struct ExperimentalDisconnectView: View {
    let presentation: ExperimentalDisconnectPresentation

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(presentation.title).font(.headline)
            if presentation.syntheticSession != nil {
                Text("Synthetic preview only · no display writes or live helper")
                    .font(.caption).foregroundStyle(.orange)
            }
            Text(ExperimentalDisconnectPresentation.qualificationReason)
                .foregroundStyle(.secondary)
            Text(ExperimentalDisconnectPresentation.distinction)
            if presentation.syntheticSession != nil {
                Text(presentation.detail)
                if let remaining = presentation.remainingSeconds,
                   let session = presentation.syntheticSession, session.phase == .leased {
                    ProgressView(value: Double(session.leaseSeconds - remaining), total: Double(session.leaseSeconds))
                        .accessibilityLabel("Synthetic lease elapsed")
                        .accessibilityValue("\(remaining) seconds remaining")
                }
                if let evidence = presentation.evidence {
                    Text(evidence).textSelection(.enabled)
                }
                if let failure = presentation.syntheticSession?.failure {
                    Text("Recorded failure: \(failure)").foregroundStyle(.orange).textSelection(.enabled)
                }
                Text("Next: inspect the retained journal with recovery status. Identity ambiguity requires evidence review; lease expiry requires checking the helper result. Any hardware recovery needs separate scoped approval. Reopening the app does not grant consent.")
            }
            Text(ExperimentalDisconnectPresentation.limitations).foregroundStyle(.secondary)
            HStack {
                Button("Disconnect unavailable") {}.disabled(true)
                    .accessibilityLabel("Experimental disconnect unavailable: qualification required")
                if presentation.syntheticSession != nil {
                    Button("Reconnect unavailable") {}.disabled(true)
                        .accessibilityLabel("Experimental reconnect unavailable: offline preview")
                }
            }
        }
        .font(.caption)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
