import Foundation
import IOKit

/// Read-only closure injection, following RecoveryEngine's existing test seam.
/// Offline tests replace every operation; fake handles never reach IOKit.
struct IdentityRegistryAPI {
    var next: (io_iterator_t) -> io_object_t = { IOIteratorNext($0) }
    var valid: (io_iterator_t) -> Bool = { IOIteratorIsValid($0) != 0 }
    var service: (io_service_t) throws -> [String: Any] = IdentityObservationInventory.service
    var retain: (io_object_t) -> kern_return_t = { IOObjectRetain($0) }
    var release: (io_object_t) -> Void = { _ = IOObjectRelease($0) }
    var equal: (io_object_t, io_object_t) -> Bool = { IOObjectIsEqualTo($0, $1) != 0 }
    var matching: (IONotificationPortRef?, String, String, UnsafeMutableRawPointer, inout io_iterator_t) -> kern_return_t = {
        port, name, kind, context, iterator in
        guard let port, let match = IOServiceMatching(name) else { return KERN_FAILURE }
        return IOServiceAddMatchingNotification(port, kind, match, IdentityLifetimeCollector.matching, context, &iterator)
    }
    var interest: (IONotificationPortRef?, io_service_t, UnsafeMutableRawPointer, inout io_object_t) -> kern_return_t = {
        port, service, context, notification in
        guard let port else { return KERN_FAILURE }
        return IOServiceAddInterestNotification(port, service, kIOGeneralInterest,
                                               IdentityLifetimeCollector.interest, context, &notification)
    }
}
