import XCTest
@testable import PanelCtlCore

// Shared by pure policy tests and real session-boundary tests with fake writers.
enum DriverInventoryFixture {
    static var valid: RecoveryDriverInventory.Evidence {
        .init(onlineIDs: [1, 2], paths: [1: "IOService:/frame-1", 2: "IOService:/frame-2"],
            framebuffers: (0..<5).map { .init(registryID: UInt64($0 + 1), path: "IOService:/frame-\($0)",
                index: UInt32($0), bundle: RecoveryDriverInventory.owner,
                kernelBundle: RecoveryDriverInventory.owner, publisher: RecoveryDriverInventory.owner) },
            serviceLabels: ["IOMobileFramebufferShim"],
            loadedKexts: ["com.apple.kpi.iokit", RecoveryDriverInventory.owner], systemExtensions: "0 extension(s)\n")
    }

    static var refusals: [(String, (inout RecoveryDriverInventory.Evidence) -> Void)] {
        [
            ("unmapped virtual display", { $0.onlineIDs.append(3); $0.paths[3] = "virtual" }),
            ("missing mapping", { $0.paths[2] = nil }),
            ("extra mapping", { $0.paths[3] = "IOService:/frame-3" }),
            ("duplicate mapping", { $0.paths[2] = $0.paths[1] }),
            ("duplicate CG ID", { $0.onlineIDs.append(2) }),
            ("empty CG inventory", { $0.onlineIDs = []; $0.paths = [:] }),
            ("DisplayLink", { $0.serviceLabels.append("DisplayLinkManager") }),
            ("Sidecar", { $0.serviceLabels.append("SidecarDisplay") }),
            ("AirPlay", { $0.serviceLabels.append("AirPlayDisplay") }),
            ("third-party kext", { $0.loadedKexts.append("org.vendor.driver") }),
            ("Apple-lookalike kext", { $0.loadedKexts.append("com.appleevil.driver") }),
            ("missing loaded driver", { $0.loadedKexts.removeLast() }),
            ("empty kext inventory", { $0.loadedKexts = [] }),
            ("duplicate loaded driver", { $0.loadedKexts.append(RecoveryDriverInventory.owner) }),
            ("active system extension", { $0.systemExtensions = "1 extension(s)\n* * TEAM org.vendor.driver [activated enabled]" }),
            ("unrecognized extension output", { $0.systemExtensions = "0 extension(s)\npartial output" }),
            ("unreadable extension inventory", { $0.systemExtensions = "" }),
            ("partial framebuffer inventory", { $0.framebuffers.removeLast() }),
            ("extra framebuffer", { $0.framebuffers.append($0.framebuffers[0]) }),
            ("duplicate registry ID", { $0.framebuffers[1].registryID = $0.framebuffers[0].registryID }),
            ("duplicate path", { $0.framebuffers[1].path = $0.framebuffers[0].path }),
            ("duplicate index", { $0.framebuffers[1].index = 0 }),
            ("unreadable path", { $0.framebuffers[1].path = "" }),
            ("unreadable owner", { $0.framebuffers[1].bundle = "" }),
            ("wrong publisher", { $0.framebuffers[1].publisher = "com.apple.unqualified" }),
            ("wrong kernel owner", { $0.framebuffers[1].kernelBundle = "org.vendor.driver" }),
            ("unsupported host", { $0.host = "Mac99,1" }),
            ("unknown host", { $0.host = nil }),
            ("unsupported build", { $0.build = "26A435" }),
            ("unsupported architecture", { $0.architecture = "x86_64" })
        ]
    }
}

final class RecoveryDriverInventoryTests: XCTestCase {
    func testPositiveInventoryAndEveryRefusal() {
        XCTAssertEqual(RecoveryDriverInventory.evaluate(DriverInventoryFixture.valid).drivers, .nativeOnly)
        for (name, change) in DriverInventoryFixture.refusals {
            var evidence = DriverInventoryFixture.valid; change(&evidence)
            let result = RecoveryDriverInventory.evaluate(evidence)
            XCTAssertNotEqual(result.drivers, .nativeOnly, name)
            XCTAssertFalse(result.diagnostic.isEmpty, name)
        }
        // An absent retained target does not make an unused native slot foreign.
        var absent = DriverInventoryFixture.valid
        absent.onlineIDs = [1]; absent.paths[2] = nil
        XCTAssertEqual(RecoveryDriverInventory.evaluate(absent).drivers, .nativeOnly)
    }

    func testLoadedKextParserRequiresCompleteRecognizedRows() throws {
        let row = " 3 221 0 0 0 com.apple.kpi.iokit (27.0.0) 25FECA3D-AD9D-3958-B633-A14EC36D3BE7 <>\n"
        let driver = " 4 0 0xfffffe0007144000 0x7098 0x7098 \(RecoveryDriverInventory.owner) (1.0.0) 25FECA3D-AD9D-3958-B633-A14EC36D3BE7 <3>\n"
        XCTAssertEqual(try RecoveryDriverInventory.parseLoadedKexts(row + driver), DriverInventoryFixture.valid.loadedKexts)
        for text in ["", "permission denied", row + "truncated", row + row,
                     row.replacingOccurrences(of: "<>", with: ""), row + "Index Refs Address Size"] {
            XCTAssertThrowsError(try RecoveryDriverInventory.parseLoadedKexts(text), text)
        }
    }

    func testCommandFailureCannotReturnCleanInventory() {
        XCTAssertThrowsError(try RecoveryDriverInventory.command("/nonexistent/panelctl-inventory", arguments: []))
        XCTAssertThrowsError(try RecoveryDriverInventory.command("/usr/bin/false", arguments: []))
    }
}
