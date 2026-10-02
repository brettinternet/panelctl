import Foundation
import AppKit
import CoreGraphics
import IOKit

/// Explicit research command, not part of recovery/guard or app startup.
public enum IdentityObservation {
    public static func run() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("panelctl-identity-observation-\(UUID())")
        let recording = try IdentityObservationRecording(root: root)
        print("Private identity evidence: \(root.path)"); fflush(stdout)
        let operation = RecoveryStore.operationLock()
        var observer: IdentityLifetimeCollector?
        do {
            try operation.lock()
            defer { operation.unlock() }
            let context = try IdentityObservationInventory.context()
            recording.append("context", context)
            let baseline = try RecoverySnapshot.capture()
            let store = RecoveryStore(url: root.appendingPathComponent("baseline.json"))
            try store.lock(); defer { store.unlock() }
            try store.create(RecoveryJournal(snapshot: baseline, verifyOnly: true))
            // Fresh evidence only: this diagnostic cannot accept or retrofit an old journal.
            try baseline.verify(.capture())
            guard let dell = baseline.displays.first(where: { $0.uuid == "09084682-3c42-4455-aab8-126a7431125b" }),
                  dell.vendor == 4268, dell.model == 16857, dell.serial == 1094800204,
                  dell.active, !dell.main, !dell.builtin, dell.x == 3440, dell.y == -4 else {
                throw RecoveryError.unsafe("DELL passive-control baseline mismatch; no correction permitted")
            }
            var iccBytes = 0
            for display in baseline.displays {
                guard let profile = CGDisplayCopyColorSpace(display.id).copyICCData() as Data?,
                      profile.count <= 1_048_576, iccBytes + profile.count <= 8 * 1_048_576,
                      RecoveryColorProfile.digest(profile) == display.colorProfileDigest else {
                    throw RecoveryError.unsafe("missing/changed/oversized raw ICC evidence")
                }
                iccBytes += profile.count
                try recording.save(profile, name: "\(display.uuid).icc")
            }
            let collector = IdentityLifetimeCollector(recording: recording)
            observer = collector
            defer { collector.stop() }
            try collector.start()
            let initial = try IdentityObservationInventory.displays(validateService: collector.checkService)
            let initialServices = try collector.inventory()
            recording.append("inventory", ["phase": "before-ready", "context": context, "enumeration": initial, "retainedServices": initialServices])
            try baseline.verify(.capture())
            try IdentityObservationInventory.require(NSDictionary(dictionary: context).isEqual(to: IdentityObservationInventory.context()), "context changed before readiness")
            try collector.arm {
                print("RECORDING READY — passive 60 seconds; NOT recovery readiness. Do not disconnect anything.")
                fflush(stdout)
            }
            let began = Date()
            let deadline = DispatchTime.now().uptimeNanoseconds + 60_000_000_000
            var eventInventories = 0
            var deadlineReached = false
            while recording.failure == nil {
                RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
                guard Date().timeIntervalSince(began) >= 0, Date().timeIntervalSince(began) < 62 else {
                    throw RecoveryError.unsafe("clock/scheduling/sleep gap; observation duration exceeded")
                }
                let changed = collector.consumeCG()
                if changed || collector.inventoryNeeded {
                    collector.inventoryNeeded = false
                    eventInventories += 1
                    guard eventInventories <= 8 else { throw RecoveryError.unsafe("event inventory overflow") }
                    let freshContext = try IdentityObservationInventory.context()
                    let inventory = try IdentityObservationInventory.displays(validateService: collector.checkService)
                    let services = try collector.inventory()
                    recording.append("inventory", ["phase": "event", "context": freshContext, "enumeration": inventory, "retainedServices": services])
                    try IdentityObservationInventory.require(NSArray(array: initialServices).isEqual(to: services), "passive retained-service mismatch")
                    try IdentityObservationInventory.require(NSDictionary(dictionary: context).isEqual(to: freshContext), "context changed")
                    try IdentityObservationInventory.require(NSDictionary(dictionary: initial).isEqual(to: inventory), "passive inventory mismatch")
                    try baseline.verify(.capture())
                }
                if DispatchTime.now().uptimeNanoseconds >= deadline { deadlineReached = true; break }
            }
            // Last reads still have notifications registered. Stop and drain the
            // fixed CG receipt queue before writing a terminal summary.
            let finalContext = try IdentityObservationInventory.context()
            let finalInventory = try IdentityObservationInventory.displays(validateService: collector.checkService)
            let finalServices = try collector.inventory()
            recording.append("inventory", ["phase": "after", "context": finalContext, "enumeration": finalInventory, "retainedServices": finalServices])
            try IdentityObservationInventory.require(NSArray(array: initialServices).isEqual(to: finalServices), "final retained-service mismatch")
            let finalSnapshot = try RecoverySnapshot.capture()
            try recording.save(JSONEncoder().encode(finalSnapshot), name: "after-snapshot.json")
            try baseline.verify(finalSnapshot)
            try IdentityObservationInventory.require(NSDictionary(dictionary: context).isEqual(to: finalContext), "final context mismatch")
            try IdentityObservationInventory.require(NSDictionary(dictionary: initial).isEqual(to: finalInventory), "final passive inventory mismatch")
            collector.stop()
            try recording.finish(deadlineReached: deadlineReached)
            if let failure = recording.failure { throw RecoveryError.unsafe(failure) }
        } catch {
            observer?.stop()
            recording.fail(String(describing: error))
            // A failed terminal write leaves started.json as explicit incomplete
            // evidence; never replace or resume artifacts from this run.
            try? recording.finish(deadlineReached: false)
            throw error
        }
    }
}

final class IdentityLifetimeCollector {
    let recording: IdentityObservationRecording
    let cg = IdentityCGEvents()
    var port: IONotificationPortRef?
    var source: CFRunLoopSource?
    var iterators: [io_iterator_t: (String, String)] = [:]
    var services: [(io_service_t, io_object_t)] = []
    var initialDrains = 0
    var inventoryNeeded = false
    var cgReference: UnsafeMutableRawPointer?
    var removeCG: (UnsafeMutableRawPointer) -> CGError = {
        CGDisplayRemoveReconfigurationCallback(IdentityLifetimeCollector.reconfiguration, $0)
    }
    var stopped = false

    init(recording: IdentityObservationRecording) { self.recording = recording }
    deinit { stop() }

    static let matching: IOServiceMatchingCallback = { ref, iterator in
        guard let ref else { return }
        Unmanaged<IdentityLifetimeCollector>.fromOpaque(ref).takeUnretainedValue().drain(iterator, initial: false)
    }
    static let interest: IOServiceInterestCallback = { ref, service, message, _ in
        guard let ref else { return }
        let owner = Unmanaged<IdentityLifetimeCollector>.fromOpaque(ref).takeUnretainedValue()
        let stamp = IdentityObservationRecording.stamp()
        do {
            let row = try IdentityObservationInventory.service(service)
            owner.recordInterest(row, message: message, receipt: stamp)
        } catch { owner.recording.fail("interest collection failure: \(error)") }
        // messageArgument is intentionally not dereferenced: message-specific
        // payloads have no generic public size/lifetime contract.
    }
    static let reconfiguration: CGDisplayReconfigurationCallBack = { id, flags, ref in
        guard let ref else { return }
        Unmanaged<IdentityCGEvents>.fromOpaque(ref).takeUnretainedValue().receive(id: id, flags: flags.rawValue)
    }

    func start() throws {
        guard port == nil, !stopped else { throw RecoveryError.unsafe("collector restart refused") }
        guard let port = IONotificationPortCreate(kIOMainPortDefault) else {
            throw RecoveryError.unsafe("notification port registration failure")
        }
        self.port = port
        guard let source = IONotificationPortGetRunLoopSource(port)?.takeUnretainedValue() else {
            throw RecoveryError.unsafe("notification run-loop registration failure")
        }
        self.source = source
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .defaultMode)
        let reference = Unmanaged.passRetained(cg).toOpaque()
        let cgStatus = CGDisplayRegisterReconfigurationCallback(Self.reconfiguration, reference)
        recording.append("registration", ["api": "CGDisplayRegisterReconfigurationCallback", "status": cgStatus.rawValue])
        guard cgStatus == .success else {
            Unmanaged<IdentityCGEvents>.fromOpaque(reference).release()
            throw RecoveryError.unsafe("CG callback registration failure")
        }
        cgReference = reference
        for name in IdentityObservationInventory.classes {
            for kind in [kIOPublishNotification, kIOTerminatedNotification] {
                guard let match = IOServiceMatching(name) else { throw RecoveryError.unsafe("matching dictionary unavailable") }
                var iterator: io_iterator_t = 0
                let status = IOServiceAddMatchingNotification(port, kind, match, Self.matching,
                    Unmanaged.passUnretained(self).toOpaque(), &iterator)
                recording.append("registration", ["class": name, "notification": kind, "status": status])
                if iterator != 0 { iterators[iterator] = (name, kind) }
                guard status == KERN_SUCCESS, iterator != 0 else { throw RecoveryError.unsafe("IOKit notification registration failure") }
                drain(iterator, initial: true)
                if let failure = recording.failure { throw RecoveryError.unsafe(failure) }
            }
        }
    }

    func drain(_ iterator: io_iterator_t, initial: Bool) {
        let receipt = IdentityObservationRecording.stamp()
        guard recording.failure == nil, let (name, kind) = iterators[iterator] else {
            recording.fail("unknown iterator or incomplete prior recording"); return
        }
        for index in 0...32 {
            let entry = IOIteratorNext(iterator)
            if entry == 0 {
                let valid = IOIteratorIsValid(iterator) != 0
                recording.append("iterator-drained", ["class": name, "notification": kind, "initial": initial, "valid": valid], receipt: receipt)
                if !valid { recording.fail("invalid iterator; no reset/restart permitted") }
                else if initial { initialDrains += 1 }
                return
            }
            defer { IOObjectRelease(entry) }
            guard index < 32 else { recording.fail("iterator inventory overflow; notification not armed"); return }
            do {
                let row = try IdentityObservationInventory.service(entry)
                recording.append(initial ? "initial-service" : "service-event",
                    ["class": name, "notification": kind, "service": row], receipt: receipt)
                try checkService(row)
                if kind == kIOPublishNotification && !services.contains(where: { IOObjectIsEqualTo($0.0, entry) != 0 }) {
                    guard services.count < 96, let port else { throw RecoveryError.unsafe("retained service inventory overflow") }
                    var notification: io_object_t = 0
                    let status = IOServiceAddInterestNotification(port, entry, kIOGeneralInterest, Self.interest,
                        Unmanaged.passUnretained(self).toOpaque(), &notification)
                    recording.append("interest-registration", ["status": status, "registryEntryID": row["registryEntryID"]!])
                    guard status == KERN_SUCCESS, notification != 0 else {
                        if notification != 0 { IOObjectRelease(notification) }
                        throw RecoveryError.unsafe("general-interest registration failure")
                    }
                    let retained = IOObjectRetain(entry)
                    guard retained == KERN_SUCCESS else { IOObjectRelease(notification); throw RecoveryError.unsafe("service retain failure") }
                    services.append((entry, notification))
                }
                if !initial { inventoryNeeded = true }
            } catch { recording.fail(String(describing: error)); return }
        }
    }

    func recordInterest(_ row: [String: Any], message: UInt32, receipt: [String: Any]) {
        recording.append("general-interest", ["messageType": message, "service": row], receipt: receipt)
        do { try checkService(row) } catch { recording.fail(String(describing: error)) }
        inventoryNeeded = true
    }

    func checkService(_ row: [String: Any]) throws {
        guard row["entryIDStatus"] as? Int32 == 0, row["pathStatus"] as? Int32 == 0,
              row["busyStatus"] as? Int32 == 0, row["identityReadable"] as? Bool == true else {
            recording.append("service-read-failure", row)
            recording.fail("required service read failed")
            throw RecoveryError.unsafe("required service read failed")
        }
    }

    func arm(acknowledge: () -> Void) throws {
        if consumeCG() { recording.fail("CG events during setup; stable readiness not established") }
        do {
            try cg.whenEmpty {
                try recording.arm(initialIteratorsDrained: initialDrains == 6)
                acknowledge()
            }
        } catch { recording.fail(String(describing: error)); throw error }
    }

    func inventory() throws -> [[String: Any]] {
        try services.map {
            let row = try IdentityObservationInventory.service($0.0)
            try checkService(row)
            return row
        }.sorted {
            ($0["registryEntryID"] as! UInt64) < ($1["registryEntryID"] as! UInt64)
        }
    }

    @discardableResult func consumeCG(close: Bool = false) -> Bool {
        let (events, overflow) = cg.drain(close: close)
        for event in events {
            recording.append("cg-reconfiguration", ["enumerationRequired": true, "id": event.id, "flags": event.flags],
                receipt: ["wallTime": event.wall, "monotonicNanoseconds": event.monotonic])
        }
        if overflow { recording.fail("CG callback queue overflow") }
        return !events.isEmpty
    }

    func stop() {
        guard !stopped else { return }; stopped = true
        if consumeCG(close: true) { recording.fail("CG events at cleanup; incomplete final context") }
        if let reference = cgReference {
            let status = removeCG(reference)
            recording.append("unregistration", ["api": "CGDisplayRemoveReconfigurationCallback", "status": status.rawValue])
            if status == .success { Unmanaged<IdentityCGEvents>.fromOpaque(reference).release() }
            else {
                // Failed removal may leave CG calling this address. Intentionally
                // retain the closed, bounded context until process exit, no retry.
                recording.fail("CG callback removal failure; closed context retained until process exit")
            }
            cgReference = nil
        }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .defaultMode) }
        for (service, notification) in services { IOObjectRelease(notification); IOObjectRelease(service) }
        services.removeAll()
        for iterator in iterators.keys { IOObjectRelease(iterator) }; iterators.removeAll()
        if let port { IONotificationPortDestroy(port) }
        port = nil; source = nil
    }
}
