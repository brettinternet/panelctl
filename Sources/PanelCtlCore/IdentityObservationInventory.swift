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
        let console = try consoleContext(CGSessionCopyCurrentDictionary() as? [String: Any])
        // proc_pidinfo denies WindowServer on this host. Public KERN_PROC_ALL
        // exposes the same PID + microsecond process-start context without sudo.
        var processes = [kinfo_proc](repeating: kinfo_proc(), count: 4096)
        let capacity = processes.count * MemoryLayout<kinfo_proc>.stride
        var size = capacity
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        let status = sysctl(&mib, 4, &processes, &size, nil, 0)
        try require(status == 0 && size > 0 && size < capacity && size % MemoryLayout<kinfo_proc>.stride == 0,
                    "missing/bounded process context")
        var servers: [[String: Any]] = []
        for process in processes.prefix(size / MemoryLayout<kinfo_proc>.stride) {
            let info = process.kp_proc
            let name = withUnsafeBytes(of: info.p_comm) { bytes in
                String(decoding: bytes.prefix(while: { $0 != 0 }), as: UTF8.self)
            }
            if name == "WindowServer" {
                let start = info.p_un.__p_starttime
                try require(info.p_pid > 0 && start.tv_sec > 0 && (0..<1_000_000).contains(start.tv_usec), "missing WindowServer lifetime")
                servers.append(["pid": info.p_pid, "startSeconds": start.tv_sec, "startMicroseconds": start.tv_usec])
            }
        }
        try require(servers.count == 1, "missing/ambiguous WindowServer lifetime context")
        return ["bootSession": try system("kern.bootsessionuuid"), "osBuild": try system("kern.osversion"),
                "userID": getuid(), "console": console, "windowServer": servers[0]]
    }

    static func consoleContext(_ session: [String: Any]?) throws -> [String: Any] {
        guard let session,
              session[kCGSessionOnConsoleKey as String] as? Bool == true,
              (session[kCGSessionUserIDKey as String] as? NSNumber)?.uint32Value == getuid(),
              let auditID = session["kCGSSessionAuditIDKey"] as? NSNumber, auditID.int64Value > 0,
              let uuid = session["CGSSessionUniqueSessionUUID"] as? String, UUID(uuidString: uuid) != nil else {
            throw RecoveryError.unsafe("missing console/session context")
        }
        // These dictionary fields are observed context, not an identity contract.
        // Require both; no PID-only/session-ID fallback when either disappears.
        return ["onConsole": true, "auditID": auditID, "sessionUUID": uuid]
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

    static func displays(validateService: ([String: Any]) throws -> Void) throws -> [String: Any] {
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
                guard entry != 0 else { throw RecoveryError.unsafe("enumerated CG service missing") }
                defer { IOObjectRelease(entry) }
                let serviceRow = try service(entry)
                try validateService(serviceRow)
                row["service"] = serviceRow
            } else { throw RecoveryError.unsafe("enumerated CG metadata missing") }
            return row
        }
        return ["publicStatus": onlineStatus.rawValue, "privateStatus": status.rawValue,
                "onlineIDs": online.sorted(), "displays": rows.sorted { ($0["id"] as! UInt32) < ($1["id"] as! UInt32) }]
    }
}
