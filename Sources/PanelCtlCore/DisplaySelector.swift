import Foundation

enum DisplaySelector {
    static func resolve(_ selector: String, in records: [DisplayRecord]) -> DisplayRecord? {
        if selector.lowercased().hasPrefix("index:"),
           let index = Int(selector.dropFirst("index:".count)),
           index > 0,
           records.indices.contains(index - 1) {
            return records[index - 1]
        }
        if let id = UInt32(selector), let record = records.first(where: { $0.id == id }) {
            return record
        }
        if selector.lowercased().hasPrefix("0x"),
           let id = UInt32(selector.dropFirst(2), radix: 16),
           let record = records.first(where: { $0.id == id }) {
            return record
        }
        if let record = records.first(where: { $0.uuid?.caseInsensitiveCompare(selector) == .orderedSame }) {
            return record
        }
        if let index = Int(selector), index > 0, records.indices.contains(index - 1) {
            return records[index - 1]
        }
        return nil
    }
}
