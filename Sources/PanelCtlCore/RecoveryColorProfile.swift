import Foundation
import CryptoKit

/// ICC header creation time is metadata, not a color transform. The observed
/// macOS regeneration changed only bytes 24...35 (historical evidence summarized
/// in docs/display-recovery.md).
/// This is not a general semantic ICC comparison: every other byte stays hashed.
enum RecoveryColorProfile {
    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func dateIndependentDigest(_ data: Data) -> String? {
        // Unknown/malformed formats retain full-hash-only comparison. Constrain
        // normalization to bounded v2/v4 display profiles with no computed ID.
        guard (132...1_048_576).contains(data.count) else { return nil }
        var bytes = [UInt8](data)
        func u32(_ offset: Int) -> Int {
            (0..<4).reduce(0) { ($0 << 8) | Int(bytes[offset + $1]) }
        }
        guard u32(0) == bytes.count, [2, 4].contains(bytes[8]),
              Array(bytes[12..<16]) == Array("mntr".utf8),
              Array(bytes[36..<40]) == Array("acsp".utf8),
              bytes[84..<100].allSatisfy({ $0 == 0 }) else { return nil }
        let parts = stride(from: 24, to: 36, by: 2).map { Int(bytes[$0]) * 256 + Int(bytes[$0 + 1]) }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let components = DateComponents(year: parts[0], month: parts[1], day: parts[2],
                                        hour: parts[3], minute: parts[4], second: parts[5])
        guard (1...9999).contains(parts[0]), let date = calendar.date(from: components),
              calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date) == components else {
            return nil
        }
        let count = u32(128)
        guard count > 0, count <= (bytes.count - 132) / 12 else { return nil }
        let tableEnd = 132 + count * 12
        var tags = Set<Int>()
        for index in 0..<count {
            let entry = 132 + index * 12
            let offset = u32(entry + 4), size = u32(entry + 8)
            guard tags.insert(u32(entry)).inserted, offset >= tableEnd,
                  offset % 4 == 0, offset <= bytes.count, size >= 8,
                  size <= bytes.count - offset else { return nil }
        }
        bytes.replaceSubrange(24..<36, with: repeatElement(UInt8(0), count: 12))
        return digest(Data(bytes))
    }
}
