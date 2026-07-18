import DeviceActivity
import FamilyControls
import Foundation
import ManagedSettings

final class PagePassDeviceActivityMonitor: DeviceActivityMonitor {
    // AuthorizationCenter status starts as notDetermined in this extension process.
    // The containing app owns authorization checks; callbacks enforce its persisted policy.
    private enum RearmError: Error {
        case activeRunChanged
        case emptySelection
        case monitoringPolicyChanged
    }

    private let managedStore = ManagedSettingsStore(named: ManagedSettingsStore.Name(SpikeConstants.storeName))
    private let legacyStore = ManagedSettingsStore(named: ManagedSettingsStore.Name(SpikeConstants.legacyStoreName))

    override func intervalDidStart(for activity: DeviceActivityName) {
        guard let store = try? SpikeStateStore.appGroup() else {
            applyEmergencyFailClosedShield()
            return
        }

        var matchedRunID: String?
        let state: SpikeState
        do {
            state = try store.mutateStateWithEnforcementSnapshot(
                { state in
                    guard state.activeActivityName == activity.rawValue,
                          let runID = state.activeRunID else { return }
                    matchedRunID = runID
                    SpikeReducer.apply(.intervalDidStart(runID: runID), to: &state)
                }
            )
        } catch {
            let expectedRunIDs = Set(matchedRunID.map { [$0] } ?? [])
            guard shouldFailClosed(store: store, expectedRunIDs: expectedRunIDs) else {
                try? store.append(SpikeEvent(name: "stale callback error ignored", activityName: activity.rawValue, eventName: nil, runID: matchedRunID, source: "extension", creditBefore: 0, creditAfter: 0, selectedApplicationTokenCount: selectedTokenCount(store: store), detail: "intervalDidStart lost ownership: \(error.localizedDescription)"))
                return
            }
            persistTerminalFailClosed(store: store, expectedRunIDs: expectedRunIDs, expectedActivityName: activity.rawValue)
            try? store.append(SpikeEvent(name: "fail-closed storage recovery", activityName: activity.rawValue, eventName: nil, runID: matchedRunID, source: "extension", creditBefore: 0, creditAfter: 0, selectedApplicationTokenCount: 0, detail: "intervalDidStart transaction failed; all applications shielded: \(error.localizedDescription)"))
            return
        }

        guard let runID = matchedRunID else {
            try? store.append(SpikeEvent(name: "stale callback ignored", activityName: activity.rawValue, eventName: nil, runID: state.activeRunID, source: "extension", creditBefore: state.creditSeconds, creditAfter: state.creditSeconds, selectedApplicationTokenCount: selectedTokenCount(store: store), detail: "intervalDidStart did not match active activity"))
            return
        }
        let detail = state.wallClockSession?.sessionID == runID
            ? "wall-clock monitoring interval started"
            : "active cumulative run interval started"
        try? store.append(SpikeEvent(name: "interval did start", activityName: activity.rawValue, eventName: state.activeEventName, runID: runID, source: "extension", creditBefore: state.creditSeconds, creditAfter: state.creditSeconds, selectedApplicationTokenCount: selectedTokenCount(store: store), detail: detail))
    }

    override func intervalDidEnd(for activity: DeviceActivityName) {
        guard let store = try? SpikeStateStore.appGroup() else {
            applyEmergencyFailClosedShield()
            return
        }
        var matchedRunID: String?
        var creditBefore = 0
        var shieldWasApplied = false
        let state: SpikeState
        do {
            state = try store.mutateStateWithEnforcementSnapshot(
                beforeSave: { state, snapshot in
                    guard let runID = matchedRunID else { return }
                    shieldWasApplied = try self.applyPendingShieldBeforeSave(snapshot: snapshot, state: &state, runID: runID)
                },
                { state in
                    guard state.activeActivityName == activity.rawValue,
                          let runID = state.activeRunID else { return }
                    matchedRunID = runID
                    creditBefore = state.creditSeconds
                    SpikeReducer.apply(.intervalDidEnd(runID: runID), to: &state)
                }
            )
        } catch {
            let expectedRunIDs = Set(matchedRunID.map { [$0] } ?? [])
            guard shouldFailClosed(store: store, expectedRunIDs: expectedRunIDs) else {
                try? store.append(SpikeEvent(name: "stale callback error ignored", activityName: activity.rawValue, eventName: nil, runID: matchedRunID, source: "extension", creditBefore: creditBefore, creditAfter: creditBefore, selectedApplicationTokenCount: selectedTokenCount(store: store), detail: "intervalDidEnd lost ownership: \(error.localizedDescription)"))
                return
            }
            persistTerminalFailClosed(store: store, expectedRunIDs: expectedRunIDs, expectedActivityName: activity.rawValue)
            try? store.append(SpikeEvent(name: "fail-closed storage recovery", activityName: activity.rawValue, eventName: nil, runID: matchedRunID, source: "extension", creditBefore: creditBefore, creditAfter: 0, selectedApplicationTokenCount: 0, detail: "intervalDidEnd transaction failed; all applications shielded: \(error.localizedDescription)"))
            return
        }
        guard let runID = matchedRunID else {
            try? store.append(SpikeEvent(name: "stale callback ignored", activityName: activity.rawValue, eventName: nil, runID: state.activeRunID, source: "extension", creditBefore: state.creditSeconds, creditAfter: state.creditSeconds, selectedApplicationTokenCount: selectedTokenCount(store: store), detail: "intervalDidEnd did not match active activity"))
            return
        }
        try? store.append(SpikeEvent(name: "interval did end", activityName: activity.rawValue, eventName: state.activeEventName, runID: runID, source: "extension", creditBefore: creditBefore, creditAfter: state.creditSeconds, selectedApplicationTokenCount: selectedTokenCount(store: store), detail: "monitoring window ended; fail-closed shield applied=\(shieldWasApplied)"))
    }

    override func eventDidReachThreshold(_ event: DeviceActivityEvent.Name, activity: DeviceActivityName) {
        guard let store = try? SpikeStateStore.appGroup() else {
            applyEmergencyFailClosedShield()
            return
        }
        var markerRunID: String?
        var markerCredit = 0
        var markerWasSaved = false
        var markerWasPremature = false
        var resumesPersistedMarker = false
        if let pending = try? store.loadState(),
           pending.thresholdDebitPending,
           pending.activeActivityName == activity.rawValue,
           let pendingRunID = pending.activeRunID {
            let expectedThreshold = pending.activeEventName.flatMap {
                SpikeConstants.cumulativeThresholdSeconds(eventName: $0, runID: pendingRunID)
            }
            let callbackThreshold = SpikeConstants.cumulativeThresholdSeconds(
                eventName: event.rawValue,
                runID: pendingRunID
            )
            if callbackThreshold == expectedThreshold,
               pending.activeEventName == event.rawValue {
                markerRunID = pendingRunID
                markerCredit = pending.creditSeconds
                markerWasSaved = true
                resumesPersistedMarker = true
            } else if let callbackThreshold, let expectedThreshold,
                      callbackThreshold < expectedThreshold {
                try? store.append(SpikeEvent(name: "duplicate threshold ignored", activityName: activity.rawValue, eventName: event.rawValue, runID: pendingRunID, source: "extension", creditBefore: pending.creditSeconds, creditAfter: pending.creditSeconds, selectedApplicationTokenCount: selectedTokenCount(store: store), detail: "Older cumulative callback arrived while the expected debit marker was pending"))
                return
            } else {
                persistTerminalFailClosed(store: store, expectedRunIDs: [pendingRunID], expectedActivityName: activity.rawValue)
                try? store.append(SpikeEvent(name: "overlapping threshold failed closed", activityName: activity.rawValue, eventName: event.rawValue, runID: pendingRunID, source: "extension", creditBefore: pending.creditSeconds, creditAfter: 0, selectedApplicationTokenCount: selectedTokenCount(store: store), detail: "A conflicting or future cumulative callback arrived while the previous debit marker was pending"))
                return
            }
        }

        if !resumesPersistedMarker {
            if let current = try? store.loadState(),
               current.activeActivityName == activity.rawValue,
               let runID = current.activeRunID,
               let expectedName = current.activeEventName,
               let expectedThreshold = SpikeConstants.cumulativeThresholdSeconds(eventName: expectedName, runID: runID),
               let callbackThreshold = SpikeConstants.cumulativeThresholdSeconds(eventName: event.rawValue, runID: runID),
               callbackThreshold != expectedThreshold {
                if callbackThreshold < expectedThreshold {
                    try? store.append(SpikeEvent(name: "duplicate threshold ignored", activityName: activity.rawValue, eventName: event.rawValue, runID: runID, source: "extension", creditBefore: current.creditSeconds, creditAfter: current.creditSeconds, selectedApplicationTokenCount: selectedTokenCount(store: store), detail: "Older cumulative callback arrived after state had advanced"))
                } else {
                    persistTerminalFailClosed(store: store, expectedRunIDs: [runID], expectedActivityName: activity.rawValue)
                    DeviceActivityCenter().stopMonitoring([activity])
                    try? store.append(SpikeEvent(name: "future threshold failed closed", activityName: activity.rawValue, eventName: event.rawValue, runID: runID, source: "extension", creditBefore: current.creditSeconds, creditAfter: 0, selectedApplicationTokenCount: selectedTokenCount(store: store), detail: "Expected cumulative threshold \(expectedThreshold)s but received \(callbackThreshold)s"))
                }
                return
            }

            if let current = try? store.loadState(),
               current.activeActivityName == activity.rawValue,
               current.activeEventName == event.rawValue,
               let runID = current.activeRunID,
               current.creditSeconds <= current.debitQuantumSeconds {
                do {
                    try store.enforceAndPersistFinalThresholdShieldIntent(
                        runID: runID,
                        eventName: event.rawValue
                    ) { state, snapshot in
                        try self.validateMonitoringSnapshot(snapshot, state: state)
                        try self.applyFailClosedShield(snapshot: snapshot, state: state)
                    }
                } catch {
                    persistTerminalFailClosed(store: store, expectedRunIDs: [runID], expectedActivityName: activity.rawValue)
                    try? store.append(SpikeEvent(name: "final shield intent failed closed", activityName: activity.rawValue, eventName: event.rawValue, runID: runID, source: "extension", creditBefore: current.creditSeconds, creditAfter: 0, selectedApplicationTokenCount: selectedTokenCount(store: store), detail: error.localizedDescription))
                    return
                }
            }

            do {
                _ = try store.mutateStateWithEnforcementSnapshot { state in
                        guard !state.enforcementPending,
                              !state.monitoringEnded,
                              state.activeActivityName == activity.rawValue,
                              state.activeEventName == event.rawValue,
                              let runID = state.activeRunID,
                              SpikeConstants.cumulativeThresholdSeconds(
                                eventName: event.rawValue,
                                runID: runID
                              ) != nil else { return }
                        markerRunID = runID
                        markerCredit = state.creditSeconds
                        markerWasSaved = true
                        markerWasPremature = state.isShielded
                        if markerWasPremature {
                            self.markTerminalFailure(state: &state)
                        } else {
                            state.enforcementPending = true
                            state.thresholdDebitPending = true
                            state.isShielded = false
                        }
                    }
            } catch {
                let expectedRunIDs = Set(markerRunID.map { [$0] } ?? [])
                guard shouldFailClosed(store: store, expectedRunIDs: expectedRunIDs) else {
                    try? store.append(SpikeEvent(name: "stale callback error ignored", activityName: activity.rawValue, eventName: event.rawValue, runID: markerRunID, source: "extension", creditBefore: markerCredit, creditAfter: markerCredit, selectedApplicationTokenCount: selectedTokenCount(store: store), detail: "threshold marker lost ownership: \(error.localizedDescription)"))
                    return
                }
                persistTerminalFailClosed(store: store, expectedRunIDs: expectedRunIDs, expectedActivityName: activity.rawValue)
                try? store.append(SpikeEvent(name: "threshold marker failed closed", activityName: activity.rawValue, eventName: event.rawValue, runID: markerRunID, source: "extension", creditBefore: markerCredit, creditAfter: 0, selectedApplicationTokenCount: 0, detail: error.localizedDescription))
                return
            }
        }
        guard markerWasSaved else {
            try? store.append(SpikeEvent(name: "stale callback ignored", activityName: activity.rawValue, eventName: event.rawValue, runID: markerRunID, source: "extension", creditBefore: markerCredit, creditAfter: markerCredit, selectedApplicationTokenCount: selectedTokenCount(store: store), detail: "threshold callback could not acquire the active run marker"))
            return
        }
        if markerWasPremature {
            let expectedRunIDs = Set(markerRunID.map { [$0] } ?? [])
            persistTerminalFailClosed(store: store, expectedRunIDs: expectedRunIDs, expectedActivityName: activity.rawValue)
            if let markerRunID {
                stopMonitoringRun(markerRunID)
            } else {
                DeviceActivityCenter().stopMonitoring([activity])
            }
            try? store.append(SpikeEvent(name: "premature threshold invalidated run", activityName: activity.rawValue, eventName: event.rawValue, runID: markerRunID, source: "extension", creditBefore: markerCredit, creditAfter: 0, selectedApplicationTokenCount: selectedTokenCount(store: store), detail: "matching callback arrived before physical unlock was durably confirmed"))
            return
        }
        var matchedRunID: String?
        var creditBefore = markerCredit
        var shieldWasApplied = false
        let state: SpikeState
        do {
            state = try store.mutateStateWithEnforcementSnapshot(
                beforeSave: { state, snapshot in
                    guard let runID = matchedRunID else { return }
                    try self.validateMonitoringSnapshot(snapshot, state: state)
                    shieldWasApplied = try self.applyPendingShieldBeforeSave(snapshot: snapshot, state: &state, runID: runID)
                },
                { state in
                    guard let runID = state.activeRunID,
                          state.activeActivityName == activity.rawValue,
                          state.activeEventName == event.rawValue,
                          SpikeConstants.cumulativeThresholdSeconds(eventName: event.rawValue, runID: runID) != nil else { return }
                    matchedRunID = runID
                    creditBefore = state.creditSeconds
                    SpikeReducer.apply(.thresholdReached(runID: runID, activityName: activity.rawValue, eventName: event.rawValue), to: &state)
                }
            )
        } catch {
            let expectedRunIDs = Set([markerRunID, matchedRunID].compactMap { $0 })
            guard shouldFailClosed(store: store, expectedRunIDs: expectedRunIDs) else {
                try? store.append(SpikeEvent(name: "stale callback error ignored", activityName: activity.rawValue, eventName: event.rawValue, runID: matchedRunID, source: "extension", creditBefore: creditBefore, creditAfter: creditBefore, selectedApplicationTokenCount: selectedTokenCount(store: store), detail: "threshold callback lost ownership: \(error.localizedDescription)"))
                return
            }
            persistTerminalFailClosed(store: store, expectedRunIDs: expectedRunIDs, expectedActivityName: activity.rawValue)
            try? store.append(SpikeEvent(name: "fail-closed storage recovery", activityName: activity.rawValue, eventName: event.rawValue, runID: matchedRunID ?? markerRunID, source: "extension", creditBefore: creditBefore, creditAfter: 0, selectedApplicationTokenCount: 0, detail: "threshold transaction failed; all applications shielded: \(error.localizedDescription)"))
            return
        }
        guard let runID = matchedRunID else {
            try? store.append(SpikeEvent(name: "stale callback ignored", activityName: activity.rawValue, eventName: event.rawValue, runID: state.activeRunID, source: "extension", creditBefore: state.creditSeconds, creditAfter: state.creditSeconds, selectedApplicationTokenCount: selectedTokenCount(store: store), detail: "threshold callback did not match active run"))
            return
        }
        if state.monitoringCompromised {
            stopMonitoringRun(runID)
            try? store.append(SpikeEvent(name: "premature threshold invalidated run", activityName: activity.rawValue, eventName: event.rawValue, runID: runID, source: "extension", creditBefore: creditBefore, creditAfter: state.creditSeconds, selectedApplicationTokenCount: selectedTokenCount(store: store), detail: "callback arrived before the active cumulative interval was ready; run failed closed"))
            return
        }
        guard state.creditSeconds < creditBefore else {
            let eventName = state.monitoringCompromised ? "premature threshold invalidated run" : "duplicate threshold ignored"
            try? store.append(SpikeEvent(name: eventName, activityName: activity.rawValue, eventName: event.rawValue, runID: runID, source: "extension", creditBefore: creditBefore, creditAfter: state.creditSeconds, selectedApplicationTokenCount: selectedTokenCount(store: store), detail: "callback was duplicate, out of order, or arrived before credit activation"))
            return
        }

        let logicalThreshold = SpikeConstants.cumulativeThresholdSeconds(eventName: event.rawValue, runID: runID)!
        let nextThreshold = state.activeEventName.flatMap {
            SpikeConstants.cumulativeThresholdSeconds(eventName: $0, runID: runID)
        } ?? 0
        try? store.append(SpikeEvent(name: "threshold reached", activityName: activity.rawValue, eventName: event.rawValue, runID: runID, source: "extension", creditBefore: creditBefore, creditAfter: state.creditSeconds, selectedApplicationTokenCount: selectedTokenCount(store: store), detail: "path=\(state.deductionPath.rawValue); cumulative threshold=\(logicalThreshold)s; threshold hits=\(state.thresholdReachedCount); next cumulative threshold=\(nextThreshold)s"))
        if shieldWasApplied {
            try? store.append(SpikeEvent(name: "fail-closed shield confirmed", activityName: state.activeActivityName, eventName: state.activeEventName, runID: runID, source: "extension", creditBefore: state.creditSeconds, creditAfter: state.creditSeconds, selectedApplicationTokenCount: selectedTokenCount(store: store), detail: "trigger=threshold; shield applied before state commit"))
        }
        if state.creditSeconds == 0 {
            store.clearFinalThresholdShieldIntent(runID: runID)
            if !state.isPersistentMeter || state.monitoringEnded {
                stopMonitoringRun(runID)
            }
        }
    }

    private func stopMonitoringRun(_ runID: String) {
        let prefix = "\(SpikeConstants.activityPrefix)-\(runID)"
        let center = DeviceActivityCenter()
        center.stopMonitoring(center.activities.filter { $0.rawValue.hasPrefix(prefix) })
    }

    private func selectedTokenCount(store: SpikeStateStore) -> Int {
        (try? store.loadMonitoringSelection().applicationTokens.count) ?? 0
    }

    private func validateMonitoringSnapshot(
        _ snapshot: SpikeStateStore.EnforcementSnapshot,
        state: SpikeState
    ) throws {
        guard state.enforcementMode == .managedApps else { return }
        let tokens = ManagedAppPolicy.tokenSets(from: snapshot.managedApps)
        guard tokens.isWithinManagedSettingsLimits else {
            throw ManagedAppPolicyError.managedAppTokenLimitExceeded
        }
        guard ManagedAppPolicy.matchesMonitoringSnapshot(
            records: snapshot.managedApps,
            policyVersion: snapshot.managedPolicyVersion,
            selection: snapshot.monitoringSelection,
            expectedPolicyVersion: state.monitoringPolicyVersion
        ) else {
            throw RearmError.monitoringPolicyChanged
        }
    }

    private func applyPendingShieldBeforeSave(snapshot: SpikeStateStore.EnforcementSnapshot, state: inout SpikeState, runID: String) throws -> Bool {
        guard state.enforcementPending else { return false }
        try applyFailClosedShield(snapshot: snapshot, state: state)
        SpikeReducer.apply(.enforcementApplied(runID: runID), to: &state)
        return true
    }

    private func applyFailClosedShield(snapshot: SpikeStateStore.EnforcementSnapshot, state: SpikeState) throws {
        switch state.enforcementMode {
        case .legacySelection:
            legacyStore.shield.applications = snapshot.monitoringSelection.applicationTokens
            legacyStore.shield.applicationCategories = nil
        case .managedApps:
            let tokens = ManagedAppPolicy.tokenSets(from: snapshot.managedApps)
            guard tokens.isWithinManagedSettingsLimits else {
                applyEmergencyFailClosedShield()
                throw ManagedAppPolicyError.managedAppTokenLimitExceeded
            }
            managedStore.shield.applications = tokens.zeroCreditShields.isEmpty ? nil : tokens.zeroCreditShields
            managedStore.shield.applicationCategories = .all(except: tokens.alwaysAllowed)
        }
    }

    private func applyPositiveCreditPolicy(snapshot: SpikeStateStore.EnforcementSnapshot, state: SpikeState) throws {
        switch state.enforcementMode {
        case .legacySelection:
            legacyStore.clearAllSettings()
        case .managedApps:
            let tokens = ManagedAppPolicy.tokenSets(from: snapshot.managedApps)
            guard tokens.isWithinManagedSettingsLimits else {
                applyEmergencyFailClosedShield()
                throw ManagedAppPolicyError.managedAppTokenLimitExceeded
            }
            managedStore.shield.applications = tokens.positiveCreditShields.isEmpty ? nil : tokens.positiveCreditShields
            managedStore.shield.applicationCategories = .all(except: tokens.positiveCreditExceptions)
        }
    }

    private func applyEmergencyFailClosedShield() {
        managedStore.shield.applicationCategories = .all()
        managedStore.shield.applications = nil
    }

    private func applyEmergencyFailClosedShield(for mode: EnforcementMode) {
        switch mode {
        case .managedApps:
            applyEmergencyFailClosedShield()
        case .legacySelection:
            legacyStore.shield.applicationCategories = .all()
            legacyStore.shield.applications = nil
        }
    }

    private func persistTerminalFailClosed(
        store: SpikeStateStore,
        expectedRunIDs: Set<String>,
        expectedActivityName: String
    ) {
        do {
            _ = try store.mutateStateWithEnforcementSnapshot(
                beforeSave: { state, snapshot in
                    guard state.activeActivityName == expectedActivityName,
                          let runID = state.activeRunID,
                          expectedRunIDs.isEmpty || expectedRunIDs.contains(runID) else {
                        throw RearmError.activeRunChanged
                    }
                    _ = try self.applyPendingShieldBeforeSave(
                        snapshot: snapshot,
                        state: &state,
                        runID: runID
                    )
                },
                { state in
                    guard state.activeActivityName == expectedActivityName,
                          let runID = state.activeRunID,
                          expectedRunIDs.isEmpty || expectedRunIDs.contains(runID) else {
                        throw RearmError.activeRunChanged
                    }
                    self.markTerminalFailure(state: &state)
                }
            )
        } catch {
            _ = try? store.mutateState(
                beforeSave: { state in
                    self.applyEmergencyFailClosedShield(for: state.enforcementMode)
                    state.enforcementPending = false
                    state.isShielded = true
                    state.activeRunID = nil
                    state.activeActivityName = nil
                    state.activeEventName = nil
                },
                { state in
                    guard state.activeActivityName == expectedActivityName,
                          let runID = state.activeRunID,
                          expectedRunIDs.isEmpty || expectedRunIDs.contains(runID) else {
                        throw RearmError.activeRunChanged
                    }
                    self.markTerminalFailure(state: &state)
                }
            )
        }
    }

    private func shouldFailClosed(
        store: SpikeStateStore,
        expectedRunIDs: Set<String>
    ) -> Bool {
        guard !expectedRunIDs.isEmpty else { return true }
        guard let currentState = try? store.loadState() else { return true }
        guard let activeRunID = currentState.activeRunID else { return false }
        return expectedRunIDs.contains(activeRunID)
    }

    private func markTerminalFailure(state: inout SpikeState) {
        state.creditSeconds = 0
        state.intervalDidStart = false
        state.intervalDidStartAt = nil
        state.creditWasActivated = false
        state.monitoringCompromised = true
        state.quantumRearmPending = false
        state.monitoringEnded = true
        state.enforcementPending = true
        state.thresholdDebitPending = false
        state.isShielded = false
        state.eventThresholdSeconds = 0
    }
}
