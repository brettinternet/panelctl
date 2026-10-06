import XCTest
@testable import PanelCtlCore

final class DDCTests: XCTestCase {
    func testGetVCPRequestAndChecksum() {
        let packet = DDC.makeGetVCPRequest(code: 0x10)
        XCTAssertEqual(packet, [0x82, 0x01, 0x10, 0xFD])
        XCTAssertEqual(packet.reduce(0, ^) ^ 0x6E, 0)
    }

    func testSetVCPRequestAndChecksum() {
        let dim = DDC.makeSetVCPRequest(code: 0x10, value: 74)
        let restore = DDC.makeSetVCPRequest(code: 0x10, value: 75)
        XCTAssertEqual(dim, [0x84, 0x03, 0x10, 0x00, 0x4A, 0xE2])
        XCTAssertEqual(restore, [0x84, 0x03, 0x10, 0x00, 0x4B, 0xE3])
        XCTAssertEqual(0x6E ^ 0x51 ^ dim.reduce(0, ^), 0)
        XCTAssertEqual(0x6E ^ 0x51 ^ restore.reduce(0, ^), 0)
    }

    func testReplyValidationCurrentAndMaximum() throws {
        let reply = makeReply(code: 0x10, current: 42, maximum: 100)
        let result = try DDCLuminance.validateReply(reply, expectedCode: 0x10)
        XCTAssertEqual(result.current, 42)
        XCTAssertEqual(result.maximum, 100)
    }

    func testReplyValidationRejectsMalformedWrongVCPAndUnsupported() {
        XCTAssertThrowsError(try DDCLuminance.validateReply([0x02, 0x06], expectedCode: 0x10)) { error in
            XCTAssertEqual(error as? DDCError, .invalidReply("reply is shorter than 11 bytes"))
        }

        var wrong = makeReply(code: 0x12, current: 10, maximum: 100)
        XCTAssertThrowsError(try DDCLuminance.validateReply(wrong, expectedCode: 0x10)) { error in
            XCTAssertEqual(error as? DDCError, .wrongVCP(expected: 0x10, actual: 0x12))
        }

        wrong = makeReply(code: 0x10, current: 10, maximum: 100, result: 0x01)
        XCTAssertThrowsError(try DDCLuminance.validateReply(wrong, expectedCode: 0x10)) { error in
            XCTAssertEqual(error as? DDCError, .reportedUnsupported(0x10))
        }
    }

    func testPathMapsToExternalController() {
        let location = "IOService:/AppleARMPE/arm-io/AppleT600xIO/dispext0@88000000/AppleCLCD2"
        let candidates: [(path: String, external: Bool)] = [
            ("IOService:/AppleARMPE/dcpext0/dispext0:dcpav-service/DCPAVServiceProxy", false),
            ("IOService:/AppleARMPE/dcpext0/dispext0:dcpav-service/DCPAVServiceProxy", true),
            ("IOService:/AppleARMPE/dcpext1/dispext1:dcpav-service/DCPAVServiceProxy", true)
        ]
        XCTAssertEqual(try DDC.controllerPath(forLocation: location, candidates: candidates), candidates[1].path)
        XCTAssertNil(try DDC.controllerPath(forLocation: "IOService:/AppleARMPE/disp0@0/AppleCLCD2", candidates: candidates))
    }

    func testAmbiguousControllerMappingRefuses() {
        let location = "IOService:/AppleARMPE/arm-io/AppleT600xIO/dispext0@88000000/AppleCLCD2"
        let candidates: [(path: String, external: Bool)] = [
            ("IOService:/AppleARMPE/dcpext0/dispext0:dcpav-service/DCPAVServiceProxy", true),
            ("IOService:/AppleARMPE/dcpext2/dispext0:dcpav-service/DCPAVServiceProxy", true)
        ]
        XCTAssertThrowsError(try DDC.controllerPath(forLocation: location, candidates: candidates)) {
            XCTAssertEqual($0 as? DDCError, .ambiguousController(location))
        }
    }

    // MARK: Input select (VCP 0x60)

    func testInputRequestEncodingAndNonContinuousReply() throws {
        XCTAssertEqual(DDC.makeGetVCPRequest(code: 0x60), [0x82, 0x01, 0x60, 0x8D])
        let hdmi1 = DDC.makeSetVCPRequest(code: 0x60, value: 0x11)
        XCTAssertEqual(hdmi1, [0x84, 0x03, 0x60, 0x00, 0x11, 0xC9])
        XCTAssertEqual(0x6E ^ 0x51 ^ hdmi1.reduce(0, ^), 0)

        // Input select has no meaningful maximum; current may exceed it.
        let reply = makeReply(code: 0x60, current: 0x010F, maximum: 0x0003)
        XCTAssertEqual(try DDC.parseReply(reply, expectedCode: 0x60).current, 0x010F)
        XCTAssertThrowsError(try DDCLuminance.validateReply(reply, expectedCode: 0x60))
        let channel = FakeChannel(inputs: [.success(0x010F)])
        XCTAssertEqual(try DDCInput.current(channel.channel), 0x0F)
    }

    func testInputValueParsing() {
        XCTAssertEqual(DDCInput.parseValue("HDMI1"), 0x11)
        XCTAssertEqual(DDCInput.parseValue("dp1"), 0x0F)
        XCTAssertEqual(DDCInput.parseValue("0x12"), 0x12)
        XCTAssertEqual(DDCInput.parseValue("17"), 0x11)
        XCTAssertNil(DDCInput.parseValue("0"))
        XCTAssertNil(DDCInput.parseValue("256"))
        XCTAssertNil(DDCInput.parseValue("usb"))
    }

    func testSelectVerifiesWithOneWrite() throws {
        let fake = FakeChannel(inputs: [.success(0x0F), .success(0x0F), .success(0x11)])
        let result = try select(0x11, fake)
        XCTAssertEqual(result.outcome, .verified)
        XCTAssertEqual(result.original, 0x0F)
        XCTAssertEqual(result.observed, 0x11)
        XCTAssertEqual(fake.writes, [0x11])
    }

    func testAlreadySelectedDoesNotWrite() throws {
        let fake = FakeChannel(inputs: [.success(0x11)])
        XCTAssertEqual(try select(0x11, fake).outcome, .alreadySelected)
        XCTAssertEqual(fake.writes, [])
    }

    func testUnsupportedOrUnreadableInputRefusesBeforeWrite() {
        for failure in [DDCError.reportedUnsupported(0x60), .requestFailed(-536870212)] {
            let fake = FakeChannel(inputs: [.failure(failure)])
            XCTAssertThrowsError(try select(0x11, fake)) { XCTAssertEqual($0 as? DDCError, failure) }
            XCTAssertEqual(fake.writes, [])
        }
    }

    func testKnownReturnWithUnknownOriginalWritesOnceAndReportsReadbackHonestly() throws {
        for scenario in ["verified", "unreadable", "mismatch", "write-failed"] {
            let fake = FakeChannel(
                inputs: scenario == "unreadable" ? [.failure(.invalidReply("invalid payload length"))] :
                    [.success(scenario == "mismatch" ? 0x11 : 0x0F)],
                writeError: scenario == "write-failed" ? .requestFailed(-1) : nil)
            do {
                let result = try DDCInput.select(0x0F, channel: fake.channel, displayID: 7, uuid: "UUID",
                                                 readOriginal: false, polls: 3, pause: { _ in })
                XCTAssertFalse(["mismatch", "write-failed"].contains(scenario))
                XCTAssertNil(result.original)
                XCTAssertEqual(result.outcome, scenario == "verified" ? .verified : .unverified)
                XCTAssertEqual(result.observed, scenario == "verified" ? 0x0F : nil)
            } catch {
                XCTAssertTrue(["mismatch", "write-failed"].contains(scenario))
                XCTAssertTrue(String(describing: error).contains("previous input unknown"))
                XCTAssertFalse(String(describing: error).contains("--set"), "do not invent a recovery input")
            }
            XCTAssertEqual(fake.writes, [0x0F], scenario)
        }
    }

    func testTransportLossAfterWriteIsUnverifiedNotRetried() throws {
        let fake = FakeChannel(inputs: [.success(0x0F), .success(0x0F), .failure(DDCError.requestFailed(-1))])
        let result = try select(0x11, fake)
        XCTAssertEqual(result.outcome, .unverified)
        XCTAssertEqual(result.observed, 0x0F)
        XCTAssertNotNil(result.detail)
        XCTAssertEqual(fake.writes, [0x11])
    }

    func testWriteFailureReportsUnknownStateWithSwitchBack() {
        let fake = FakeChannel(inputs: [.success(0x0F)], writeError: DDCError.requestFailed(-1))
        XCTAssertThrowsError(try select(0x11, fake)) { error in
            guard case .inputWriteStateUnknown(0x0F, "UUID", _) = error as? DDCError else { return XCTFail("\(error)") }
            XCTAssertTrue(String(describing: error).contains("--set 0x0F"))
        }
        XCTAssertEqual(fake.writes, [0x11])
    }

    func testReadbackMismatchFailsWithoutRewrite() {
        let fake = FakeChannel(inputs: [.success(0x0F), .success(0x12)])
        XCTAssertThrowsError(try select(0x11, fake)) {
            XCTAssertEqual($0 as? DDCError, .inputNotVerified(original: 0x0F, requested: 0x11, observed: 0x12, uuid: "UUID"))
        }
        XCTAssertEqual(fake.writes, [0x11])
    }

    private func select(_ value: UInt8, _ fake: FakeChannel) throws -> DDCInputSelection {
        try DDCInput.select(value, channel: fake.channel, displayID: 7, uuid: "UUID", polls: 3, interval: 0, pause: { _ in })
    }

    /// Replays scripted 0x60 reads (the last entry repeats) and records writes.
    private final class FakeChannel {
        var inputs: [Result<UInt16, DDCError>]
        let writeError: DDCError?
        var writes: [UInt16] = []

        init(inputs: [Result<UInt16, DDCError>], writeError: DDCError? = nil) {
            self.inputs = inputs
            self.writeError = writeError
        }

        var channel: DDCChannel {
            DDCChannel(
                getVCP: { code in
                    XCTAssertEqual(code, 0x60)
                    let next = self.inputs.count > 1 ? self.inputs.removeFirst() : self.inputs[0]
                    return (try next.get(), 0)
                },
                setVCP: { code, value in
                    XCTAssertEqual(code, 0x60)
                    self.writes.append(value)
                    if let error = self.writeError { throw error }
                }
            )
        }
    }

    private func makeReply(code: UInt8, current: UInt16, maximum: UInt16, result: UInt8 = 0) -> [UInt8] {
        var bytes: [UInt8] = [0x6E, 0x88, 0x02, result, code, 0x00,
                              UInt8(maximum >> 8), UInt8(maximum & 0xFF),
                              UInt8(current >> 8), UInt8(current & 0xFF), 0]
        bytes[10] = 0x50 ^ bytes[0..<10].reduce(0, ^)
        return bytes
    }
}
