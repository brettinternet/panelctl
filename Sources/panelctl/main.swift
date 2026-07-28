import Foundation
import PanelCtlCore
import Darwin

@main
struct PanelCtlMain {
    static func main() {
        do {
            let command = try CLIParser.parse(Array(CommandLine.arguments.dropFirst()))
            switch command {
            case .list(let json): try DisplayInventory.printRecords(DisplayInventory.records(), json: json)
            case .probe(let json): try Probe.printReport(Probe.report(), json: json)
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
            case .sleepDisplays(let keepSystemAwake, let timeout):
                let controller = DisplaySleepController()
                try controller.start(keepSystemAwake: keepSystemAwake, timeout: timeout)
                if keepSystemAwake {
                    controller.runUntilTermination()
                    controller.stop()
                }
            case .wakeDisplays:
                try DisplaySleepController.wake()
            case .app(let appCommand, let durationSeconds, let json):
                let client = try AppControlClient()
                let response = try client.execute(
                    appCommand,
                    durationSeconds: durationSeconds
                )
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
                if appCommand == .status, !response.running {
                    Foundation.exit(3)
                }
                if !response.ok {
                    Foundation.exit(EXIT_FAILURE)
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
            controller = BlackoutController { state in
                let line = #"{"state":"\#(state.rawValue)"}"# + "\n"
                FileHandle.standardOutput.write(Data(line.utf8))
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
