import XCTest
@testable import PanelCtlCore

final class ProbeTests: XCTestCase {
    func testReadsBothFeaturesWithoutSetsAndContinuesAfterFailure() throws {
        var reads: [String] = []
        let results = Probe.ddcAvailability(displays: [display(1), display(2)], architecture: "arm64") { display in
            DDCChannel(getVCP: { code in
                reads.append("\(display.id):\(code)")
                if display.id == 1 && code == 0x60 { throw DDCError.reportedUnsupported(code) }
                return (50, 100)
            }, setVCP: { _, _ in XCTFail("probe must never Set VCP") })
        }
        XCTAssertEqual(reads, ["1:96", "1:16", "2:96", "2:16"])
        XCTAssertEqual(results[0].input.status, .unsupported)
        XCTAssertEqual(results[0].luminance.status, .readable)
        XCTAssertEqual(results[1].input.status, .readable)
        XCTAssertEqual(results[1].luminance.status, .readable)
        XCTAssertEqual(results[0].input.detail, DDCError.reportedUnsupported(0x60).description)
        let report = ProbeReport(displays: [display(1), display(2)], os: "fake", architecture: "arm64",
                                 symbols: [], avServices: [], clcdServices: [], ddc: results, ddcNotice: Probe.ddcNotice)
        let data = try JSONEncoder().encode(report)
        XCTAssertEqual(try JSONDecoder().decode(ProbeReport.self, from: data), report)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["ddcNotice"] as? String, Probe.ddcNotice)
        let entries = try XCTUnwrap(json["ddc"] as? [[String: Any]])
        XCTAssertEqual((entries[0]["input"] as? [String: Any])?["status"] as? String, "unsupported")
        let text = Probe.ddcText(report)
        XCTAssertTrue(text.contains("input(0x60)=unsupported (monitor reports VCP 0x60 unsupported)"))
        XCTAssertTrue(text.contains("DDC displayID=2 input(0x60)=readable luminance(0x10)=readable"))
        XCTAssertTrue(text.contains("a successful read is not write qualification"))
    }

    func testOpeningFailuresAreReportedAndDoNotStopOtherDisplays() {
        let cases: [(DDCError, DDCReadAvailability.Status)] = [
            (.controllerNotFound("port"), .noController),
            (.ambiguousController("port"), .ambiguousMapping),
            (.symbolUnavailable("IOAVServiceReadI2C"), .unsupported),
            (.transportUnavailable("service"), .transportError),
            (.displayMetadataUnavailable(1), .transportError),
            (.displayNotFound("1"), .transportError)
        ]
        for (error, status) in cases {
            var opened: [UInt32] = []
            let results = Probe.ddcAvailability(displays: [display(1), display(2)], architecture: "arm64") { display in
                opened.append(display.id)
                if display.id == 1 { throw error }
                return DDCChannel(getVCP: { _ in (1, 100) }, setVCP: { _, _ in XCTFail("unexpected write") })
            }
            XCTAssertEqual(opened, [1, 2])
            XCTAssertEqual(results[0].input.status, status)
            XCTAssertEqual(results[0].input.detail, error.description)
            XCTAssertEqual(results[0].luminance, results[0].input)
            XCTAssertEqual(results[1].input.status, .readable)
        }
    }

    func testReadFailuresAreIndependent() {
        for error in [DDCError.requestFailed(-1), .invalidReply("checksum"), .wrongVCP(expected: 0x10, actual: 0x60)] {
            let results = Probe.ddcAvailability(displays: [display(1)], architecture: "arm64") { _ in
                DDCChannel(getVCP: { code in
                    if code == 0x10 { throw error }
                    return (0x0F, 0)
                }, setVCP: { _, _ in XCTFail("unexpected write") })
            }
            XCTAssertEqual(results[0].input.status, .readable)
            XCTAssertEqual(results[0].luminance.status, .transportError)
            XCTAssertEqual(results[0].luminance.detail, error.description)
        }
    }

    func testIneligibleDisplaysAndArchitecturesNeverOpenChannel() {
        let ineligible = [display(1, builtin: true), display(2, active: false), display(3, online: false)]
        for (arch, displays) in [("arm64", ineligible), ("x86_64", [display(4)]), ("unknown", [display(5)])] {
            let results = Probe.ddcAvailability(displays: displays, architecture: arch) { _ in
                XCTFail("ineligible display must not open a DDC channel")
                throw DDCError.requestFailed(-1)
            }
            XCTAssertEqual(results.count, displays.count)
            for result in results {
                XCTAssertEqual(result.input.status, .notApplicable)
                XCTAssertEqual(result.luminance.status, .notApplicable)
                XCTAssertNotNil(result.input.detail)
            }
        }
        XCTAssertEqual(Probe.ddcAvailability(displays: [], architecture: "arm64"), [])
    }

    private func display(_ id: UInt32, builtin: Bool = false, active: Bool = true, online: Bool = true) -> DisplayRecord {
        DisplayRecord(index: Int(id), id: id, uuid: "UUID-\(id)", name: "Fake", active: active,
                      online: online, asleep: false, builtin: builtin, main: false, vendor: 1, model: 2, serial: id,
                      bounds: DisplayBounds(.zero), pixelWidth: 1920, pixelHeight: 1080)
    }
}
