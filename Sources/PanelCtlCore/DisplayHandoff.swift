import Foundation

/// Optional monitor input selection around journal-backed public mirroring.
public enum DisplayHandoff {
    public static func run(selector: String, source: String?, input: UInt8?, journalPath: String?) throws {
        let store = RecoveryStore(url: journalPath.map { URL(fileURLWithPath: $0) } ?? RecoveryStore.defaultURL)
        let controller = HandoffController()
        if let source {
            try controller.away(selector: selector, source: source, input: input, store: store)
        } else {
            try controller.back(selector: selector, input: input, store: store)
        }
    }
}

struct HandoffController {
    var mirror = MirrorController()
    var open: (String) throws -> (display: DDC.DisplayTarget, channel: DDCChannel) = { try DDC.open(selector: $0) }
    var select: (UInt8, DDCChannel, UInt32, String, UInt8) throws -> DDCInputSelection = {
        try DDCInput.select($0, channel: $1, displayID: $2, uuid: $3, original: $4)
    }
    var report: (String) -> Void = { print($0) }

    func away(selector: String, source: String, input: UInt8?, store: RecoveryStore) throws {
        var inputRecovery: String?
        do {
            let journal = try mirror.mirror(selector: selector, source: source, store: store) { target in
                try switchInput(input, target: target) { inputRecovery = $0 }
            }
            report("Away: separate desktop hidden by mirroring; Mac signal remains on. Journal: \(store.url.path)")
            let target = journal.snapshot.displays.first { $0.id == journal.mirrorTargetID }!
            report("Return with: panelctl back --display \(shellQuote(target.uuid)) --consent-back --journal \(shellQuote(store.url.path))")
            report("Add --input <Mac-input> only if DDC switching back is wanted; otherwise use the monitor's input button.")
        } catch {
            throw RecoveryError.unsafe("\(error)\(inputRecovery.map { ". Input recovery: \($0)" } ?? "")")
        }
    }

    func back(selector: String, input: UInt8?, store: RecoveryStore) throws {
        // No DDC open/read/write can prevent the topology restoration.
        _ = try mirror.unmirror(store: store, selector: selector) { target in
            report("Back: captured topology restored and verified. Journal: \(store.url.path)")
            try switchInput(input, target: target) { report("Input recovery: \($0)") }
        }
    }

    private func switchInput(_ input: UInt8?, target: RecoveryDisplay,
                             recovery: (String) -> Void) throws {
        guard let input else {
            report("DDC skipped (no --input configured); use the monitor's input button.")
            return
        }
        let session: (display: DDC.DisplayTarget, channel: DDCChannel)
        let original: UInt8
        do {
            session = try open(target.uuid)
            guard session.display.id == target.id,
                  session.display.uuid.lowercased() == target.uuid.lowercased() else {
                throw RecoveryError.unsafe("DDC target changed since journal capture")
            }
            original = try DDCInput.current(session.channel)
            guard original != 0 else { throw RecoveryError.unsafe("DDC returned unknown input 0") }
        } catch {
            report("DDC skipped (\(error)); use the monitor's input button.")
            return
        }
        let command = "panelctl ddc-input --display \(shellQuote(target.uuid)) --set \(original), or use the monitor's input button"
        recovery(command)
        // Print before attempting a write, including when readback becomes unavailable.
        report("To reverse input selection: \(command)")
        do {
            let result = try select(input, session.channel, target.id, target.uuid, original)
            report("DDC input outcome=\(result.outcome.rawValue)\(result.detail.map { ": \($0)" } ?? "")")
            if result.outcome == .unverified {
                report("Input switch is unverified; check visually and use the monitor's input button if needed.")
            }
        } catch {
            throw RecoveryError.unsafe("DDC selection failed: \(error). Input recovery: \(command)")
        }
    }

    private func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
