import Foundation
import XCTest

/// Native windows, menus and sheets require an explicit opt-in, even with fake displays.
func requireInteractiveUI(environment: [String: String] = ProcessInfo.processInfo.environment) throws {
    guard environment["PANELCTL_TEST_INTERACTIVE_UI"] == "1" else {
        throw XCTSkip("Native UI test: set PANELCTL_TEST_INTERACTIVE_UI=1 and select the relevant test with --filter.")
    }
}

final class InteractiveUITestGateTests: XCTestCase {
    func testDefaultAndNonExplicitValuesSkipBeforeRunningUI() {
        for environment in [[:], ["PANELCTL_TEST_INTERACTIVE_UI": "0"],
                            ["PANELCTL_TEST_INTERACTIVE_UI": "true"],
                            ["CI": "true"], ["PANELCTL_SETTINGS_FIXTURE_OUTPUT": "/tmp/fixture"]] {
            XCTAssertThrowsError(try requireInteractiveUI(environment: environment)) { error in
                XCTAssertTrue(error is XCTSkip)
            }
        }
    }

    func testExplicitOptInAllowsTestBodyWithoutPresentingUIHere() {
        XCTAssertNoThrow(try requireInteractiveUI(environment: ["PANELCTL_TEST_INTERACTIVE_UI": "1"]))
    }
}
