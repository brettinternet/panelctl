import Foundation

/// Captured identity is diagnostic journal data, never provider authority.
struct RecoveryIdentityEvidence: Codable, Equatable {
    enum Source: String, Codable { case cgAndCoreDisplay, cgAndIOKit, syntheticFixture }
    var source: Source
    var capturedAt: Date
    var transport: String?
    var transportLocation: String?
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

/// The bounded production contract is an exact capture/current metadata match
/// for the retained ID. This intentionally does not claim resistance to cached
/// metadata, same-port replacement, or numeric-ID reuse.
enum RecoveryIdentityPolicy {
    static func evaluate(snapshot: RecoverySnapshot, evidence: RecoveryEnableInventory) -> RecoveryIdentityDecision {
        func result(_ outcome: RecoveryIdentityOutcome, _ reason: String) -> RecoveryIdentityDecision {
            RecoveryIdentityDecision(outcome: outcome, diagnostic: reason)
        }
        guard evidence.bootSession == snapshot.bootSession, evidence.osBuild == snapshot.osBuild,
              evidence.userID == snapshot.userID else {
            return result(.stale, "boot, OS build or user changed")
        }
        guard let capturedModel = snapshot.hostModel, !capturedModel.isEmpty else {
            return result(.missingEvidence, "capture has no hardware model")
        }
        guard evidence.hostModel == capturedModel else {
            return result(.stale, "hardware model changed")
        }
        guard !snapshot.displays.isEmpty,
              snapshot.displays.allSatisfy({ $0.identityEvidence != nil }) else {
            return result(.missingEvidence, "capture has no identity provenance; legacy capture cannot authorize private writes")
        }
        let savedIDs = Set(snapshot.displays.map(\.id))
        guard evidence.identities.count == snapshot.displays.count,
              Set(evidence.identities.map(\.id)).count == evidence.identities.count,
              Set(evidence.identities.compactMap(\.uuid)).count == evidence.identities.compactMap(\.uuid).count,
              evidence.onlineIDs.isSubset(of: savedIDs) else {
            return result(.ambiguous, "inventory contains missing, duplicate or unretained identities")
        }
        guard evidence.identities.allSatisfy({ identity in
            identity.id != 0 && identity.vendor != 0 && identity.model != 0 && identity.serial != 0 &&
            !identity.connector.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !identity.transport.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            (identity.uuid == nil || UUID(uuidString: identity.uuid!) != nil)
        }) else {
            return result(.missingEvidence, "current vendor/product/serial, connector, transport or online UUID is missing/zero")
        }
        if evidence.binding == .captureMatch, evidence.identities.contains(where: { identity in
            identity.transportLocation?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false
        }) {
            return result(.missingEvidence, "current IOKit transport location is missing")
        }
        guard uniqueHardwareModels(snapshot.displays.map { ($0.vendor, $0.model) }),
              uniqueHardwareModels(evidence.identities.map { ($0.vendor, $0.model) }),
              Set(snapshot.displays.map(\.uuid)).count == snapshot.displays.count,
              Set(snapshot.displays.map(\.id)).count == snapshot.displays.count else {
            return result(.ambiguous, "duplicate retained ID/UUID or identical vendor/product peers")
        }
        for original in snapshot.displays {
            guard original.id != 0, original.vendor != 0, original.model != 0, original.serial != 0,
                  UUID(uuidString: original.uuid) != nil,
                  let connector = original.connector,
                  !connector.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return result(.missingEvidence, "capture has zero hardware identity or missing connector for \(original.uuid)")
            }
            guard let saved = original.identityEvidence,
                  saved.transport?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
                return result(.missingEvidence, "capture has no transport evidence for \(original.uuid)")
            }
            guard let current = evidence.identities.first(where: { $0.id == original.id }) else {
                return result(.stale, "retained ID \(original.id) is absent from current evidence")
            }
            guard current.vendor == original.vendor, current.model == original.model,
                  current.serial == original.serial, current.builtin == original.builtin,
                  current.connector == original.connector, current.transport == saved.transport,
                  current.transportLocation == saved.transportLocation else {
                return result(.stale, "vendor/product/serial, connector, transport/location or retained ID changed for \(original.uuid)")
            }
            if evidence.onlineIDs.contains(original.id) {
                guard current.uuid == original.uuid,
                      saved.framebufferLocation == nil || current.framebufferLocation == saved.framebufferLocation else {
                    return result(.stale, "online UUID or framebuffer location changed for \(original.uuid)")
                }
            } else if evidence.binding == .captureMatch, current.uuid != nil {
                return result(.ambiguous, "offline retained ID has an unverified current UUID")
            }
        }
        switch evidence.binding {
        case .unqualified:
            return result(.unsupported, "current identity provider is unqualified")
        case .stale:
            return result(.stale, "provider reports stale metadata")
        case .captureMatch:
            // ABI compatibility is enforced by RecoveryDisplayBinding, not by
            // treating an identity match as hardware certification.
            guard evidence.architecture == "arm64" else {
                return result(.unsupported, "private identity matching requires Apple Silicon")
            }
            guard snapshot.displays.allSatisfy({ display in
                guard let identity = display.identityEvidence,
                      identity.source == .cgAndCoreDisplay || identity.source == .cgAndIOKit,
                      let location = identity.transportLocation else { return false }
                return !location.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }) else {
                return result(.missingEvidence, "production matching requires capture-time IOKit transport locations")
            }
            return result(.eligible, "complete capture/current identity evidence matches the retained IDs on the same host/build")
        case .syntheticPhysicalFixture:
            guard snapshot.displays.allSatisfy({ $0.identityEvidence?.source == .syntheticFixture }),
                  evidence.architecture == "synthetic" else {
                return result(.unsupported, "synthetic physical fixtures cannot authorize a real capture")
            }
            return result(.eligible, "synthetic identity match is confined to fake-writer tests")
        }
    }

    private static func uniqueHardwareModels(_ models: [(UInt32, UInt32)]) -> Bool {
        Set(models.map { "\($0.0):\($0.1)" }).count == models.count
    }
}
