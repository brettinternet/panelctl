import Foundation
import CoreGraphics
import Darwin
import MachO

/// TASK-1's canonical C ABI. Never import the private symbol at link time.
typealias ConfigureDisplayEnabled = @convention(c)
    (CGDisplayConfigRef, CGDirectDisplayID, Bool) -> CGError

/// Explicitly resolved, internal capability; not installed in RecoveryEngine.
/// Holding this object keeps the selected library alive through staging.
final class RecoveryDisplayBinding {
    static let coreGraphics = "/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics"
    static let skyLight = "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight"
    static let coreGraphicsUUID = "B0FB9AC2-E3CC-31C2-A90E-0D38A776BAE2"
    static let skyLightUUID = "8A3B348E-4637-3685-92D0-6CBC2F36A234"

    // Closure seams permit resolution tests without loading or calling private APIs.
    struct Loader {
        var open: (String) -> UnsafeMutableRawPointer?
        var symbol: (UnsafeMutableRawPointer, String) -> UnsafeMutableRawPointer?
        var imageUUID: (String) -> String?
        var symbolImage: (UnsafeMutableRawPointer) -> String?
        var close: (UnsafeMutableRawPointer) -> Void

        static var dynamic: Self {
            Self(open: { dlopen($0, RTLD_LAZY | RTLD_LOCAL | RTLD_FIRST) },
                 symbol: { dlsym($0, $1) }, imageUUID: loadedImageUUID,
                 symbolImage: { pointer in
                     var info = Dl_info()
                     guard dladdr(pointer, &info) != 0, let name = info.dli_fname else { return nil }
                     return String(cString: name)
                 }, close: { _ = dlclose($0) })
        }
    }

    private let handle: UnsafeMutableRawPointer
    private let loader: Loader
    private let setter: ConfigureDisplayEnabled

    private init(handle: UnsafeMutableRawPointer, pointer: UnsafeMutableRawPointer, loader: Loader) {
        self.handle = handle; self.loader = loader
        setter = unsafeBitCast(pointer, to: ConfigureDisplayEnabled.self)
    }
    deinit { loader.close(handle) }

    /// Read-only resolution, not a consent or identity gate. Not called at startup.
    static func resolve() throws -> RecoveryDisplayBinding {
        #if arch(arm64)
        let architecture = "arm64"
        #else
        let architecture = "unsupported"
        #endif
        return try resolve(architecture: architecture, osBuild: systemString("kern.osversion"), loader: .dynamic)
    }

    /// Explicit evidence and loader injection is reserved for offline tests.
    static func resolve(architecture: String, osBuild: String, loader: Loader) throws -> RecoveryDisplayBinding {
        guard architecture == "arm64" else {
            throw RecoveryError.unsafe("private display backend unavailable: unsupported architecture \(architecture)")
        }
        guard osBuild == "26A434" else {
            throw RecoveryError.unsafe("private display backend unavailable: unverified ABI for OS build \(osBuild)")
        }
        var failures: [String] = []
        for (path, name, uuid) in [(coreGraphics, "CGSConfigureDisplayEnabled", coreGraphicsUUID),
                                   (skyLight, "SLSConfigureDisplayEnabled", skyLightUUID)] {
            guard let handle = loader.open(path) else {
                failures.append("missing framework \(path)"); continue
            }
            var retained = false
            defer { if !retained { loader.close(handle) } }
            guard let pointer = loader.symbol(handle, name) else {
                failures.append("missing symbol \(name)"); continue
            }
            // Both names must lead to the inspected SkyLight implementation.
            // A present but unqualified preferred image is not a fallback signal.
            guard loader.imageUUID(path) == uuid,
                  loader.symbolImage(pointer) == skyLight,
                  loader.imageUUID(skyLight) == skyLightUUID else {
                throw RecoveryError.unsafe("private display backend unavailable: unverified ABI image for \(name)")
            }
            let result = RecoveryDisplayBinding(handle: handle, pointer: pointer, loader: loader)
            retained = true
            return result
        }
        throw RecoveryError.unsafe("private display backend unavailable: " + failures.joined(separator: "; "))
    }

    /// Construction does not begin a transaction. Defaults remain disconnected
    /// from all CLI/app paths until journal, eligibility and consent gates exist.
    func transaction() -> RecoveryEnableTransaction {
        RecoveryEnableTransaction(begin: {
            var config: CGDisplayConfigRef?
            try Self.check(CGBeginDisplayConfiguration(&config), "begin")
            guard let config else { throw RecoveryError.unsafe("begin returned no display configuration") }
            return config
        }, setEnabled: { [self] config, id, enabled in
            try Self.check(setter(config, id, enabled), "stage enabled=\(enabled)")
        }, commit: { config, scope in
            try Self.check(CGCompleteDisplayConfiguration(config, scope), "complete")
        }, cancel: { _ = CGCancelDisplayConfiguration($0) })
    }

    private static func check(_ error: CGError, _ operation: String) throws {
        guard error == .success else {
            throw RecoveryError.unsafe("private display \(operation) failed (CGError \(error.rawValue))")
        }
    }
}

/// Read only the UUID load command of an already-loaded system image. No file
/// extraction or private API invocation. Unknown formats fail closed.
private func loadedImageUUID(_ path: String) -> String? {
    for index in 0..<_dyld_image_count() {
        guard let name = _dyld_get_image_name(index), String(cString: name) == path,
              let header = _dyld_get_image_header(index), header.pointee.magic == MH_MAGIC_64 else { continue }
        let raw = UnsafeRawPointer(header)
        let header64 = raw.load(as: mach_header_64.self)
        var offset = MemoryLayout<mach_header_64>.size
        let end = offset + Int(header64.sizeofcmds)
        for _ in 0..<header64.ncmds {
            guard offset + MemoryLayout<load_command>.size <= end else { return nil }
            let command = raw.advanced(by: offset).load(as: load_command.self)
            let size = Int(command.cmdsize)
            guard size >= MemoryLayout<load_command>.size, offset + size <= end else { return nil }
            if command.cmd == LC_UUID {
                guard size >= MemoryLayout<uuid_command>.size else { return nil }
                return UUID(uuid: raw.advanced(by: offset).load(as: uuid_command.self).uuid).uuidString
            }
            offset += size
        }
    }
    return nil
}
