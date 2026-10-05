import XCTest
import CoreGraphics
@testable import PanelCtlCore

final class RecoveryProductionProviderTests: XCTestCase {
    func testCurrentHostNoWriteConnectedTargetAndSurvivorRehearsal() throws {
        let snapshot = try RecoverySnapshot.capture()
        let records = Dictionary(uniqueKeysWithValues: DisplayInventory.records().map { ($0.id, $0) })
        let identity: RecoveryEnableInventory?
        do {
            identity = try RecoveryProductionProviders.identityInventory(for: snapshot)
        } catch {
            identity = nil
            print("NO-WRITE REHEARSAL identity=refused reason=\(error)")
        }
        let environment: RecoveryEligibilityEnvironment?
        do {
            environment = try RecoveryProductionProviders.eligibilityEnvironment(current: snapshot)
        } catch {
            environment = nil
            print("NO-WRITE REHEARSAL environment=refused reason=\(error)")
        }
        let transports = (try? RecoveryProductionProviders.transports()) ?? []
        let lifecycle = RecoveryProductionProviders.lifecycleObservation()
        let identityDecision = identity.map { RecoveryIdentityPolicy.evaluate(snapshot: snapshot, evidence: $0) }
        print("NO-WRITE REHEARSAL host=\(snapshot.hostModel ?? "unknown") build=\(snapshot.osBuild) architecture=\(RecoveryProductionProviders.architecture()) lifecycle.awake=\(String(describing: lifecycle.awake)) lid=\(lifecycle.lid) lifecycle.evidence=\(lifecycle.diagnostic)")
        print("NO-WRITE REHEARSAL identity=\(identityDecision?.outcome.rawValue ?? "refused") reason=\(identityDecision?.diagnostic ?? "provider did not return a complete inventory")")
        print("NO-WRITE REHEARSAL drivers=\(String(describing: environment?.drivers)) evidence=\(environment?.driverInventory ?? "unknown") mirrored=\(String(describing: environment?.mirrored))")
        for display in snapshot.displays {
            let name = records[display.id]?.name ?? display.name ?? "unknown"
            let screen = environment?.screens[display.id]
            let matchingTransports = transports.filter { $0.matches(display) }
            let transport = matchingTransports.count == 1 ? matchingTransports.first : nil
            let target = !display.main && !display.builtin
            if target {
                let decision: RecoveryEligibilityDecision?
                if let identity, let environment {
                    decision = RecoveryEligibilityPolicy.evaluate(snapshot: snapshot, targetID: display.id,
                        identity: identity, environment: environment)
                } else {
                    decision = nil
                }
                let survivors = decision?.usableSurvivors.sorted().map { id in
                    "\(id):\(records[id]?.name ?? "unknown")"
                }.joined(separator: ",") ?? "unknown"
                print("NO-WRITE REHEARSAL target id=\(display.id) name=\(name) connector=\(display.connector ?? "unknown") transport=\(display.identityEvidence?.transport ?? "unknown") io-location=\(display.identityEvidence?.transportLocation ?? "unknown") hpd=\(transport?.hpd ?? "unknown") io-active=\(String(describing: transport?.active)) physical=\(String(describing: screen?.kind)) online=\(String(describing: screen?.online)) active=\(String(describing: screen?.active)) mode=\(display.mode.width)x\(display.mode.height) verdict=\(decision.map { $0.eligible ? "eligible (no-write only)" : $0.refusals.joined(separator: ";") } ?? "provider unavailable") survivors=\(survivors)")
            } else {
                print("NO-WRITE REHEARSAL survivor-candidate id=\(display.id) name=\(name) connector=\(display.connector ?? "unknown") transport=\(display.identityEvidence?.transport ?? "unknown") io-location=\(display.identityEvidence?.transportLocation ?? "unknown") hpd=\(transport?.hpd ?? "unknown") io-active=\(String(describing: transport?.active)) physical=\(String(describing: screen?.kind)) online=\(String(describing: screen?.online)) active=\(String(describing: screen?.active)) mode=\(display.mode.width)x\(display.mode.height)")
            }
        }
        XCTAssertFalse(snapshot.displays.isEmpty)
        // This rehearsal collects metadata and evaluates pure policy only. It
        // intentionally never resolves or constructs a display writer.
    }

    func testAwakeMirrorDestinationPermitsFakePublicUnmirrorRestoration() throws {
        func snapshot(mirrored: Bool) throws -> RecoverySnapshot {
            let sourceUUID = "00000000-0000-0000-0000-000000000001"
            let displays: [[String: Any]] = (1...2).map { id in
                var display: [String: Any] = [
                    "uuid": String(format: "00000000-0000-0000-0000-%012d", id), "id": id,
                    "vendor": 1, "model": id, "serial": id, "builtin": false,
                    "main": id == 1, "active": id == 1 || !mirrored,
                    "x": id == 1 || !mirrored ? (id - 1) * 1920 : 0, "y": 0, "rotation": 0,
                    "mode": ["id": 1, "width": 1920, "height": 1080, "pixelWidth": 1920,
                             "pixelHeight": 1080, "refreshRate": 60, "flags": 0]
                ]
                if mirrored && id == 2 { display["mirrorUUID"] = sourceUUID }
                return display
            }
            let value: [String: Any] = ["bootSession": "mirror-boot", "osBuild": "mirror-build",
                "userID": getuid(), "hostModel": "mirror-host", "displays": displays]
            return try JSONDecoder().decode(RecoverySnapshot.self,
                from: JSONSerialization.data(withJSONObject: value))
        }

        let baseline = try snapshot(mirrored: false)
        let current = try snapshot(mirrored: true)
        let awakeScreens = Dictionary(uniqueKeysWithValues: current.displays.map { ($0.id, true) })
        let lifecycle = RecoveryProductionProviders.lifecycleObservation(current: current, rootAwake: true,
            lid: .unknown, consoleIsCurrent: true, screenAwake: awakeScreens)
        XCTAssertEqual(lifecycle.awake, true)
        XCTAssertFalse(current.displays[1].active)
        XCTAssertNotNil(current.displays[1].mirrorUUID)

        let environment = RecoveryEligibilityEnvironment(architecture: .unknown, drivers: .unknown,
            lid: .unknown, mirrored: true, screens: Dictionary(uniqueKeysWithValues: current.displays.map {
                ($0.id, .init(kind: .unknown, online: true, active: $0.active, awake: true))
            }))
        var fakePublicWrites = 0
        let session = RecoveryPrivateSession(snapshot: baseline, capture: { current },
            inventory: { throw RecoveryError.unsafe("private identity must not be queried") },
            environment: { environment },
            transaction: { XCTFail("public unmirror must not construct private writer"); throw RecoveryError.unsafe("unexpected") },
            apply: { _, validate in try validate(); fakePublicWrites += 1 },
            lifecycleObservation: { lifecycle })
        try session.makeEngine(requiresPrivateIdentity: false).apply(baseline)
        XCTAssertEqual(fakePublicWrites, 1)
    }
}
