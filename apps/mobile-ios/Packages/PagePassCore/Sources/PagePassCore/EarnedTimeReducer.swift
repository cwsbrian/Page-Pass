import Foundation

public enum EarnedTimeAction: Equatable, Sendable {
    case prepareSession(id: UUID, durationSeconds: Int, startedAt: Date)
    case scheduleRegistered(id: UUID, registeredAt: Date)
    case scheduleRegistrationFailed(id: UUID)
    case beginEnding(id: UUID, endedAt: Date, reason: EarnedTimeSessionEndReason)
    case finishEnding(id: UUID)
    case settlementSynced(id: UUID)
    case settlementRejected(id: UUID)
}

public enum EarnedTimeReducerError: Error, Equatable {
    case activeSessionExists
    case durationBelowMinimum
    case insufficientBalance
    case invalidTransition
    case sessionExpiredBeforeActivation
    case expiryBeforeDeadline
}

public enum EarnedTimeReducer {
    public static func reduce(
        _ action: EarnedTimeAction,
        state: inout EarnedTimeState
    ) throws {
        switch action {
        case let .prepareSession(id, durationSeconds, startedAt):
            guard state.session == nil || [.settled, .rejected].contains(state.session?.phase) else {
                throw EarnedTimeReducerError.activeSessionExists
            }
            guard durationSeconds >= EarnedTimeSessionRules.minimumDurationSeconds else {
                throw EarnedTimeReducerError.durationBelowMinimum
            }
            guard durationSeconds <= state.balanceSeconds else {
                throw EarnedTimeReducerError.insufficientBalance
            }

            let startedAt = canonicalTimestamp(startedAt)
            state.session = EarnedTimeSession(
                id: id,
                balanceBeforeSeconds: state.balanceSeconds,
                requestedDurationSeconds: durationSeconds,
                startedAt: startedAt,
                expiresAt: startedAt.addingTimeInterval(TimeInterval(durationSeconds)),
                phase: .arming
            )

        case let .scheduleRegistered(id, registeredAt):
            guard var session = state.session,
                  session.id == id,
                  session.phase == .arming else {
                throw EarnedTimeReducerError.invalidTransition
            }
            guard registeredAt < session.expiresAt else {
                throw EarnedTimeReducerError.sessionExpiredBeforeActivation
            }
            session.phase = .active
            state.session = session

        case let .scheduleRegistrationFailed(id):
            guard state.session?.id == id,
                  let phase = state.session?.phase,
                  [.arming, .active].contains(phase) else {
                return
            }
            state.session = nil

        case let .beginEnding(id, endedAt, reason):
            guard var session = state.session,
                  session.id == id,
                  [.arming, .active].contains(session.phase) else {
                return
            }
            let endedAt = canonicalTimestamp(endedAt)
            if reason != .manualStop, endedAt < session.expiresAt {
                throw EarnedTimeReducerError.expiryBeforeDeadline
            }
            session.phase = .ending
            session.endedAt = endedAt
            session.endReason = reason
            state.session = session

        case let .finishEnding(id):
            guard var session = state.session,
                  session.id == id,
                  session.phase == .ending,
                  let endedAt = session.endedAt,
                  let reason = session.endReason else {
                return
            }

            let consumedSeconds: Int
            switch reason {
            case .manualStop:
                let elapsed = max(0, endedAt.timeIntervalSince(session.startedAt))
                consumedSeconds = min(
                    session.requestedDurationSeconds,
                    Int(ceil(elapsed))
                )
            case .expired, .recovery:
                consumedSeconds = session.requestedDurationSeconds
            }

            session.phase = .settlementPending
            session.consumedSeconds = consumedSeconds
            state.session = session
            state.balanceSeconds = max(0, session.balanceBeforeSeconds - consumedSeconds)

            let settlement = EarnedTimeSettlement(
                sessionID: session.id,
                requestedDurationSeconds: session.requestedDurationSeconds,
                balanceBeforeSeconds: session.balanceBeforeSeconds,
                startedAt: session.startedAt,
                expiresAt: session.expiresAt,
                endedAt: endedAt,
                consumedSeconds: consumedSeconds,
                endReason: reason,
                idempotencyKey: "earned-time-session:\(session.id.uuidString.lowercased())"
            )
            if !state.pendingSettlements.contains(where: { $0.sessionID == id }) {
                state.pendingSettlements.append(settlement)
            }

        case let .settlementSynced(id):
            state.pendingSettlements.removeAll { $0.sessionID == id }
            guard var session = state.session,
                  session.id == id,
                  session.phase == .settlementPending else {
                return
            }
            session.phase = .settled
            state.session = session

        case let .settlementRejected(id):
            guard var session = state.session,
                  session.id == id,
                  session.phase == .settlementPending else {
                return
            }
            session.phase = .rejected
            state.session = session
        }
    }


    private static func canonicalTimestamp(_ date: Date) -> Date {
        let milliseconds = (date.timeIntervalSince1970 * 1_000).rounded()
        return Date(timeIntervalSince1970: milliseconds / 1_000)
    }
}
