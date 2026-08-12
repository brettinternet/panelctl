import Foundation
import Darwin

/// A journal entry for a display whose luminance may need to be restored.
/// UUIDs are deliberately retained exactly as returned by DisplayInventory;
/// restoration never falls back to a display index or display ID.
struct BlackoutLuminanceEntry: Codable, Equatable, Hashable {
    let uuid: String
    let original: UInt16
}

/// Best-effort luminance dimming used by blackout.  The lock is held for the
/// lifetime of a blackout process so two sessions cannot race the same
/// monitors or journal.
final class BlackoutDimming {
    typealias Read = (String) throws -> DDCLuminanceReading
    typealias Write = (String, UInt16) throws -> DDCLuminanceWriteResult
    typealias Records = () -> [DisplayRecord]
    typealias JournalWriter = ([BlackoutLuminanceEntry]) throws -> Void

    static let defaultJournalURL = URL(
        fileURLWithPath: NSHomeDirectory(),
        isDirectory: true
    ).appendingPathComponent("Library/Application Support/PanelCtl/blackout-luminance.json")

    private let journalURL: URL
    private let lockURL: URL
    private let records: Records
    private let read: Read
    private let set: Write
    private let journalWriter: JournalWriter
    private var lockFD: Int32?
    // Keys are lowercased UUIDs so equivalent UUID spellings cannot carry
    // conflicting originals.
    private var entries: [String: BlackoutLuminanceEntry] = [:]

    init(
        journalURL: URL = BlackoutDimming.defaultJournalURL,
        records: @escaping Records = { DisplayInventory.records() },
        read: @escaping Read = { try DDCLuminance.read(selector: $0) },
        set: @escaping Write = { try DDCLuminance.set(selector: $0, value: $1) },
        journalWriter: JournalWriter? = nil
    ) {
        self.journalURL = journalURL
        self.lockURL = journalURL.appendingPathExtension("lock")
        self.records = records
        self.read = read
        self.set = set
        self.journalWriter = journalWriter ?? { entries in
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(entries.sorted { $0.uuid < $1.uuid })
            let directory = journalURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: journalURL, options: .atomic)
        }
    }

    deinit {
        releaseLock()
    }

    /// Acquires the process-held lock and restores any entries left by an
    /// earlier crashed session. Failure to acquire the lock disables dimming.
    func start() {
        guard lockFD == nil else { return }
        let directory = lockURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let fd = open(lockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
            guard fd >= 0 else { return }
            guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
                close(fd)
                return
            }
            lockFD = fd
            entries = try loadJournal()
            restoreLoadedEntries()
        } catch {
            releaseLock()
        }
    }

    func stop() {
        releaseLock()
    }

    /// Replays stale journal entries. This is intentionally a no-op when this
    /// process does not own the blackout lock.
    func recoverStale() {
        guard lockFD != nil else { return }
        do {
            entries = try loadJournal()
            restoreLoadedEntries()
        } catch {
            // A malformed or inaccessible journal must never abort blackout.
        }
    }

    /// Dims selected active external displays to the requested percentage of
    /// each monitor's reported luminance maximum. A target that is equal to or
    /// above the sampled current value is skipped so dimming never brightens a
    /// display. Every changed non-zero read is journaled before attempting the
    /// write; a failed write leaves the entry persisted for later recovery.
    func dim(
        _ targets: [BlackoutScreenTarget],
        to targetPercent: Int,
        screenIDs: [UInt32] = []
    ) {
        guard lockFD != nil, (0...100).contains(targetPercent) else { return }
        let currentRecords = records()
        var targetIDs = targets.map(\.id)
        if targetIDs.isEmpty {
            targetIDs = screenIDs
        }
        let generatedTargets = targetIDs
            .filter { id in !targets.contains(where: { $0.id == id }) }
            .map { id in BlackoutScreenTarget(id: id, uuid: nil, selector: "\(id)") }
        for target in targets + generatedTargets {
            guard let record = currentRecords.first(where: {
                if let targetUUID = target.uuid {
                    return $0.uuid?.caseInsensitiveCompare(targetUUID) == .orderedSame
                }
                return $0.id == target.id
            }),
                  record.active,
                  !record.builtin,
                  let recordUUID = record.uuid,
                  let uuid = target.uuid ?? (recordUUID.isEmpty ? nil : recordUUID),
                  !uuid.isEmpty else { continue }
            do {
                let reading = try read(uuid)
                guard reading.uuid.caseInsensitiveCompare(uuid) == .orderedSame else {
                    continue
                }
                let requested = UInt16(
                    (UInt32(reading.maximum) * UInt32(targetPercent)) / 100
                )
                guard requested < reading.current else { continue }
                let entry = BlackoutLuminanceEntry(uuid: uuid, original: reading.current)
                let key = uuid.lowercased()
                if entries[key] == nil {
                    entries[key] = entry
                    try persist()
                }
                do {
                    _ = try set(uuid, requested)
                } catch {
                    // Keep the journal entry: the write may have succeeded
                    // without a verified response.
                }
            } catch {
                // Unsupported or unavailable DDC is non-fatal to blackout.
            }
        }
    }

    /// Restores every journaled luminance while blackout windows are still up.
    /// Verified writes are removed; failures remain persisted for retry.
    func restore() {
        guard lockFD != nil else { return }
        restoreLoadedEntries()
    }

    private func restoreLoadedEntries() {
        guard !entries.isEmpty else { return }
        for (key, entry) in Array(entries) {
            do {
                _ = try set(entry.uuid, entry.original)
                entries.removeValue(forKey: key)
                do { try persist() } catch { /* retry on next wake */ }
            } catch {
                // Keep failed entries for a future launch/wake retry.
            }
        }
        do { try persist() } catch { /* best effort */ }
    }

    private func loadJournal() throws -> [String: BlackoutLuminanceEntry] {
        guard FileManager.default.fileExists(atPath: journalURL.path) else { return [:] }
        let data = try Data(contentsOf: journalURL)
        return Dictionary(
            (try JSONDecoder().decode([BlackoutLuminanceEntry].self, from: data)).map {
                ($0.uuid.lowercased(), $0)
            }, uniquingKeysWith: { first, _ in first }
        )
    }

    private func persist() throws {
        try journalWriter(entries.values.sorted { $0.uuid < $1.uuid })
    }

    private func releaseLock() {
        if let lockFD {
            _ = flock(lockFD, LOCK_UN)
            close(lockFD)
            self.lockFD = nil
        }
    }
}
