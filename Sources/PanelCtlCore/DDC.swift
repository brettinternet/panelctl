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

public enum DDCError: Error, Equatable, CustomStringConvertible {
    case unsupportedArchitecture
    case displayNotFound(String)
    case displayMetadataUnavailable(UInt32)
    case symbolUnavailable(String)
    case transportUnavailable(String)
    case controllerNotFound(String)
    case ambiguousController(String)
    case requestFailed(Int32)
    case invalidReply(String)
    case reportedUnsupported(UInt8)
    case wrongVCP(expected: UInt8, actual: UInt8)
    case valueOutOfRange(value: UInt16, maximum: UInt16)
    case verificationFailed(original: UInt16, expected: UInt16, actual: UInt16, uuid: String)
    case writeStateUnknown(original: UInt16, uuid: String, detail: String)
    case inputNotVerified(original: UInt8, requested: UInt8, observed: UInt8, uuid: String)
    case inputWriteStateUnknown(original: UInt8, uuid: String, detail: String)

    public var description: String {
        switch self {
        case .unsupportedArchitecture: return "DDC control requires Apple Silicon (arm64)"
        case .displayNotFound(let selector): return "no active external display matches selector \(selector)"
        case .displayMetadataUnavailable(let id): return "CoreDisplay metadata is unavailable for display \(id)"
        case .symbolUnavailable(let symbol): return "required private symbol is unavailable: \(symbol)"
        case .transportUnavailable(let detail): return "DDC transport is unavailable: \(detail)"
        case .controllerNotFound(let location): return "no external DCPAVServiceProxy matches display location \(location)"
        case .ambiguousController(let location): return "more than one external DCPAVServiceProxy matches display location \(location)"
        case .requestFailed(let status): return "DDC I2C request failed (IOReturn \(status))"
        case .invalidReply(let detail): return "invalid DDC reply: \(detail)"
        case .reportedUnsupported(let code): return String(format: "monitor reports VCP 0x%02X unsupported", code)
        case .wrongVCP(let expected, let actual): return String(format: "DDC reply returned VCP 0x%02X, expected 0x%02X", actual, expected)
        case .valueOutOfRange(let value, let maximum): return "luminance \(value) exceeds the monitor maximum \(maximum)"
        case .verificationFailed(let original, let expected, let actual, let uuid):
            return "DDC luminance write was not verified (expected \(expected), read \(actual)); restore \(uuid) with: panelctl ddc-luminance --display \(uuid) --set \(original)"
        case .writeStateUnknown(let original, let uuid, let detail):
            return "DDC luminance state is unknown after the write attempt (\(detail)); restore \(uuid) with: panelctl ddc-luminance --display \(uuid) --set \(original)"
        case .inputNotVerified(let original, let requested, let observed, let uuid):
            return String(format: "monitor reports input 0x%02X after selecting 0x%02X; switch back with: panelctl ddc-input --display %@ --set 0x%02X, or use the monitor's input button", observed, requested, uuid, original)
        case .inputWriteStateUnknown(let original, let uuid, let detail):
            return String(format: "monitor input is unknown after the write attempt (%@); switch back with: panelctl ddc-input --display %@ --set 0x%02X, or use the monitor's input button", detail, uuid, original)
        }
    }
}

/// One Get/Set VCP channel to a resolved display. Tests inject fakes.
struct DDCChannel {
    let getVCP: (UInt8) throws -> (current: UInt16, maximum: UInt16)
    let setVCP: (UInt8, UInt16) throws -> Void
}

/// Shared DDC/CI framing and Apple Silicon IOAVService transport.
///
/// The framing and transport are based on the MIT-licensed waydabber/m1ddc
/// implementation (protocol reference).
enum DDC {
    static func makeGetVCPRequest(code: UInt8) -> [UInt8] {
        let body: [UInt8] = [0x82, 0x01, code]
        return body + [0x6E ^ body[0] ^ body[1] ^ body[2]]
    }

    static func makeSetVCPRequest(code: UInt8, value: UInt16) -> [UInt8] {
        let body: [UInt8] = [0x84, 0x03, code, UInt8(value >> 8), UInt8(value & 0xFF)]
        return body + [0x6E ^ 0x51 ^ body.reduce(0, ^)]
    }

    /// Parse a Get VCP Feature reply without assuming a continuous control:
    /// non-continuous features such as input select do not have a meaningful
    /// maximum.
    static func parseReply(_ bytes: [UInt8], expectedCode: UInt8) throws -> (current: UInt16, maximum: UInt16) {
        guard bytes.count >= 11 else { throw DDCError.invalidReply("reply is shorter than 11 bytes") }
        let frame = Array(bytes.prefix(11))
        guard (frame[1] & 0x7F) >= 0x06 else { throw DDCError.invalidReply("invalid payload length") }
        guard frame[0] == 0x6E else { throw DDCError.invalidReply("unexpected source address") }
        guard frame[2] == 0x02 else { throw DDCError.invalidReply("not a Get VCP Feature reply") }
        guard (0x50 ^ frame.reduce(0, ^)) == 0 else { throw DDCError.invalidReply("checksum mismatch") }
        if frame[3] == 0x01 { throw DDCError.reportedUnsupported(frame[4]) }
        guard frame[3] == 0x00 else { throw DDCError.invalidReply(String(format: "monitor result code 0x%02X", frame[3])) }
        guard frame[4] == expectedCode else { throw DDCError.wrongVCP(expected: expectedCode, actual: frame[4]) }
        let maximum = UInt16(frame[6]) << 8 | UInt16(frame[7])
        let current = UInt16(frame[8]) << 8 | UInt16(frame[9])
        return (current, maximum)
    }

    /// Match the connector name in the AppleCLCD2 location (for example,
    /// dispext0) to exactly one external DCPAV service path for that connector.
    static func controllerPath(forLocation location: String, candidates: [(path: String, external: Bool)]) throws -> String? {
        guard let connector = location.split(separator: "/")
            .map(String.init)
            .first(where: { $0.hasPrefix("dispext") })?
            .split(separator: "@")
            .first
            .map(String.init) else { return nil }
        let marker = "/\(connector):"
        let matches = Set(candidates.filter { $0.external && $0.path.contains(marker) }.map(\.path))
        guard matches.count <= 1 else { throw DDCError.ambiguousController(location) }
        return matches.first
    }

    struct DisplayTarget {
        let id: CGDirectDisplayID
        let uuid: String
    }

    static func open(selector: String) throws -> (display: DisplayTarget, channel: DDCChannel) {
        #if arch(arm64)
        let display = try resolveDisplay(selector: selector)
        let location = try displayLocation(display.id)
        let transport = try DDCTransport()
        guard let service = try transport.service(for: location) else {
            throw DDCError.controllerNotFound(location)
        }
        let channel = DDCChannel(
            getVCP: { code in
                var request = makeGetVCPRequest(code: code)
                let writeStatus = request.withUnsafeMutableBytes { bytes in
                    transport.write(service, address: 0x51, bytes: bytes.baseAddress!, count: UInt32(bytes.count))
                }
                guard writeStatus == KERN_SUCCESS else { throw DDCError.requestFailed(writeStatus) }
                usleep(10_000)

                var reply = [UInt8](repeating: 0, count: 12)
                let readStatus = reply.withUnsafeMutableBytes { bytes in
                    transport.read(service, chipAddress: 0x37, address: 0x51, output: bytes.baseAddress!, count: UInt32(bytes.count))
                }
                guard readStatus == KERN_SUCCESS else { throw DDCError.requestFailed(readStatus) }
                return try parseReply(reply, expectedCode: code)
            },
            setVCP: { code, value in
                var request = makeSetVCPRequest(code: code, value: value)
                let status = request.withUnsafeMutableBytes { bytes in
                    transport.write(service, address: 0x51, bytes: bytes.baseAddress!, count: UInt32(bytes.count))
                }
                guard status == KERN_SUCCESS else { throw DDCError.requestFailed(status) }
            }
        )
        return (display, channel)
        #else
        throw DDCError.unsupportedArchitecture
        #endif
    }

    private static func resolveDisplay(selector: String) throws -> DisplayTarget {
        let records = DisplayInventory.records()
        guard let record = DisplaySelector.resolve(selector, in: records),
              record.active, !record.builtin, let uuid = record.uuid else {
            throw DDCError.displayNotFound(selector)
        }
        return DisplayTarget(id: record.id, uuid: uuid)
    }

    private static func displayLocation(_ id: CGDirectDisplayID) throws -> String {
        let transport = try CoreDisplayMetadata()
        guard let info = transport.info(id) else { throw DDCError.displayMetadataUnavailable(id) }
        let values = info.takeRetainedValue() as NSDictionary
        guard let location = values["IODisplayLocation"] as? String, !location.isEmpty else {
            throw DDCError.displayMetadataUnavailable(id)
        }
        return location
    }
}

/// DDC/CI luminance access for active external displays on Apple Silicon.
public enum DDCLuminance {
    public static let luminanceVCP: UInt8 = 0x10

    public static func read(selector: String) throws -> DDCLuminanceReading {
        let session = try DDC.open(selector: selector)
        let values = try readValues(session.channel)
        return DDCLuminanceReading(displayID: session.display.id, uuid: session.display.uuid, current: values.current, maximum: values.maximum)
    }

    public static func set(selector: String, value: UInt16) throws -> DDCLuminanceWriteResult {
        let session = try DDC.open(selector: selector)
        let original = try readValues(session.channel)
        guard value <= original.maximum else {
            throw DDCError.valueOutOfRange(value: value, maximum: original.maximum)
        }

        var observed = original.current
        do {
            for _ in 0..<2 {
                try session.channel.setVCP(luminanceVCP, value)
                usleep(50_000)
                observed = try readValues(session.channel).current
                if observed == value { break }
            }
        } catch {
            throw DDCError.writeStateUnknown(
                original: original.current,
                uuid: session.display.uuid,
                detail: String(describing: error)
            )
        }
        guard observed == value else {
            throw DDCError.verificationFailed(
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
    }

    /// Validate a continuous luminance reply.
    static func validateReply(_ bytes: [UInt8], expectedCode: UInt8) throws -> (current: UInt16, maximum: UInt16) {
        try checkRange(DDC.parseReply(bytes, expectedCode: expectedCode))
    }

    private static func readValues(_ channel: DDCChannel) throws -> (current: UInt16, maximum: UInt16) {
        try checkRange(channel.getVCP(luminanceVCP))
    }

    private static func checkRange(_ values: (current: UInt16, maximum: UInt16)) throws -> (current: UInt16, maximum: UInt16) {
        guard values.maximum > 0, values.current <= values.maximum else {
            throw DDCError.invalidReply("current/max values are out of range")
        }
        return values
    }
}

public struct DDCInputReading: Equatable, Codable {
    public let displayID: UInt32
    public let uuid: String
    public let current: UInt8
}

public struct DDCInputSelection: Equatable, Codable {
    public enum Outcome: String, Codable {
        /// The requested input was already current; nothing was written.
        case alreadySelected
        /// One write was sent and a readback reported the requested input.
        case verified
        /// One write was sent but no readback succeeded afterwards. This is
        /// expected when the monitor stops answering DDC on the Mac's input.
        case unverified
    }

    public let displayID: UInt32
    public let uuid: String
    public let original: UInt8
    public let requested: UInt8
    public let observed: UInt8?
    public let outcome: Outcome
    public let detail: String?
}

/// Explicit MCCS input-source select (VCP 0x60). It switches the monitor's
/// input only; macOS still treats the display as attached.
public enum DDCInput {
    public static let inputVCP: UInt8 = 0x60

    /// Common MCCS input-source values. Monitors may differ; read the current
    /// value on a known input to confirm its code.
    public static let namedValues: [(name: String, value: UInt8)] = [
        ("dp1", 0x0F), ("dp2", 0x10), ("hdmi1", 0x11), ("hdmi2", 0x12)
    ]

    /// Parse a name, decimal, or 0x-prefixed hex input value from 1 through 255.
    public static func parseValue(_ text: String) -> UInt8? {
        let lowered = text.lowercased()
        if let named = namedValues.first(where: { $0.name == lowered }) { return named.value }
        let parsed = lowered.hasPrefix("0x") ? UInt8(lowered.dropFirst(2), radix: 16) : UInt8(lowered)
        guard let parsed, parsed > 0 else { return nil }
        return parsed
    }

    public static func read(selector: String) throws -> DDCInputReading {
        let session = try DDC.open(selector: selector)
        return DDCInputReading(displayID: session.display.id, uuid: session.display.uuid, current: try current(session.channel))
    }

    public static func set(selector: String, value: UInt8) throws -> DDCInputSelection {
        let session = try DDC.open(selector: selector)
        return try select(value, channel: session.channel, displayID: session.display.id, uuid: session.display.uuid)
    }

    /// Use the caller's pre-read or read first (refusing if unreadable), write at most once, then poll
    /// read-only for up to `polls` × `interval` microseconds.
    static func select(
        _ value: UInt8,
        channel: DDCChannel,
        displayID: UInt32,
        uuid: String,
        original preRead: UInt8? = nil,
        polls: Int = 12,
        interval: useconds_t = 250_000,
        pause: (useconds_t) -> Void = { usleep($0) }
    ) throws -> DDCInputSelection {
        precondition(polls > 0)
        let original = try preRead ?? current(channel)
        func result(_ observed: UInt8?, _ outcome: DDCInputSelection.Outcome, _ detail: String? = nil) -> DDCInputSelection {
            DDCInputSelection(displayID: displayID, uuid: uuid, original: original, requested: value, observed: observed, outcome: outcome, detail: detail)
        }
        if original == value { return result(original, .alreadySelected) }

        do {
            try channel.setVCP(inputVCP, UInt16(value))
        } catch {
            throw DDCError.inputWriteStateUnknown(original: original, uuid: uuid, detail: String(describing: error))
        }

        var observed: UInt8?
        var lastError: Error?
        for _ in 0..<polls {
            pause(interval)
            do {
                let reading = try current(channel)
                if reading == value { return result(reading, .verified) }
                observed = reading
                lastError = nil
            } catch {
                lastError = error
            }
        }
        if let lastError {
            return result(observed, .unverified, "readback unavailable after write: \(lastError)")
        }
        throw DDCError.inputNotVerified(original: original, requested: value, observed: observed!, uuid: uuid)
    }

    /// MCCS reports the input-source value in the low byte.
    static func current(_ channel: DDCChannel) throws -> UInt8 {
        UInt8(truncatingIfNeeded: try channel.getVCP(inputVCP).current)
    }
}

final class CoreDisplayMetadata {
    typealias InfoFn = @convention(c) (CGDirectDisplayID) -> Unmanaged<CFDictionary>?
    let handle: UnsafeMutableRawPointer
    let infoFn: InfoFn

    init() throws {
        guard let handle = dlopen("/System/Library/Frameworks/CoreDisplay.framework/CoreDisplay", RTLD_LAZY | RTLD_LOCAL) else {
            throw DDCError.symbolUnavailable("CoreDisplay_DisplayCreateInfoDictionary")
        }
        guard let symbol = dlsym(handle, "CoreDisplay_DisplayCreateInfoDictionary") else {
            dlclose(handle); throw DDCError.symbolUnavailable("CoreDisplay_DisplayCreateInfoDictionary")
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
            throw DDCError.transportUnavailable("cannot load IOKit")
        }
        func symbol<T>(_ name: String, _ type: T.Type) throws -> T {
            guard let pointer = dlsym(handle, name) else { throw DDCError.symbolUnavailable(name) }
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
        guard let matching = IOServiceMatching("DCPAVServiceProxy") else { throw DDCError.transportUnavailable("DCPAVServiceProxy matching unavailable") }
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else { throw DDCError.transportUnavailable("cannot enumerate DCPAVServiceProxy") }
        defer { IOObjectRelease(iterator) }
        var candidates: [(path: String, external: Bool, service: io_service_t)] = []
        defer { candidates.forEach { IOObjectRelease($0.service) } }
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
        guard let selectedPath = try DDC.controllerPath(forLocation: location, candidates: candidates.map { ($0.path, $0.external) }),
              let selected = candidates.first(where: { $0.external && $0.path == selectedPath }) else {
            return nil
        }
        return createFn(kCFAllocatorDefault, selected.service)?.takeRetainedValue()
    }

    func read(_ service: CFTypeRef, chipAddress: UInt32, address: UInt32, output: UnsafeMutableRawPointer, count: UInt32) -> Int32 {
        readFn(service, chipAddress, address, output, count)
    }

    func write(_ service: CFTypeRef, address: UInt32, bytes: UnsafeMutableRawPointer, count: UInt32) -> Int32 {
        writeFn(service, 0x37, address, bytes, count)
    }

    deinit { dlclose(handle) }
}
