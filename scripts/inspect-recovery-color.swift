#!/usr/bin/env swift
// Read-only display/ColorSync inspection. Writes private diagnostic artifacts,
// never changes display configuration or profile selection. Optional argument:
// a retained recovery journal to compare full ICC SHA-256 values against.
import Foundation
import AppKit
import CoreGraphics
import ColorSync
import CryptoKit
import Darwin

struct InspectionError: Error { let reason: String }
func require(_ condition: Bool, _ reason: String) throws {
    if !condition { throw InspectionError(reason: reason) }
}
func digest(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}
func jsonValue(_ value: Any) -> Any {
    if let url = value as? URL { return url.absoluteString }
    if let data = value as? Data { return ["byteCount": data.count, "sha256": digest(data)] }
    if let dict = value as? [String: Any] { return dict.mapValues(jsonValue) }
    if let array = value as? [Any] { return array.map(jsonValue) }
    if value is String || value is NSNumber || value is NSNull { return value }
    return String(describing: value)
}
func save(_ data: Data, to url: URL) throws {
    try require(!FileManager.default.fileExists(atPath: url.path), "refusing to replace an artifact")
    try data.write(to: url, options: .withoutOverwriting)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
}

func run() throws {
    try require(CommandLine.arguments.count <= 2, "usage: swift scripts/inspect-recovery-color.swift [journal.json]")
    var previous: [String: [String: Any]] = [:]
    if CommandLine.arguments.count == 2 {
        let url = URL(fileURLWithPath: CommandLine.arguments[1])
        let data = try Data(contentsOf: url)
        try require(data.count <= 1_048_576, "journal too large")
        guard let journal = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let snapshot = journal["snapshot"] as? [String: Any],
              let displays = snapshot["displays"] as? [[String: Any]] else {
            throw InspectionError(reason: "invalid journal")
        }
        for display in displays {
            guard let uuid = display["uuid"] as? String, previous[uuid.lowercased()] == nil else {
                throw InspectionError(reason: "missing/duplicate journal UUID")
            }
            previous[uuid.lowercased()] = display
        }
    }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("panelctl-color-inspection-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                           attributes: [.posixPermissions: 0o700])
    print("Color evidence: \(root.path)")
    fflush(stdout)
    try save(Data("panelctl read-only color evidence\n".utf8), to: root.appendingPathComponent(".panelctl-test-owned"))
    var count: UInt32 = 0
    var ids = [UInt32](repeating: 0, count: 129)
    try require(CGGetOnlineDisplayList(129, &ids, &count) == .success && count > 0 && count < 129,
                "unavailable/truncated online inventory")
    let online = Array(ids.prefix(Int(count)))
    var rows: [[String: Any]] = []
    for id in online {
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() else {
            throw InspectionError(reason: "display has no UUID")
        }
        let name = (CFUUIDCreateString(nil, uuid) as String).lowercased()
        let space = CGDisplayCopyColorSpace(id)
        var row: [String: Any] = ["uuid": name, "id": id, "vendor": CGDisplayVendorNumber(id),
            "model": CGDisplayModelNumber(id), "serial": CGDisplaySerialNumber(id),
            "x": CGDisplayBounds(id).origin.x, "y": CGDisplayBounds(id).origin.y,
            "rotation": CGDisplayRotation(id), "colorSpaceName": space.name as String? ?? NSNull() as Any]
        if let profile = space.copyICCData() as Data? {
            let filename = "\(name).icc"
            try save(profile, to: root.appendingPathComponent(filename))
            row["iccFile"] = filename; row["iccBytes"] = profile.count; row["iccSHA256"] = digest(profile)
            if profile.count >= 128, profile[36..<40] == Data("acsp".utf8) {
                row["iccCreationTimeComponents"] = stride(from: 24, to: 36, by: 2).map {
                    Int(profile[$0]) * 256 + Int(profile[$0 + 1])
                }
            }
            row["repeatedReadEqual"] = CGDisplayCopyColorSpace(id).copyICCData() as Data? == profile
            if let baseline = previous[name] {
                row["journalICCEqual"] = baseline["colorProfileDigest"] as? String == digest(profile)
                row["journalICC"] = baseline["colorProfileDigest"] ?? NSNull()
            }
        } else { row["iccUnavailable"] = true }
        if let info = ColorSyncDeviceCopyDeviceInfo(kColorSyncDisplayDeviceClass.takeUnretainedValue(), uuid)?.takeRetainedValue(),
           var values = info as? [String: Any] {
            values["DeviceID"] = name
            row["colorSyncDevice"] = jsonValue(values)
        }
        rows.append(row)
    }
    let report: [String: Any] = ["capturedAt": ISO8601DateFormatter().string(from: Date()),
                                "osVersion": ProcessInfo.processInfo.operatingSystemVersionString,
                                "displays": rows,
                                "note": "ICC bytes are evidence only. No normalization, color equivalence, or restoration is inferred."]
    let json = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
    try save(json, to: root.appendingPathComponent("report.json"))
    FileHandle.standardOutput.write(json)
    print()
}
do { try run() }
catch { fputs("Color inspection failed: \(error)\n", stderr); exit(1) }
