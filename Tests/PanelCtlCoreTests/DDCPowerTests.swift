import XCTest
@testable import PanelCtlCore

final class DDCPowerTests: XCTestCase {
    private let uuid = "12345678-1234-1234-1234-123456789ABC"

    func testEncodingAndNamedValues() {
        XCTAssertEqual(DDCPowerValue.on.code, 1)
        XCTAssertEqual(DDCPowerValue.off.code, 4)
        XCTAssertEqual(DDC.makeGetVCPRequest(code: DDCPower.powerVCP), [0x82, 0x01, 0xD6, 0x3B])
        XCTAssertEqual(DDC.makeSetVCPRequest(code: DDCPower.powerVCP, value: DDCPowerValue.off.code), [0x84, 0x03, 0xD6, 0, 4, 0x6A])
        XCTAssertEqual(DDC.makeSetVCPRequest(code: DDCPower.powerVCP, value: DDCPowerValue.on.code), [0x84, 0x03, 0xD6, 0, 1, 0x6F])
    }

    func testCLIParsingAndConsent() throws {
        XCTAssertEqual(try CLIParser.parse(["ddc-power", "--display", uuid]),
                       .ddcPower(selector: uuid, value: nil, acceptedRisk: false, json: false))
        XCTAssertEqual(try CLIParser.parse(["ddc-power", "--display", uuid, "--set", "on", "--json"]),
                       .ddcPower(selector: uuid, value: .on, acceptedRisk: false, json: true))
        XCTAssertEqual(try CLIParser.parse(["ddc-power", "--display", uuid, "--set", "off", "--accept-power-risk"]),
                       .ddcPower(selector: uuid, value: .off, acceptedRisk: true, json: false))
        XCTAssertThrowsError(try CLIParser.parse(["ddc-power", "--display", uuid, "--set", "off"])) {
            XCTAssertEqual($0 as? CLIParseError, .powerConsentRequired)
            XCTAssertTrue(String(describing: $0).contains("unplugging monitor power"))
            XCTAssertTrue(String(describing: $0).contains("physical power button may not suffice"))
        }
        for args in [
            ["--set", "off", "--accept-power-risk"], ["--display"],
            ["--display", uuid, "--set"], ["--display", uuid, "--all"],
            ["--display", uuid, "--display", uuid],
            ["--display", uuid, "--set", "on", "--set", "off"],
            ["--display", uuid, "--json", "--json"],
            ["--display", uuid, "--accept-power-risk", "--accept-power-risk"]
        ] {
            XCTAssertThrowsError(try CLIParser.parse(["ddc-power"] + args))
        }
        for raw in ["1", "4", "0x04", "5", "standby", "suspend", "cycle"] {
            XCTAssertThrowsError(try CLIParser.parse(["ddc-power", "--display", uuid, "--set", raw, "--accept-power-risk"]))
        }
        XCTAssertEqual(try CLIParser.parse(["ddc-power", "--help"]), .help(command: "ddc-power"))
        XCTAssertTrue(CLIHelp.text(for: "ddc-power").contains("0x04"))
        XCTAssertTrue(CLIHelp.text(for: nil).contains("ddc-power"))
    }

    func testConsentRefusesBeforeOpeningEvenForAlreadyOff() {
        var opened = false
        XCTAssertThrowsError(try DDCPower.run(selector: uuid, value: .off, acceptedRisk: false, open: { _ in
            opened = true
            throw DDCError.requestFailed(-1)
        }))
        XCTAssertFalse(opened)
    }

    func testReadAndAlreadyReportedNeverWriteOrPause() throws {
        for value: DDCPowerValue? in [nil, .on, .off] {
            let fake = Fake([.success(value?.code ?? 1)])
            let result = try run(value, fake)
            XCTAssertEqual(result.outcome, value == nil ? .reported : .alreadyReported)
            XCTAssertEqual(fake.reads, 1)
            XCTAssertEqual(fake.writes, [])
            XCTAssertEqual(fake.pauses, 0)
        }
    }

    func testOnAndOffUseOneWriteAndOneReadback() throws {
        for value in [DDCPowerValue.on, .off] {
            let fake = Fake([.success(value == .on ? 4 : 1), .success(value.code)])
            let result = try run(value, fake)
            XCTAssertEqual(result.outcome, .matchingReadback)
            XCTAssertEqual(result.observed, value.code)
            XCTAssertEqual(fake.writes, [value.code])
            XCTAssertEqual(fake.reads, 2)
            XCTAssertEqual(fake.pauses, 1)
            XCTAssertTrue(result.detail.contains("not proof"))
            let encoded = try JSONEncoder().encode(result)
            XCTAssertEqual(try JSONDecoder().decode(DDCPowerResult.self, from: encoded), result)
        }
    }

    func testUnsupportedUnreadableOrInvalidStateRefusesBeforeWrite() {
        for input: Result<UInt16, DDCError> in [
            .failure(.reportedUnsupported(0xD6)), .failure(.requestFailed(-1)),
            .success(0), .success(5), .success(0x0101)
        ] {
            let fake = Fake([input])
            XCTAssertThrowsError(try run(.off, fake)) {
                guard case DDCPowerError.beforeWrite = $0 else { return XCTFail("\($0)") }
            }
            XCTAssertEqual(fake.writes, [])
            XCTAssertEqual(fake.reads, 1)
        }
    }

    func testUnreachableWakeNeverGuessesOrRetries() {
        var opens = 0
        XCTAssertThrowsError(try DDCPower.run(selector: uuid, value: .on, acceptedRisk: false, open: { selector in
            opens += 1
            XCTAssertEqual(selector, self.uuid)
            throw DDCError.displayNotFound(selector)
        })) {
            guard case DDCPowerError.beforeWrite = $0 else { return XCTFail("\($0)") }
            XCTAssertTrue(String(describing: $0).contains("unplugging monitor power"))
        }
        XCTAssertEqual(opens, 1)
        let fake = Fake([.failure(.transportUnavailable("offline"))])
        XCTAssertThrowsError(try run(.on, fake))
        XCTAssertEqual(fake.writes, [])
    }

    func testTransportLossAfterWriteIsUnverified() throws {
        for failure in [DDCError.requestFailed(-1), .transportUnavailable("offline")] {
            let fake = Fake([.success(1), .failure(failure)])
            let result = try run(.off, fake)
            XCTAssertEqual(result.outcome, .unverified)
            XCTAssertNil(result.observed)
            XCTAssertTrue(result.detail.contains("unplugging monitor power"))
            XCTAssertEqual(fake.writes, [4])
            XCTAssertEqual(fake.reads, 2)
        }
    }

    func testWriteFailureRemainsUnknownWithoutReadbackOrRetry() {
        let fake = Fake([.success(1)])
        fake.writeError = .requestFailed(-1)
        XCTAssertThrowsError(try run(.off, fake)) {
            guard case DDCPowerError.writeStateUnknown = $0 else { return XCTFail("\($0)") }
        }
        XCTAssertEqual(fake.writes, [4])
        XCTAssertEqual(fake.reads, 1)
        XCTAssertEqual(fake.pauses, 0)
    }

    func testMismatchAndMalformedOrUnsupportedReadbackAreErrorsNotTransportLoss() {
        for reading: Result<UInt16, DDCError> in [
            .success(1), .success(5), .failure(.reportedUnsupported(0xD6)),
            .failure(.invalidReply("checksum mismatch")), .failure(.wrongVCP(expected: 0xD6, actual: 0x60))
        ] {
            let fake = Fake([.success(1), reading])
            XCTAssertThrowsError(try run(.off, fake)) {
                guard case DDCPowerError.readbackFailed = $0 else { return XCTFail("\($0)") }
            }
            XCTAssertEqual(fake.writes, [4])
            XCTAssertEqual(fake.reads, 2)
        }
    }

    func testIdentityRefusalAndControllerAmbiguityBeforeChannelUse() throws {
        let valid = record()
        XCTAssertEqual(try DDC.resolveDisplay(selector: uuid, records: [valid]).id, 7)
        for records in [
            [], [record(builtin: true)], [record(active: false)], [record(online: false)],
            [record(uuid: nil)], [record(uuid: "invalid")],
            [valid, record(id: 8)], [valid, record(uuid: "22345678-1234-1234-1234-123456789ABC")]
        ] {
            var constructed = false
            XCTAssertThrowsError(try DDCPower.run(selector: "7", value: .off, acceptedRisk: true, open: { selector in
                let target = try DDC.resolveDisplay(selector: selector, records: records)
                constructed = true
                return (target, Fake([.success(1)]).channel)
            }))
            XCTAssertFalse(constructed)
        }
        var constructed = false
        XCTAssertThrowsError(try DDCPower.run(selector: uuid, value: .on, acceptedRisk: false, open: { _ in
            _ = try DDC.controllerPath(forLocation: "/dispext0@123/AppleCLCD2", candidates: [
                ("/a/dispext0:first", true), ("/b/dispext0:second", true)
            ])
            constructed = true
            return (DDC.DisplayTarget(id: 7, uuid: self.uuid), Fake([.success(4)]).channel)
        }))
        XCTAssertFalse(constructed)
    }

    private func record(id: UInt32 = 7, uuid: String? = "12345678-1234-1234-1234-123456789ABC", active: Bool = true, online: Bool = true, builtin: Bool = false) -> DisplayRecord {
        DisplayRecord(index: 1, id: id, uuid: uuid, name: "Test", active: active, online: online,
                      asleep: false, builtin: builtin, main: false, vendor: 1, model: 2, serial: 3,
                      bounds: DisplayBounds(.zero), pixelWidth: 100, pixelHeight: 100)
    }

    private func run(_ value: DDCPowerValue?, _ fake: Fake) throws -> DDCPowerResult {
        try DDCPower.run(selector: uuid, value: value, acceptedRisk: true,
                         open: { _ in (DDC.DisplayTarget(id: 7, uuid: self.uuid), fake.channel) },
                         pause: { fake.pauses += 1 })
    }

    private final class Fake {
        var replies: [Result<UInt16, DDCError>]
        var writes: [UInt16] = []
        var reads = 0
        var pauses = 0
        var writeError: DDCError?
        init(_ replies: [Result<UInt16, DDCError>]) { self.replies = replies }
        var channel: DDCChannel {
            DDCChannel(getVCP: { code in
                XCTAssertEqual(code, 0xD6)
                self.reads += 1
                guard !self.replies.isEmpty else {
                    XCTFail("read budget exceeded")
                    throw DDCError.requestFailed(-1)
                }
                return (try self.replies.removeFirst().get(), 0)
            }, setVCP: { code, value in
                XCTAssertEqual(code, 0xD6)
                self.writes.append(value)
                if let error = self.writeError { throw error }
            })
        }
    }
}
