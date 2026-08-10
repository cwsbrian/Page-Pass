import Foundation
import Testing

@testable import PagePassCore

@Suite("Earned Time session reducer")
struct EarnedTimeReducerTests {
    private let start = Date(timeIntervalSince1970: 1_000)

    @Test("Requires the configured five-minute minimum")
    func rejectsShortDuration() {
        var state = EarnedTimeState(balanceSeconds: 3_600)

        #expect(throws: EarnedTimeReducerError.durationBelowMinimum) {
            try EarnedTimeReducer.reduce(
                .prepareSession(id: UUID(), durationSeconds: 299, startedAt: start),
                state: &state
            )
        }
        #expect(state.session == nil)
    }

    @Test("Reserves the selected duration while arming")
    func reservesSelectedDuration() throws {
        var state = EarnedTimeState(balanceSeconds: 3_600)
        try EarnedTimeReducer.reduce(
            .prepareSession(id: UUID(), durationSeconds: 900, startedAt: start),
            state: &state
        )

        #expect(state.balanceSeconds == 3_600)
        #expect(state.spendableBalanceSeconds == 2_700)
        #expect(state.isEarnedTimeUnlocked == false)
    }

    @Test("Unlocks only after schedule registration")
    func activatesAfterRegistration() throws {
        let id = UUID()
        var state = EarnedTimeState(balanceSeconds: 1_800)
        try EarnedTimeReducer.reduce(
            .prepareSession(id: id, durationSeconds: 900, startedAt: start),
            state: &state
        )
        try EarnedTimeReducer.reduce(
            .scheduleRegistered(id: id, registeredAt: start),
            state: &state
        )

        #expect(state.session?.phase == .active)
        #expect(state.isEarnedTimeUnlocked)
    }

    @Test("Registration failure leaves no unlockable session")
    func registrationFailureFailsClosed() throws {
        let id = UUID()
        var state = EarnedTimeState(balanceSeconds: 1_800)
        try EarnedTimeReducer.reduce(
            .prepareSession(id: id, durationSeconds: 900, startedAt: start),
            state: &state
        )
        try EarnedTimeReducer.reduce(.scheduleRegistrationFailed(id: id), state: &state)

        #expect(state.session == nil)
        #expect(state.isEarnedTimeUnlocked == false)
        #expect(state.balanceSeconds == 1_800)
    }

    @Test("Manual stop spends rounded-up elapsed seconds")
    func manualStop() throws {
        let id = UUID()
        var state = try activeState(id: id, balance: 18_000, duration: 3_600)
        try EarnedTimeReducer.reduce(
            .beginEnding(
                id: id,
                endedAt: start.addingTimeInterval(246.2),
                reason: .manualStop
            ),
            state: &state
        )
        try EarnedTimeReducer.reduce(.finishEnding(id: id), state: &state)

        #expect(state.isEarnedTimeUnlocked == false)
        #expect(state.session?.consumedSeconds == 247)
        #expect(state.balanceSeconds == 17_753)
        #expect(state.pendingSettlements.count == 1)
    }

    @Test("Fractional timestamps preserve canonical rounded usage")
    func fractionalTimestampParity() throws {
        let id = UUID()
        let fractionalStart = Date(timeIntervalSince1970: 1_000.1)
        var state = EarnedTimeState(balanceSeconds: 1_800)
        try EarnedTimeReducer.reduce(
            .prepareSession(id: id, durationSeconds: 900, startedAt: fractionalStart),
            state: &state
        )
        try EarnedTimeReducer.reduce(
            .scheduleRegistered(id: id, registeredAt: fractionalStart),
            state: &state
        )
        try EarnedTimeReducer.reduce(
            .beginEnding(
                id: id,
                endedAt: fractionalStart.addingTimeInterval(60.8),
                reason: .manualStop
            ),
            state: &state
        )
        try EarnedTimeReducer.reduce(.finishEnding(id: id), state: &state)

        #expect(state.session?.consumedSeconds == 61)
        #expect(state.pendingSettlements.first?.consumedSeconds == 61)
        #expect(
            state.pendingSettlements.first.map {
                Int(($0.startedAt.timeIntervalSince1970 * 1_000).rounded())
            } == 1_000_100
        )
        #expect(
            state.pendingSettlements.first.map {
                Int(($0.endedAt.timeIntervalSince1970 * 1_000).rounded())
            } == 1_060_900
        )
    }

    @Test("Expiry spends the selected duration")
    func expiry() throws {
        let id = UUID()
        var state = try activeState(id: id, balance: 3_600, duration: 900)
        try EarnedTimeReducer.reduce(
            .beginEnding(
                id: id,
                endedAt: start.addingTimeInterval(903),
                reason: .expired
            ),
            state: &state
        )
        try EarnedTimeReducer.reduce(.finishEnding(id: id), state: &state)

        #expect(state.session?.consumedSeconds == 900)
        #expect(state.balanceSeconds == 2_700)
    }

    @Test("Interrupted stop recovers from the persisted stop time")
    func interruptedStopRecovery() throws {
        let id = UUID()
        var state = try activeState(id: id, balance: 18_000, duration: 3_600)
        try EarnedTimeReducer.reduce(
            .beginEnding(
                id: id,
                endedAt: start.addingTimeInterval(246.2),
                reason: .manualStop
            ),
            state: &state
        )

        let data = try JSONEncoder().encode(state)
        var recovered = try JSONDecoder().decode(EarnedTimeState.self, from: data)
        try EarnedTimeReducer.reduce(.finishEnding(id: id), state: &recovered)

        #expect(recovered.session?.consumedSeconds == 247)
        #expect(recovered.balanceSeconds == 17_753)
    }

    @Test("Duplicate end callbacks cannot spend twice")
    func duplicateEndIsIdempotent() throws {
        let id = UUID()
        var state = try activeState(id: id, balance: 1_800, duration: 900)
        try EarnedTimeReducer.reduce(
            .beginEnding(
                id: id,
                endedAt: start.addingTimeInterval(900),
                reason: .expired
            ),
            state: &state
        )
        try EarnedTimeReducer.reduce(.finishEnding(id: id), state: &state)
        try EarnedTimeReducer.reduce(
            .beginEnding(
                id: id,
                endedAt: start.addingTimeInterval(901),
                reason: .expired
            ),
            state: &state
        )
        try EarnedTimeReducer.reduce(.finishEnding(id: id), state: &state)

        #expect(state.balanceSeconds == 900)
        #expect(state.pendingSettlements.count == 1)
    }

    @Test("Synced settlement clears pending work and closes the session")
    func syncedSettlementClosesSession() throws {
        let id = UUID()
        var state = try activeState(id: id, balance: 1_800, duration: 900)
        try EarnedTimeReducer.reduce(
            .beginEnding(
                id: id,
                endedAt: start.addingTimeInterval(120),
                reason: .manualStop
            ),
            state: &state
        )
        try EarnedTimeReducer.reduce(.finishEnding(id: id), state: &state)
        try EarnedTimeReducer.reduce(.settlementSynced(id: id), state: &state)

        #expect(state.session?.phase == .settled)
        #expect(state.pendingSettlements.isEmpty)
    }

    @Test("State survives Codable round trip")
    func codableRoundTrip() throws {
        let id = UUID()
        let state = try activeState(id: id, balance: 1_800, duration: 900)

        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(EarnedTimeState.self, from: data)

        #expect(decoded == state)
    }

    private func activeState(
        id: UUID,
        balance: Int,
        duration: Int
    ) throws -> EarnedTimeState {
        var state = EarnedTimeState(balanceSeconds: balance)
        try EarnedTimeReducer.reduce(
            .prepareSession(id: id, durationSeconds: duration, startedAt: start),
            state: &state
        )
        try EarnedTimeReducer.reduce(
            .scheduleRegistered(id: id, registeredAt: start),
            state: &state
        )
        return state
    }
}
