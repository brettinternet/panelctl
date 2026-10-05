import CoreGraphics
import Foundation
import Darwin

/// A read-only, build-scoped inventory, not a persistent qualification or write authority.
/// Unused native framebuffer slots are expected; extra CG mappings/services are not.
enum RecoveryDriverInventory {
    static let owner = "com.apple.driver.AppleMobileDispT605X-DCP"

    struct Framebuffer: Equatable {
        var registryID: UInt64
        var path: String
        var index: UInt32
        var bundle: String
        var kernelBundle: String
        var publisher: String
    }

    struct Evidence {
        var host: String? = RecoveryIdentityPolicy.supportedHostModel
        var architecture = "arm64"
        var build = RecoveryIdentityPolicy.supportedOSBuild
        var onlineIDs: [UInt32]
        var paths: [UInt32: String]
        var framebuffers: [Framebuffer]
        var serviceLabels: [String]
        var loadedKexts: [String]
        var systemExtensions: String
    }

    struct Observation {
        let drivers: RecoveryEligibilityEnvironment.Drivers
        let diagnostic: String
    }

    static func evaluate(_ evidence: Evidence) -> Observation {
        func refuse(_ reason: String) -> Observation { .init(drivers: .unknown, diagnostic: reason) }
        guard evidence.host == RecoveryIdentityPolicy.supportedHostModel,
              evidence.architecture == "arm64", evidence.build == RecoveryIdentityPolicy.supportedOSBuild else {
            return refuse("driver inventory is outside Mac17,14/arm64/26A434 qualification")
        }
        let labels = (evidence.serviceLabels + evidence.loadedKexts + [evidence.systemExtensions])
            .joined(separator: " ").lowercased()
        if labels.contains("displaylink") {
            return .init(drivers: .displayLink, diagnostic: "inventory contains DisplayLink")
        }
        if ["virtualdisplay", "airplaydisplay", "sidecardisplay", "duetdisplay"].contains(where: labels.contains) {
            return .init(drivers: .virtual, diagnostic: "inventory contains a recognized virtual-display provider")
        }
        let frames = evidence.framebuffers
        // This host has five native DCP slots, including an unused slot. Do not
        // infer online/offline state from a slot's cached DisplayAttributes.
        guard frames.count == 5, Set(frames.map(\.index)) == Set(UInt32(0)...4),
              Set(frames.map(\.registryID)).count == frames.count,
              Set(frames.map(\.path)).count == frames.count,
              frames.allSatisfy({ $0.registryID != 0 && $0.path.hasPrefix("IOService:/") &&
                  $0.bundle == owner && $0.kernelBundle == owner && $0.publisher == owner }) else {
            return refuse("incomplete, duplicate, extra or non-qualified Apple framebuffer inventory")
        }
        let ids = Set(evidence.onlineIDs)
        guard !ids.isEmpty, !ids.contains(0), ids.count == evidence.onlineIDs.count,
              Set(evidence.paths.keys) == ids,
              Set(evidence.paths.values).count == ids.count,
              evidence.paths.values.allSatisfy({ path in frames.filter { $0.path == path }.count == 1 }) else {
            return refuse("online CG displays do not map one-to-one to qualified Apple framebuffer services")
        }
        guard !evidence.loadedKexts.isEmpty,
              Set(evidence.loadedKexts).count == evidence.loadedKexts.count,
              evidence.loadedKexts.contains(owner), evidence.loadedKexts.contains("com.apple.kpi.iokit"),
              evidence.loadedKexts.allSatisfy({ $0.hasPrefix("com.apple.") }) else {
            return refuse("loaded kernel extension inventory is incomplete or contains non-Apple extensions")
        }
        // Only the observed zero-extension format is qualified. Even unrelated
        // or inactive extensions refuse rather than guessing their capabilities.
        guard evidence.systemExtensions.trimmingCharacters(in: .whitespacesAndNewlines) == "0 extension(s)" else {
            return refuse("system extension inventory is nonempty, unreadable or unrecognized")
        }
        return .init(drivers: .nativeOnly,
            diagnostic: "\(ids.count) online CG displays uniquely mapped to 5 Apple DCP framebuffer slots; \(evidence.loadedKexts.count) Apple loaded kexts; 0 system extensions; Mac17,14/arm64/26A434")
    }

    /// Consume every row, not just recognized names; malformed/partial output
    /// never becomes an empty (and therefore clean) inventory.
    static func parseLoadedKexts(_ output: String) throws -> [String] {
        let pattern = #"^\s*([0-9]+)\s+[0-9]+\s+0(?:x[0-9a-fA-F]+)?\s+0(?:x[0-9a-fA-F]+)?\s+0(?:x[0-9a-fA-F]+)?\s+([A-Za-z0-9_.-]+)\s+\([^\s()]+\)\s+[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}\s+<[0-9 ]*>\s*$"#
        let regex = try NSRegularExpression(pattern: pattern)
        var identifiers: [String] = [], tags = Set<String>()
        for line in output.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.trimmingCharacters(in: .whitespaces).isEmpty { continue }
            let text = String(line), range = NSRange(text.startIndex..., in: text)
            guard let match = regex.firstMatch(in: text, range: range),
                  let tag = Range(match.range(at: 1), in: text),
                  let identifier = Range(match.range(at: 2), in: text),
                  tags.insert(String(text[tag])).inserted else {
                throw RecoveryError.unsafe("unrecognized or duplicate loaded-kext inventory row")
            }
            identifiers.append(String(text[identifier]))
        }
        guard !identifiers.isEmpty else { throw RecoveryError.unsafe("empty loaded-kext inventory") }
        return identifiers
    }

    /// Fixed read-only commands only. Bound execution and output; never run a
    /// shell, prompt for authorization, or let a full pipe stall a recovery lease.
    static func command(_ executable: String, arguments: [String]) throws -> String {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("panelctl-driver-inventory-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appendingPathComponent("stdout"), errors = directory.appendingPathComponent("stderr")
        guard FileManager.default.createFile(atPath: output.path, contents: nil, attributes: [.posixPermissions: 0o600]),
              FileManager.default.createFile(atPath: errors.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw RecoveryError.unsafe("cannot allocate driver inventory output")
        }
        let stdout = try FileHandle(forWritingTo: output), stderr = try FileHandle(forWritingTo: errors)
        defer { try? stdout.close(); try? stderr.close() }
        let process = Process(), exited = DispatchSemaphore(value: 0)
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = ["LC_ALL": "C", "LANG": "C", "PATH": "/usr/bin:/usr/sbin:/bin:/sbin"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdout; process.standardError = stderr
        process.terminationHandler = { _ in exited.signal() }
        try process.run()
        guard exited.wait(timeout: .now() + 2) == .success else {
            kill(process.processIdentifier, SIGKILL)
            throw RecoveryError.unsafe("driver inventory command timed out")
        }
        guard process.terminationReason == .exit, process.terminationStatus == 0,
              (try errors.resourceValues(forKeys: [.fileSizeKey]).fileSize) == 0,
              let size = try output.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 1_048_576,
              let text = String(data: try Data(contentsOf: output), encoding: .utf8) else {
            throw RecoveryError.unsafe("driver inventory command failed or returned incomplete output")
        }
        return text
    }
}
