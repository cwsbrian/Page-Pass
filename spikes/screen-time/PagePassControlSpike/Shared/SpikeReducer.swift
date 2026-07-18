import Foundation

enum SpikeReducer {
    static func apply(_ action: SpikeAction, to state: inout SpikeState, now: Date = Date()) {
        switch action {
        case let .monitoringStarted(runID, activityName, eventName, deductionPath, creditGrantSeconds, thresholdSeconds):
            state.activeRunID = runID
            state.activeActivityName = activityName
            state.activeEventName = eventName
            state.creditSeconds = 0
            state.intervalDidStart = false
            state.intervalDidStartAt = nil
            state.creditWasActivated = false
            state.monitoringCompromised = false
            state.quantumRearmPending = false
            state.monitoringEnded = false
            state.enforcementPending = false
            state.thresholdDebitPending = false
            state.monitoringPolicyVersion = nil
            state.deductionPath = deductionPath
            state.creditGrantSeconds = creditGrantSeconds
            state.debitQuantumSeconds = thresholdSeconds
            state.eventThresholdSeconds = thresholdSeconds
            state.thresholdReachedCount = 0
            state.isShielded = true
            state.isPersistentMeter = false
            state.meterCapacitySeconds = 0
            state.lastReachedCumulativeThresholdSeconds = 0
            state.lastAppliedGrantSequence = 0

        case let .intervalDidStart(runID):
            guard state.activeRunID == runID else { return }
            state.intervalDidStart = true
            state.intervalDidStartAt = now

        case let .creditUnlockApplied(runID):
            guard state.activeRunID == runID,
                  state.intervalDidStart,
                  !state.quantumRearmPending,
                  !state.enforcementPending,
                  state.creditWasActivated,
                  state.creditSeconds > 0 else { return }
            state.isShielded = false

        case let .intervalDidEnd(runID):
            guard state.activeRunID == runID else { return }
            if state.wallClockSession?.sessionID == runID {
                settleWallClockSession(runID: runID, at: now, state: &state)
                return
            }
            state.creditSeconds = 0
            state.intervalDidStart = false
            state.intervalDidStartAt = nil
            state.creditWasActivated = false
            state.quantumRearmPending = false
            state.monitoringEnded = true
            state.enforcementPending = true
            state.thresholdDebitPending = false
            state.isShielded = false

        case let .wallClockSessionPrepared(runID, activityName, balanceSeconds, durationSeconds, startedAt, expiresAt):
            guard balanceSeconds > 0,
                  durationSeconds > 0,
                  durationSeconds <= balanceSeconds,
                  expiresAt > startedAt else { return }
            state.activeRunID = runID
            state.activeActivityName = activityName
            state.activeEventName = nil
            state.creditSeconds = balanceSeconds
            state.intervalDidStart = false
            state.intervalDidStartAt = nil
            state.creditWasActivated = false
            state.monitoringCompromised = false
            state.quantumRearmPending = false
            state.monitoringEnded = false
            state.enforcementPending = false
            state.thresholdDebitPending = false
            state.monitoringIntervalStart = startedAt
            state.monitoringIntervalEnd = expiresAt
            state.monitoringPolicyVersion = nil
            state.eventThresholdSeconds = 0
            state.creditGrantSeconds = 0
            state.thresholdReachedCount = 0
            state.isShielded = true
            state.isPersistentMeter = false
            state.meterCapacitySeconds = 0
            state.lastReachedCumulativeThresholdSeconds = 0
            state.lastAppliedGrantSequence = 0
            state.wallClockSession = WallClockSessionState(
                sessionID: runID,
                balanceBeforeSeconds: balanceSeconds,
                durationSeconds: durationSeconds,
                startedAt: startedAt,
                expiresAt: expiresAt,
                status: .arming,
                consumedSeconds: 0,
                endedAt: nil
            )

        case let .wallClockSessionActivated(runID, at):
            guard state.activeRunID == runID,
                  var session = state.wallClockSession,
                  session.sessionID == runID,
                  session.status == .arming,
                  at < session.expiresAt else { return }
            session.status = .active
            state.wallClockSession = session
            state.creditWasActivated = true
            state.isShielded = false

        case let .wallClockSessionStopped(runID, at):
            settleWallClockSession(runID: runID, at: at, state: &state)

        case .creditAdded:
            guard !state.creditWasActivated,
                  !state.monitoringEnded else { return }
            guard state.intervalDidStart,
                  !state.monitoringCompromised,
                  let baselineStart = state.monitoringIntervalStart ?? state.intervalDidStartAt else {
                return
            }
            let activationDelay = now.timeIntervalSince(baselineStart)
            guard activationDelay >= -1,
                  activationDelay <= Double(SpikeConstants.maximumCreditActivationDelaySeconds) else {
                state.monitoringCompromised = true
                state.enforcementPending = false
                state.thresholdDebitPending = false
                state.isShielded = true
                return
            }
            state.creditSeconds = state.creditGrantSeconds
            state.eventThresholdSeconds = threshold(for: state)
            state.creditWasActivated = true
            state.isShielded = true

        case let .persistentMeterConfigured(capacitySeconds):
            guard state.activeRunID != nil,
                  state.activeActivityName != nil,
                  state.activeEventName != nil,
                  state.deductionPath == .quantized,
                  !state.isPersistentMeter,
                  !state.monitoringEnded,
                  capacitySeconds > 0,
                  state.debitQuantumSeconds > 0 else { return }
            state.isPersistentMeter = true
            state.meterCapacitySeconds = capacitySeconds
            state.creditGrantSeconds = 0
            state.lastReachedCumulativeThresholdSeconds = 0
            state.lastAppliedGrantSequence = 0

        case let .creditGranted(sequence, seconds):
            guard state.isPersistentMeter,
                  state.activeRunID != nil,
                  state.activeActivityName != nil,
                  state.activeEventName != nil,
                  state.deductionPath == .quantized,
                  state.intervalDidStart,
                  !state.monitoringEnded,
                  !state.monitoringCompromised,
                  sequence > state.lastAppliedGrantSequence,
                  seconds > 0,
                  state.debitQuantumSeconds > 0,
                  seconds.isMultiple(of: state.debitQuantumSeconds),
                  state.lastReachedCumulativeThresholdSeconds <= state.meterCapacitySeconds,
                  state.creditSeconds <= state.meterCapacitySeconds - state.lastReachedCumulativeThresholdSeconds,
                  seconds <= state.meterCapacitySeconds
                    - state.lastReachedCumulativeThresholdSeconds
                    - state.creditSeconds else { return }
            let wasZeroCredit = state.creditSeconds == 0
            state.creditSeconds += seconds
            state.creditGrantSeconds += seconds
            state.lastAppliedGrantSequence = sequence
            state.eventThresholdSeconds = threshold(for: state)
            if wasZeroCredit {
                state.creditWasActivated = true
                state.isShielded = true
            }

        case let .thresholdReached(runID, activityName, eventName):
            guard state.activeRunID == runID,
                  !state.monitoringEnded,
                  state.activeActivityName == activityName,
                  state.activeEventName == eventName,
                  let logicalThreshold = SpikeConstants.cumulativeThresholdSeconds(
                    eventName: eventName,
                    runID: runID
                  ),
                  logicalThreshold > 0 else { return }
            state.thresholdDebitPending = false
            if state.isPersistentMeter {
                applyPersistentThreshold(
                    logicalThreshold: logicalThreshold,
                    runID: runID,
                    to: &state
                )
                return
            }
            guard state.creditWasActivated else {
                state.creditSeconds = 0
                state.monitoringCompromised = true
                state.monitoringEnded = true
                state.quantumRearmPending = false
                state.enforcementPending = true
                state.isShielded = false
                state.eventThresholdSeconds = 0
                return
            }
            guard state.intervalDidStart,
                  !state.quantumRearmPending,
                  !state.isShielded else {
                state.creditSeconds = 0
                state.monitoringCompromised = true
                state.monitoringEnded = true
                state.quantumRearmPending = false
                state.enforcementPending = true
                state.isShielded = false
                state.eventThresholdSeconds = 0
                return
            }
            let debit = state.deductionPath == .quantized
                ? min(state.debitQuantumSeconds, state.creditSeconds)
                : state.creditSeconds
            state.creditSeconds -= debit
            state.thresholdReachedCount += 1
            state.eventThresholdSeconds = threshold(for: state)
            state.monitoringEnded = state.creditSeconds == 0
            state.quantumRearmPending = false
            state.enforcementPending = state.creditSeconds == 0
            state.thresholdDebitPending = false
            state.isShielded = false
            if state.creditSeconds > 0 {
                let consumedCredit = state.creditGrantSeconds - state.creditSeconds
                let nextDebit = min(state.debitQuantumSeconds, state.creditSeconds)
                state.activeEventName = SpikeConstants.eventName(
                    for: runID,
                    cumulativeThresholdSeconds: consumedCredit + nextDebit
                )
            }

        case let .enforcementApplied(runID):
            guard state.activeRunID == runID, state.enforcementPending else { return }
            state.enforcementPending = false
            state.thresholdDebitPending = false
            state.isShielded = true
            if state.isPersistentMeter,
               state.creditSeconds == 0,
               !state.monitoringEnded,
               state.lastReachedCumulativeThresholdSeconds < state.meterCapacitySeconds {
                return
            }
            if state.creditSeconds == 0 || state.monitoringEnded {
                state.activeRunID = nil
                state.activeActivityName = nil
                state.activeEventName = nil
                state.eventThresholdSeconds = 0
            }

        case .creditConsumed:
            state.creditSeconds = 0
            state.enforcementPending = true
            state.thresholdDebitPending = false
            state.isShielded = false

        case .cleanupReset:
            state = SpikeState(creditSeconds: 0, isShielded: false)
        }
    }

    private static func threshold(for state: SpikeState) -> Int {
        switch state.deductionPath {
        case .quantized:
            return min(state.creditSeconds, state.debitQuantumSeconds)
        case .singleThresholdFallback:
            return state.creditSeconds
        }
    }

    private static func settleWallClockSession(runID: String, at: Date, state: inout SpikeState) {
        guard state.activeRunID == runID,
              var session = state.wallClockSession,
              session.sessionID == runID,
              session.status == .active else { return }
        let elapsed = max(0, at.timeIntervalSince(session.startedAt))
        let roundedElapsed = Int(ceil(elapsed))
        let consumed = min(session.durationSeconds, roundedElapsed)
        session.status = .ended
        session.consumedSeconds = consumed
        session.endedAt = at
        state.wallClockSession = session
        state.creditSeconds = max(0, session.balanceBeforeSeconds - consumed)
        state.intervalDidStart = false
        state.intervalDidStartAt = nil
        state.creditWasActivated = false
        state.monitoringEnded = true
        state.enforcementPending = true
        state.thresholdDebitPending = false
        state.isShielded = false
    }

    private static func applyPersistentThreshold(
        logicalThreshold: Int,
        runID: String,
        to state: inout SpikeState
    ) {
        guard state.creditWasActivated else {
            failClosedPersistentMeter(&state)
            return
        }
        guard state.intervalDidStart,
              !state.quantumRearmPending,
              !state.isShielded,
              state.debitQuantumSeconds > 0,
              state.creditSeconds >= state.debitQuantumSeconds,
              state.lastReachedCumulativeThresholdSeconds <= state.meterCapacitySeconds,
              state.debitQuantumSeconds <= state.meterCapacitySeconds
                - state.lastReachedCumulativeThresholdSeconds,
              logicalThreshold == state.lastReachedCumulativeThresholdSeconds + state.debitQuantumSeconds,
              logicalThreshold <= state.meterCapacitySeconds else {
            failClosedPersistentMeter(&state)
            return
        }

        state.creditSeconds -= state.debitQuantumSeconds
        state.lastReachedCumulativeThresholdSeconds = logicalThreshold
        state.thresholdReachedCount += 1
        state.eventThresholdSeconds = threshold(for: state)
        state.quantumRearmPending = false
        state.thresholdDebitPending = false
        state.isShielded = false

        let hasNextThreshold = state.debitQuantumSeconds
            <= state.meterCapacitySeconds - logicalThreshold
        if !hasNextThreshold {
            state.creditSeconds = 0
            state.creditWasActivated = false
            state.monitoringEnded = true
            state.enforcementPending = true
            return
        }

        state.activeEventName = SpikeConstants.eventName(
            for: runID,
            cumulativeThresholdSeconds: logicalThreshold + state.debitQuantumSeconds
        )
        state.monitoringEnded = false
        state.enforcementPending = state.creditSeconds == 0
        if state.creditSeconds == 0 {
            state.creditWasActivated = false
        }
    }

    private static func failClosedPersistentMeter(_ state: inout SpikeState) {
        state.creditSeconds = 0
        state.creditWasActivated = false
        state.monitoringCompromised = true
        state.monitoringEnded = true
        state.quantumRearmPending = false
        state.enforcementPending = true
        state.isShielded = false
        state.eventThresholdSeconds = 0
    }

    static func isRecoverableThresholdDebit(_ state: SpikeState) -> Bool {
        state.thresholdDebitPending
            && state.enforcementPending
            && state.creditWasActivated
            && state.creditSeconds > 0
            && state.intervalDidStart
            && !state.quantumRearmPending
            && !state.monitoringEnded
            && state.activeRunID != nil
            && state.activeActivityName != nil
            && state.activeEventName != nil
    }

    static func requiresMissingInitialMonitorRecovery(
        _ state: SpikeState,
        monitoredActivityNames: Set<String>
    ) -> Bool {
        guard state.activeRunID != nil,
              let activityName = state.activeActivityName,
              !state.enforcementPending,
              !state.quantumRearmPending,
              !state.monitoringEnded else {
            return false
        }
        return !monitoredActivityNames.contains(activityName)
    }

}
