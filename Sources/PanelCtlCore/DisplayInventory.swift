import Foundation
import AppKit
import CoreGraphics

public struct DisplayBounds: Codable, Equatable {
    public let x: Double; public let y: Double; public let width: Double; public let height: Double
    init(_ r: CGRect) { x = r.origin.x; y = r.origin.y; width = r.size.width; height = r.size.height }
}

public struct DisplayRecord: Codable, Equatable {
    public let index: Int
    public let id: UInt32
    public let uuid: String?
    public let name: String?
    public let active: Bool
    public let online: Bool
    public let asleep: Bool
    public let builtin: Bool
    public let main: Bool
    public let vendor: UInt32
    public let model: UInt32
    public let serial: UInt32
    public let bounds: DisplayBounds
    public let pixelWidth: Int
    public let pixelHeight: Int
}

public enum DisplayInventory {
    public static func records() -> [DisplayRecord] {
        var onlineCount: UInt32 = 0
        var activeCount: UInt32 = 0
        var online = Array(repeating: CGDirectDisplayID(0), count: 32)
        var active = Array(repeating: CGDirectDisplayID(0), count: 32)
        CGGetOnlineDisplayList(UInt32(online.count), &online, &onlineCount)
        CGGetActiveDisplayList(UInt32(active.count), &active, &activeCount)
        let onlineIDs = Set(online.prefix(Int(onlineCount)))
        let activeIDs = Set(active.prefix(Int(activeCount)))
        let ids = onlineIDs.union(activeIDs).sorted()
        let screens = NSScreen.screens
        return ids.enumerated().map { offset, id in
            let screen = screens.first {
                ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id
            }
            let uuid: String?
            if let uuidRef = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() {
                uuid = CFUUIDCreateString(nil, uuidRef) as String
            } else {
                uuid = nil
            }
            return DisplayRecord(
                index: offset + 1,
                id: id,
                uuid: uuid,
                name: screen?.localizedName,
                active: activeIDs.contains(id),
                online: onlineIDs.contains(id),
                asleep: CGDisplayIsAsleep(id) != 0,
                builtin: CGDisplayIsBuiltin(id) != 0,
                main: CGDisplayIsMain(id) != 0,
                vendor: CGDisplayVendorNumber(id),
                model: CGDisplayModelNumber(id),
                serial: CGDisplaySerialNumber(id),
                bounds: DisplayBounds(CGDisplayBounds(id)),
                pixelWidth: CGDisplayPixelsWide(id),
                pixelHeight: CGDisplayPixelsHigh(id)
            )
        }
    }

    public static func printRecords(_ records: [DisplayRecord], json: Bool) throws {
        if json {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            FileHandle.standardOutput.write(try encoder.encode(records))
            print()
        } else if records.isEmpty {
            print("No online or active displays found (headless or no WindowServer context).")
        } else {
            for d in records {
                print("index=\(d.index) id=\(d.id) uuid=\(d.uuid ?? "-") name=\(d.name ?? "-") active=\(d.active) online=\(d.online) asleep=\(d.asleep) builtin=\(d.builtin) main=\(d.main) vendor=\(d.vendor) model=\(d.model) serial=\(d.serial) bounds=\(d.bounds.x),\(d.bounds.y) \(d.bounds.width)x\(d.bounds.height) pixels=\(d.pixelWidth)x\(d.pixelHeight)")
            }
        }
    }
}
