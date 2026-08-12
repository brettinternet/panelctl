import XCTest
@testable import PanelCtlCore

final class BlackoutDimmingTests: XCTestCase {
    func testJournalIsWrittenBeforeLuminanceWriteAndUsesExactUUID() {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        var events: [String] = []
        var selector: String?
        let manager = BlackoutDimming(
            journalURL: url,
            records: { [displayRecord(id: 7, uuid: "exact-uuid")] },
            read: { uuid in
                selector = uuid
                return DDCLuminanceReading(displayID: 7, uuid: uuid, current: 55, maximum: 100)
            },
            set: { uuid, value in
                events.append("set:\(uuid):\(value)")
                return DDCLuminanceWriteResult(displayID: 7, uuid: uuid, original: 55, requested: value, observed: value, maximum: 100)
            },
            journalWriter: { entries in events.append("journal:\(entries[0].uuid):\(entries[0].original)") }
        )
        manager.start()
        manager.dim(
            [BlackoutScreenTarget(id: 7, uuid: "Exact-UUID", selector: "Exact-UUID")],
            to: 0
        )

        XCTAssertEqual(selector, "Exact-UUID")
        XCTAssertEqual(events, ["journal:Exact-UUID:55", "set:Exact-UUID:0"])
    }

    func testPartialDDCFailureDoesNotAbortOtherDisplays() {
        var writes: [(String, UInt16)] = []
        var latestJournal: [BlackoutLuminanceEntry] = []
        let manager = makeManager(
            records: [displayRecord(id: 1, uuid: "one"), displayRecord(id: 2, uuid: "two")],
            read: { uuid in
                DDCLuminanceReading(displayID: uuid == "one" ? 1 : 2, uuid: uuid, current: 40, maximum: 100)
            },
            set: { uuid, value in
                writes.append((uuid, value))
                if uuid == "one" { throw TestError.failed }
                return DDCLuminanceWriteResult(displayID: 2, uuid: uuid, original: 40, requested: value, observed: value, maximum: 100)
            },
            journalWriter: { latestJournal = $0 }
        )
        manager.start()
        manager.dim(
            [
                BlackoutScreenTarget(id: 1, uuid: "one", selector: "one"),
                BlackoutScreenTarget(id: 2, uuid: "two", selector: "two")
            ],
            to: 0
        )

        XCTAssertEqual(writes.filter { $0.1 == 0 }.map(\.0), ["one", "two"])

        manager.restore()

        XCTAssertTrue(writes.contains { $0 == ("two", 40) })
        XCTAssertEqual(
            latestJournal,
            [BlackoutLuminanceEntry(uuid: "one", original: 40)]
        )
    }

    func testCommittedScreenIDsDimAllDisplayTargets() {
        var writes: [(String, UInt16)] = []
        let manager = makeManager(
            records: [
                displayRecord(id: 1, uuid: "external"),
                displayRecord(id: 2, uuid: "builtin", builtin: true)
            ],
            read: { uuid in
                DDCLuminanceReading(
                    displayID: uuid == "external" ? 1 : 2,
                    uuid: uuid,
                    current: 40,
                    maximum: 100
                )
            },
            set: { uuid, value in
                writes.append((uuid, value))
                return DDCLuminanceWriteResult(
                    displayID: uuid == "external" ? 1 : 2,
                    uuid: uuid,
                    original: 40,
                    requested: value,
                    observed: value,
                    maximum: 100
                )
            }
        )
        manager.start()

        manager.dim([], to: 0, screenIDs: [1, 2])

        XCTAssertEqual(writes.count, 1)
        XCTAssertEqual(writes.first?.0, "external")
        XCTAssertEqual(writes.first?.1, 0)
    }

    func testRestoreIsIdempotentAfterVerifiedWrite() {
        var restoreCount = 0
        let manager = makeManager(
            read: { DDCLuminanceReading(displayID: 1, uuid: $0, current: 20, maximum: 100) },
            set: { _, value in
                if value == 20 { restoreCount += 1 }
                return DDCLuminanceWriteResult(displayID: 1, uuid: "one", original: 20, requested: value, observed: value, maximum: 100)
            }
        )
        manager.start()
        manager.dim(
            [BlackoutScreenTarget(id: 1, uuid: "one", selector: "one")],
            to: 0
        )
        manager.restore()
        manager.restore()
        XCTAssertEqual(restoreCount, 1)
    }

    func testFailedRestoreRetainsJournalEntryForRetry() {
        var shouldFail = true
        var latest: [BlackoutLuminanceEntry] = []
        let manager = makeManager(
            read: { DDCLuminanceReading(displayID: 1, uuid: $0, current: 20, maximum: 100) },
            set: { _, value in
                if value == 20, shouldFail { throw TestError.failed }
                return DDCLuminanceWriteResult(displayID: 1, uuid: "one", original: 20, requested: value, observed: value, maximum: 100)
            },
            journalWriter: { latest = $0 }
        )
        manager.start()
        manager.dim(
            [BlackoutScreenTarget(id: 1, uuid: "one", selector: "one")],
            to: 0
        )
        manager.restore()
        XCTAssertEqual(latest, [BlackoutLuminanceEntry(uuid: "one", original: 20)])
        shouldFail = false
        manager.restore()
        XCTAssertTrue(latest.isEmpty)
    }

    func testAlreadyZeroSkipsJournalAndWrite() {
        var writes = 0
        let manager = makeManager(
            read: { DDCLuminanceReading(displayID: 1, uuid: $0, current: 0, maximum: 100) },
            set: { _, _ in
                writes += 1
                throw TestError.failed
            }
        )
        manager.start()
        manager.dim(
            [BlackoutScreenTarget(id: 1, uuid: "one", selector: "one")],
            to: 0
        )
        XCTAssertEqual(writes, 0)
    }

    func testPercentageTargetUsesEachMaximumAndFloorRounding() {
        var writes: [(String, UInt16)] = []
        let manager = makeManager(
            records: [
                displayRecord(id: 1, uuid: "one"),
                displayRecord(id: 2, uuid: "two"),
                displayRecord(id: 3, uuid: "three")
            ],
            read: { uuid in
                switch uuid {
                case "one":
                    return DDCLuminanceReading(
                        displayID: 1,
                        uuid: uuid,
                        current: 90,
                        maximum: 100
                    )
                case "two":
                    return DDCLuminanceReading(
                        displayID: 2,
                        uuid: uuid,
                        current: 190,
                        maximum: 200
                    )
                default:
                    return DDCLuminanceReading(
                        displayID: 3,
                        uuid: uuid,
                        current: 200,
                        maximum: 255
                    )
                }
            },
            set: { uuid, value in
                writes.append((uuid, value))
                return DDCLuminanceWriteResult(
                    displayID: uuid == "one" ? 1 : uuid == "two" ? 2 : 3,
                    uuid: uuid,
                    original: 0,
                    requested: value,
                    observed: value,
                    maximum: uuid == "one" ? 100 : uuid == "two" ? 200 : 255
                )
            }
        )
        manager.start()
        manager.dim([
            BlackoutScreenTarget(id: 1, uuid: "one", selector: "one"),
            BlackoutScreenTarget(id: 2, uuid: "two", selector: "two"),
            BlackoutScreenTarget(id: 3, uuid: "three", selector: "three")
        ], to: 25)

        XCTAssertEqual(
            writes.map { "\($0.0):\($0.1)" },
            ["one:25", "two:50", "three:63"]
        )
    }

    func testEqualOrHigherTargetNeverBrightensOrJournals() {
        var writes: [(String, UInt16)] = []
        var journalWrites = 0
        let manager = makeManager(
            read: {
                DDCLuminanceReading(
                    displayID: 1,
                    uuid: $0,
                    current: 40,
                    maximum: 100
                )
            },
            set: { uuid, value in
                writes.append((uuid, value))
                return DDCLuminanceWriteResult(
                    displayID: 1,
                    uuid: uuid,
                    original: 40,
                    requested: value,
                    observed: value,
                    maximum: 100
                )
            },
            journalWriter: { _ in journalWrites += 1 }
        )
        manager.start()
        let target = [BlackoutScreenTarget(id: 1, uuid: "one", selector: "one")]
        manager.dim(target, to: 50)
        manager.dim(target, to: 40)

        XCTAssertTrue(writes.isEmpty)
        XCTAssertEqual(journalWrites, 0)
    }

    func testZeroPercentageTargetWritesZeroForNonzeroCurrentLuminance() {
        var writes: [(String, UInt16)] = []
        let manager = makeManager(
            read: {
                DDCLuminanceReading(
                    displayID: 1,
                    uuid: $0,
                    current: 55,
                    maximum: 120
                )
            },
            set: { uuid, value in
                writes.append((uuid, value))
                return DDCLuminanceWriteResult(
                    displayID: 1,
                    uuid: uuid,
                    original: 55,
                    requested: value,
                    observed: value,
                    maximum: 120
                )
            }
        )
        manager.start()
        manager.dim(
            [BlackoutScreenTarget(id: 1, uuid: "one", selector: "one")],
            to: 0
        )

        XCTAssertEqual(
            writes.map { "\($0.0):\($0.1)" },
            ["one:0"]
        )
    }

    func testStaleJournalIsRecoveredAtStart() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let url = directory.appendingPathComponent("blackout-luminance.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = BlackoutDimming(
            journalURL: url,
            records: { [] },
            read: { _ in throw TestError.failed },
            set: { _, _ in throw TestError.failed }
        )
        first.start()
        first.dim([], to: 0)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode([BlackoutLuminanceEntry(uuid: "stale", original: 33)])
        try data.write(to: url)
        first.stop()

        var restored = false
        let second = BlackoutDimming(
            journalURL: url,
            records: { [] },
            read: { _ in throw TestError.failed },
            set: { uuid, value in
                restored = uuid == "stale" && value == 33
                return DDCLuminanceWriteResult(displayID: 1, uuid: uuid, original: 33, requested: value, observed: value, maximum: 100)
            }
        )
        second.start()
        XCTAssertTrue(restored)
    }

    private func makeManager(
        records: [DisplayRecord] = [displayRecord(id: 1, uuid: "one")],
        read: @escaping BlackoutDimming.Read,
        set: @escaping BlackoutDimming.Write,
        journalWriter: BlackoutDimming.JournalWriter? = nil
    ) -> BlackoutDimming {
        BlackoutDimming(
            journalURL: temporaryURL(),
            records: { records },
            read: read,
            set: set,
            journalWriter: journalWriter
        )
    }

    private func temporaryURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("blackout-luminance.json")
    }
}

private enum TestError: Error { case failed }

private func displayRecord(
    id: UInt32,
    uuid: String?,
    builtin: Bool = false
) -> DisplayRecord {
    DisplayRecord(
        index: 1,
        id: id,
        uuid: uuid,
        name: nil,
        active: true,
        online: true,
        asleep: false,
        builtin: builtin,
        main: false,
        vendor: 0,
        model: 0,
        serial: 0,
        bounds: DisplayBounds(.zero),
        pixelWidth: 0,
        pixelHeight: 0
    )
}
