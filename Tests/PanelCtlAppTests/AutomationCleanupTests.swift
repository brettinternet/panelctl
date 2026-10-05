import XCTest
@testable import PanelCtlApp

@MainActor
final class AutomationCleanupTests: XCTestCase {
    func testSixPostShowRestartsAndPreStatusExitDoNotLatchFalseCleanupFailure() async throws {
        try await withHelper("""
        #!/bin/bash
        trap 'exit 0' TERM
        printf '{"state":"waiting","blackedOutDisplayIDs":[]}\\n'
        while kill -0 "$PPID" 2>/dev/null; do /bin/sleep 0.02; done
        """) {
            let service = ProtectionService(cleanupIsVerified: { true })
            service.run(arguments: ["blackout"])
            for _ in 0..<6 {
                try await wait { service.state == .waiting }
                service.run(arguments: ["blackout"], restartForDisplayChange: true)
            }
            try await wait { service.state == .waiting }
            var stopped: Bool?
            service.disableForDisplayHide { stopped = $0; XCTAssertNil($1) }
            try await wait { stopped != nil }
            XCTAssertEqual(stopped, true)
            XCTAssertNil(service.unresolvedCleanupFailure)
            // Terminate immediately, before the helper can install a signal
            // handler or report anything. Empty locked journal is the proof.
            service.run(arguments: ["blackout"])
            stopped = nil
            service.disableForDisplayHide { stopped = $0; XCTAssertNil($1) }
            try await wait { stopped != nil }
            XCTAssertEqual(stopped, true)
        }
    }

    func testUnverifiedEarlyExitBlocksAndCleanOrdinaryStopCannotClearIt() async throws {
        try await withHelper("""
        #!/bin/bash
        trap 'printf "{\\"state\\":\\"stopped\\",\\"blackedOutDisplayIDs\\":[],\\"cleanupSucceeded\\":true}\\n"; exit 0' TERM
        printf '{"state":"waiting","blackedOutDisplayIDs":[]}\\n'
        while kill -0 "$PPID" 2>/dev/null; do /bin/sleep 0.02; done
        """) {
            var verified = true
            let service = ProtectionService(cleanupIsVerified: { verified })
            service.run(arguments: ["blackout"])
            verified = false
            var stopped: Bool?
            service.disableForDisplayHide { succeeded, _ in stopped = succeeded }
            try await wait { stopped != nil }
            XCTAssertEqual(stopped, false)
            XCTAssertNotNil(service.unresolvedCleanupFailure)
            verified = true
            service.run(arguments: ["blackout"])
            try await wait { service.state == .waiting }
            stopped = nil
            service.disableForDisplayHide { succeeded, _ in stopped = succeeded }
            try await wait { stopped != nil }
            XCTAssertEqual(stopped, false, "only explicit cleanup retry clears a previous failure")
        }
    }

    func testCleanupRetryRequiresBothReportAndCleanExit() async throws {
        for script in [
            "#!/bin/bash\nexit 0\n",
            "#!/bin/bash\nprintf '{\"state\":\"stopped\",\"blackedOutDisplayIDs\":[],\"cleanupSucceeded\":true}\\n'\nexit 1\n"
        ] {
            try await withHelper(script) {
                let service = ProtectionService(initialCleanupFailure: "restore failed", cleanupIsVerified: { true })
                var result: Bool?
                service.retryCleanup { result = $0; XCTAssertEqual($1, "restore failed") }
                try await wait { result != nil }
                XCTAssertEqual(result, false)
                XCTAssertEqual(service.unresolvedCleanupFailure, "restore failed")
            }
        }
    }

    func testShutdownDuringRetryDoesNotLaunchAnotherHelper() async throws {
        try await withHelper("""
        #!/bin/bash
        if [[ "$PANELCTL_CLEANUP_ONLY" == "1" ]]; then
            /bin/sleep 0.2
            printf '{"state":"stopped","blackedOutDisplayIDs":[],"cleanupSucceeded":true}\\n'
            exit 0
        fi
        trap '/bin/sleep 0.1; exit 0' TERM
        printf '{"state":"waiting","blackedOutDisplayIDs":[]}\\n'
        while kill -0 "$PPID" 2>/dev/null; do /bin/sleep 0.02; done
        """) {
            let service = ProtectionService(cleanupIsVerified: { true })
            service.run(arguments: ["blackout"])
            try await wait { service.state == .waiting }
            var retried: Bool?
            service.retryCleanup { succeeded, _ in retried = succeeded }
            var shutdown = false
            service.shutdown {
                XCTAssertFalse(service.hasManagedProcess, "shutdown cannot leave a cleanup writer running")
                shutdown = true
            }
            try await wait { shutdown && retried != nil }
            XCTAssertEqual(retried, false, "shutdown cancels the queued retry")
            try await wait { !service.hasManagedProcess }
        }
    }

    func testSuccessfulCleanupCallbackCannotRestartWatcherDuringShutdown() async throws {
        try await withHelper("""
        #!/bin/bash
        trap 'exit 0' TERM
        printf '{"state":"stopped","blackedOutDisplayIDs":[],"cleanupSucceeded":true}\\n'
        /bin/sleep 0.2
        """) {
            let service = ProtectionService(initialCleanupFailure: "restore failed", cleanupIsVerified: { true })
            var shutdownRequested = false
            var shutdownFinished = false
            var retried: Bool?
            service.onStateChange = { state in
                if state == .stopping && !shutdownRequested {
                    shutdownRequested = true
                    service.shutdown {
                        XCTAssertFalse(service.hasManagedProcess)
                        shutdownFinished = true
                    }
                }
            }
            service.retryCleanup { succeeded, _ in
                retried = succeeded
                // The model normally rearms enabled automation on success.
                service.run(arguments: ["blackout"])
                XCTAssertFalse(service.hasManagedProcess)
            }
            try await wait { shutdownFinished }
            XCTAssertEqual(retried, true)
            XCTAssertFalse(service.hasManagedProcess)
        }
    }

    func testQuiescenceDuringCleanupRetrySharesItsResultWithoutCancellingIt() async throws {
        try await withHelper("""
        #!/bin/bash
        /bin/sleep 0.1
        printf '{"state":"stopped","blackedOutDisplayIDs":[],"cleanupSucceeded":true}\\n'
        """) {
            let service = ProtectionService(initialCleanupFailure: "restore failed", cleanupIsVerified: { true })
            var retried: Bool?
            var stopped: Bool?
            service.retryCleanup { succeeded, _ in retried = succeeded }
            service.disableForDisplayHide { succeeded, _ in stopped = succeeded }
            try await wait { retried != nil && stopped != nil }
            XCTAssertEqual(retried, true)
            XCTAssertEqual(stopped, true, "external recovery quiescence must not get stranded")
            XCTAssertFalse(service.hasManagedProcess)
        }
    }

    private func withHelper(_ script: String, body: () async throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("panelctl-cleanup-helper-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let helper = directory.appendingPathComponent("fake-panelctl")
        try Data(script.utf8).write(to: helper)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)
        setenv("PANELCTL_HELPER", helper.path, 1)
        defer { unsetenv("PANELCTL_HELPER") }
        try await body()
    }

    private func wait(_ predicate: () -> Bool) async throws {
        for _ in 0..<200 {
            if predicate() { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("Timed out waiting for fake cleanup helper")
    }
}
