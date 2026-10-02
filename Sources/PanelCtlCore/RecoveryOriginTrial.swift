import Foundation
import CoreGraphics

/// Test-only journal payload. No CLI command creates this payload.
struct RecoveryOriginTrial: Codable {
    let uuid: String
    let x: Int32
    let y: Int32

    func target(in snapshot: RecoverySnapshot) throws -> RecoverySnapshot {
        guard let display = snapshot.displays.first(where: { $0.uuid == uuid }),
              !display.main, !display.builtin, display.active,
              snapshot.displays.allSatisfy({ $0.mirrorUUID == nil && $0.active }),
              snapshot.displays.contains(where: { $0.main && $0.active }),
              display.connector?.isEmpty == false,
              x == display.x, Int64(y) == Int64(display.y) + 16,
              !(x == 0 && y == 0) else {
            throw RecoveryError.unsafe("origin trial requires one active non-main external target, no mirrors, and a 16-point downward move")
        }
        // Preserve every field except the selected origin.
        var displays = snapshot.displays
        let index = displays.firstIndex { $0.uuid == uuid }!
        displays[index].x = x; displays[index].y = y
        return RecoverySnapshot(bootSession: snapshot.bootSession, osBuild: snapshot.osBuild,
                                userID: snapshot.userID, displays: displays)
    }

    func apply(snapshot: RecoverySnapshot) throws {
        _ = try target(in: snapshot)
        try snapshot.verify(.capture())
        let display = snapshot.displays.first { $0.uuid == uuid }!
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success, let config else {
            throw RecoveryError.unsafe("cannot begin origin trial")
        }
        var completed = false
        defer { if !completed { CGCancelDisplayConfiguration(config) } }
        guard CGConfigureDisplayOrigin(config, display.id, x, y) == .success else {
            throw RecoveryError.unsafe("cannot stage trial origin")
        }
        try snapshot.verify(.capture())
        let result = CGCompleteDisplayConfiguration(config, .forSession)
        completed = true
        guard result == .success else { throw RecoveryError.unsafe("origin trial commit failed: \(result.rawValue)") }
        try target(in: snapshot).verify(.capture())
    }
}
