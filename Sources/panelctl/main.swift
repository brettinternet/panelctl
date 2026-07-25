import Foundation
import PanelCtlCore

@main
struct PanelCtlMain {
    static func main() {
        do {
            let command = try CLIParser.parse(Array(CommandLine.arguments.dropFirst()))
            switch command {
            case .list(let json): try DisplayInventory.printRecords(DisplayInventory.records(), json: json)
            case .probe(let json): try Probe.printReport(Probe.report(), json: json)
            case .blackout(let options):
                let controller = BlackoutController()
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

    private static func printJSON<T: Encodable>(_ value: T) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        FileHandle.standardOutput.write(try encoder.encode(value))
        print()
    }
}
