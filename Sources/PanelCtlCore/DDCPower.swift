import Foundation
import Darwin

/// Deliberately excludes standby, suspend, power-button off (0x05), and raw values.
/// VESA MCCS 2.2a, Table 8-9, p70: 0x01 = DPM/DPMS On; 0x04 = DPM/DPMS Off.
public enum DDCPowerValue: String, Codable {
    case on, off

    public var code: UInt16 { self == .on ? 0x01 : 0x04 }
}

public struct DDCPowerResult: Equatable, Codable {
    public enum Outcome: String, Codable {
        case reported, alreadyReported, matchingReadback, unverified
    }
    public let displayID: UInt32
    public let uuid: String
    public let original: UInt16
    public let requested: DDCPowerValue?
    public let observed: UInt16?
    public let outcome: Outcome
    public let detail: String
}

public enum DDCPowerError: Error, CustomStringConvertible {
    case consentRequired
    case beforeWrite(String)
    case writeStateUnknown(String)
    case readbackFailed(String)

    public var description: String {
        switch self {
        case .consentRequired:
            return "--set off requires --accept-power-risk: \(DDCPower.risk)"
        case .beforeWrite(let detail):
            return "DDC power refused before Set VCP (\(detail)). \(DDCPower.manualRecovery)"
        case .writeStateUnknown(let detail):
            return "DDC power write attempted; state unknown (\(detail)). No retry. \(DDCPower.manualRecovery)"
        case .readbackFailed(let detail):
            return "DDC power readback failed after one write (\(detail)). No retry. \(DDCPower.manualRecovery)"
        }
    }
}

/// Explicit CLI-only operation. No journal, automatic restoration or wake hook.
public enum DDCPower {
    public static let powerVCP: UInt8 = 0xD6
    public static let risk = "Software wake may fail; the physical power button may not suffice; unplugging monitor power may be required. Harmlessness and physical recovery are not guaranteed."
    public static let manualRecovery = "If the monitor is unusable, use its physical power controls; unplugging monitor power may be required. Recovery is not guaranteed. Do not guess display IDs or cycle power values."
    public static let observationWarning = "A reported value or delivered command is not proof of visible panel state or desktop removal."

    public static func run(selector: String, value: DDCPowerValue?, acceptedRisk: Bool) throws -> DDCPowerResult {
        try run(selector: selector, value: value, acceptedRisk: acceptedRisk, open: DDC.open)
    }

    static func run(
        selector: String, value: DDCPowerValue?, acceptedRisk: Bool,
        open: (String) throws -> (display: DDC.DisplayTarget, channel: DDCChannel),
        pause: () -> Void = { usleep(250_000) }
    ) throws -> DDCPowerResult {
        // Consent is enforced at the operation boundary, not only by the parser.
        guard value != .off || acceptedRisk else { throw DDCPowerError.consentRequired }
        let session: (display: DDC.DisplayTarget, channel: DDCChannel)
        let original: UInt16
        do {
            session = try open(selector)
            original = try current(session.channel)
        } catch {
            throw DDCPowerError.beforeWrite(String(describing: error))
        }
        func result(_ observed: UInt16?, _ outcome: DDCPowerResult.Outcome, _ detail: String = observationWarning) -> DDCPowerResult {
            DDCPowerResult(displayID: session.display.id, uuid: session.display.uuid,
                           original: original, requested: value, observed: observed,
                           outcome: outcome, detail: detail)
        }
        guard let value else { return result(original, .reported) }
        if original == value.code { return result(original, .alreadyReported) }
        do {
            try session.channel.setVCP(powerVCP, value.code)
        } catch {
            throw DDCPowerError.writeStateUnknown(String(describing: error))
        }
        // One readback only; no write retry, alternate value, or automatic rollback.
        pause()
        let observed: UInt16
        do {
            observed = try current(session.channel)
        } catch let error as DDCError {
            switch error {
            case .requestFailed, .transportUnavailable:
                return result(nil, .unverified, "Readback transport unavailable (\(error)). \(observationWarning) \(manualRecovery)")
            default:
                throw DDCPowerError.readbackFailed(String(describing: error))
            }
        } catch {
            throw DDCPowerError.readbackFailed(String(describing: error))
        }
        guard observed == value.code else {
            throw DDCPowerError.readbackFailed(String(format: "requested 0x%02X, reported 0x%02X", value.code, observed))
        }
        return result(observed, .matchingReadback)
    }

    private static func current(_ channel: DDCChannel) throws -> UInt16 {
        let value = try channel.getVCP(powerVCP).current
        guard (1...4).contains(value) else {
            throw DDCError.invalidReply(String(format: "invalid MCCS power state 0x%04X", value))
        }
        return value
    }
}
