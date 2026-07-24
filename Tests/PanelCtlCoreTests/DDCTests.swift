import XCTest
@testable import PanelCtlCore

final class DDCTests: XCTestCase {
    func testGetVCPRequestAndChecksum() {
        let packet = DDCLuminance.makeGetVCPRequest(code: 0x10)
        XCTAssertEqual(packet, [0x82, 0x01, 0x10, 0xFD])
        XCTAssertEqual(packet.reduce(0, ^) ^ 0x6E, 0)
    }

    func testSetVCPRequestAndChecksum() {
        let dim = DDCLuminance.makeSetVCPRequest(code: 0x10, value: 74)
        let restore = DDCLuminance.makeSetVCPRequest(code: 0x10, value: 75)
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
            XCTAssertEqual(error as? DDCLuminanceError, .invalidReply("reply is shorter than 11 bytes"))
        }

        var wrong = makeReply(code: 0x12, current: 10, maximum: 100)
        XCTAssertThrowsError(try DDCLuminance.validateReply(wrong, expectedCode: 0x10)) { error in
            XCTAssertEqual(error as? DDCLuminanceError, .wrongVCP(expected: 0x10, actual: 0x12))
        }

        wrong = makeReply(code: 0x10, current: 10, maximum: 100, result: 0x01)
        XCTAssertThrowsError(try DDCLuminance.validateReply(wrong, expectedCode: 0x10)) { error in
            XCTAssertEqual(error as? DDCLuminanceError, .reportedUnsupported(0x10))
        }
    }

    func testPathMapsToExternalController() {
        let location = "IOService:/AppleARMPE/arm-io/AppleT600xIO/dispext0@88000000/AppleCLCD2"
        let candidates: [(path: String, external: Bool)] = [
            ("IOService:/AppleARMPE/dcpext0/dispext0:dcpav-service/DCPAVServiceProxy", false),
            ("IOService:/AppleARMPE/dcpext0/dispext0:dcpav-service/DCPAVServiceProxy", true),
            ("IOService:/AppleARMPE/dcpext1/dispext1:dcpav-service/DCPAVServiceProxy", true)
        ]
        XCTAssertEqual(DDCLuminance.controllerPath(forLocation: location, candidates: candidates), candidates[1].path)
        XCTAssertNil(DDCLuminance.controllerPath(forLocation: "IOService:/AppleARMPE/disp0@0/AppleCLCD2", candidates: candidates))
    }

    private func makeReply(code: UInt8, current: UInt16, maximum: UInt16, result: UInt8 = 0) -> [UInt8] {
        var bytes: [UInt8] = [0x6E, 0x88, 0x02, result, code, 0x00,
                              UInt8(maximum >> 8), UInt8(maximum & 0xFF),
                              UInt8(current >> 8), UInt8(current & 0xFF), 0]
        bytes[10] = 0x50 ^ bytes[0..<10].reduce(0, ^)
        return bytes
    }
}
