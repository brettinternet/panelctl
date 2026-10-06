import XCTest
import CoreGraphics
@testable import PanelCtlCore

// A genuine C-convention fake proves the cast/call widths without an Apple setter.
private let fakeSetter: ConfigureDisplayEnabled = { config, id, enabled in
    guard config == CGDisplayConfigRef(bitPattern: 1),
          id == (enabled ? 0xFFFFFFFE : 0xFFFFFFFD) else { return .illegalArgument }
    return .success
}

final class RecoveryDisplayBindingTests: XCTestCase {
    private typealias Binding = RecoveryDisplayBinding
    private final class Fixture {
        var opens: [String] = [], symbols: [String] = [], closes = 0
        var missingFrameworks: Set<String> = [], missingSymbols: Set<String> = []
        var uuids = [Binding.coreGraphics: Binding.coreGraphicsUUID, Binding.skyLight: Binding.skyLightUUID]
        var origin: String? = Binding.skyLight
        var loader: Binding.Loader {
            Binding.Loader(open: { path in
                self.opens.append(path)
                return self.missingFrameworks.contains(path) ? nil : UnsafeMutableRawPointer(bitPattern: 1)
            }, symbol: { _, name in
                self.symbols.append(name)
                return self.missingSymbols.contains(name) ? nil : unsafeBitCast(fakeSetter, to: UnsafeMutableRawPointer.self)
            }, imageUUID: { self.uuids[$0] }, symbolImage: { _ in self.origin }, close: { _ in self.closes += 1 })
        }
        func resolve(architecture: String = "arm64", build: String = "26A434") throws -> Binding {
            try Binding.resolve(architecture: architecture, osBuild: build, loader: loader)
        }
    }

    func testPreferredSymbolAndHandleLifetimeThroughTransaction() throws {
        let fixture = Fixture()
        var binding: Binding? = try fixture.resolve()
        XCTAssertEqual(fixture.opens, [Binding.coreGraphics])
        XCTAssertEqual(fixture.symbols, ["CGSConfigureDisplayEnabled"])
        var transaction: RecoveryEnableTransaction? = binding!.transaction()
        binding = nil
        XCTAssertEqual(fixture.closes, 0)
        XCTAssertNotNil(transaction)
        transaction = nil
        XCTAssertEqual(fixture.closes, 1)
    }

    func testQualifiedFallbackForMissingFrameworkOrSymbol() throws {
        for missingFramework in [true, false] {
            let fixture = Fixture()
            if missingFramework { fixture.missingFrameworks = [Binding.coreGraphics] }
            else { fixture.missingSymbols = ["CGSConfigureDisplayEnabled"] }
            var binding: Binding? = try fixture.resolve()
            XCTAssertNotNil(binding)
            XCTAssertEqual(fixture.opens, [Binding.coreGraphics, Binding.skyLight])
            XCTAssertEqual(fixture.symbols.last, "SLSConfigureDisplayEnabled")
            XCTAssertEqual(fixture.closes, missingFramework ? 0 : 1)
            binding = nil
            XCTAssertEqual(fixture.closes, missingFramework ? 1 : 2)
        }
    }

    func testMissingFrameworksAndSymbolsGiveSpecificDiagnostics() {
        for frameworks in [true, false] {
            let fixture = Fixture()
            if frameworks { fixture.missingFrameworks = [Binding.coreGraphics, Binding.skyLight] }
            else { fixture.missingSymbols = ["CGSConfigureDisplayEnabled", "SLSConfigureDisplayEnabled"] }
            XCTAssertThrowsError(try fixture.resolve()) {
                XCTAssertTrue(String(describing: $0).contains(frameworks ? "missing framework" : "missing symbol"))
            }
            XCTAssertEqual(fixture.closes, frameworks ? 0 : 2)
        }
    }

    func testUnsupportedArchitectureDoesNotLoad() {
        let fixture = Fixture()
        XCTAssertThrowsError(try fixture.resolve(architecture: "x86_64")) {
            XCTAssertTrue(String(describing: $0).contains("unsupported architecture"))
        }
        XCTAssertTrue(fixture.opens.isEmpty)
        XCTAssertTrue(fixture.symbols.isEmpty)
    }

    func testBuildLabelDoesNotOverrideBinaryCompatibility() throws {
        let fixture = Fixture()
        XCTAssertNoThrow(try fixture.resolve(build: "another-build"))
        fixture.uuids[Binding.skyLight] = "unverified-image"
        XCTAssertThrowsError(try fixture.resolve(build: "another-build")) {
            XCTAssertTrue(String(describing: $0).contains("unverified ABI image"))
        }
    }

    func testUnknownImagesOrSymbolOriginRefuseWithoutFallback() {
        for variant in 0..<5 {
            let fixture = Fixture()
            switch variant {
            case 0: fixture.uuids[Binding.coreGraphics] = "other"
            case 1: fixture.uuids[Binding.skyLight] = nil
            case 2: fixture.origin = Binding.coreGraphics
            case 3: fixture.origin = nil
            default:
                fixture.missingSymbols = ["CGSConfigureDisplayEnabled"]
                fixture.uuids[Binding.skyLight] = "other"
            }
            XCTAssertThrowsError(try fixture.resolve()) {
                XCTAssertTrue(String(describing: $0).contains("unverified ABI image"))
            }
            XCTAssertEqual(fixture.opens.count, variant == 4 ? 2 : 1)
            XCTAssertEqual(fixture.closes, fixture.opens.count)
        }
    }

    func testOnlyExactVerifiedVersionedSymbolOriginIsAccepted() throws {
        XCTAssertEqual(Binding.coreGraphics,
            "/System/Library/Frameworks/CoreGraphics.framework/Versions/A/CoreGraphics")
        XCTAssertEqual(Binding.skyLight,
            "/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/SkyLight")
        for fallback in [false, true] {
            for origin in [Binding.skyLight,
                           "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight",
                           "/System/Library/PrivateFrameworks/SkyLight.framework/Versions/B/SkyLight",
                           "/tmp/SkyLight.framework/Versions/A/SkyLight"] {
                let fixture = Fixture()
                if fallback { fixture.missingSymbols = ["CGSConfigureDisplayEnabled"] }
                fixture.origin = origin
                if origin == Binding.skyLight {
                    XCTAssertNoThrow(try fixture.resolve())
                } else {
                    XCTAssertThrowsError(try fixture.resolve())
                    XCTAssertEqual(fixture.opens.count, fallback ? 2 : 1)
                }
                XCTAssertEqual(fixture.closes, fixture.opens.count)
            }
        }
    }

    func testCurrentVerifiedBuildResolvesWithoutConstructingTransaction() throws {
        #if arch(arm64)
        guard try systemString("kern.osversion") == "26A434" else {
            throw XCTSkip("read-only binding check requires verified build 26A434")
        }
        // Resolve symbols and inspect loaded images only: no transaction is
        // constructed, and neither public nor private display APIs are called.
        XCTAssertNoThrow(try Binding.resolve())
        #else
        throw XCTSkip("read-only binding check requires arm64")
        #endif
    }

    func testExactCBindingWithFakeSetterOnlyAndErrorPropagation() throws {
        XCTAssertEqual(MemoryLayout<CGDirectDisplayID>.size, 4)
        XCTAssertEqual(MemoryLayout<CGError>.size, 4)
        for enabled in [false, true] {
            for stageFailure in [false, true] {
                let fixture = Fixture()
                var transaction = try fixture.resolve().transaction()
                var events: [String] = []
                // Replace every public mutation before using the fake C setter.
                transaction.begin = { events.append("begin"); return CGDisplayConfigRef(bitPattern: 1)! }
                transaction.commit = { _, scope in
                    XCTAssertEqual(scope, .forSession); events.append("complete")
                }
                transaction.cancel = { _ in events.append("cancel") }
                let id: UInt32 = stageFailure ? 0 : (enabled ? 0xFFFFFFFE : 0xFFFFFFFD)
                let operation = { try transaction.configure(id: id, enabled: enabled) { events.append("validate") } }
                if stageFailure {
                    XCTAssertThrowsError(try operation()) {
                        XCTAssertTrue(String(describing: $0).contains("CGError 1001"))
                    }
                    XCTAssertEqual(events, ["validate", "begin", "validate", "cancel"])
                } else {
                    XCTAssertNoThrow(try operation())
                    XCTAssertEqual(events, ["validate", "begin", "validate", "validate", "complete"])
                }
            }
        }
    }

    func testBothDirectionsCancelOnlyBeforeCompletion() {
        for enabled in [false, true] {
            for failure in ["none", "validate-1", "begin", "validate-2", "stage", "validate-3", "will-commit", "complete"] {
                var events: [String] = [], validations = 0
                func step(_ event: String) throws {
                    events.append(event)
                    if failure == event { throw RecoveryError.unsafe(event) }
                }
                let transaction = RecoveryEnableTransaction(begin: {
                    try step("begin"); return CGDisplayConfigRef(bitPattern: 1)!
                }, setEnabled: { _, id, value in
                    XCTAssertEqual(id, 42); XCTAssertEqual(value, enabled); try step("stage")
                }, commit: { _, scope in
                    XCTAssertEqual(scope, .forSession); try step("complete")
                }, cancel: { _ in events.append("cancel") })
                let operation = {
                    try transaction.configure(id: 42, enabled: enabled, willCommit: { try step("will-commit") }) {
                        validations += 1; try step("validate-\(validations)")
                    }
                }
                if failure == "none" { XCTAssertNoThrow(try operation()) }
                else { XCTAssertThrowsError(try operation()) }
                let order = ["validate-1", "begin", "validate-2", "stage", "validate-3", "will-commit", "complete"]
                var expected = failure == "none" ? order : Array(order.prefix(through: order.firstIndex(of: failure)!))
                if ["validate-2", "stage", "validate-3", "will-commit"].contains(failure) { expected.append("cancel") }
                XCTAssertEqual(events, expected)
            }
        }
    }
}
