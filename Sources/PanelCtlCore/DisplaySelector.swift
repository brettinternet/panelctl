import Foundation

enum DisplaySelector {
    static func resolve(_ selector: String, in records: [DisplayRecord]) -> DisplayRecord? {
        let normalizedSelector = selector.lowercased()
        if normalizedSelector.hasPrefix("index:"),
           let index = Int(selector.dropFirst("index:".count)),
           index > 0,
           records.indices.contains(index - 1) {
            return records[index - 1]
        }
        let id = UInt32(selector) ?? (
            normalizedSelector.hasPrefix("0x")
                ? UInt32(selector.dropFirst(2), radix: 16)
                : nil
        )
        if let id, let record = records.first(where: { $0.id == id }) {
            return record
        }
        if let record = records.first(where: { $0.uuid?.caseInsensitiveCompare(selector) == .orderedSame }) {
            return record
        }
        return nil
    }
}
