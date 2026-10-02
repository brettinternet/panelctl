#!/usr/bin/env swift
// Read-only evidence. Enumerates WindowServer-known IDs, never guesses IDs or
// invokes any display setter. Output can contain hardware serials/UUIDs.
import Foundation
import CoreGraphics
import AppKit
import IOKit
import CryptoKit

let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY | RTLD_LOCAL)!
let metadata = dlopen("/System/Library/Frameworks/CoreDisplay.framework/CoreDisplay", RTLD_LAZY | RTLD_LOCAL)!
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
guard list(129, &ids, &count) == .success, count < 129 else { fatalError("invalid display list") }
var output: [[String: Any]] = []
for id in ids.prefix(Int(count)) {
    var row: [String: Any] = ["id": id, "online": CGDisplayIsOnline(id) != 0,
                             "vendor": CGDisplayVendorNumber(id), "model": CGDisplayModelNumber(id),
                             "serial": CGDisplaySerialNumber(id)]
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
let result: [String: Any] = ["CGSGetDisplayList": output,
                            "CGSConfigureDisplayEnabledPresent": dlsym(handle, "CGSConfigureDisplayEnabled") != nil,
                            "SLSConfigureDisplayEnabledPresent": dlsym(handle, "SLSConfigureDisplayEnabled") != nil,
                            "SLSGetDisplayListPresent": dlsym(handle, "SLSGetDisplayList") != nil]
FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]))
