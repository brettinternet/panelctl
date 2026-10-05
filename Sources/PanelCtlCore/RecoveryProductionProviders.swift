import AppKit
import CoreGraphics
import Foundation
import IOKit
import IOKit.pwr_mgt
import Darwin

/// Read-only host/display observations used by private recovery preflight.
/// Metadata is compared exactly, but HPD/EDID/registry observations can be
/// cached; this is the bounded matching contract, not fresh-sink proof.
enum RecoveryProductionProviders {
    struct Transport: Equatable {
        let vendor: UInt32
        let product: UInt32
        let serial: UInt32
        let kind: String
        let location: String
        let hpd: String?
        let active: Bool?
        let name: String?

        func matches(_ display: RecoveryDisplay) -> Bool {
            vendor == display.vendor && product == display.model && serial == display.serial
        }
    }

    struct LifecycleObservation {
        let awake: Bool?
        let lid: RecoveryEligibilityEnvironment.Lid
        let diagnostic: String
    }

    static func architecture() -> String {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x86_64"
        #else
        return "unknown"
        #endif
    }

    static func transports() throws -> [Transport] {
        guard let matching = IOServiceMatching("IOPortTransportStateDisplayPort") else {
            throw RecoveryError.unsafe("IOKit transport matching unavailable")
        }
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else {
            throw RecoveryError.unsafe("cannot enumerate read-only IOKit display transports")
        }
        defer { IOObjectRelease(iterator) }
        var result: [Transport] = []
        while true {
            let service = IOIteratorNext(iterator)
            if service == 0 { break }
            defer { IOObjectRelease(service) }
            guard let values = properties(service),
                  let manufacturer = values["ManufacturerName"] as? String,
                  let vendor = eisaVendor(manufacturer),
                  let product = number(values["ProductID"]),
                  let serial = number(values["SerialNumber"]),
                  let kind = values["TransportTypeDescription"] as? String,
                  !kind.isEmpty,
                  let location = values["TransportDescription"] as? String,
                  !location.isEmpty else {
                // One incomplete transport makes a complete inventory unknown.
                throw RecoveryError.unsafe("IOKit transport inventory contains incomplete display identity")
            }
            result.append(Transport(vendor: vendor, product: product, serial: serial, kind: kind,
                location: location, hpd: values["HPD_StateDescription"] as? String,
                active: bool(values["Active"]), name: values["ProductName"] as? String))
        }
        return result
    }

    static func identityInventory(for snapshot: RecoverySnapshot) throws -> RecoveryEnableInventory {
        let current = try RecoverySnapshot.capture()
        let transports = try self.transports()
        let onlineIDs = Set(current.displays.map(\.id))
        var identities: [RecoveryEnableIdentity] = []
        for saved in snapshot.displays {
            let matching = transports.filter { $0.matches(saved) }
            guard matching.count == 1, let port = matching.first,
                  port.serial != 0,
                  port.location.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
                  saved.identityEvidence?.transport == port.kind,
                  saved.identityEvidence?.transportLocation == port.location else {
                throw RecoveryError.unsafe(matching.isEmpty
                    ? "missing current IOKit sink identity for retained ID \(saved.id)"
                    : "ambiguous IOKit sink identity for retained ID \(saved.id)")
            }
            if let visible = current.displays.first(where: { $0.id == saved.id }) {
                guard visible.vendor == port.vendor, visible.model == port.product,
                      visible.serial == port.serial,
                      visible.identityEvidence?.transportLocation == port.location,
                      visible.identityEvidence?.transport == port.kind else {
                    throw RecoveryError.unsafe("current IOKit and CoreGraphics identity disagree for retained ID \(saved.id)")
                }
                identities.append(RecoveryEnableIdentity(visible))
            } else {
                // Preserve only the saved CG ID; absent displays have no current
                // CG UUID/framebuffer path. The unique IOKit tuple and exact
                // connector/transport match are the bounded absent-target evidence.
                identities.append(RecoveryEnableIdentity(uuid: nil, id: saved.id, vendor: port.vendor,
                    model: port.product, serial: port.serial, builtin: saved.builtin,
                    connector: saved.connector ?? "", transport: port.kind, framebufferLocation: nil,
                    transportLocation: port.location))
            }
        }
        return RecoveryEnableInventory(bootSession: current.bootSession, osBuild: current.osBuild,
            userID: current.userID, identities: identities, onlineIDs: onlineIDs,
            hostModel: current.hostModel, architecture: architecture(), binding: .captureMatch)
    }

    static func restorationEnvironment(current: RecoverySnapshot) -> RecoveryEligibilityEnvironment {
        let root = rootObservation()
        let screens = Dictionary(uniqueKeysWithValues: current.displays.map { display in
            (display.id, RecoveryEligibilityEnvironment.Screen(kind: .unknown,
                online: CGDisplayIsOnline(display.id) != 0, active: display.active,
                awake: CGDisplayIsAsleep(display.id) == 0))
        })
        let hostArchitecture = Self.architecture()
        let architecture = hostArchitecture == "arm64" ? RecoveryEligibilityEnvironment.Architecture.appleSilicon :
            (hostArchitecture == "x86_64" ? .intel : .unknown)
        return RecoveryEligibilityEnvironment(architecture: architecture, drivers: .unknown,
            lid: root.lid, mirrored: current.displays.contains { $0.mirrorUUID != nil }, screens: screens,
            driverInventory: "not required for strict public restoration")
    }

    static func eligibilityEnvironment(current: RecoverySnapshot) throws -> RecoveryEligibilityEnvironment {
        let transports = try self.transports()
        let drivers = driverObservation()
        let root = rootObservation()
        var screens: [UInt32: RecoveryEligibilityEnvironment.Screen] = [:]
        for display in current.displays {
            let matches = transports.filter { $0.matches(display) }
            let kind: RecoveryEligibilityEnvironment.PhysicalKind
            if matches.count == 1, let transport = matches.first,
               transport.hpd == "High", transport.active == true {
                kind = .physical
            } else if display.builtin && CGDisplayIsBuiltin(display.id) != 0 {
                kind = .physical
            } else if display.mode.width <= 0 || display.mode.height <= 0 ||
                        display.mode.pixelWidth <= 0 || display.mode.pixelHeight <= 0 {
                kind = .headless
            } else if drivers == .displayLink {
                kind = .displayLink
            } else if drivers == .virtual {
                kind = .virtual
            } else {
                kind = .unknown
            }
            screens[display.id] = .init(kind: kind, online: true, active: display.active,
                                         awake: CGDisplayIsAsleep(display.id) == 0)
        }
        let hostArchitecture = Self.architecture()
        let architecture = hostArchitecture == "arm64" ? RecoveryEligibilityEnvironment.Architecture.appleSilicon :
            (hostArchitecture == "x86_64" ? .intel : .unknown)
        let lid: RecoveryEligibilityEnvironment.Lid = root.lid
        let mirrored = current.displays.contains { $0.mirrorUUID != nil }
        let driverEvidence: String
        switch drivers {
        case .displayLink: driverEvidence = "IOKit service plane contains a DisplayLink-named service"
        case .virtual: driverEvidence = "IOKit service plane contains a known virtual-display service"
        case .nativeOnly: driverEvidence = "not qualified"
        case .unknown:
            driverEvidence = "IOKit service plane found no recognized prohibited name, but no complete native-only inventory is qualified"
        }
        return RecoveryEligibilityEnvironment(architecture: architecture, drivers: drivers, lid: lid,
            mirrored: mirrored, screens: screens, driverInventory: driverEvidence)
    }

    static func lifecycleObservation() -> LifecycleObservation {
        let current = try? RecoverySnapshot.capture()
        let root = rootObservation()
        let screenAwake = Dictionary(uniqueKeysWithValues: (current?.displays ?? []).map {
            ($0.id, CGDisplayIsAsleep($0.id) == 0)
        })
        return lifecycleObservation(current: current, rootAwake: root.awake, lid: root.lid,
            consoleIsCurrent: consoleSessionIsCurrent(), screenAwake: screenAwake)
    }

    static func lifecycleObservation(current: RecoverySnapshot?, rootAwake: Bool?,
                                     lid: RecoveryEligibilityEnvironment.Lid, consoleIsCurrent: Bool,
                                     screenAwake: [UInt32: Bool]) -> LifecycleObservation {
        guard let current, rootAwake == true, consoleIsCurrent,
              current.displays.allSatisfy({ screenAwake[$0.id] == true }) else {
            return LifecycleObservation(awake: false, lid: lid,
                diagnostic: "system, console session or every online screen could not be positively observed awake")
        }
        return LifecycleObservation(awake: true, lid: lid,
            diagnostic: "IOPMrootDomain, console and CoreGraphics online screens observed awake")
    }

    static func rootObservation() -> (awake: Bool?, lid: RecoveryEligibilityEnvironment.Lid) {
        guard let matching = IOServiceMatching("IOPMrootDomain") else { return (nil, .unknown) }
        let service = IOServiceGetMatchingService(kIOMainPortDefault, matching)
        guard service != 0 else { return (nil, .unknown) }
        defer { IOObjectRelease(service) }
        guard let values = properties(service) else { return (nil, .unknown) }
        let power = values["IOPowerManagement"] as? [String: Any]
        let state = power.flatMap { number($0["CurrentPowerState"]) }
        let awake = state.map { $0 > 0 }
        let lid: RecoveryEligibilityEnvironment.Lid
        if let closed = bool(values["AppleClamshellState"]) {
            lid = closed ? .closed : .open
        } else {
            lid = .unknown
        }
        return (awake, lid)
    }

    private static func consoleSessionIsCurrent() -> Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return session[kCGSessionOnConsoleKey as String] as? Bool == true &&
            (session[kCGSessionUserIDKey as String] as? NSNumber)?.uint32Value == getuid()
    }

    private static func driverObservation() -> RecoveryEligibilityEnvironment.Drivers {
        guard let iterator = try? serviceIterator() else { return .unknown }
        defer { IOObjectRelease(iterator) }
        var foundDisplayLink = false
        var foundVirtual = false
        while true {
            let service = IOIteratorNext(iterator)
            if service == 0 { break }
            defer { IOObjectRelease(service) }
            let name = registryName(service).lowercased()
            let values = properties(service) ?? [:]
            let labels = ([name] + ["IOClass", "IONameMatched", "IOProviderClass", "CFBundleIdentifier"].compactMap { values[$0] as? String })
                .joined(separator: " ").lowercased()
            if labels.contains("displaylink") { foundDisplayLink = true }
            if ["virtualdisplay", "airplaydisplay", "sidecardisplay", "duetdisplay"].contains(where: labels.contains) {
                foundVirtual = true
            }
        }
        if foundDisplayLink { return .displayLink }
        if foundVirtual { return .virtual }
        return .unknown
    }

    private static func serviceIterator() throws -> io_iterator_t {
        var iterator: io_iterator_t = 0
        guard IORegistryCreateIterator(kIOMainPortDefault, kIOServicePlane,
                                       1, &iterator) == KERN_SUCCESS else {
            throw RecoveryError.unsafe("cannot enumerate IOKit service plane")
        }
        return iterator
    }

    private static func registryName(_ service: io_registry_entry_t) -> String {
        var bytes = [CChar](repeating: 0, count: 128)
        guard IORegistryEntryGetName(service, &bytes) == KERN_SUCCESS else { return "" }
        return String(cString: bytes)
    }

    private static func properties(_ service: io_registry_entry_t) -> [String: Any]? {
        var values: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &values, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let dictionary = values?.takeRetainedValue() as NSDictionary? else { return nil }
        return dictionary as? [String: Any]
    }

    private static func number(_ value: Any?) -> UInt32? {
        (value as? NSNumber)?.uint32Value ?? (value as? UInt32)
    }

    private static func bool(_ value: Any?) -> Bool? {
        (value as? NSNumber)?.boolValue ?? (value as? Bool)
    }

    private static func eisaVendor(_ value: String) -> UInt32? {
        let letters = Array(value.uppercased().utf8)
        guard letters.count == 3, letters.allSatisfy({ (65...90).contains($0) }) else { return nil }
        return UInt32(letters[0] - 64) << 10 | UInt32(letters[1] - 64) << 5 | UInt32(letters[2] - 64)
    }
}
