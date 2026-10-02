import Foundation
import AppKit
import CoreGraphics
import IOKit
import Darwin

/// Same read-only CGS enumeration/registry evidence as inspect-recovery-identity.
/// No setter is resolved, and no saved/callback/guessed CG ID is inspected.
enum IdentityObservationInventory {
    static let classes = ["IOMobileFramebufferShim", "DCPAVServiceProxy", "AppleCLCD2"]

    static func require(_ condition: Bool, _ reason: String) throws {
        if !condition { throw RecoveryError.unsafe(reason) }
    }

    static func context() throws -> [String: Any] {
        func system(_ name: String) throws -> String {
            var size = 0
            try require(sysctlbyname(name, nil, &size, nil, 0) == 0 && size > 1 && size < 4096,
                        "missing context: \(name)")
            var value = [CChar](repeating: 0, count: size)
            try require(sysctlbyname(name, &value, &size, nil, 0) == 0, "missing context: \(name)")
            return String(cString: value)
        }
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any],
              session[kCGSessionOnConsoleKey as String] as? Bool == true,
              (session[kCGSessionUserIDKey as String] as? NSNumber)?.uint32Value == getuid(),
              let sessionID = session["kCGSSessionIDKey"] as? NSNumber else {
            throw RecoveryError.unsafe("missing console/session context")
        }
        var pids = [Int32](repeating: 0, count: 4096)
        let count = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<Int32>.size))
        try require(count > 0 && count < pids.count, "missing/bounded process context")
        var servers: [[String: Any]] = []
        for pid in pids.prefix(Int(count)) where pid > 0 {
            var info = proc_bsdinfo()
            if proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout.size(ofValue: info))) != MemoryLayout.size(ofValue: info) { continue }
            let name = withUnsafeBytes(of: info.pbi_comm) { bytes in
                String(decoding: bytes.prefix(while: { $0 != 0 }), as: UTF8.self)
            }
            if name == "WindowServer" {
                try require(info.pbi_start_tvsec > 0, "missing WindowServer lifetime")
                servers.append(["pid": pid, "startSeconds": info.pbi_start_tvsec, "startMicroseconds": info.pbi_start_tvusec])
            }
        }
        try require(servers.count == 1, "missing/ambiguous WindowServer lifetime context")
        return ["bootSession": try system("kern.bootsessionuuid"), "osBuild": try system("kern.osversion"),
                "userID": getuid(), "consoleSessionID": sessionID, "onConsole": true, "windowServer": servers[0]]
    }

    static func value(_ input: Any, depth: Int = 0) throws -> Any {
        try require(depth <= 6, "registry property depth overflow")
        if let data = input as? Data {
            try require(data.count <= 1_048_576, "registry data overflow")
            return ["byteCount": data.count, "sha256": RecoveryColorProfile.digest(data)]
        }
        if let string = input as? String {
            try require(string.utf8.count <= 4096, "registry string overflow"); return string
        }
        if let dict = input as? [String: Any] {
            try require(dict.count <= 64, "registry dictionary overflow")
            var result: [String: Any] = [:]
            for (key, item) in dict {
                try require(key.utf8.count <= 256, "registry key overflow")
                result[key] = try value(item, depth: depth + 1)
            }
            return result
        }
        if let array = input as? [Any] {
            try require(array.count <= 64, "registry array overflow")
            return try array.map { try value($0, depth: depth + 1) }
        }
        if input is NSNumber || input is NSNull { return input }
        throw RecoveryError.unsafe("unsupported registry property type")
    }

    static func service(_ entry: io_service_t) throws -> [String: Any] {
        var id: UInt64 = 0, busy: UInt32 = 0
        var path = [CChar](repeating: 0, count: 4096)
        let idStatus = IORegistryEntryGetRegistryEntryID(entry, &id)
        let pathStatus = IORegistryEntryGetPath(entry, kIOServicePlane, &path)
        let busyStatus = IOServiceGetBusyState(entry, &busy)
        var row: [String: Any] = ["entryIDStatus": idStatus, "registryEntryID": id,
            "pathStatus": pathStatus, "busyStatus": busyStatus, "busy": busy,
            "inServicePlane": IORegistryEntryInPlane(entry, kIOServicePlane) != 0]
        if pathStatus == KERN_SUCCESS { row["path"] = String(cString: path) }
        // Selected reads avoid copying unbounded whole property dictionaries.
        var properties: [String: Any] = [:]
        for key in ["IOClass", "IOProviderClass", "IOMatchedAtBoot", "IOMFBUUID", "EDID UUID",
                    "DisplayAttributes", "IODisplayEDID", "external", "NormalModeActive",
                    "NormalModeEnable", "DCPIndex", "Location", "Unit"] {
            if let property = IORegistryEntryCreateCFProperty(entry, key as CFString, nil, 0)?.takeRetainedValue() {
                properties[key] = try value(property)
            } else { properties[key] = NSNull() }
        }
        row["properties"] = properties
        row["identityReadable"] = idStatus == KERN_SUCCESS && pathStatus == KERN_SUCCESS
        return row
    }

    static func displays() throws -> [String: Any] {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY | RTLD_LOCAL) else {
            throw RecoveryError.unsafe("read-only enumeration unavailable")
        }
        defer { dlclose(handle) }
        typealias List = @convention(c) (UInt32, UnsafeMutablePointer<UInt32>?, UnsafeMutablePointer<UInt32>?) -> CGError
        guard let symbol = dlsym(handle, "CGSGetDisplayList") else { throw RecoveryError.unsafe("CGS enumeration unavailable") }
        let list = unsafeBitCast(symbol, to: List.self)
        var ids = [UInt32](repeating: 0, count: 129), online = ids
        var count: UInt32 = 0, onlineCount: UInt32 = 0
        let status = list(129, &ids, &count), onlineStatus = CGGetOnlineDisplayList(129, &online, &onlineCount)
        try require(status == .success && onlineStatus == .success, "display enumeration failure")
        try require(count > 0 && count < 129 && onlineCount > 0 && onlineCount < 129, "display inventory overflow/empty")
        ids = Array(ids.prefix(Int(count))); online = Array(online.prefix(Int(onlineCount)))
        try require(!ids.contains(0) && Set(ids).count == ids.count && !online.contains(0)
                    && Set(online).count == online.count && Set(online).isSubset(of: Set(ids)), "ambiguous display inventory")
        let metadata = try CoreDisplayMetadata()
        let rows = try ids.map { id -> [String: Any] in
            var row: [String: Any] = ["id": id, "online": CGDisplayIsOnline(id) != 0,
                "active": CGDisplayIsActive(id) != 0, "main": CGDisplayIsMain(id) != 0,
                "builtin": CGDisplayIsBuiltin(id) != 0, "vendor": CGDisplayVendorNumber(id),
                "model": CGDisplayModelNumber(id), "serial": CGDisplaySerialNumber(id)]
            if let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() {
                row["uuid"] = (CFUUIDCreateString(nil, uuid) as String).lowercased()
            } else { row["uuid"] = NSNull() }
            if online.contains(id) {
                row["x"] = CGDisplayBounds(id).origin.x; row["y"] = CGDisplayBounds(id).origin.y
            }
            if let info = metadata.info(id)?.takeRetainedValue() as? [String: Any],
               let path = info["IODisplayLocation"] as? String {
                row["connector"] = try value(path)
                let entry = IORegistryEntryFromPath(kIOMainPortDefault, path)
                if entry != 0 { defer { IOObjectRelease(entry) }; row["service"] = try service(entry) }
                else { row["serviceMissing"] = true }
            } else { row["metadataMissing"] = true }
            return row
        }
        return ["publicStatus": onlineStatus.rawValue, "privateStatus": status.rawValue,
                "onlineIDs": online.sorted(), "displays": rows.sorted { ($0["id"] as! UInt32) < ($1["id"] as! UInt32) }]
    }
}
