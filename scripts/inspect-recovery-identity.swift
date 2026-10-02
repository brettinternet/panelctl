#!/usr/bin/env swift
// Read-only evidence. Enumerates WindowServer-known IDs, never guesses IDs or
// invokes any display setter. Output can contain hardware serials/UUIDs.
import Foundation
import CoreGraphics
import AppKit
import IOKit
import CryptoKit
import Darwin

// The same private artifact convention as inspect-recovery-color.swift. No
// journal is read or replaced. Serials/paths belong in private evidence only.
let root = FileManager.default.temporaryDirectory.appendingPathComponent("panelctl-identity-inspection-\(UUID())")
try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                       attributes: [.posixPermissions: 0o700])
fputs("Identity evidence: \(root.path)\n", stderr)

func systemString(_ name: String) -> String? {
    var size = 0
    guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 1, size < 4096 else { return nil }
    var bytes = [CChar](repeating: 0, count: size)
    guard sysctlbyname(name, &bytes, &size, nil, 0) == 0 else { return nil }
    return String(cString: bytes)
}

// Independently enumerate registered objects, rather than following only a
// WindowServer-provided path. These are driver properties, NOT fresh sink reads.
func registeredServices(_ className: String) -> [String: Any] {
    guard let matching = IOServiceMatching(className) else { return ["error": "matching unavailable"] }
    var iterator: io_iterator_t = 0
    let status = IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator)
    guard status == KERN_SUCCESS else { return ["error": status] }
    defer { if iterator != 0 { IOObjectRelease(iterator) } }
    if iterator == 0 { return ["entries": [], "complete": true] }
    var rows: [[String: Any]] = []
    while rows.count < 32 {
        let entry = IOIteratorNext(iterator)
        if entry == 0 { return ["entries": rows, "complete": IOIteratorIsValid(iterator) != 0] }
        defer { IOObjectRelease(entry) }
        var row: [String: Any] = ["inServicePlane": IORegistryEntryInPlane(entry, kIOServicePlane) != 0]
        var entryID: UInt64 = 0, busy: UInt32 = 0
        row["entryIDStatus"] = IORegistryEntryGetRegistryEntryID(entry, &entryID)
        row["registryEntryID"] = entryID
        row["busyStatus"] = IOServiceGetBusyState(entry, &busy)
        row["busy"] = busy
        var path = [CChar](repeating: 0, count: 4096)
        row["pathStatus"] = IORegistryEntryGetPath(entry, kIOServicePlane, &path)
        if row["pathStatus"] as? kern_return_t == KERN_SUCCESS {
            let location = String(cString: path)
            row["path"] = location
            let again = IORegistryEntryFromPath(kIOMainPortDefault, location)
            row["sameObjectAtPathOnReread"] = again != 0 && IOObjectIsEqualTo(entry, again) != 0
            if again != 0 { IOObjectRelease(again) }
        }
        var properties: Unmanaged<CFMutableDictionary>?
        row["propertiesStatus"] = IORegistryEntryCreateCFProperties(entry, &properties, nil, 0)
        if let values = properties?.takeRetainedValue() as? [String: Any] {
            row["propertyKeys"] = values.keys.sorted()
            for key in ["IOClass", "IOProviderClass", "IOMatchedAtBoot", "IONameMatched",
                        "IOMFBUUID", "EDID UUID", "DisplayAttributes", "external",
                        "NormalModeActive", "NormalModeEnable", "DCPIndex", "Location", "Unit"] {
                row[key] = values[key]
            }
        }
        rows.append(row)
    }
    return ["entries": rows, "complete": false, "error": "service bound reached; do not infer completeness"]
}

let bootBefore = systemString("kern.bootsessionuuid")
let buildBefore = systemString("kern.osversion")
guard let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY | RTLD_LOCAL),
      let metadata = dlopen("/System/Library/Frameworks/CoreDisplay.framework/CoreDisplay", RTLD_LAZY | RTLD_LOCAL) else {
    fatalError("read-only identity framework unavailable")
}
defer { dlclose(handle); dlclose(metadata) }
typealias List = @convention(c) (UInt32, UnsafeMutablePointer<UInt32>?, UnsafeMutablePointer<UInt32>?) -> CGError
typealias Info = @convention(c) (UInt32) -> Unmanaged<CFDictionary>?
guard let listSymbol = dlsym(handle, "CGSGetDisplayList"),
      let infoSymbol = dlsym(metadata, "CoreDisplay_DisplayCreateInfoDictionary") else {
    fatalError("read-only identity API unavailable")
}
let list = unsafeBitCast(listSymbol, to: List.self)
let info = unsafeBitCast(infoSymbol, to: Info.self)
var ids = [UInt32](repeating: 0, count: 129)
var count: UInt32 = 0
guard list(129, &ids, &count) == .success, count > 0, count < 129,
      !ids.prefix(Int(count)).contains(0), Set(ids.prefix(Int(count))).count == Int(count) else {
    fatalError("invalid display list")
}
var onlineIDs = [UInt32](repeating: 0, count: 129), onlineCount: UInt32 = 0
guard CGGetOnlineDisplayList(129, &onlineIDs, &onlineCount) == .success, onlineCount > 0, onlineCount < 129 else {
    fatalError("invalid online list")
}
var output: [[String: Any]] = []
for id in ids.prefix(Int(count)) {
    var row: [String: Any] = ["id": id, "online": CGDisplayIsOnline(id) != 0,
                             "vendor": CGDisplayVendorNumber(id), "model": CGDisplayModelNumber(id),
                             "serial": CGDisplaySerialNumber(id), "active": CGDisplayIsActive(id) != 0,
                             "main": CGDisplayIsMain(id) != 0, "builtin": CGDisplayIsBuiltin(id) != 0]
    if CGDisplayIsOnline(id) != 0 {
        row["x"] = CGDisplayBounds(id).origin.x; row["y"] = CGDisplayBounds(id).origin.y
    }
    if let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() {
        row["uuid"] = CFUUIDCreateString(nil, uuid) as String
    }
    let values = info(id)?.takeRetainedValue() as? [String: Any]
    row["metadataKeys"] = values?.keys.sorted()
    if let location = values?["IODisplayLocation"] as? String {
        row["connector"] = location
        let entry = IORegistryEntryFromPath(kIOMainPortDefault, location)
        if entry != 0 {
            defer { IOObjectRelease(entry) }
            var entryID: UInt64 = 0
            if IORegistryEntryGetRegistryEntryID(entry, &entryID) == KERN_SUCCESS { row["registryEntryID"] = entryID }
            var properties: Unmanaged<CFMutableDictionary>?
            if IORegistryEntryCreateCFProperties(entry, &properties, nil, 0) == KERN_SUCCESS,
               let properties = properties?.takeRetainedValue() as? [String: Any] {
                for key in ["IOClass", "IOMFBUUID", "EDID UUID", "DisplayAttributes", "external"] {
                    row[key] = properties[key]
                }
                if let edid = properties["IODisplayEDID"] as? Data {
                    row["edidSHA256"] = SHA256.hash(data: edid).map { String(format: "%02x", $0) }.joined()
                }
            }
        }
    }
    output.append(row)
}
let services = ["IOMobileFramebufferShim": registeredServices("IOMobileFramebufferShim"),
                "DCPAVServiceProxy": registeredServices("DCPAVServiceProxy"),
                "AppleCLCD2": registeredServices("AppleCLCD2")]
let result: [String: Any] = ["capturedAt": ISO8601DateFormatter().string(from: Date()),
                            "bootSessionBefore": bootBefore as Any? ?? NSNull(),
                            "bootSessionAfter": systemString("kern.bootsessionuuid") as Any? ?? NSNull(),
                            "osBuildBefore": buildBefore as Any? ?? NSNull(),
                            "osBuildAfter": systemString("kern.osversion") as Any? ?? NSNull(),
                            "userID": getuid(), "registeredServices": services,
                            "note": "Non-atomic diagnostic, not an offline identity provider. Same object/path and driver properties do not prove a live physical sink. No lifetime notifications were collected.",
                            "CGGetOnlineDisplayList": Array(onlineIDs.prefix(Int(onlineCount))),
                            "CGSGetDisplayList": output,
                            "CGSConfigureDisplayEnabledPresent": dlsym(handle, "CGSConfigureDisplayEnabled") != nil,
                            "SLSConfigureDisplayEnabledPresent": dlsym(handle, "SLSConfigureDisplayEnabled") != nil,
                            "SLSGetDisplayListPresent": dlsym(handle, "SLSGetDisplayList") != nil]
let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
let report = root.appendingPathComponent("report.json")
try data.write(to: report, options: .withoutOverwriting)
try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: report.path)
FileHandle.standardOutput.write(data)
print()
