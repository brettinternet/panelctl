import Foundation
import IOKit

public struct SymbolEvidence: Codable, Equatable {
    public let library: String
    public let symbols: [String: Bool]
}

public struct AVServiceRecord: Codable, Equatable {
    public let registryEntryID: UInt64
    public let path: String?
    public let location: String?
    public let unit: String?
    public let ioavServiceUserInterfaceSupported: Bool?
}

public struct CLCDRecord: Codable, Equatable {
    public let registryEntryID: UInt64
    public let path: String?
    public let external: Bool?
    public let normalModeActive: Bool?
    public let dcpIndex: Int?
    public let ioNameMatched: String?
    public let edidUUID: String?
    public let manufacturer: String?
    public let productName: String?
    public let productID: Int?
    public let serial: Int?
    public let supportsStandby: Bool?
    public let supportsSuspend: Bool?
    public let supportsActiveOff: Bool?
}

public struct DDCReadAvailability: Codable, Equatable {
    public enum Status: String, Codable {
        case readable, notApplicable, noController, ambiguousMapping, unsupported, transportError
    }
    public let status: Status
    public let detail: String?
}

public struct DDCDisplayAvailability: Codable, Equatable {
    public let displayID: UInt32
    public let input: DDCReadAvailability
    public let luminance: DDCReadAvailability
}

public struct ProbeReport: Codable, Equatable {
    public let displays: [DisplayRecord]
    public let os: String
    public let architecture: String
    public let symbols: [SymbolEvidence]
    public let avServices: [AVServiceRecord]
    public let clcdServices: [CLCDRecord]
    public let ddc: [DDCDisplayAvailability]
    public let ddcNotice: String
}

public enum Probe {
    public static let ddcNotice = "DDC Get VCP reads only; a successful read is not write qualification."

    public static func report() -> ProbeReport {
        let displays = DisplayInventory.records()
        let arch = architecture()
        return ProbeReport(displays: displays, os: ProcessInfo.processInfo.operatingSystemVersionString,
                           architecture: arch, symbols: symbolEvidence(), avServices: avServices(), clcdServices: clcdServices(),
                           ddc: ddcAvailability(displays: displays, architecture: arch), ddcNotice: ddcNotice)
    }

    static func ddcAvailability(
        displays: [DisplayRecord], architecture: String,
        open: (DisplayRecord) throws -> DDCChannel = { display in
            // Numeric selectors are CG IDs, never inventory indexes.
            try DDC.open(selector: String(display.id)).channel
        }
    ) -> [DDCDisplayAvailability] {
        func failure(_ error: Error) -> DDCReadAvailability {
            let status: DDCReadAvailability.Status
            switch error as? DDCError {
            case .controllerNotFound: status = .noController
            case .ambiguousController: status = .ambiguousMapping
            case .reportedUnsupported, .symbolUnavailable: status = .unsupported
            case .unsupportedArchitecture: status = .notApplicable
            default: status = .transportError
            }
            return DDCReadAvailability(status: status, detail: String(describing: error))
        }
        return displays.map { display in
            func both(_ result: DDCReadAvailability) -> DDCDisplayAvailability {
                DDCDisplayAvailability(displayID: display.id, input: result, luminance: result)
            }
            guard architecture == "arm64" else {
                return both(DDCReadAvailability(status: .notApplicable, detail: "DDC requires arm64"))
            }
            guard !display.builtin, display.active, display.online else {
                return both(DDCReadAvailability(status: .notApplicable, detail: "DDC requires an active online external display"))
            }
            do {
                let channel = try open(display)
                func read(_ code: UInt8) -> DDCReadAvailability {
                    do {
                        _ = try channel.getVCP(code)
                        return DDCReadAvailability(status: .readable, detail: nil)
                    } catch { return failure(error) }
                }
                return DDCDisplayAvailability(displayID: display.id, input: read(DDCInput.inputVCP),
                                              luminance: read(DDCLuminance.luminanceVCP))
            } catch { return both(failure(error)) }
        }
    }

    static func ddcText(_ report: ProbeReport) -> String {
        func value(_ result: DDCReadAvailability) -> String {
            result.status.rawValue + (result.detail.map { " (\($0))" } ?? "")
        }
        return ([report.ddcNotice] + report.ddc.map {
            "DDC displayID=\($0.displayID) input(0x60)=\(value($0.input)) luminance(0x10)=\(value($0.luminance))"
        }).joined(separator: "\n")
    }

    public static func printReport(_ report: ProbeReport, json: Bool) throws {
        if json {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            FileHandle.standardOutput.write(try encoder.encode(report)); print()
        } else {
            print("OS: \(report.os)"); print("Architecture: \(report.architecture)")
            if report.displays.isEmpty { print("Displays: none (headless or no WindowServer context)") }
            else {
                for d in report.displays {
                    let uuid = d.uuid ?? "-"; let name = d.name ?? "-"
                    print("Display index=\(d.index) id=\(d.id) uuid=\(uuid) name=\(name) active=\(d.active) online=\(d.online) asleep=\(d.asleep) builtin=\(d.builtin) main=\(d.main) vendor=\(d.vendor) model=\(d.model) serial=\(d.serial) bounds=\(d.bounds.x),\(d.bounds.y) \(d.bounds.width)x\(d.bounds.height) pixels=\(d.pixelWidth)x\(d.pixelHeight)")
                }
            }
            print(ddcText(report))
            for evidence in report.symbols {
                let values = evidence.symbols.keys.sorted().map { "\($0)=\(evidence.symbols[$0] == true)" }.joined(separator: " ")
                print("Symbols \(evidence.library): \(values)")
            }
            print("DCPAVServiceProxy services: \(report.avServices.count)")
            for service in report.avServices {
                print("  entryID=\(service.registryEntryID) path=\(service.path ?? "-") Location=\(service.location ?? "-") Unit=\(service.unit ?? "-") IOAVServiceUserInterfaceSupported=\(service.ioavServiceUserInterfaceSupported.map(String.init) ?? "-")")
            }
            print("AppleCLCD2 services: \(report.clcdServices.count)")
            for service in report.clcdServices {
                print("  entryID=\(service.registryEntryID) path=\(service.path ?? "-") external=\(service.external.map(String.init) ?? "-") NormalModeActive=\(service.normalModeActive.map(String.init) ?? "-") DCPIndex=\(service.dcpIndex.map(String.init) ?? "-") IONameMatched=\(service.ioNameMatched ?? "-") EDIDUUID=\(service.edidUUID ?? "-") manufacturer=\(service.manufacturer ?? "-") product=\(service.productName ?? "-") productID=\(service.productID.map(String.init) ?? "-") serial=\(service.serial.map(String.init) ?? "-") SupportsStandby=\(service.supportsStandby.map(String.init) ?? "-") SupportsSuspend=\(service.supportsSuspend.map(String.init) ?? "-") SupportsActiveOff=\(service.supportsActiveOff.map(String.init) ?? "-")")
            }
        }
    }

    private static func architecture() -> String {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x86_64"
        #else
        return "unknown"
        #endif
    }

    private static func symbolEvidence() -> [SymbolEvidence] {
        let groups: [(String, String, [String])] = [
            ("CoreGraphics", "/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", ["CGSConfigureDisplayEnabled"]),
            ("DisplayServices", "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", ["DisplayServicesSetPowerMode"]),
            ("IOKit", "/System/Library/Frameworks/IOKit.framework/IOKit", ["IOAVServiceReadI2C", "IOAVServiceWriteI2C", "IOAVServiceGetPower", "IOAVServiceStartLink", "IOAVServiceStopLink"]),
            ("CoreDisplay", "/System/Library/Frameworks/CoreDisplay.framework/CoreDisplay", ["CoreDisplay_DisplayCreateInfoDictionary"])
        ]
        return groups.map { name, path, symbols in
            let handle = dlopen(path, RTLD_LAZY | RTLD_FIRST)
            var result: [String: Bool] = [:]
            for symbol in symbols { result[symbol] = handle != nil && dlsym(handle, symbol) != nil }
            if let handle { dlclose(handle) }
            return SymbolEvidence(library: name, symbols: result)
        }
    }

    private static func avServices() -> [AVServiceRecord] {
        guard let matching = IOServiceMatching("DCPAVServiceProxy") else { return [] }
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }
        var result: [AVServiceRecord] = []
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            var entryID: UInt64 = 0; IORegistryEntryGetRegistryEntryID(service, &entryID)
            var pathBuffer = [CChar](repeating: 0, count: 1024)
            let path = IORegistryEntryGetPath(service, kIOServicePlane, &pathBuffer) == KERN_SUCCESS ? String(cString: pathBuffer) : nil
            var properties: Unmanaged<CFMutableDictionary>?
            let location: String?; let unit: String?; let supported: Bool?
            if IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS,
               let dict = properties?.takeRetainedValue() as? [String: Any] {
                location = dict["Location"] as? String ?? (dict["Location"] as? NSNumber).map(String.init)
                unit = dict["Unit"] as? String ?? (dict["Unit"] as? NSNumber).map(String.init)
                supported = (dict["IOAVServiceUserInterfaceSupported"] as? NSNumber)?.boolValue ?? (dict["IOAVServiceUserInterfaceSupported"] as? Bool)
            } else { location = nil; unit = nil; supported = nil }
            result.append(AVServiceRecord(registryEntryID: entryID, path: path, location: location, unit: unit, ioavServiceUserInterfaceSupported: supported))
        }
        return result
    }

    private static func clcdServices() -> [CLCDRecord] {
        guard let matching = IOServiceMatching("AppleCLCD2") else { return [] }
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }
        var result: [CLCDRecord] = []
        while true {
            let service = IOIteratorNext(iterator); if service == 0 { break }
            defer { IOObjectRelease(service) }
            var entryID: UInt64 = 0; IORegistryEntryGetRegistryEntryID(service, &entryID)
            var pathBuffer = [CChar](repeating: 0, count: 1024)
            let path = IORegistryEntryGetPath(service, kIOServicePlane, &pathBuffer) == KERN_SUCCESS ? String(cString: pathBuffer) : nil
            var properties: Unmanaged<CFMutableDictionary>?
            var values: [String: Any] = [:]
            if IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS,
               let dict = properties?.takeRetainedValue() as? [String: Any] { values = dict }
            let attrs = values["DisplayAttributes"] as? [String: Any] ?? (values["DisplayAttributes"] as? NSDictionary as? [String: Any]) ?? [:]
            func bool(_ key: String) -> Bool? { (values[key] as? NSNumber)?.boolValue ?? (values[key] as? Bool) ?? (attrs[key] as? NSNumber)?.boolValue ?? (attrs[key] as? Bool) }
            func int(_ key: String) -> Int? { (values[key] as? NSNumber)?.intValue ?? (values[key] as? Int) }
            func string(_ key: String) -> String? { values[key] as? String ?? (values[key] as? NSString).map(String.init) }
            let product = attrs["ProductAttributes"] as? [String: Any] ?? (attrs["ProductAttributes"] as? NSDictionary as? [String: Any]) ?? [:]
            let matched = string("IONameMatched")
            result.append(CLCDRecord(registryEntryID: entryID, path: path, external: bool("external") ?? matched?.hasPrefix("dispext"), normalModeActive: bool("NormalModeActive"), dcpIndex: int("DCPIndex"), ioNameMatched: matched, edidUUID: string("EDID UUID") ?? string("EDIDUUID") ?? string("UUID"), manufacturer: product["ManufacturerID"] as? String ?? product["Manufacturer"] as? String, productName: product["ProductName"] as? String, productID: (product["ProductID"] as? NSNumber)?.intValue ?? product["ProductID"] as? Int, serial: (product["SerialNumber"] as? NSNumber)?.intValue ?? product["SerialNumber"] as? Int, supportsStandby: bool("SupportsStandby"), supportsSuspend: bool("SupportsSuspend"), supportsActiveOff: bool("SupportsActiveOff")))
        }
        return result
    }
}
