import Foundation
import Darwin
import PanelCtlCore

@MainActor
final class ProtectionCoordinator {
    typealias ServiceFactory = (UUID?) -> ProtectionService

    private let makeService: ServiceFactory
    private let initialService: ProtectionService?
    private var initialServiceAvailable: Bool
    private var services: [UUID: ProtectionService] = [:]
    private var oneShotRuleIDs: Set<UUID> = []
    private var oneShotRuleNames: [UUID: String] = [:]
    private var oneShotDisplaySelections: [UUID: (allDisplays: Bool, uuids: Set<String>, mode: BlackoutMode)] = [:]
    private var legacyCleanupService: ProtectionService?
    private var rules: [UUID: ProtectionRule] = [:]
    private var validations: [UUID: ProtectionRuleValidation] = [:]
    private var desiredArguments: [UUID: [String]] = [:]
    private var desiredSignature: String?
    private var reconciliationGeneration: UInt64 = 0
    private var relocationGeneration: UInt64 = 0
    private var reconciliationInProgress = false
    private var pendingDisplayRearmOnLaunch = false
    private var retryInProgress = false
    private var isShuttingDown = false
    private var storedCleanupFailure: String?
    private let verifyJournal: (UUID?) -> Bool
    private let ruleJournalDirectory: URL
    private let removeDeletedDirectories: Bool
    private let discoverRuleIDs: () throws -> Set<UUID>

    var onStateChange: (() -> Void)?
    var onMembershipChange: ((Set<UInt32>) -> Void)?
    var onOneShotFinished: ((UUID, Bool, String?) -> Void)?

    init(
        initialCleanupFailure: String? = nil,
        initialService: ProtectionService? = nil,
        verifyJournal: @escaping (UUID?) -> Bool = { BlackoutController.brightnessCleanupIsVerified(ruleID: $0) },
        ruleJournalDirectory: URL = BlackoutController.ruleBrightnessJournalDirectoryURL,
        removeDeletedDirectories: Bool = true,
        discoverRuleIDs: (() throws -> Set<UUID>)? = nil,
        serviceFactory: ServiceFactory? = nil
    ) {
        self.storedCleanupFailure = initialCleanupFailure
        self.initialService = initialService
        self.initialServiceAvailable = initialService != nil
        self.verifyJournal = verifyJournal
        self.ruleJournalDirectory = ruleJournalDirectory
        self.removeDeletedDirectories = removeDeletedDirectories
        self.discoverRuleIDs = discoverRuleIDs ?? {
            try Self.discoverRuleIDs(in: ruleJournalDirectory)
        }
        self.makeService = serviceFactory ?? { ruleID in
            ProtectionService(
                cleanupRuleID: ruleID,
                cleanupIsVerified: { BlackoutController.brightnessCleanupIsVerified(ruleID: ruleID) }
            )
        }
    }

    var unresolvedCleanupFailure: String? {
        if let storedCleanupFailure { return storedCleanupFailure }
        if let serviceFailure = (Array(services.values) + (legacyCleanupService.map { [$0] } ?? []))
            .compactMap(\.unresolvedCleanupFailure).first {
            return serviceFailure
        }
        return runtimeJournalsAreVerified ? nil : Self.unknownCleanup
    }

    var hasManagedProcess: Bool { services.values.contains(where: \.hasManagedProcess) }
    var canReceiveControl: Bool { services.values.contains(where: \.canReceiveControl) }

    var blackedOutDisplayIDs: Set<UInt32> {
        services.values.reduce(into: Set<UInt32>()) { $0.formUnion($1.blackedOutDisplayIDs) }
    }

    var hasUncertainBlackoutCoverage: Bool {
        services.values.contains { $0.hasManagedProcess && !$0.relocationControlIsHealthy }
    }

    func beginRelocationSuppression(_ control: BlackoutRelocationControl) async -> (Bool, String?, UInt64?) {
        let active = services.values.filter(\.hasManagedProcess)
        let generation = relocationGeneration
        guard active.allSatisfy(\.relocationControlIsHealthy) else {
            return (false, "A managed blackout helper is starting or stopping; relocation is paused until coverage is certain.", nil)
        }
        guard !active.isEmpty else { return (true, nil, generation) }
        return await withCheckedContinuation { continuation in
            var remaining = active.count
            var failure: String?
            var completed = false
            let timeout = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !completed else { return }
                completed = true
                for service in active { service.cancelRelocationSuppressionAcknowledgement(for: control.token) }
                continuation.resume(returning: (false, "A managed blackout helper did not acknowledge relocation suppression within one second.", nil))
            }
            for service in active {
                service.beginRelocationSuppression(control) { succeeded, message in
                    guard !completed else { return }
                    if !succeeded, failure == nil { failure = message }
                    remaining -= 1
                    guard remaining == 0 else { return }
                    completed = true
                    timeout.cancel()
                    guard failure == nil, self.relocationGeneration == generation,
                          self.relocationHelpersAreHealthy else {
                        continuation.resume(returning: (false,
                            failure ?? "Blackout helper generation changed before relocation was acknowledged.", nil))
                        return
                    }
                    continuation.resume(returning: (true, nil, generation))
                }
            }
        }
    }

    func relocationSuppressionIsCurrent(_ generation: UInt64) -> Bool {
        !isShuttingDown && relocationGeneration == generation && relocationHelpersAreHealthy
    }

    private var relocationHelpersAreHealthy: Bool {
        services.values.filter(\.hasManagedProcess).allSatisfy(\.relocationControlIsHealthy)
    }

    func endRelocationSuppression(_ control: BlackoutRelocationControl) {
        for service in services.values where service.hasManagedProcess {
            service.endRelocationSuppression(control)
        }
    }

    func blackedOutDisplayIDs(forRule id: UUID) -> Set<UInt32> {
        services[id]?.blackedOutDisplayIDs ?? []
    }

    var ruleIDs: [UUID] { rules.keys.sorted { $0.uuidString < $1.uuidString } }
    var runningOneShotRuleID: UUID? { oneShotRuleIDs.first }
    var runningOneShotRuleName: String? { runningOneShotRuleID.flatMap { oneShotRuleNames[$0] } }
    var hasRunningOneShot: Bool { !oneShotRuleIDs.isEmpty }

    func oneShotMode(for id: UUID) -> BlackoutMode? {
        oneShotDisplaySelections[id]?.mode
    }

    func oneShotReadiness(for id: UUID) -> String? {
        if isShuttingDown {
            return "PanelCtl is shutting down; the rule cannot be started."
        }
        if retryInProgress || reconciliationInProgress {
            return "Automation is starting, stopping or awaiting a display operation. Try again when it settles."
        }
        if oneShotRuleIDs.contains(id) {
            return "This Automation rule is already running once. Try again when it finishes."
        }
        if hasRunningOneShot {
            return "Another one-shot Automation rule is running. Try again when it finishes."
        }
        if let service = services[id], !service.canStartOneShot {
            if service.hasActiveEffect {
                return "This rule is already active. Restore it and wait for it to finish before running it once."
            }
            return "This rule is starting, stopping or needs cleanup. Try again after it settles."
        }
        if let selectedRule = rules[id] {
            for (otherID, service) in services where otherID != id && service.hasActiveEffect {
                guard let otherRule = rules[otherID], Self.rulesOverlap(selectedRule, otherRule) else { continue }
                return "Another Automation rule is active on this rule’s selected displays. Restore it and wait for it to finish."
            }
        }
        return nil
    }

    private static func rulesOverlap(_ lhs: ProtectionRule, _ rhs: ProtectionRule) -> Bool {
        if lhs.settings.allDisplays || rhs.settings.allDisplays { return true }
        let left = Set(lhs.settings.selectedDisplayUUIDs.map { $0.lowercased() })
        return rhs.settings.selectedDisplayUUIDs.contains { left.contains($0.lowercased()) }
    }

    private func canScheduleRule(_ id: UUID) -> Bool {
        guard !oneShotRuleIDs.contains(id), unresolvedCleanupFailure == nil, runtimeJournalsAreVerified,
              let rule = rules[id] else { return false }
        for (activeID, selection) in oneShotDisplaySelections where activeID != id {
            if selection.allDisplays || rule.settings.allDisplays ||
                rule.settings.selectedDisplayUUIDs.contains(where: { selection.uuids.contains($0.lowercased()) }) {
                return false
            }
        }
        return true
    }

    @discardableResult
    func runOneShot(
        id: UUID,
        name: String,
        arguments: [String],
        mode: BlackoutMode,
        allDisplays: Bool,
        selectedDisplayUUIDs: Set<String>,
        onInstalled: @escaping (Bool, String?) -> Void
    ) -> Bool {
        guard oneShotReadiness(for: id) == nil else { return false }
        let service = service(for: id)
        oneShotRuleIDs.insert(id)
        oneShotRuleNames[id] = name
        oneShotDisplaySelections[id] = (
            allDisplays: allDisplays,
            uuids: Set(selectedDisplayUUIDs.map { $0.lowercased() }),
            mode: mode
        )
        pendingDisplayRearmOnLaunch = true
        publishChanges()
        let accepted = service.runOneShot(
            arguments: arguments,
            onInstalled: onInstalled
        ) { [weak self] succeeded, message in
            guard let self else { return }
            self.oneShotRuleIDs.remove(id)
            self.oneShotRuleNames.removeValue(forKey: id)
            self.oneShotDisplaySelections.removeValue(forKey: id)
            self.publishChanges()
            self.onOneShotFinished?(id, succeeded, message)
        }
        if !accepted {
            oneShotRuleIDs.remove(id)
            oneShotRuleNames.removeValue(forKey: id)
            oneShotDisplaySelections.removeValue(forKey: id)
            publishChanges()
        }
        return accepted
    }

    @discardableResult
    func stopOneShotsForRestore() -> Bool {
        var stopped = false
        for id in Array(oneShotRuleIDs) {
            stopped = services[id]?.stopOneShot() == true || stopped
        }
        return stopped
    }

    func resumeAutomaticRulesAfterOneShot() {
        guard !isShuttingDown, unresolvedCleanupFailure == nil, runtimeJournalsAreVerified else { return }
        for (id, arguments) in desiredArguments where canScheduleRule(id) {
            let service = service(for: id)
            guard !service.hasManagedProcess else { continue }
            service.run(arguments: arguments, restartForDisplayChange: true)
        }
        pendingDisplayRearmOnLaunch = false
    }

    func runtimeState(for id: UUID, automationEnabled: Bool, snoozedUntil: Date?) -> ProtectionRuntimeState {
        guard let rule = rules[id] else { return .disabled }
        guard rule.isEnabled else { return .disabled }
        if let storedCleanupFailure = unresolvedCleanupFailure {
            return .failed(storedCleanupFailure)
        }
        if let snoozedUntil { return .snoozed(snoozedUntil) }
        guard automationEnabled else { return .disabled }
        if let validation = validations[id] {
            if let reason = validation.blockingReason { return .failed(reason) }
            if let reason = validation.waitingReason { return .waitingForDisplays(reason) }
        }
        return services[id]?.state ?? .waiting
    }

    func reconcile(
        ruleSet: AutomationPreferences,
        validations: [UUID: ProtectionRuleValidation],
        arguments: [UUID: [String]],
        forceRestart: Bool = false
    ) {
        guard !isShuttingDown else { return }
        rules = Dictionary(ruleSet.rules.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        // Deleting a rule ends any blackout or dimming it is running once.
        for id in oneShotRuleIDs where rules[id] == nil {
            services[id]?.stopOneShot()
        }
        if initialServiceAvailable, let firstRuleID = ruleSet.rules.first?.id {
            _ = service(for: firstRuleID)
        }
        self.validations = validations
        desiredArguments = arguments
        let signature = Self.signature(for: arguments)
        let changed = forceRestart || signature != desiredSignature
        desiredSignature = signature
        guard changed else {
            publishChanges()
            return
        }
        reconciliationGeneration &+= 1
        let generation = reconciliationGeneration
        reconciliationInProgress = true
        let current = services.filter { !oneShotRuleIDs.contains($0.key) }.map(\.value)
        if !current.isEmpty || forceRestart {
            pendingDisplayRearmOnLaunch = true
        }
        guard !current.isEmpty else {
            finishReconciliation(generation: generation, succeeded: true, message: nil)
            return
        }
        var remaining = current.count
        var failure: String?
        for service in current {
            service.disableForDisplayHide { [weak self] succeeded, message in
                guard let self else { return }
                if !succeeded, failure == nil {
                    failure = message ?? Self.unknownCleanup
                }
                remaining -= 1
                if remaining == 0 {
                    self.finishReconciliation(generation: generation, succeeded: failure == nil, message: failure)
                }
            }
        }
    }

    func disable() {
        desiredArguments = [:]
        desiredSignature = Self.signature(for: [:])
        for service in services.values { service.disable() }
        publishChanges()
    }

    func disableForDisplayHide(completion: @escaping (Bool, String?) -> Void) {
        desiredArguments = [:]
        desiredSignature = Self.signature(for: [:])
        reconciliationGeneration &+= 1
        reconciliationInProgress = false
        pendingDisplayRearmOnLaunch = true
        let current = Array(services.values)
        guard !current.isEmpty else {
            let failure = unresolvedCleanupFailure
            completion(failure == nil, failure)
            return
        }
        var remaining = current.count
        var succeeded = true
        var failure: String?
        for service in current {
            service.disableForDisplayHide { [weak self] result, message in
                guard let self else { return }
                succeeded = succeeded && result
                if !result, failure == nil { failure = message ?? self.unresolvedCleanupFailure ?? Self.unknownCleanup }
                remaining -= 1
                if remaining == 0 {
                    let journalsClean = self.allJournalsAreVerified
                    if !journalsClean, failure == nil { failure = Self.unknownCleanup }
                    completion(succeeded && journalsClean && self.storedCleanupFailure == nil, failure)
                    self.publishChanges()
                }
            }
        }
    }

    func retryCleanup(completion: @escaping (Bool, String?) -> Void) {
        guard !retryInProgress else { completion(false, "Automation cleanup is already running."); return }
        retryInProgress = true
        let ids = Set(rules.keys).union(services.keys).union(discoveredRuleIDs ?? [])
        var cleanupServices: [ProtectionService] = ids.sorted { $0.uuidString < $1.uuidString }.map { id in
            if let service = services[id] { return service }
            return makeService(id)
        }
        if legacyCleanupService == nil {
            legacyCleanupService = makeService(nil)
        }
        if let legacyCleanupService { cleanupServices.append(legacyCleanupService) }
        guard !cleanupServices.isEmpty else {
            finishCleanupRetry(services: [], remaining: 0, succeeded: true, failure: nil, completion: completion)
            return
        }
        var remaining = cleanupServices.count
        var succeeded = true
        var failure: String?
        for service in cleanupServices {
            service.retryCleanup { [weak self] result, message in
                guard let self else { return }
                succeeded = succeeded && result
                if !result, failure == nil { failure = message ?? Self.unknownCleanup }
                remaining -= 1
                if remaining == 0 {
                    self.finishCleanupRetry(
                        services: cleanupServices,
                        remaining: 0,
                        succeeded: succeeded,
                        failure: failure,
                        completion: completion
                    )
                }
            }
        }
    }

    private func finishCleanupRetry(
        services: [ProtectionService],
        remaining: Int,
        succeeded: Bool,
        failure: String?,
        completion: @escaping (Bool, String?) -> Void
    ) {
        _ = services
        _ = remaining
        let verified = allJournalsAreVerified
        let result = succeeded && verified
        if result {
            storedCleanupFailure = nil
            removeVerifiedDeletedDirectories()
        } else {
            storedCleanupFailure = failure ?? Self.unknownCleanup
        }
        retryInProgress = false
        publishChanges()
        completion(result, result ? nil : (failure ?? Self.unknownCleanup))
    }

    func restore() throws -> Bool {
        var sent = false
        var firstError: Error?
        for service in services.values where service.canReceiveControl {
            do {
                sent = try service.sendControl(.restore) || sent
            } catch {
                if firstError == nil { firstError = error }
            }
        }
        if let firstError { throw firstError }
        return sent
    }

    func shutdown(completion: @escaping () -> Void) {
        isShuttingDown = true
        reconciliationGeneration &+= 1
        let all = Array(services.values) + (legacyCleanupService.map { [$0] } ?? [])
        guard !all.isEmpty else { completion(); return }
        var remaining = all.count
        for service in all {
            service.shutdown {
                remaining -= 1
                if remaining == 0 { completion() }
            }
        }
    }

    private func finishReconciliation(generation: UInt64, succeeded: Bool, message: String?) {
        guard generation == reconciliationGeneration, !isShuttingDown else { return }
        reconciliationInProgress = false
        guard succeeded, unresolvedCleanupFailure == nil, runtimeJournalsAreVerified else {
            if storedCleanupFailure == nil {
                storedCleanupFailure = message ?? Self.unknownCleanup
            }
            for service in services.values { service.disable() }
            publishChanges()
            return
        }
        removeVerifiedDeletedDirectories()
        let knownRuleIDs = Set(rules.keys)
        for id in Array(services.keys) where !oneShotRuleIDs.contains(id) && !knownRuleIDs.contains(id) {
            if let removed = services.removeValue(forKey: id) {
                relocationGeneration &+= 1
                removed.disable()
            }
        }
        for (id, arguments) in desiredArguments where canScheduleRule(id) {
            service(for: id).run(
                arguments: arguments,
                restartForDisplayChange: pendingDisplayRearmOnLaunch
            )
        }
        pendingDisplayRearmOnLaunch = false
        publishChanges()
    }

    private func service(for id: UUID) -> ProtectionService {
        if let service = services[id] { return service }
        let service: ProtectionService
        if initialServiceAvailable, let initialService {
            initialServiceAvailable = false
            service = initialService
        } else {
            service = makeService(id)
        }
        service.onStateChange = { [weak self] _ in
            self?.relocationGeneration &+= 1
            self?.publishChanges()
        }
        service.onMembershipChange = { [weak self] _ in
            guard let self else { return }
            self.onMembershipChange?(self.blackedOutDisplayIDs)
            self.publishChanges()
        }
        services[id] = service
        relocationGeneration &+= 1
        return service
    }

    private var discoveredRuleIDs: Set<UUID>? {
        try? discoverRuleIDs()
    }

    private var runtimeJournalsAreVerified: Bool {
        guard let discovered = discoveredRuleIDs else { return false }
        let liveRuleIDs = Set(services.compactMap { id, service in
            service.hasManagedProcess ? id : nil
        })
        if legacyCleanupService?.hasManagedProcess != true, !verifyJournal(nil) { return false }
        return discovered.filter { !liveRuleIDs.contains($0) }.allSatisfy(verifyJournal)
    }

    private var allJournalsAreVerified: Bool {
        guard let discovered = discoveredRuleIDs, verifyJournal(nil) else { return false }
        return discovered.allSatisfy(verifyJournal)
    }

    private static func discoverRuleIDs(in directory: URL) throws -> Set<UUID> {
        var info = stat()
        guard lstat(directory.path, &info) == 0 else {
            let code = errno
            if code == ENOENT { return [] }
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(code))
        }
        guard info.st_mode & S_IFMT == S_IFDIR else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOTDIR))
        }
        let entries = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        return Set(entries.compactMap { UUID(uuidString: $0.lastPathComponent) })
    }

    private func removeVerifiedDeletedDirectories() {
        guard removeDeletedDirectories, let discovered = discoveredRuleIDs else { return }
        let existing = Set(rules.keys)
        for id in discovered where !existing.contains(id) {
            guard verifyJournal(id) else { continue }
            try? FileManager.default.removeItem(at: ruleJournalDirectory.appendingPathComponent(id.uuidString, isDirectory: true))
        }
    }

    private func publishChanges() {
        onMembershipChange?(blackedOutDisplayIDs)
        onStateChange?()
    }

    private static func signature(for arguments: [UUID: [String]]) -> String {
        arguments.keys.sorted { $0.uuidString < $1.uuidString }.map { id in
            "\(id.uuidString):\(arguments[id, default: []].joined(separator: "\u{1f}"))"
        }.joined(separator: "\u{1e}")
    }

    private static let unknownCleanup = "Automation cleanup couldn’t confirm brightness was restored."
}
