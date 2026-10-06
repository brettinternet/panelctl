import SwiftUI
import PanelCtlCore

/// Presentation only. The production adapter supplies journal observations;
/// synthetic previews never construct a controller or authorize a write.
/// Qualification, scope and limits live in docs/display-disable.md#app-controls.
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

    static let summary = "Uses a private macOS API. Available only for the tested Dell on this Mac."
    static let docsURL = URL(string: "https://github.com/brettinternet/panelctl/blob/main/docs/display-disable.md#app-controls")!

    let syntheticSession: SyntheticSession?
    var isSynthetic = true
    static let production = Self(syntheticSession: nil)
    var canDisconnect: Bool { false }
    var canReconnect: Bool { false }

    var title: String {
        guard let session = syntheticSession else { return "Full disconnect" }
        switch session.phase {
        case .consent: return "Review consent"
        case .leased: return remainingSeconds == 0 ? "Reconnecting" : "Disconnected"
        case .refused: return "Disconnect refused"
        case .helperFailed: return "Recovery helper failed"
        case .watchdogRecovery: return "Reconnecting"
        case .reconnectFailed: return "Reconnect failed"
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
        guard let session = syntheticSession else { return Self.summary }
        guard leaseIsValid else { return "Refused: the lease must be 1–60 seconds." }
        switch session.phase {
        case .consent:
            return "One \(session.leaseSeconds)-second disconnect of this display while another screen stays usable. Cancel changes nothing."
        case .leased:
            if remainingSeconds == 0 {
                return "Time\u{2019}s up. Waiting for the helper to confirm the reconnect."
            }
            return "Reconnects automatically in \(remainingSeconds ?? 0) seconds."
        case .refused:
            return "The display\u{2019}s identity is ambiguous, so PanelCtl won\u{2019}t guess which display to use."
        case .helperFailed:
            return "Reconnect, or check recovery details. The recovery journal is kept."
        case .watchdogRecovery:
            return "Reconnect requested. Not verified yet."
        case .reconnectFailed:
            return "PanelCtl couldn\u{2019}t verify the reconnect. The recovery journal is kept."
        }
    }

    /// Recovery details, shown collapsed.
    var evidence: [(label: String, value: String)] {
        guard let session = syntheticSession else { return [] }
        return [
            ("Display", "\(session.target.name ?? session.target.uuid)\n\(session.target.identityDetail)"
                + (session.targetEnumerable ? "" : "\nNot connected now")),
            ("Journal", session.journalPath),
            ("Journal ID", session.journalID),
        ]
    }
}

struct ExperimentalDisconnectView: View {
    let presentation: ExperimentalDisconnectPresentation

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(presentation.title).font(.headline)
            if presentation.syntheticSession != nil && presentation.isSynthetic {
                Text("Synthetic preview · no display writes")
                    .font(.caption).foregroundStyle(.orange)
            }
            Text(presentation.detail)
                .foregroundStyle(.secondary)
            if let remaining = presentation.remainingSeconds,
               let session = presentation.syntheticSession, session.phase == .leased {
                ProgressView(value: Double(session.leaseSeconds - remaining), total: Double(session.leaseSeconds))
                    .accessibilityLabel(presentation.isSynthetic ? "Synthetic lease elapsed" : "Disconnect lease elapsed")
                    .accessibilityValue("\(remaining) seconds remaining")
            }
            if let failure = presentation.syntheticSession?.failure {
                Text(failure).foregroundStyle(.orange).textSelection(.enabled)
            }
            if !presentation.evidence.isEmpty {
                DisclosureGroup("Recovery details") {
                    ForEach(presentation.evidence, id: \.label) { row in
                        LabeledContent(row.label) {
                            Text(row.value).textSelection(.enabled)
                        }
                    }
                    LabeledContent("Inspect") {
                        Text("panelctl recovery status").font(.callout.monospaced()).textSelection(.enabled)
                    }
                }
            }
            if presentation.isSynthetic { HStack {
                Button("Disconnect unavailable") {}.disabled(true)
                    .accessibilityLabel("Experimental disconnect unavailable: qualification required")
                if presentation.syntheticSession != nil {
                    Button("Reconnect unavailable") {}.disabled(true)
                        .accessibilityLabel("Experimental reconnect unavailable: offline preview")
                }
            } }
        }
        .disclosureGroupStyle(FullRowDisclosureGroupStyle())
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
