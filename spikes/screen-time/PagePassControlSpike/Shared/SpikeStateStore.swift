import FamilyControls
import Foundation
import Darwin

struct SpikeStateStore {
    struct EnforcementSnapshot {
        let monitoringSelection: FamilyActivitySelection
        let managedApps: [ManagedAppRecord]
        let managedPolicyVersion: Int
    }

    struct FinalThresholdShieldIntent: Codable, Equatable {
        let runID: String
        let eventName: String
        let enforcementMode: EnforcementMode
    }

    enum StoreError: Error {
        case appGroupUnavailable
        case invalidSelectionPayload
        case invalidTransferPayload
        case lockUnavailable
        case persistenceSynchronizationFailed
        case activeRunChanged
    }

    private struct AutomationOwnership: Codable {
        var lease: String?
        var consumedNonces: Set<String>
        var lastNonce: String?
    }

    private let defaults: UserDefaults
    private let lockURL: URL
    private let synchronize: () -> Bool
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    init(
        defaults: UserDefaults,
        lockURL: URL? = nil,
        synchronize: (() -> Bool)? = nil
    ) {
        self.defaults = defaults
        self.lockURL = lockURL ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("PagePassStateStore.lock")
        self.synchronize = synchronize ?? {
            // App Group domains can report false even when the new value is
            // durably visible to the app and extension on physical devices.
            defaults.synchronize()
            return true
        }
    }

    static func appGroup() throws -> SpikeStateStore {
        guard let defaults = UserDefaults(suiteName: SpikeConstants.appGroupID),
              let containerURL = FileManager.default.containerURL(
                forSecurityApplicationGroupIdentifier: SpikeConstants.appGroupID
              ) else {
            throw StoreError.appGroupUnavailable
        }
        return SpikeStateStore(
            defaults: defaults,
            lockURL: containerURL.appendingPathComponent("pagepass-state.lock")
        )
    }

    func loadState() throws -> SpikeState {
        try withExclusiveLock(synchronizeAfterOperation: false) {
            try loadStateUnlocked()
        }
    }

    func loadEnforcementSnapshot() throws -> EnforcementSnapshot {
        try withExclusiveLock(synchronizeAfterOperation: false) {
            EnforcementSnapshot(
                monitoringSelection: try loadMonitoringSelectionUnlocked(),
                managedApps: try loadManagedAppsUnlocked(),
                managedPolicyVersion: defaults.integer(forKey: "managedPolicyVersion")
            )
        }
    }

    func enforceAndPersistFinalThresholdShieldIntent(
        runID: String,
        eventName: String,
        enforcement: (SpikeState, EnforcementSnapshot) throws -> Void
    ) throws {
        try withExclusiveLock(synchronizeAfterOperation: false) {
            let state = try loadStateUnlocked()
            guard state.activeRunID == runID,
                  state.activeEventName == eventName else {
                throw StoreError.activeRunChanged
            }
            let snapshot = EnforcementSnapshot(
                monitoringSelection: try loadMonitoringSelectionUnlocked(),
                managedApps: try loadManagedAppsUnlocked(),
                managedPolicyVersion: defaults.integer(forKey: "managedPolicyVersion")
            )
            try enforcement(state, snapshot)
            let intent = FinalThresholdShieldIntent(
                runID: runID,
                eventName: eventName,
                enforcementMode: state.enforcementMode
            )
            defaults.set(try encoder.encode(intent), forKey: "finalThresholdShieldIntent")
            try synchronizeOrThrow()
        }
    }

    func loadFinalThresholdShieldIntent() -> FinalThresholdShieldIntent? {
        try? withExclusiveLock(synchronizeAfterOperation: false) {
            guard let data = defaults.data(forKey: "finalThresholdShieldIntent") else {
                return nil
            }
            return try decoder.decode(FinalThresholdShieldIntent.self, from: data)
        }
    }

    func clearFinalThresholdShieldIntent(runID: String) {
        try? withExclusiveLock {
            guard let data = defaults.data(forKey: "finalThresholdShieldIntent"),
                  let intent = try? decoder.decode(FinalThresholdShieldIntent.self, from: data),
                  intent.runID == runID else { return }
            defaults.removeObject(forKey: "finalThresholdShieldIntent")
        }
    }

    func reconcileAndClearFinalThresholdShieldIntent(
        _ expectedIntent: FinalThresholdShieldIntent,
        enforcement: (inout SpikeState, EnforcementSnapshot) throws -> Void
    ) throws {
        try withExclusiveLock(synchronizeAfterOperation: false) {
            guard let data = defaults.data(forKey: "finalThresholdShieldIntent"),
                  try decoder.decode(FinalThresholdShieldIntent.self, from: data) == expectedIntent else {
                return
            }
            var state = try loadStateUnlocked()
            let snapshot = EnforcementSnapshot(
                monitoringSelection: try loadMonitoringSelectionUnlocked(),
                managedApps: try loadManagedAppsUnlocked(),
                managedPolicyVersion: defaults.integer(forKey: "managedPolicyVersion")
            )
            try enforcement(&state, snapshot)
            try saveUnlocked(state)
            defaults.removeObject(forKey: "finalThresholdShieldIntent")
            try synchronizeOrThrow()
        }
    }

    func save(_ state: SpikeState) throws {
        try withExclusiveLock {
            try saveUnlocked(state)
        }
    }

    @discardableResult
    func mutateState(
        beforeSave: ((inout SpikeState) throws -> Void)? = nil,
        afterSave: ((SpikeState) throws -> Void)? = nil,
        _ mutation: (inout SpikeState) throws -> Void
    ) throws -> SpikeState {
        try withExclusiveLock(synchronizeAfterOperation: false) {
            var state = try loadStateUnlocked()
            try mutation(&state)
            try beforeSave?(&state)
            try saveUnlocked(state)
            try synchronizeOrThrow()
            try afterSave?(state)
            return state
        }
    }

    @discardableResult
    func mutateStateWithEnforcementSnapshot(
        beforeSave: ((inout SpikeState, EnforcementSnapshot) throws -> Void)? = nil,
        afterSave: ((SpikeState, EnforcementSnapshot) throws -> Void)? = nil,
        _ mutation: (inout SpikeState) throws -> Void
    ) throws -> SpikeState {
        try withExclusiveLock(synchronizeAfterOperation: false) {
            var state = try loadStateUnlocked()
            let snapshot = try EnforcementSnapshot(
                monitoringSelection: loadMonitoringSelectionUnlocked(),
                managedApps: loadManagedAppsUnlocked(),
                managedPolicyVersion: defaults.integer(forKey: "managedPolicyVersion")
            )
            try mutation(&state)
            try beforeSave?(&state, snapshot)
            try saveUnlocked(state)
            try synchronizeOrThrow()
            try afterSave?(state, snapshot)
            return state
        }
    }

    func append(_ event: SpikeEvent) throws {
        try withExclusiveLock {
            var events = try loadEventsUnlocked()
            events.append(event)
            let data = try encoder.encode(events)
            defaults.set(data, forKey: "events")
        }
    }

    func loadEvents() throws -> [SpikeEvent] {
        try withExclusiveLock {
            try loadEventsUnlocked()
        }
    }

    private func loadEventsUnlocked() throws -> [SpikeEvent] {
        guard let data = defaults.data(forKey: "events") else { return [] }
        return try decoder.decode([SpikeEvent].self, from: data)
    }

    func saveSelection(_ selection: FamilyActivitySelection) throws {
        try withExclusiveLock {
            let data = try encoder.encode(selection)
            defaults.set(data, forKey: "selection")
        }
    }

    func loadSelection() throws -> FamilyActivitySelection {
        try withExclusiveLock {
            try loadSelectionUnlocked()
        }
    }

    func saveMonitoringSelection(_ selection: FamilyActivitySelection) throws {
        try withExclusiveLock {
            let data = try encoder.encode(selection)
            defaults.set(data, forKey: "monitoringSelection")
        }
    }

    func loadMonitoringSelection() throws -> FamilyActivitySelection {
        try withExclusiveLock {
            try loadMonitoringSelectionUnlocked()
        }
    }

    private func loadSelectionUnlocked() throws -> FamilyActivitySelection {
        guard let data = defaults.data(forKey: "selection") else { return FamilyActivitySelection() }
        return try decoder.decode(FamilyActivitySelection.self, from: data)
    }

    private func loadMonitoringSelectionUnlocked() throws -> FamilyActivitySelection {
        guard let data = defaults.data(forKey: "monitoringSelection") else {
            return try loadSelectionUnlocked()
        }
        return try decoder.decode(FamilyActivitySelection.self, from: data)
    }

    func saveManagedApps(_ records: [ManagedAppRecord]) throws {
        try withExclusiveLock {
            try saveManagedAppsUnlocked(records)
        }
    }

    func loadManagedApps() throws -> [ManagedAppRecord] {
        try withExclusiveLock {
            try loadManagedAppsUnlocked()
        }
    }

    func saveManagedPolicy(records: [ManagedAppRecord], version: Int) throws {
        try withExclusiveLock {
            try saveManagedAppsUnlocked(records)
            defaults.set(version, forKey: "managedPolicyVersion")
        }
    }

    private func saveManagedAppsUnlocked(_ records: [ManagedAppRecord]) throws {
        let data = try encoder.encode(records)
        defaults.set(data, forKey: "managedApps")
    }

    private func loadManagedAppsUnlocked() throws -> [ManagedAppRecord] {
        guard let data = defaults.data(forKey: "managedApps") else { return [] }
        return try decoder.decode([ManagedAppRecord].self, from: data)
    }

    func saveManagedPolicyVersion(_ version: Int) {
        try? withExclusiveLock {
            defaults.set(version, forKey: "managedPolicyVersion")
        }
    }

    func loadManagedPolicyVersion() -> Int {
        (try? withExclusiveLock {
            defaults.integer(forKey: "managedPolicyVersion")
        }) ?? 0
    }

    func saveAppliedManagedPolicyVersion(_ version: Int) {
        try? withExclusiveLock {
            defaults.set(version, forKey: "appliedManagedPolicyVersion")
        }
    }

    func loadAppliedManagedPolicyVersion() -> Int {
        (try? withExclusiveLock {
            defaults.integer(forKey: "appliedManagedPolicyVersion")
        }) ?? 0
    }

    func saveAutomationLease(_ lease: String) {
        try? withExclusiveLock {
            var ownership = try loadAutomationOwnershipUnlocked()
            ownership.lease = lease
            try saveAutomationOwnershipUnlocked(ownership)
        }
    }

    func loadAutomationLease() -> String? {
        try? withExclusiveLock {
            try loadAutomationOwnershipUnlocked().lease
        }
    }

    enum AutomationSessionClaim: Equatable {
        case claimed
        case leaseRejected
        case nonceRejected
    }

    func claimAutomationSession(
        lease requestedLease: String,
        replacing expectedLease: String?,
        replacingNonce expectedNonce: String?,
        nonce: String
    ) -> AutomationSessionClaim {
        (try? withExclusiveLock {
            var ownership = try loadAutomationOwnershipUnlocked()
            let activeLease = ownership.lease
            if let activeLease {
                guard expectedLease == activeLease,
                      expectedNonce == ownership.lastNonce else {
                    return .leaseRejected
                }
            } else if expectedLease != nil || expectedNonce != nil {
                return .leaseRejected
            }

            guard !ownership.consumedNonces.contains(nonce) else {
                return .nonceRejected
            }

            ownership.lease = requestedLease
            ownership.consumedNonces.insert(nonce)
            ownership.lastNonce = nonce
            try saveAutomationOwnershipUnlocked(ownership)
            return .claimed
        }) ?? .leaseRejected
    }

    func hasConsumedAutomationNonce(_ nonce: String) -> Bool {
        (try? withExclusiveLock {
            try loadAutomationOwnershipUnlocked().consumedNonces.contains(nonce)
        }) ?? false
    }

    func saveConsumedAutomationNonce(_ nonce: String) {
        try? withExclusiveLock {
            var ownership = try loadAutomationOwnershipUnlocked()
            ownership.consumedNonces.insert(nonce)
            ownership.lastNonce = nonce
            try saveAutomationOwnershipUnlocked(ownership)
        }
    }

    func loadConsumedAutomationNonce() -> String? {
        try? withExclusiveLock {
            try loadAutomationOwnershipUnlocked().lastNonce
        }
    }

    func exportSelectionPayload(_ selection: FamilyActivitySelection) throws -> String {
        try encoder.encode(selection).base64EncodedString()
    }

    func importSelectionPayload(_ payload: String) throws -> FamilyActivitySelection {
        let trimmed = payload.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = Data(base64Encoded: trimmed) else {
            throw StoreError.invalidSelectionPayload
        }
        return try decoder.decode(FamilyActivitySelection.self, from: data)
    }

    func exportRequestEnvelope(_ envelope: AppRequestEnvelope) throws -> String {
        try encodeTransfer(envelope)
    }

    func importRequestEnvelope(_ payload: String) throws -> AppRequestEnvelope {
        try decodeTransfer(AppRequestEnvelope.self, payload: payload)
    }

    func exportPolicyEnvelope(_ envelope: ParentPolicyEnvelope) throws -> String {
        try encodeTransfer(envelope)
    }

    func importPolicyEnvelope(_ payload: String) throws -> ParentPolicyEnvelope {
        try decodeTransfer(ParentPolicyEnvelope.self, payload: payload)
    }

    func reset() {
        try? withExclusiveLock {
            defaults.removeObject(forKey: "state")
            defaults.removeObject(forKey: "events")
            defaults.removeObject(forKey: "selection")
            defaults.removeObject(forKey: "monitoringSelection")
            defaults.removeObject(forKey: "managedApps")
            defaults.removeObject(forKey: "managedPolicyVersion")
            defaults.removeObject(forKey: "appliedManagedPolicyVersion")
            defaults.removeObject(forKey: "automationLease")
            defaults.removeObject(forKey: "consumedAutomationNonce")
            defaults.removeObject(forKey: "consumedAutomationNonces")
            defaults.removeObject(forKey: "automationOwnership")
            defaults.removeObject(forKey: "finalThresholdShieldIntent")
        }
    }

    private func encodeTransfer<Value: Encodable>(_ value: Value) throws -> String {
        try encoder.encode(value).base64EncodedString()
    }

    private func decodeTransfer<Value: Decodable>(_ type: Value.Type, payload: String) throws -> Value {
        let trimmed = payload.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = Data(base64Encoded: trimmed) else {
            throw StoreError.invalidTransferPayload
        }
        return try decoder.decode(type, from: data)
    }

    private func loadStateUnlocked() throws -> SpikeState {
        guard let data = defaults.data(forKey: "state") else { return SpikeState() }
        return try decoder.decode(SpikeState.self, from: data)
    }

    private func saveUnlocked(_ state: SpikeState) throws {
        let data = try encoder.encode(state)
        defaults.set(data, forKey: "state")
    }

    private func loadAutomationOwnershipUnlocked() throws -> AutomationOwnership {
        if let data = defaults.data(forKey: "automationOwnership") {
            return try decoder.decode(AutomationOwnership.self, from: data)
        }

        var consumedNonces = Set(defaults.stringArray(forKey: "consumedAutomationNonces") ?? [])
        let legacyNonce = defaults.string(forKey: "consumedAutomationNonce")
        if let legacyNonce {
            consumedNonces.insert(legacyNonce)
        }
        return AutomationOwnership(
            lease: defaults.string(forKey: "automationLease"),
            consumedNonces: consumedNonces,
            lastNonce: legacyNonce
        )
    }

    private func saveAutomationOwnershipUnlocked(_ ownership: AutomationOwnership) throws {
        defaults.set(try encoder.encode(ownership), forKey: "automationOwnership")
        try synchronizeOrThrow()

        defaults.set(ownership.lease, forKey: "automationLease")
        defaults.set(ownership.consumedNonces.sorted(), forKey: "consumedAutomationNonces")
        defaults.set(ownership.lastNonce, forKey: "consumedAutomationNonce")
    }

    private func withExclusiveLock<Value>(
        synchronizeAfterOperation: Bool = true,
        _ operation: () throws -> Value
    ) throws -> Value {
        let descriptor = Darwin.open(
            lockURL.path,
            O_CREAT | O_RDWR,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else { throw StoreError.lockUnavailable }
        defer { Darwin.close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else { throw StoreError.lockUnavailable }
        defer { flock(descriptor, LOCK_UN) }

        try synchronizeOrThrow()
        let value = try operation()
        if synchronizeAfterOperation {
            try synchronizeOrThrow()
        }
        return value
    }

    private func synchronizeOrThrow() throws {
        guard synchronize() else {
            throw StoreError.persistenceSynchronizationFailed
        }
    }
}
