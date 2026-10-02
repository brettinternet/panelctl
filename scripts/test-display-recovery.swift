#!/usr/bin/env swift
// Opt-in, no-write integration checks. Run from a logged-in GUI session with
// the freshly built panelctl path as the only argument. Artifacts are retained.
import Foundation
import Darwin

struct TestFailure: Error, CustomStringConvertible {
    let description: String
}
func require(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !value() { throw TestFailure(description: message) }
}

let root = FileManager.default.temporaryDirectory.appendingPathComponent("panelctl-recovery-integration-\(UUID())")
try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                       attributes: [.posixPermissions: 0o700])
try Data("panelctl recovery test artifacts\n".utf8).write(to: root.appendingPathComponent(".panelctl-test-owned"))
print("Recovery test artifacts: \(root.path)")

final class Invocation {
    let process = Process()
    let completed = DispatchSemaphore(value: 0)
    let output: URL
    let handle: FileHandle

    init(executable: URL, args: [String]) throws {
        output = root.appendingPathComponent("process-\(UUID()).log")
        FileManager.default.createFile(atPath: output.path, contents: nil, attributes: [.posixPermissions: 0o600])
        handle = try FileHandle(forWritingTo: output)
        process.executableURL = executable
        process.arguments = args
        process.standardOutput = handle
        process.standardError = handle
        process.terminationHandler = { [completed] _ in completed.signal() }
        try process.run()
    }

    func wait(success: Bool) throws {
        guard completed.wait(timeout: .now() + 10) == .success else {
            process.terminate()
            throw TestFailure(description: "process timed out: \(output.path)")
        }
        try handle.close()
        let log = try String(contentsOf: output, encoding: .utf8)
        try require((process.terminationStatus == 0) == success,
                    "unexpected exit \(process.terminationStatus): \(log)")
    }
}

func load(_ url: URL) throws -> [String: Any] {
    try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
}

// Observe atomic journal replacements without a polling/sleep loop.
func awaitState(_ state: String, at url: URL, trigger: () throws -> Void = {}) throws -> [String: Any] {
    let fd = open(url.deletingLastPathComponent().path, O_EVTONLY | O_CLOEXEC)
    guard fd >= 0 else { throw TestFailure(description: "cannot watch journal directory") }
    let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .write, queue: .global())
    let done = DispatchSemaphore(value: 0)
    let check = {
        if let journal = try? load(url), journal["state"] as? String == state { done.signal() }
    }
    source.setEventHandler(handler: check)
    source.setCancelHandler { close(fd) }
    source.resume()
    defer { source.cancel() }
    try trigger()
    check()
    try require(done.wait(timeout: .now() + 8) == .success, "journal did not reach \(state): \(url.path)")
    return try load(url)
}

func fixture(_ name: String) throws -> URL {
    let directory = root.appendingPathComponent(name)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                           attributes: [.posixPermissions: 0o700])
    return directory.appendingPathComponent("current.json")
}

func run() throws {
    try require(CommandLine.arguments.count == 2, "usage: swift scripts/test-display-recovery.swift <panelctl-binary>")
    let binary = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL
    func command(_ arguments: [String], success: Bool = true) throws {
        try Invocation(executable: binary, args: arguments).wait(success: success)
    }
    let journalURL = try fixture("deadline")
    try command(["recovery", "capture", "--journal", journalURL.path])
    let captured = try load(journalURL)
    try command(["recovery", "capture", "--journal", journalURL.path], success: false)
    try require(try load(journalURL)["id"] as? String == captured["id"] as? String, "unresolved snapshot overwritten")
    try command(["recovery", "verify", "--journal", journalURL.path])
    try command(["recovery", "rehearse", "--timeout", "2s", "--journal", journalURL.path])
    let deadline = try load(journalURL)
    try require(deadline["state"] as? String == "verified", "deadline verification failed")
    try require(deadline["trigger"] as? String == "deadline", "deadline was not the trigger")
    try require(deadline["verifyOnly"] as? Bool == true, "rehearsal enabled a writer")
    print("PASS capture, unresolved protection, verify, deadline")

    let crashURL = try fixture("parent-crash")
    let parent = try Invocation(executable: binary, args: ["recovery", "rehearse", "--timeout", "30s", "--journal", crashURL.path])
    let armed = try awaitState("armed", at: crashURL)
    guard let helperPID = (armed["watchdogPID"] as? NSNumber)?.int32Value else {
        throw TestFailure(description: "armed helper has no PID")
    }
    // Observe exit as well as the journal: the terminal state is persisted
    // before the helper releases its locks and exits.
    let helperExited = DispatchSemaphore(value: 0)
    let exitSource = DispatchSource.makeProcessSource(identifier: helperPID, eventMask: .exit, queue: .global())
    exitSource.setEventHandler { helperExited.signal() }
    exitSource.resume()
    defer { exitSource.cancel() }
    // An unrelated journal must not bypass the process-wide operation lock.
    let otherURL = try fixture("concurrent")
    try command(["recovery", "capture", "--journal", otherURL.path], success: false)
    try command(["recovery", "verify", "--journal", crashURL.path], success: false)
    let recovered = try awaitState("verified", at: crashURL) {
        try require(kill(parent.process.processIdentifier, SIGKILL) == 0, "could not kill owned rehearsal parent")
    }
    try parent.wait(success: false)
    try require(helperExited.wait(timeout: .now() + 5) == .success, "helper did not exit after verification")
    try require(recovered["id"] as? String == armed["id"] as? String, "helper changed snapshot identity")
    try require(recovered["trigger"] as? String == "parent-exit", "parent crash did not trigger verification")
    print("PASS independent helper survives parent SIGKILL; concurrent operations blocked")

    let helperDeathURL = try fixture("helper-death")
    let orphan = try Invocation(executable: binary, args: ["recovery", "rehearse", "--timeout", "30s", "--journal", helperDeathURL.path])
    let beforeDeath = try awaitState("armed", at: helperDeathURL)
    guard let doomedPID = (beforeDeath["watchdogPID"] as? NSNumber)?.int32Value else {
        throw TestFailure(description: "owned rehearsal helper has no PID")
    }
    try require(kill(doomedPID, SIGKILL) == 0, "could not stop owned no-write helper")
    try orphan.wait(success: false)
    try require(try load(helperDeathURL)["state"] as? String == "armed", "dead helper falsely reported success")
    try command(["recovery", "capture", "--journal", helperDeathURL.path], success: false)
    try command(["recovery", "verify", "--journal", helperDeathURL.path])
    print("PASS helper SIGKILL retains unresolved evidence for manual verification")

    let invalidURL = try fixture("invalid-boot")
    try command(["recovery", "capture", "--journal", invalidURL.path])
    var invalid = try load(invalidURL)
    var snapshot = invalid["snapshot"] as! [String: Any]
    snapshot["bootSession"] = "intentionally-invalid-test-boot"
    invalid["snapshot"] = snapshot
    try JSONSerialization.data(withJSONObject: invalid).write(to: invalidURL)
    try command(["recovery", "verify", "--journal", invalidURL.path], success: false)
    try require(try load(invalidURL)["state"] as? String == "needsAttention", "identity failure not retained")
    try command(["recovery", "capture", "--journal", invalidURL.path], success: false)
    print("PASS stale-boot rejection retains unresolved journal")

    // The entire script intentionally never invokes recovery restore or guard.
    print("All recovery integration checks passed; no display writes requested.")
}

do { try run() }
catch {
    fputs("FAIL: \(error)\nArtifacts: \(root.path)\n", stderr)
    exit(1)
}
