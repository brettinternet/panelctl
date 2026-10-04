import Foundation

/// Observations are diagnostic journal data, not a persisted authorization token.
struct RecoveryIdentityEvidence: Codable, Equatable {
    enum Source: String, Codable { case cgAndCoreDisplay, syntheticFixture }
    var source: Source
    var capturedAt: Date
    var transport: String?
    var hpd: String?
    var framebufferLocation: String?
}

enum RecoveryIdentityOutcome: String {
    case eligible, ambiguous, stale, missingEvidence, unsupported
}

struct RecoveryIdentityDecision {
    let outcome: RecoveryIdentityOutcome
    let diagnostic: String

    func requireEligible() throws {
        guard outcome == .eligible else {
            throw RecoveryError.unsafe("\(outcome.rawValue): \(diagnostic); retain journal and recover manually")
        }
    }
}

/// Only synthetic fixtures can currently supply a proven binding. Adding a real
/// provider requires separately reviewed hardware-to-retained-CG-ID evidence.
/// Never deserialize provider authority from the journal.
enum RecoveryIdentityPolicy {
    static func evaluate(snapshot: RecoverySnapshot, evidence: RecoveryEnableInventory) -> RecoveryIdentityDecision {
        func result(_ outcome: RecoveryIdentityOutcome, _ reason: String) -> RecoveryIdentityDecision {
            RecoveryIdentityDecision(outcome: outcome, diagnostic: reason)
        }
        guard evidence.bootSession == snapshot.bootSession, evidence.osBuild == snapshot.osBuild,
              evidence.userID == snapshot.userID else {
            return result(.stale, "boot, OS build or user changed")
        }
        guard !snapshot.displays.isEmpty,
              snapshot.displays.allSatisfy({ $0.identityEvidence != nil }) else {
            return result(.missingEvidence, "capture has no identity provenance; legacy capture cannot authorize private writes")
        }
        guard evidence.identities.count == snapshot.displays.count,
              Set(evidence.identities.map(\.id)).count == evidence.identities.count,
              Set(evidence.identities.map(\.uuid)).count == evidence.identities.count else {
            return result(.ambiguous, "inventory contains missing or duplicate retained identities")
        }
        for original in snapshot.displays {
            let identity = RecoveryEnableIdentity(original)
            guard identity.id != 0, UUID(uuidString: identity.uuid) != nil,
                  identity.vendor != 0, identity.model != 0, identity.serial != 0,
                  identity.connector?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
                return result(.missingEvidence, "hardware serial or connector missing for \(original.uuid)")
            }
            guard snapshot.displays.filter({ $0.vendor == original.vendor && $0.model == original.model && $0.serial == original.serial }).count == 1 else {
                return result(.ambiguous, "duplicate hardware serial for \(original.uuid)")
            }
            guard evidence.identities.filter({ $0 == identity }).count == 1 else {
                return result(.stale, "retained ID, hardware identity or connector changed for \(original.uuid)")
            }
        }
        switch evidence.binding {
        case .unqualified:
            return result(.unsupported, "no qualified fresh physical-sink binding; cached CG/CoreDisplay fields, HPD and registry lifetime are insufficient")
        case .stale:
            return result(.stale, "provider metadata is stale; fresh binding required")
        case .syntheticPhysicalFixture:
            guard snapshot.displays.allSatisfy({ $0.identityEvidence?.source == .syntheticFixture }) else {
                return result(.unsupported, "synthetic binding cannot authorize a real capture")
            }
            return result(.eligible, "synthetic same-session physical binding matches every retained identity; fake writers only")
        }
    }
}
