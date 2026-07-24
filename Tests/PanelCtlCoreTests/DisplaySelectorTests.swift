import XCTest
@testable import PanelCtlCore

final class DisplaySelectorTests: XCTestCase {
    func testIDUUIDAndIndexSelectors() {
        let records = [
            record(index: 1, id: 1, uuid: "AAAA"),
            record(index: 2, id: 5, uuid: "BBBB"),
            record(index: 3, id: 9, uuid: "CCCC")
        ]
        XCTAssertEqual(DisplaySelector.resolve("5", in: records)?.id, 5)
        XCTAssertEqual(DisplaySelector.resolve("0x5", in: records)?.id, 5)
        XCTAssertEqual(DisplaySelector.resolve("bbbb", in: records)?.id, 5)
        XCTAssertEqual(DisplaySelector.resolve("index:3", in: records)?.id, 9)
        XCTAssertEqual(DisplaySelector.resolve("3", in: records)?.id, 9)
        XCTAssertNil(DisplaySelector.resolve("index:0", in: records))
        XCTAssertNil(DisplaySelector.resolve("missing", in: records))
    }

    private func record(index: Int, id: UInt32, uuid: String) -> DisplayRecord {
        DisplayRecord(
            index: index,
            id: id,
            uuid: uuid,
            name: nil,
            active: true,
            online: true,
            asleep: false,
            builtin: false,
            main: false,
            vendor: 0,
            model: 0,
            serial: 0,
            bounds: DisplayBounds(.zero),
            pixelWidth: 0,
            pixelHeight: 0
        )
    }
}
