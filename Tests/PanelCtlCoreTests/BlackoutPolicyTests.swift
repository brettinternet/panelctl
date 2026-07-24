import XCTest
@testable import PanelCtlCore

final class BlackoutPolicyTests: XCTestCase {
    func testIdleThresholdIsInclusive() {
        let policy = BlackoutPolicy(idleAfter: 60, timeout: nil, sleepAfter: nil)
        XCTAssertFalse(policy.shouldBegin(idleSeconds: 59.999))
        XCTAssertTrue(policy.shouldBegin(idleSeconds: 60))
    }

    func testInputIsComparedByLastInputEpoch() {
        let policy = BlackoutPolicy(idleAfter: nil, timeout: nil, sleepAfter: nil)
        XCTAssertFalse(policy.hasNewInput(IdleSample(seconds: 20, lastInputUptime: 100), after: 100))
        XCTAssertTrue(policy.hasNewInput(IdleSample(seconds: 0, lastInputUptime: 101), after: 100))
    }

    func testLimitActionsAreInclusive() {
        let timeout = BlackoutPolicy(idleAfter: nil, timeout: 10, sleepAfter: nil)
        XCTAssertEqual(timeout.limitAction(elapsed: 9.999), .none)
        XCTAssertEqual(timeout.limitAction(elapsed: 10), .finish)

        let sleep = BlackoutPolicy(idleAfter: nil, timeout: nil, sleepAfter: 20)
        XCTAssertEqual(sleep.limitAction(elapsed: 19.999), .none)
        XCTAssertEqual(sleep.limitAction(elapsed: 20), .sleep)
    }

    func testIdleSampleTakesUptimeAfterPotentiallySlowQuery() throws {
        var now: TimeInterval = 100
        let source = StubIdleSource {
            now += 0.05
            return 10.05
        }
        let controller = BlackoutController(idleSource: source, uptime: { now })

        let sample = try controller.idleSample()

        XCTAssertEqual(sample.lastInputUptime, 90, accuracy: 0.000_001)
    }
}

private struct StubIdleSource: IdleTimeSource {
    let read: () -> TimeInterval?

    func secondsSinceLastInput() -> TimeInterval? {
        read()
    }
}
