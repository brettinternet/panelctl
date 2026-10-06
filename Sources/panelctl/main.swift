import Foundation
import PanelCtlCore
import Darwin

@main
struct PanelCtlMain {
    static func main() {
        do {
            if ProcessInfo.processInfo.environment["PANELCTL_CLEANUP_ONLY"] == "1" {
                let succeeded = BlackoutController.retryBrightnessCleanup()
                let status = BlackoutRuntimeStatus(
                    state: .stopped, blackedOutDisplayIDs: [], cleanupSucceeded: succeeded
                )
                FileHandle.standardOutput.write(try JSONEncoder().encode(status))
                FileHandle.standardOutput.write(Data([0x0A]))
                Foundation.exit(succeeded ? 0 : EXIT_FAILURE)
            }
            let command = try CLIParser.parse(Array(CommandLine.arguments.dropFirst()))
            switch command {
            case .list(let json): try DisplayInventory.printRecords(DisplayInventory.records(), json: json)
            case .probe(let json): try Probe.printReport(Probe.report(), json: json)
            case .mirror(let selector, let source, let journalPath):
                try DisplayMirroring.mirror(selector: selector, source: source, journalPath: journalPath)
            case .unmirror(let journalPath):
                try DisplayMirroring.unmirror(journalPath: journalPath)
            case .unmirrorTarget(let selector, let journalPath):
                try DisplayMirroring.unmirror(selector: selector, journalPath: journalPath)
            case .away(let selector, let source, let input, let journalPath):
                try DisplayHandoff.run(selector: selector, source: source, input: input, journalPath: journalPath)
            case .back(let selector, let input, let journalPath):
                try DisplayHandoff.run(selector: selector, source: nil, input: input, journalPath: journalPath)
            case .recovery(let action, let timeout, let journalPath):
                guard let executable = Bundle.main.executableURL else {
                    throw RecoveryError.unsafe("cannot locate watchdog executable")
                }
                try DisplayRecovery.run(action: action, timeout: timeout, journalPath: journalPath, executable: executable)
            case .recoverySelected(let action, let timeout, let selector, let journalPath):
                guard let executable = Bundle.main.executableURL else {
                    throw RecoveryError.unsafe("cannot locate watchdog executable")
                }
                try DisplayRecovery.run(action: action, timeout: timeout, journalPath: journalPath,
                                       displaySelector: selector, executable: executable)
            case .recoveryDisable(let selector, let timeout, let journalPath):
                guard let executable = Bundle.main.executableURL else {
                    throw RecoveryError.unsafe("cannot locate watchdog executable")
                }
                try DisplayRecovery.disable(selector: selector, timeout: timeout, journalPath: journalPath, executable: executable)
            case .recoveryHelper(let journalPath, let id):
                try DisplayRecovery.runHelper(journalPath: journalPath, id: id)
            case .blackout(let options):
                let controller = blackoutController()
                try controller.run(options: options)
            case .ddcLuminance(let selector, let setValue, let json):
                if let setValue {
                    let result = try DDCLuminance.set(selector: selector, value: setValue)
                    if json {
                        try printJSON(result)
                    } else {
                        print("id=\(result.displayID) uuid=\(result.uuid) original=\(result.original)/\(result.maximum) requested=\(result.requested) observed=\(result.observed)")
                    }
                } else {
                    let reading = try DDCLuminance.read(selector: selector)
                    if json {
                        try printJSON(reading)
                    } else {
                        print("id=\(reading.displayID) uuid=\(reading.uuid) luminance=\(reading.current)/\(reading.maximum)")
                    }
                }
            case .ddcInput(let selector, let setValue, let json):
                if let setValue {
                    let result = try DDCInput.set(selector: selector, value: setValue)
                    if json {
                        try printJSON(result)
                    } else {
                        var line = String(format: "id=%u uuid=%@ original=0x%02X requested=0x%02X", result.displayID, result.uuid, result.original, result.requested)
                        if let observed = result.observed { line += String(format: " observed=0x%02X", observed) }
                        line += " outcome=\(result.outcome.rawValue)"
                        if let detail = result.detail { line += " detail=\(quoted(detail))" }
                        print(line)
                    }
                } else {
                    let reading = try DDCInput.read(selector: selector)
                    if json {
                        try printJSON(reading)
                    } else {
                        print(String(format: "id=%u uuid=%@ input=0x%02X", reading.displayID, reading.uuid, reading.current))
                    }
                }
            case .ddcPower(let selector, let value, let acceptedRisk, let json):
                let result = try DDCPower.run(selector: selector, value: value, acceptedRisk: acceptedRisk)
                if json {
                    try printJSON(result)
                } else {
                    var line = String(format: "id=%u uuid=%@ original=0x%02X", result.displayID, result.uuid, result.original)
                    if let requested = result.requested { line += " requested=\(requested.rawValue)" }
                    if let observed = result.observed { line += String(format: " observed=0x%02X", observed) }
                    line += " outcome=\(result.outcome.rawValue) detail=\(quoted(result.detail))"
                    print(line)
                }
            case .sleepDisplays(let keepSystemAwake, let timeout):
                let controller = DisplaySleepController()
                try controller.start(keepSystemAwake: keepSystemAwake, timeout: timeout)
                if keepSystemAwake {
                    controller.runUntilTermination()
                    controller.stop()
                }
            case .wakeDisplays:
                try DisplaySleepController.wake()
            case .app(let appCommand, let durationSeconds, let targetUUID, let json):
                let client = try AppControlClient()
                let response: AppControlResponse
                do {
                    response = try client.execute(
                        appCommand,
                        durationSeconds: durationSeconds,
                        targetUUID: targetUUID
                    )
                } catch {
                    guard appCommand.isDisplayCommand else { throw error }
                    // A transport failure does not prove whether the request was received.
                    response = AppControlResponse(
                        ok: false, running: true, enabled: false, state: "unknown",
                        summary: "App control result unavailable; inspect status before retrying.",
                        error: error.localizedDescription, outcome: .responseLost
                    )
                }
                if json {
                    try printJSON(response)
                } else if !response.ok, appCommand != .status {
                    fputs(
                        "panelctl: \(response.error ?? response.summary)\n",
                        stderr
                    )
                } else {
                    var line = "running=\(response.running) enabled=\(response.enabled) state=\(response.state) summary=\(quoted(response.summary))"
                    if let detail = response.detail, !detail.isEmpty {
                        line += " detail=\(quoted(detail))"
                    }
                    if let nextAction = response.nextAction {
                        line += " nextAction=\(quoted(nextAction))"
                    }
                    if let secondsRemaining = response.secondsRemaining {
                        line += " secondsRemaining=\(secondsRemaining)"
                    }
                    if let snoozedUntil = response.snoozedUntil {
                        line += " snoozedUntil=\(quoted(snoozedUntil))"
                    }
                    print(line)
                }
                if response.exitCode != 0 {
                    Foundation.exit(response.exitCode)
                }
            case .help(let command):
                print(CLIHelp.text(for: command))
            case .version:
                print(CLIHelp.version)
            }
        } catch let error as CLIParseError {
            fputs("panelctl: \(error)\n", stderr)
            fputs("Try 'panelctl help' for usage.\n", stderr)
            Foundation.exit(2)
        } catch {
            fputs("panelctl: \(error)\n", stderr)
            Foundation.exit(EXIT_FAILURE)
        }
    }

    private static func blackoutController() -> BlackoutController {
        let controller: BlackoutController
        if ProcessInfo.processInfo.environment["PANELCTL_EMIT_STATUS"] == "1" {
            controller = BlackoutController { status in
                guard let data = try? JSONEncoder().encode(status) else { return }
                FileHandle.standardOutput.write(data)
                FileHandle.standardOutput.write(Data([0x0A]))
            }
        } else {
            controller = BlackoutController()
        }
        if ProcessInfo.processInfo.environment["PANELCTL_PARENT_PIPE"] == "1" {
            monitorParentPipe(controller)
        }
        return controller
    }

    private static func monitorParentPipe(_ controller: BlackoutController) {
        DispatchQueue.global(qos: .utility).async {
            var pending = Data()
            var buffer = [UInt8](repeating: 0, count: 256)
            while true {
                let count = buffer.withUnsafeMutableBytes {
                    Darwin.read(STDIN_FILENO, $0.baseAddress, $0.count)
                }
                if count > 0 {
                    pending.append(contentsOf: buffer.prefix(count))
                    while let newline = pending.firstIndex(of: 0x0A) {
                        let line = Data(pending[..<newline])
                        pending.removeSubrange(...newline)
                        guard let value = String(data: line, encoding: .utf8),
                              let command = BlackoutControlCommand(
                                rawValue: value
                              ) else {
                            continue
                        }
                        DispatchQueue.main.async {
                            controller.handleControl(command)
                        }
                    }
                    if pending.count <= 1024 { continue }
                }
                if count < 0, errno == EINTR { continue }
                DispatchQueue.main.async {
                    controller.stop()
                }
                return
            }
        }
    }

    private static func printJSON<T: Encodable>(_ value: T) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        FileHandle.standardOutput.write(try encoder.encode(value))
        print()
    }

    private static func quoted(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
}
