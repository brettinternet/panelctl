import XCTest
@testable import PanelCtlCore

final class RecoveryColorProfileTests: XCTestCase {
    static func profile(second: UInt8 = 1) -> Data {
        var bytes = [UInt8](repeating: 0, count: 176)
        bytes[3] = 176; bytes[8] = 4
        bytes.replaceSubrange(12..<16, with: "mntr".utf8)
        bytes.replaceSubrange(36..<40, with: "acsp".utf8)
        bytes.replaceSubrange(24..<36, with: [7, 234, 0, 10, 0, 2, 0, 8, 0, 52, 0, second])
        bytes[131] = 2
        bytes.replaceSubrange(132..<136, with: "rXYZ".utf8)
        bytes[139] = 156; bytes[143] = 20
        bytes.replaceSubrange(144..<148, with: "gXYZ".utf8)
        bytes[151] = 156; bytes[155] = 20 // Shared tag payload is valid.
        bytes.replaceSubrange(156..<160, with: "XYZ ".utf8)
        return Data(bytes)
    }

    func testCreationTimeOnlyMatchesWhileRawHashesDiffer() throws {
        let before = Self.profile(), after = Self.profile(second: 2)
        XCTAssertNotEqual(RecoveryColorProfile.digest(before), RecoveryColorProfile.digest(after))
        let fingerprint = try XCTUnwrap(RecoveryColorProfile.dateIndependentDigest(before))
        XCTAssertEqual(fingerprint, RecoveryColorProfile.dateIndependentDigest(after))
        var v2 = before; v2[8] = 2
        XCTAssertNotNil(RecoveryColorProfile.dateIndependentDigest(v2))
    }

    func testEveryOtherByteIsProtected() throws {
        let original = Self.profile()
        let fingerprint = try XCTUnwrap(RecoveryColorProfile.dateIndependentDigest(original))
        for offset in original.indices where !(24..<36).contains(offset) {
            var changed = original; changed[offset] ^= 1
            XCTAssertNotEqual(RecoveryColorProfile.dateIndependentDigest(changed), fingerprint, "byte \(offset)")
        }
    }

    func testMalformedOrUnsupportedProfilesDoNotNormalize() {
        let original = Self.profile()
        for length in 0..<original.count {
            XCTAssertNil(RecoveryColorProfile.dateIndependentDigest(Data(original.prefix(length))))
        }
        // Unsupported version/class, computed profile ID, impossible date,
        // table overflow, header-overlapping/out-of-bounds tag, duplicate tags.
        for (offset, value): (Int, UInt8) in [(8, 5), (12, 0), (84, 1), (27, 13), (29, 32),
                                            (31, 24), (33, 60), (35, 60), (131, 255),
                                            (139, 24), (139, 255), (143, 255), (144, 114)] {
            var changed = original; changed[offset] = value
            XCTAssertNil(RecoveryColorProfile.dateIndependentDigest(changed), "offset \(offset)")
        }
        var noTags = original; noTags[131] = 0
        XCTAssertNil(RecoveryColorProfile.dateIndependentDigest(noTags))
        XCTAssertNil(RecoveryColorProfile.dateIndependentDigest(Data(repeating: 0, count: 1_048_577)))
    }

    func testDateValidityAndNonzeroDataStartIndex() {
        var leap = Self.profile()
        leap[25] = 232 // 2024
        leap[27] = 2; leap[29] = 29
        XCTAssertNotNil(RecoveryColorProfile.dateIndependentDigest(leap))
        leap[25] = 233 // 2025
        XCTAssertNil(RecoveryColorProfile.dateIndependentDigest(leap))
        let original = Self.profile()
        var prefixed = Data([0]); prefixed.append(original)
        XCTAssertEqual(RecoveryColorProfile.dateIndependentDigest(prefixed.dropFirst()),
                       RecoveryColorProfile.dateIndependentDigest(original))
    }

    /// Replays retained bytes only; never calls a display API or edits evidence.
    func testRetainedProfileEvidence() throws {
        guard let path = ProcessInfo.processInfo.environment["PANELCTL_ICC_EVIDENCE_DIR"] else {
            throw XCTSkip("optional offline replay of retained ICC artifacts")
        }
        let root = URL(fileURLWithPath: path)
        let report = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("report.json"))) as? [String: Any])
        let displays = try XCTUnwrap(report["displays"] as? [[String: Any]])
        var compared = 0
        for display in displays where display["journalICCEqual"] as? Bool == false {
            let uuid = try XCTUnwrap(display["uuid"] as? String)
            XCTAssertNotNil(UUID(uuidString: uuid))
            let current = try Data(contentsOf: root.appendingPathComponent(uuid + ".icc"))
            var reconstructed = current
            reconstructed.replaceSubrange(24..<36, with: [7, 234, 0, 10, 0, 2, 0, 8, 0, 52, 0, 52])
            XCTAssertEqual(RecoveryColorProfile.digest(reconstructed), display["journalICC"] as? String)
            XCTAssertEqual(RecoveryColorProfile.digest(current), display["iccSHA256"] as? String)
            let fingerprint = try XCTUnwrap(RecoveryColorProfile.dateIndependentDigest(current))
            XCTAssertEqual(fingerprint, RecoveryColorProfile.dateIndependentDigest(reconstructed))
            compared += 1
        }
        XCTAssertEqual(compared, 2)
    }
}
