import Foundation
import AppKit
import CoreGraphics
import IOKit
import Darwin

/// A read-only MCCS luminance result. DDC/CI requires an I2C request write
/// followed by a read for this query, but the request is Get VCP Feature only
/// and does not change a monitor value.
public struct DDCLuminanceReading: Equatable, Codable {
    public let displayID: UInt32
    public let uuid: String
    public let current: UInt16
    public let maximum: UInt16

    public init(displayID: UInt32, uuid: String, current: UInt16, maximum: UInt16) {
        self.displayID = displayID
        self.uuid = uuid
        self.current = current
        self.maximum = maximum
    }
}

public struct DDCLuminanceWriteResult: Equatable, Codable {
    public let displayID: UInt32
    public let uuid: String
    public let original: UInt16
    public let requested: UInt16
    public let observed: UInt16
    public let maximum: UInt16
}

public enum DDCLuminanceError: Error, Equatable, CustomStringConvertible {
    case unsupportedArchitecture
    case displayNotFound(String)
    case displayMetadataUnavailable(UInt32)
    case symbolUnavailable(String)
    case transportUnavailable(String)
    case controllerNotFound(String)
    case requestFailed(Int32)
    case invalidReply(String)
    case reportedUnsupported(UInt8)
    case wrongVCP(expected: UInt8, actual: UInt8)
    case valueOutOfRange(value: UInt16, maximum: UInt16)
    case verificationFailed(original: UInt16, expected: UInt16, actual: UInt16, uuid: String)
    case writeStateUnknown(original: UInt16, uuid: String, detail: String)

    public var description: String {
        switch self {
        case .unsupportedArchitecture: return "DDC luminance control requires Apple Silicon (arm64)"
        case .displayNotFound(let selector): return "no active external display matches selector \(selector)"
        case .displayMetadataUnavailable(let id): return "CoreDisplay metadata is unavailable for display \(id)"
        case .symbolUnavailable(let symbol): return "required private symbol is unavailable: \(symbol)"
        case .transportUnavailable(let detail): return "DDC transport is unavailable: \(detail)"
        case .controllerNotFound(let location): return "no external DCPAVServiceProxy matches display location \(location)"
        case .requestFailed(let status): return "DDC I2C request failed (IOReturn \(status))"
        case .invalidReply(let detail): return "invalid DDC luminance reply: \(detail)"
        case .reportedUnsupported(let code): return String(format: "monitor reports VCP 0x%02X unsupported", code)
        case .wrongVCP(let expected, let actual): return String(format: "DDC reply returned VCP 0x%02X, expected 0x%02X", actual, expected)
        case .valueOutOfRange(let value, let maximum): return "luminance \(value) exceeds the monitor maximum \(maximum)"
        case .verificationFailed(let original, let expected, let actual, let uuid):
            return "DDC luminance write was not verified (expected \(expected), read \(actual)); restore \(uuid) with: panelctl ddc-luminance --display \(uuid) --set \(original)"
        case .writeStateUnknown(let original, let uuid, let detail):
            return "DDC luminance state is unknown after the write attempt (\(detail)); restore \(uuid) with: panelctl ddc-luminance --display \(uuid) --set \(original)"
        }
    }
}

/// DDC/CI luminance access for active external displays on Apple Silicon.
public enum DDCLuminance {
    public static let luminanceVCP: UInt8 = 0x10

    // The DDC/CI framing and Apple Silicon IOAVService transport are based on
    // the MIT-licensed waydabber/m1ddc implementation (protocol reference).

    public static func read(selector: String) throws -> DDCLuminanceReading {
        #if arch(arm64)
        let session = try open(selector: selector)
        let values = try readValues(transport: session.transport, service: session.service)
        let display = session.display
        return DDCLuminanceReading(displayID: display.id, uuid: display.uuid, current: values.current, maximum: values.maximum)
        #else
        throw DDCLuminanceError.unsupportedArchitecture
        #endif
    }

    public static func set(selector: String, value: UInt16) throws -> DDCLuminanceWriteResult {
        #if arch(arm64)
        let session = try open(selector: selector)
        let original = try readValues(transport: session.transport, service: session.service)
        guard value <= original.maximum else {
            throw DDCLuminanceError.valueOutOfRange(value: value, maximum: original.maximum)
        }

        var observed = original.current
        do {
            for _ in 0..<2 {
                try writeValue(value, transport: session.transport, service: session.service)
                usleep(50_000)
                observed = try readValues(transport: session.transport, service: session.service).current
                if observed == value { break }
            }
        } catch {
            throw DDCLuminanceError.writeStateUnknown(
                original: original.current,
                uuid: session.display.uuid,
                detail: String(describing: error)
            )
        }
        guard observed == value else {
            throw DDCLuminanceError.verificationFailed(
                original: original.current,
                expected: value,
                actual: observed,
                uuid: session.display.uuid
            )
        }
        return DDCLuminanceWriteResult(
            displayID: session.display.id,
            uuid: session.display.uuid,
            original: original.current,
            requested: value,
            observed: observed,
            maximum: original.maximum
        )
        #else
        throw DDCLuminanceError.unsupportedArchitecture
        #endif
    }

    // MARK: Pure protocol helpers (kept internal for unit tests)

    static func makeGetVCPRequest(code: UInt8) -> [UInt8] {
        let body: [UInt8] = [0x82, 0x01, code]
        return body + [0x6E ^ body[0] ^ body[1] ^ body[2]]
    }

    static func makeSetVCPRequest(code: UInt8, value: UInt16) -> [UInt8] {
        let body: [UInt8] = [0x84, 0x03, code, UInt8(value >> 8), UInt8(value & 0xFF)]
        return body + [0x6E ^ 0x51 ^ body.reduce(0, ^)]
    }

    static func validateReply(_ bytes: [UInt8], expectedCode: UInt8) throws -> (current: UInt16, maximum: UInt16) {
        guard bytes.count >= 11 else { throw DDCLuminanceError.invalidReply("reply is shorter than 11 bytes") }
        let frame = Array(bytes.prefix(11))
        guard (frame[1] & 0x7F) >= 0x06 else { throw DDCLuminanceError.invalidReply("invalid payload length") }
        guard frame[0] == 0x6E else { throw DDCLuminanceError.invalidReply("unexpected source address") }
        guard frame[2] == 0x02 else { throw DDCLuminanceError.invalidReply("not a Get VCP Feature reply") }
        guard (0x50 ^ frame.reduce(0, ^)) == 0 else { throw DDCLuminanceError.invalidReply("checksum mismatch") }
        if frame[3] == 0x01 { throw DDCLuminanceError.reportedUnsupported(frame[4]) }
        guard frame[3] == 0x00 else { throw DDCLuminanceError.invalidReply(String(format: "monitor result code 0x%02X", frame[3])) }
        guard frame[4] == expectedCode else { throw DDCLuminanceError.wrongVCP(expected: expectedCode, actual: frame[4]) }
        let maximum = UInt16(frame[6]) << 8 | UInt16(frame[7])
        let current = UInt16(frame[8]) << 8 | UInt16(frame[9])
        guard maximum > 0, current <= maximum else { throw DDCLuminanceError.invalidReply("current/max values are out of range") }
        return (current, maximum)
    }

    /// Match the connector name in the AppleCLCD2 location (for example,
    /// dispext0) to the same connector in a DCPAV service path.
    static func controllerPath(forLocation location: String, candidates: [(path: String, external: Bool)]) -> String? {
        guard let connector = location.split(separator: "/")
            .map(String.init)
            .first(where: { $0.hasPrefix("dispext") })?
            .split(separator: "@")
            .first
            .map(String.init) else { return nil }
        let marker = "/\(connector):"
        return candidates.first(where: { $0.external && $0.path.contains(marker) })?.path
    }

    // MARK: Display and IOKit plumbing

    private struct DisplayTarget {
        let id: CGDirectDisplayID
        let uuid: String
    }

    #if arch(arm64)
    private struct Session {
        let display: DisplayTarget
        let transport: DDCTransport
        let service: CFTypeRef
    }

    private static func open(selector: String) throws -> Session {
        let display = try resolveDisplay(selector: selector)
        let location = try displayLocation(display.id)
        let transport = try DDCTransport()
        guard let service = try transport.service(for: location) else {
            throw DDCLuminanceError.controllerNotFound(location)
        }
        return Session(display: display, transport: transport, service: service)
    }

    private static func readValues(transport: DDCTransport, service: CFTypeRef) throws -> (current: UInt16, maximum: UInt16) {
        var request = makeGetVCPRequest(code: luminanceVCP)
        let writeStatus = request.withUnsafeMutableBytes { bytes in
            transport.write(service, address: 0x51, bytes: bytes.baseAddress!, count: UInt32(bytes.count))
        }
        guard writeStatus == KERN_SUCCESS else { throw DDCLuminanceError.requestFailed(writeStatus) }
        usleep(10_000)

        var reply = [UInt8](repeating: 0, count: 12)
        let readStatus = reply.withUnsafeMutableBytes { bytes in
            transport.read(service, chipAddress: 0x37, address: 0x51, output: bytes.baseAddress!, count: UInt32(bytes.count))
        }
        guard readStatus == KERN_SUCCESS else { throw DDCLuminanceError.requestFailed(readStatus) }
        return try validateReply(reply, expectedCode: luminanceVCP)
    }

    private static func writeValue(_ value: UInt16, transport: DDCTransport, service: CFTypeRef) throws {
        var request = makeSetVCPRequest(code: luminanceVCP, value: value)
        let status = request.withUnsafeMutableBytes { bytes in
            transport.write(service, address: 0x51, bytes: bytes.baseAddress!, count: UInt32(bytes.count))
        }
        guard status == KERN_SUCCESS else { throw DDCLuminanceError.requestFailed(status) }
    }
    #endif

    private static func resolveDisplay(selector: String) throws -> DisplayTarget {
        let records = DisplayInventory.records()
        guard let record = DisplaySelector.resolve(selector, in: records),
              record.active, !record.builtin, let uuid = record.uuid else {
            throw DDCLuminanceError.displayNotFound(selector)
        }
        return DisplayTarget(id: record.id, uuid: uuid)
    }

    private static func displayLocation(_ id: CGDirectDisplayID) throws -> String {
        let transport = try CoreDisplayMetadata()
        guard let info = transport.info(id) else { throw DDCLuminanceError.displayMetadataUnavailable(id) }
        let values = info.takeRetainedValue() as NSDictionary
        guard let location = values["IODisplayLocation"] as? String, !location.isEmpty else {
            throw DDCLuminanceError.displayMetadataUnavailable(id)
        }
        return location
    }
}

private final class CoreDisplayMetadata {
    typealias InfoFn = @convention(c) (CGDirectDisplayID) -> Unmanaged<CFDictionary>?
    let handle: UnsafeMutableRawPointer
    let infoFn: InfoFn

    init() throws {
        guard let handle = dlopen("/System/Library/Frameworks/CoreDisplay.framework/CoreDisplay", RTLD_LAZY | RTLD_LOCAL) else {
            throw DDCLuminanceError.symbolUnavailable("CoreDisplay_DisplayCreateInfoDictionary")
        }
        guard let symbol = dlsym(handle, "CoreDisplay_DisplayCreateInfoDictionary") else {
            dlclose(handle); throw DDCLuminanceError.symbolUnavailable("CoreDisplay_DisplayCreateInfoDictionary")
        }
        self.handle = handle
        self.infoFn = unsafeBitCast(symbol, to: InfoFn.self)
    }

    func info(_ id: CGDirectDisplayID) -> Unmanaged<CFDictionary>? { infoFn(id) }
    deinit { dlclose(handle) }
}

private final class DDCTransport {
    typealias CreateFn = @convention(c) (CFAllocator?, io_service_t) -> Unmanaged<CFTypeRef>?
    typealias ReadFn = @convention(c) (CFTypeRef, UInt32, UInt32, UnsafeMutableRawPointer, UInt32) -> Int32
    typealias WriteFn = @convention(c) (CFTypeRef, UInt32, UInt32, UnsafeMutableRawPointer, UInt32) -> Int32

    let handle: UnsafeMutableRawPointer
    let createFn: CreateFn
    let readFn: ReadFn
    let writeFn: WriteFn

    init() throws {
        guard let handle = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY | RTLD_LOCAL) else {
            throw DDCLuminanceError.transportUnavailable("cannot load IOKit")
        }
        func symbol<T>(_ name: String, _ type: T.Type) throws -> T {
            guard let pointer = dlsym(handle, name) else { throw DDCLuminanceError.symbolUnavailable(name) }
            return unsafeBitCast(pointer, to: type)
        }
        do {
            self.createFn = try symbol("IOAVServiceCreateWithService", CreateFn.self)
            self.readFn = try symbol("IOAVServiceReadI2C", ReadFn.self)
            self.writeFn = try symbol("IOAVServiceWriteI2C", WriteFn.self)
        } catch {
            dlclose(handle); throw error
        }
        self.handle = handle
    }

    func service(for location: String) throws -> CFTypeRef? {
        guard let matching = IOServiceMatching("DCPAVServiceProxy") else { throw DDCLuminanceError.transportUnavailable("DCPAVServiceProxy matching unavailable") }
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else { throw DDCLuminanceError.transportUnavailable("cannot enumerate DCPAVServiceProxy") }
        defer { IOObjectRelease(iterator) }
        var candidates: [(path: String, external: Bool, service: io_service_t)] = []
        while true {
            let entry = IOIteratorNext(iterator); if entry == 0 { break }
            var pathBuffer = [CChar](repeating: 0, count: 2048)
            guard IORegistryEntryGetPath(entry, kIOServicePlane, &pathBuffer) == KERN_SUCCESS else { IOObjectRelease(entry); continue }
            var properties: Unmanaged<CFMutableDictionary>?
            var external = false
            if IORegistryEntryCreateCFProperties(entry, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS,
               let dict = properties?.takeRetainedValue() as? [String: Any] {
                external = (dict["Location"] as? String)?.caseInsensitiveCompare("External") == .orderedSame
            }
            candidates.append((String(cString: pathBuffer), external, entry))
        }
        guard let selectedPath = DDCLuminance.controllerPath(forLocation: location, candidates: candidates.map { ($0.path, $0.external) }),
              let selected = candidates.first(where: { $0.path == selectedPath }) else {
            candidates.forEach { IOObjectRelease($0.service) }
            return nil
        }
        let av = createFn(kCFAllocatorDefault, selected.service)
        IOObjectRelease(selected.service)
        candidates.filter { $0.service != selected.service }.forEach { IOObjectRelease($0.service) }
        guard let av else { return nil }
        return av.takeRetainedValue()
    }

    func read(_ service: CFTypeRef, chipAddress: UInt32, address: UInt32, output: UnsafeMutableRawPointer, count: UInt32) -> Int32 {
        readFn(service, chipAddress, address, output, count)
    }

    func write(_ service: CFTypeRef, address: UInt32, bytes: UnsafeMutableRawPointer, count: UInt32) -> Int32 {
        writeFn(service, 0x37, address, bytes, count)
    }

    deinit { dlclose(handle) }
}
