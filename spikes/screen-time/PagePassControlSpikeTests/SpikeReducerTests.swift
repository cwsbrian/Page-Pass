import DeviceActivity
import FamilyControls
import ManagedSettings
import XCTest
@testable import PagePassControlSpike

final class SpikeReducerTests: XCTestCase {
    func testWallClockScheduleRejectsDurationBelowDeviceActivityMinimum() {
        XCTAssertThrowsError(
            try ActivityMonitorService().prepareWallClockSession(
                runID: "short-session",
                durationSeconds: SpikeConstants.minimumWallClockSessionSeconds - 1
            )
        )
    }

    func testWallClockScheduleAcceptsDeviceActivityMinimum() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let session = try ActivityMonitorService().prepareWallClockSession(
            runID: "minimum-session",
            durationSeconds: SpikeConstants.minimumWallClockSessionSeconds,
            now: now
        )

        XCTAssertEqual(
            session.intervalEnd.timeIntervalSince(session.intervalStart),
            Double(SpikeConstants.minimumWallClockSessionSeconds),
            accuracy: 0.001
        )
    }

    func testZeroCreditMarksEnforcementPendingUntilShieldConfirmation() {
        var state = SpikeState()
        SpikeReducer.apply(.creditConsumed, to: &state)
        XCTAssertEqual(state.creditSeconds, 0)
        XCTAssertTrue(state.enforcementPending)
        XCTAssertFalse(state.isShielded)
    }

    func testIntervalMustStartBeforeCreditAndUnlockRequiresConfirmation() {
        var state = SpikeState()
        SpikeReducer.apply(.monitoringStarted(runID: "run-1", activityName: "PagePassCreditRun-run-1", eventName: eventName("run-1", 60), deductionPath: .singleThresholdFallback, creditGrantSeconds: 60, thresholdSeconds: 60), to: &state)
        SpikeReducer.apply(.creditAdded, to: &state)
        XCTAssertEqual(state.creditSeconds, 0)
        XCTAssertTrue(state.isShielded)

        SpikeReducer.apply(.intervalDidStart(runID: "run-1"), to: &state)
        SpikeReducer.apply(.creditAdded, to: &state)
        XCTAssertEqual(state.creditSeconds, 60)
        XCTAssertTrue(state.isShielded)
        SpikeReducer.apply(.creditUnlockApplied(runID: "run-1"), to: &state)
        XCTAssertFalse(state.isShielded)
    }

    func testCreditActivationRejectsAStalePreCreditBaseline() {
        let intervalStart = Date(timeIntervalSince1970: 100)
        var state = SpikeState()
        SpikeReducer.apply(.monitoringStarted(runID: "run-1", activityName: "PagePassCreditRun-run-1", eventName: eventName("run-1", 60), deductionPath: .singleThresholdFallback, creditGrantSeconds: 60, thresholdSeconds: 60), to: &state, now: intervalStart)
        state.monitoringIntervalStart = intervalStart
        SpikeReducer.apply(.intervalDidStart(runID: "run-1"), to: &state, now: intervalStart)

        SpikeReducer.apply(
            .creditAdded,
            to: &state,
            now: intervalStart.addingTimeInterval(
                Double(SpikeConstants.maximumCreditActivationDelaySeconds + 1)
            )
        )

        XCTAssertTrue(state.monitoringCompromised)
        XCTAssertFalse(state.creditWasActivated)
        XCTAssertEqual(state.creditSeconds, 0)
        XCTAssertTrue(state.isShielded)
    }

    func testCreditActivationWithinBaselineWindowSucceeds() {
        let intervalStart = Date(timeIntervalSince1970: 100)
        var state = SpikeState()
        SpikeReducer.apply(.monitoringStarted(runID: "run-1", activityName: "PagePassCreditRun-run-1", eventName: eventName("run-1", 60), deductionPath: .singleThresholdFallback, creditGrantSeconds: 60, thresholdSeconds: 60), to: &state, now: intervalStart)
        state.monitoringIntervalStart = intervalStart
        SpikeReducer.apply(.intervalDidStart(runID: "run-1"), to: &state, now: intervalStart)

        SpikeReducer.apply(
            .creditAdded,
            to: &state,
            now: intervalStart.addingTimeInterval(
                Double(SpikeConstants.maximumCreditActivationDelaySeconds)
            )
        )

        XCTAssertFalse(state.monitoringCompromised)
        XCTAssertTrue(state.creditWasActivated)
        XCTAssertEqual(state.creditSeconds, 60)
        XCTAssertTrue(state.isShielded)
        SpikeReducer.apply(.creditUnlockApplied(runID: "run-1"), to: &state)
        XCTAssertFalse(state.isShielded)
    }

    func testStaleCallbackDoesNotMutateState() {
        var state = SpikeState()
        SpikeReducer.apply(.monitoringStarted(runID: "run-1", activityName: "PagePassCreditRun-run-1", eventName: eventName("run-1", 60), deductionPath: .singleThresholdFallback, creditGrantSeconds: 60, thresholdSeconds: 60), to: &state)
        SpikeReducer.apply(.intervalDidStart(runID: "run-1"), to: &state)
        SpikeReducer.apply(.creditAdded, to: &state)
        SpikeReducer.apply(.creditUnlockApplied(runID: "run-1"), to: &state)

        SpikeReducer.apply(.thresholdReached(runID: "old-run", activityName: "PagePassCreditRun-old-run", eventName: eventName("old-run", 60)), to: &state)

        XCTAssertEqual(state.creditSeconds, 60)
        XCTAssertFalse(state.isShielded)
    }

    func testCreditUnlockRejectsAStaleRun() {
        var state = SpikeState()
        SpikeReducer.apply(.monitoringStarted(runID: "run-1", activityName: "PagePassCreditRun-run-1", eventName: eventName("run-1", 60), deductionPath: .singleThresholdFallback, creditGrantSeconds: 60, thresholdSeconds: 60), to: &state)
        SpikeReducer.apply(.intervalDidStart(runID: "run-1"), to: &state)
        SpikeReducer.apply(.creditAdded, to: &state)

        SpikeReducer.apply(.creditUnlockApplied(runID: "old-run"), to: &state)

        XCTAssertEqual(state.creditSeconds, 60)
        XCTAssertTrue(state.isShielded)
    }

    func testThresholdBeforePhysicalUnlockFailsClosedWithoutDebitAccounting() {
        var state = SpikeState()
        SpikeReducer.apply(.monitoringStarted(runID: "run-1", activityName: "PagePassCreditRun-run-1", eventName: eventName("run-1", 60), deductionPath: .quantized, creditGrantSeconds: 120, thresholdSeconds: 60), to: &state)
        SpikeReducer.apply(.intervalDidStart(runID: "run-1"), to: &state)
        SpikeReducer.apply(.creditAdded, to: &state)

        SpikeReducer.apply(.thresholdReached(runID: "run-1", activityName: "PagePassCreditRun-run-1", eventName: eventName("run-1", 60)), to: &state)

        XCTAssertEqual(state.creditSeconds, 0)
        XCTAssertEqual(state.thresholdReachedCount, 0)
        XCTAssertTrue(state.monitoringCompromised)
        XCTAssertTrue(state.monitoringEnded)
        XCTAssertTrue(state.enforcementPending)
    }

    func testMatchingThresholdConsumesCreditAndLocks() {
        var state = SpikeState()
        SpikeReducer.apply(.monitoringStarted(runID: "run-1", activityName: "PagePassCreditRun-run-1", eventName: eventName("run-1", 60), deductionPath: .singleThresholdFallback, creditGrantSeconds: 60, thresholdSeconds: 60), to: &state)
        SpikeReducer.apply(.intervalDidStart(runID: "run-1"), to: &state)
        SpikeReducer.apply(.creditAdded, to: &state)
        SpikeReducer.apply(.creditUnlockApplied(runID: "run-1"), to: &state)

        SpikeReducer.apply(.thresholdReached(runID: "run-1", activityName: "PagePassCreditRun-run-1", eventName: eventName("run-1", 60)), to: &state)

        XCTAssertEqual(state.creditSeconds, 0)
        XCTAssertTrue(state.enforcementPending)
        XCTAssertFalse(state.isShielded)
        SpikeReducer.apply(.enforcementApplied(runID: "run-1"), to: &state)
        XCTAssertTrue(state.isShielded)
        XCTAssertFalse(state.enforcementPending)
    }

    func testCleanupOverrideUnlocksOnlyForCleanup() {
        var state = SpikeState(creditSeconds: 0, isShielded: true)
        SpikeReducer.apply(.cleanupReset, to: &state)
        XCTAssertEqual(state.creditSeconds, 0)
        XCTAssertFalse(state.isShielded)
        XCTAssertNil(state.activeRunID)
    }

    func testQuantizedThresholdAdvancesToNextCumulativeEventWithoutShielding() {
        var state = SpikeState()
        SpikeReducer.apply(.monitoringStarted(runID: "run-1", activityName: "PagePassCreditRun-run-1", eventName: eventName("run-1", 60), deductionPath: .quantized, creditGrantSeconds: 120, thresholdSeconds: 60), to: &state)
        SpikeReducer.apply(.intervalDidStart(runID: "run-1"), to: &state)
        SpikeReducer.apply(.creditAdded, to: &state)
        SpikeReducer.apply(.creditUnlockApplied(runID: "run-1"), to: &state)

        SpikeReducer.apply(.thresholdReached(runID: "run-1", activityName: "PagePassCreditRun-run-1", eventName: eventName("run-1", 60)), to: &state)

        XCTAssertEqual(state.creditSeconds, 60)
        XCTAssertFalse(state.isShielded)
        XCTAssertFalse(state.enforcementPending)
        XCTAssertEqual(state.thresholdReachedCount, 1)
        XCTAssertEqual(state.eventThresholdSeconds, 60)
        XCTAssertEqual(state.activeEventName, eventName("run-1", 120))
        XCTAssertFalse(state.quantumRearmPending)
    }

    func testMonitoringStartPersistsCustomDebitQuantum() {
        var state = SpikeState(thresholdReachedCount: 7)
        SpikeReducer.apply(.monitoringStarted(runID: "run-1", activityName: "PagePassCreditRun-run-1", eventName: eventName("run-1", 3_600), deductionPath: .quantized, creditGrantSeconds: 3_600, thresholdSeconds: 900), to: &state)
        SpikeReducer.apply(.intervalDidStart(runID: "run-1"), to: &state)
        SpikeReducer.apply(.creditAdded, to: &state)

        XCTAssertEqual(state.creditSeconds, 3_600)
        XCTAssertEqual(state.debitQuantumSeconds, 900)
        XCTAssertEqual(state.eventThresholdSeconds, 900)
        XCTAssertEqual(state.thresholdReachedCount, 0)
    }

    func testDeviceActivityThresholdAddsOneRunLevelGracePeriod() {
        XCTAssertEqual(SpikeConstants.deviceActivityThresholdSeconds(for: 900), 960)
        XCTAssertEqual(SpikeConstants.deviceActivityThresholdSeconds(for: 3_600), 3_660)
    }

    func testQuantizedRunRegistersAllCumulativeThresholdsBeforeMonitoring() throws {
        let earnedToken = try applicationToken(seed: 31)
        let runID = "cumulative-run"
        let run = try ActivityMonitorService().prepareRun(
            runID: runID,
            selection: ManagedAppPolicy.monitoringSelection(from: [earnedToken]),
            creditGrantSeconds: 1_800,
            debitQuantumSeconds: 900,
            deductionPath: .quantized
        )

        XCTAssertEqual(run.events.count, 2)
        XCTAssertEqual(run.logicalThresholds, [900, 1_800])
        XCTAssertEqual(run.logicalThresholdSeconds, 900)
        let first = try XCTUnwrap(run.events[DeviceActivityEvent.Name(eventName(runID, 900))])
        let second = try XCTUnwrap(run.events[DeviceActivityEvent.Name(eventName(runID, 1_800))])
        XCTAssertEqual(first.applications, [earnedToken])
        XCTAssertEqual(first.threshold.hour, 0)
        XCTAssertEqual(first.threshold.minute, 16)
        XCTAssertEqual(first.threshold.second, 0)
        XCTAssertEqual(second.threshold.hour, 0)
        XCTAssertEqual(second.threshold.minute, 31)
        XCTAssertEqual(second.threshold.second, 0)
        XCTAssertFalse(first.includesPastActivity)
        XCTAssertFalse(second.includesPastActivity)
        XCTAssertFalse(first.includesAllActivity)
        XCTAssertEqual(run.eventConfigurationDescription, "applications=1; categories=0; web domains=0; includesAllActivity=false; threshold=0h16m0s")
    }

    func testCumulativeRunAddsOneRunLevelGraceToEveryAbsoluteThreshold() throws {
        let earnedToken = try applicationToken(seed: 32)
        let run = try ActivityMonitorService().prepareRun(
            runID: "rearmed-run",
            selection: ManagedAppPolicy.monitoringSelection(from: [earnedToken]),
            includesMeasurementGrace: true,
            creditGrantSeconds: 900,
            debitQuantumSeconds: 900,
            deductionPath: .quantized
        )

        let event = try XCTUnwrap(run.events[run.finalEventName])
        XCTAssertEqual(event.threshold.hour, 0)
        XCTAssertEqual(event.threshold.minute, 16)
        XCTAssertEqual(event.threshold.second, 0)
        XCTAssertFalse(event.includesPastActivity)
    }

    func testExactDiagnosticRunDoesNotAddMeasurementGrace() throws {
        let earnedToken = try applicationToken(seed: 33)
        let run = try ActivityMonitorService().prepareRun(
            runID: "exact-diagnostic-run",
            selection: ManagedAppPolicy.monitoringSelection(from: [earnedToken]),
            includesMeasurementGrace: false,
            creditGrantSeconds: 600,
            debitQuantumSeconds: 600,
            deductionPath: .singleThresholdFallback
        )

        let event = try XCTUnwrap(run.events[run.finalEventName])
        XCTAssertEqual(event.threshold.hour, 0)
        XCTAssertEqual(event.threshold.minute, 10)
        XCTAssertEqual(event.threshold.second, 0)
        XCTAssertEqual(
            run.eventConfigurationDescription,
            "applications=1; categories=0; web domains=0; includesAllActivity=false; threshold=0h10m0s"
        )
    }

    func testIntermediateCumulativeThresholdKeepsTheSameUnlockedRun() {
        var state = SpikeState()
        SpikeReducer.apply(.monitoringStarted(runID: "run-1", activityName: "PagePassCreditRun-run-1", eventName: eventName("run-1", 60), deductionPath: .quantized, creditGrantSeconds: 120, thresholdSeconds: 60), to: &state)
        SpikeReducer.apply(.intervalDidStart(runID: "run-1"), to: &state)
        SpikeReducer.apply(.creditAdded, to: &state)
        SpikeReducer.apply(.creditUnlockApplied(runID: "run-1"), to: &state)
        SpikeReducer.apply(.thresholdReached(runID: "run-1", activityName: "PagePassCreditRun-run-1", eventName: eventName("run-1", 60)), to: &state)

        XCTAssertEqual(state.creditSeconds, 60)
        XCTAssertFalse(state.enforcementPending)
        XCTAssertFalse(state.quantumRearmPending)
        XCTAssertFalse(state.isShielded)
        XCTAssertEqual(state.activeRunID, "run-1")
        XCTAssertEqual(state.activeEventName, eventName("run-1", 120))
        XCTAssertEqual(state.thresholdReachedCount, 1)
    }

    func testOneShotScheduleKeepsAbsoluteDatesAcrossMidnight() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "America/Vancouver"))
        let now = try XCTUnwrap(
            calendar.date(from: DateComponents(
                year: 2026,
                month: 7,
                day: 15,
                hour: 22,
                minute: 30
            ))
        )

        let run = try ActivityMonitorService().prepareRun(
            runID: "midnight-run",
            selection: FamilyActivitySelection(),
            creditGrantSeconds: 1_800,
            debitQuantumSeconds: 900,
            deductionPath: .quantized,
            now: now,
            calendar: calendar
        )

        XCTAssertEqual(run.schedule.intervalStart.year, 2026)
        XCTAssertEqual(run.schedule.intervalStart.month, 7)
        XCTAssertEqual(run.schedule.intervalStart.day, 15)
        XCTAssertEqual(run.schedule.intervalEnd.year, 2026)
        XCTAssertEqual(run.schedule.intervalEnd.month, 7)
        XCTAssertEqual(run.schedule.intervalEnd.day, 16)
        XCTAssertEqual(run.schedule.intervalStart.timeZone, calendar.timeZone)
        XCTAssertEqual(run.schedule.intervalEnd.timeZone, calendar.timeZone)
        XCTAssertNil(run.schedule.intervalStart.nanosecond)
        XCTAssertNil(run.schedule.intervalEnd.nanosecond)
        XCTAssertNil(run.schedule.intervalStart.weekday)
        XCTAssertNil(run.schedule.intervalEnd.weekday)
    }

    func testSecondCumulativeThresholdLocksAtZero() {
        var state = SpikeState()
        SpikeReducer.apply(.monitoringStarted(runID: "run-1", activityName: "PagePassCreditRun-run-1", eventName: eventName("run-1", 60), deductionPath: .quantized, creditGrantSeconds: 120, thresholdSeconds: 60), to: &state)
        SpikeReducer.apply(.intervalDidStart(runID: "run-1"), to: &state)
        SpikeReducer.apply(.creditAdded, to: &state)
        SpikeReducer.apply(.creditUnlockApplied(runID: "run-1"), to: &state)
        SpikeReducer.apply(.thresholdReached(runID: "run-1", activityName: "PagePassCreditRun-run-1", eventName: eventName("run-1", 60)), to: &state)
        SpikeReducer.apply(.thresholdReached(runID: "run-1", activityName: "PagePassCreditRun-run-1", eventName: eventName("run-1", 120)), to: &state)

        XCTAssertEqual(state.creditSeconds, 0)
        XCTAssertTrue(state.enforcementPending)
        SpikeReducer.apply(.enforcementApplied(runID: "run-1"), to: &state)
        XCTAssertTrue(state.isShielded)
        XCTAssertEqual(state.thresholdReachedCount, 2)
    }

    func testPersistentMeterConsumesTwoGrantsWithoutReplacingRun() {
        var state = persistentMeterState(capacitySeconds: 1_800, quantumSeconds: 600)

        SpikeReducer.apply(.creditGranted(sequence: 1, seconds: 600), to: &state)
        SpikeReducer.apply(.creditUnlockApplied(runID: "run-1"), to: &state)
        SpikeReducer.apply(.thresholdReached(runID: "run-1", activityName: "PagePassCreditRun-run-1", eventName: eventName("run-1", 600)), to: &state)
        SpikeReducer.apply(.enforcementApplied(runID: "run-1"), to: &state)

        XCTAssertEqual(state.creditSeconds, 0)
        XCTAssertEqual(state.activeRunID, "run-1")
        XCTAssertEqual(state.activeActivityName, "PagePassCreditRun-run-1")
        XCTAssertEqual(state.activeEventName, eventName("run-1", 1_200))
        XCTAssertEqual(state.lastReachedCumulativeThresholdSeconds, 600)
        XCTAssertFalse(state.monitoringEnded)
        XCTAssertTrue(state.isShielded)

        SpikeReducer.apply(.creditGranted(sequence: 2, seconds: 600), to: &state)
        SpikeReducer.apply(.creditUnlockApplied(runID: "run-1"), to: &state)
        SpikeReducer.apply(.thresholdReached(runID: "run-1", activityName: "PagePassCreditRun-run-1", eventName: eventName("run-1", 1_200)), to: &state)
        SpikeReducer.apply(.enforcementApplied(runID: "run-1"), to: &state)

        XCTAssertEqual(state.creditSeconds, 0)
        XCTAssertEqual(state.creditGrantSeconds, 1_200)
        XCTAssertEqual(state.lastAppliedGrantSequence, 2)
        XCTAssertEqual(state.lastReachedCumulativeThresholdSeconds, 1_200)
        XCTAssertEqual(state.activeRunID, "run-1")
        XCTAssertEqual(state.activeEventName, eventName("run-1", 1_800))
        XCTAssertFalse(state.monitoringEnded)
        XCTAssertTrue(state.isShielded)
    }

    func testPersistentMeterIgnoresDuplicateGrantSequence() {
        var state = persistentMeterState(capacitySeconds: 1_800, quantumSeconds: 600)
        SpikeReducer.apply(.creditGranted(sequence: 1, seconds: 600), to: &state)

        SpikeReducer.apply(.creditGranted(sequence: 1, seconds: 600), to: &state)

        XCTAssertEqual(state.creditSeconds, 600)
        XCTAssertEqual(state.creditGrantSeconds, 600)
        XCTAssertEqual(state.lastAppliedGrantSequence, 1)
    }

    func testPersistentMeterTopUpKeepsPositiveUnlockedBalance() {
        var state = persistentMeterState(capacitySeconds: 1_800, quantumSeconds: 600)
        SpikeReducer.apply(.creditGranted(sequence: 1, seconds: 600), to: &state)
        SpikeReducer.apply(.creditUnlockApplied(runID: "run-1"), to: &state)
        XCTAssertFalse(state.isShielded)

        SpikeReducer.apply(.creditGranted(sequence: 2, seconds: 600), to: &state)

        XCTAssertEqual(state.creditSeconds, 1_200)
        XCTAssertEqual(state.creditGrantSeconds, 1_200)
        XCTAssertFalse(state.isShielded)
        XCTAssertTrue(state.creditWasActivated)
    }

    func testPersistentMeterRejectsGrantBeyondRemainingCapacity() {
        var state = persistentMeterState(capacitySeconds: 1_200, quantumSeconds: 600)
        SpikeReducer.apply(.creditGranted(sequence: 1, seconds: 1_200), to: &state)

        SpikeReducer.apply(.creditGranted(sequence: 2, seconds: 600), to: &state)

        XCTAssertEqual(state.creditSeconds, 1_200)
        XCTAssertEqual(state.creditGrantSeconds, 1_200)
        XCTAssertEqual(state.lastAppliedGrantSequence, 1)
    }

    func testNonPersistentMeterStillTerminatesAndClearsOwnershipAtZero() {
        var state = SpikeState()
        SpikeReducer.apply(.monitoringStarted(runID: "run-1", activityName: "PagePassCreditRun-run-1", eventName: eventName("run-1", 600), deductionPath: .quantized, creditGrantSeconds: 600, thresholdSeconds: 600), to: &state)
        SpikeReducer.apply(.intervalDidStart(runID: "run-1"), to: &state)
        SpikeReducer.apply(.creditAdded, to: &state)
        SpikeReducer.apply(.creditUnlockApplied(runID: "run-1"), to: &state)
        SpikeReducer.apply(.thresholdReached(runID: "run-1", activityName: "PagePassCreditRun-run-1", eventName: eventName("run-1", 600)), to: &state)
        SpikeReducer.apply(.enforcementApplied(runID: "run-1"), to: &state)

        XCTAssertFalse(state.isPersistentMeter)
        XCTAssertTrue(state.monitoringEnded)
        XCTAssertTrue(state.isShielded)
        XCTAssertNil(state.activeRunID)
        XCTAssertNil(state.activeActivityName)
        XCTAssertNil(state.activeEventName)
    }

    func testFutureCumulativeThresholdDoesNotMutateReducerState() {
        var state = SpikeState()
        SpikeReducer.apply(.monitoringStarted(runID: "run-1", activityName: "PagePassCreditRun-run-1", eventName: eventName("run-1", 60), deductionPath: .quantized, creditGrantSeconds: 120, thresholdSeconds: 60), to: &state)
        SpikeReducer.apply(.intervalDidStart(runID: "run-1"), to: &state)
        SpikeReducer.apply(.creditAdded, to: &state)
        SpikeReducer.apply(.creditUnlockApplied(runID: "run-1"), to: &state)
        SpikeReducer.apply(.thresholdReached(runID: "run-1", activityName: "PagePassCreditRun-run-1", eventName: eventName("run-1", 120)), to: &state)

        XCTAssertEqual(state.creditSeconds, 120)
        XCTAssertFalse(state.monitoringCompromised)
        XCTAssertFalse(state.monitoringEnded)
        XCTAssertFalse(state.enforcementPending)
        XCTAssertFalse(state.isPersistentMeter)
        XCTAssertEqual(state.meterCapacitySeconds, 0)
        XCTAssertEqual(state.lastReachedCumulativeThresholdSeconds, 0)
        XCTAssertEqual(state.lastAppliedGrantSequence, 0)
        XCTAssertFalse(state.isShielded)
        XCTAssertEqual(state.thresholdReachedCount, 0)
        XCTAssertEqual(state.activeEventName, eventName("run-1", 60))
    }

    func testMissingActivatedCumulativeMonitorRequiresFailClosedRecovery() {
        var state = SpikeState()
        SpikeReducer.apply(.monitoringStarted(runID: "run-1", activityName: "PagePassCreditRun-run-1", eventName: eventName("run-1", 60), deductionPath: .quantized, creditGrantSeconds: 120, thresholdSeconds: 60), to: &state)
        SpikeReducer.apply(.intervalDidStart(runID: "run-1"), to: &state)
        SpikeReducer.apply(.creditAdded, to: &state)
        SpikeReducer.apply(.creditUnlockApplied(runID: "run-1"), to: &state)

        XCTAssertTrue(SpikeReducer.requiresMissingInitialMonitorRecovery(
            state,
            monitoredActivityNames: []
        ))
    }

    func testCumulativeConfigurationIsBoundedAndOverflowSafe() {
        XCTAssertTrue(SpikeConstants.isValidCumulativeConfiguration(
            creditGrantSeconds: 14_400,
            debitQuantumSeconds: 60,
            deductionPath: .quantized
        ))
        XCTAssertFalse(SpikeConstants.isValidCumulativeConfiguration(
            creditGrantSeconds: 14_460,
            debitQuantumSeconds: 60,
            deductionPath: .quantized
        ))
        XCTAssertFalse(SpikeConstants.isValidCumulativeConfiguration(
            creditGrantSeconds: Int.max,
            debitQuantumSeconds: 1,
            deductionPath: .quantized
        ))
        XCTAssertFalse(SpikeConstants.isValidCumulativeConfiguration(
            creditGrantSeconds: SpikeConstants.maximumCreditGrantSeconds + 1,
            debitQuantumSeconds: SpikeConstants.maximumCreditGrantSeconds + 1,
            deductionPath: .singleThresholdFallback
        ))
    }

    func testReplacementGenerationRejectsDelayedOldCallback() {
        var state = SpikeState()
        SpikeReducer.apply(.monitoringStarted(runID: "run-1", activityName: "PagePassCreditRun-run-1", eventName: eventName("run-1", 60), deductionPath: .quantized, creditGrantSeconds: 120, thresholdSeconds: 60), to: &state)
        SpikeReducer.apply(.intervalDidStart(runID: "run-1"), to: &state)
        SpikeReducer.apply(.creditAdded, to: &state)
        SpikeReducer.apply(.creditUnlockApplied(runID: "run-1"), to: &state)
        SpikeReducer.apply(.monitoringStarted(runID: "run-2", activityName: "PagePassCreditRun-run-2", eventName: eventName("run-2", 60), deductionPath: .quantized, creditGrantSeconds: 60, thresholdSeconds: 60), to: &state)
        SpikeReducer.apply(.intervalDidStart(runID: "run-2"), to: &state)
        SpikeReducer.apply(.creditAdded, to: &state)
        SpikeReducer.apply(.creditUnlockApplied(runID: "run-2"), to: &state)
        SpikeReducer.apply(.thresholdReached(runID: "run-1", activityName: "PagePassCreditRun-run-1", eventName: eventName("run-1", 60)), to: &state)

        XCTAssertEqual(state.activeRunID, "run-2")
        XCTAssertEqual(state.creditSeconds, 60)
        XCTAssertFalse(state.isShielded)
        XCTAssertEqual(state.thresholdReachedCount, 0)
    }

    func testPersistedThresholdMarkerRecoversExactlyOneQuantum() {
        var state = SpikeState()
        SpikeReducer.apply(.monitoringStarted(runID: "run-1", activityName: "PagePassCreditRun-run-1", eventName: eventName("run-1", 60), deductionPath: .quantized, creditGrantSeconds: 180, thresholdSeconds: 60), to: &state)
        SpikeReducer.apply(.intervalDidStart(runID: "run-1"), to: &state)
        SpikeReducer.apply(.creditAdded, to: &state)
        SpikeReducer.apply(.creditUnlockApplied(runID: "run-1"), to: &state)
        state.enforcementPending = true
        state.thresholdDebitPending = true
        state.isShielded = false

        XCTAssertTrue(SpikeReducer.isRecoverableThresholdDebit(state))
        SpikeReducer.apply(.thresholdReached(runID: "run-1", activityName: "PagePassCreditRun-run-1", eventName: eventName("run-1", 60)), to: &state)

        XCTAssertEqual(state.creditSeconds, 120)
        XCTAssertEqual(state.thresholdReachedCount, 1)
        XCTAssertFalse(state.thresholdDebitPending)
        XCTAssertFalse(state.enforcementPending)
        XCTAssertEqual(state.activeEventName, eventName("run-1", 120))
    }

    func testThresholdMarkerSurvivesFailureAfterPhysicalShieldSideEffect() throws {
        let suite = "SpikeStateStoreThresholdCrashWindowTests-\(UUID().uuidString)"
        let store = SpikeStateStore(defaults: UserDefaults(suiteName: suite)!)
        let activityName = "PagePassCreditRun-run-1"
        let thresholdEventName = eventName("run-1", 60)
        var state = SpikeState()
        SpikeReducer.apply(.monitoringStarted(runID: "run-1", activityName: activityName, eventName: thresholdEventName, deductionPath: .quantized, creditGrantSeconds: 180, thresholdSeconds: 60), to: &state)
        SpikeReducer.apply(.intervalDidStart(runID: "run-1"), to: &state)
        SpikeReducer.apply(.creditAdded, to: &state)
        SpikeReducer.apply(.creditUnlockApplied(runID: "run-1"), to: &state)
        try store.save(state)

        _ = try store.mutateState { state in
            state.enforcementPending = true
            state.thresholdDebitPending = true
            state.isShielded = false
        }

        XCTAssertThrowsError(
            try store.mutateState(
                beforeSave: { _ in
                    throw NSError(domain: "PhysicalShieldAppliedThenProcessExited", code: 1)
                },
                { state in
                    SpikeReducer.apply(.thresholdReached(runID: "run-1", activityName: activityName, eventName: thresholdEventName), to: &state)
                }
            )
        )

        let persisted = try store.loadState()
        XCTAssertEqual(persisted.creditSeconds, 180)
        XCTAssertEqual(persisted.thresholdReachedCount, 0)
        XCTAssertTrue(persisted.enforcementPending)
        XCTAssertTrue(persisted.thresholdDebitPending)
        XCTAssertTrue(SpikeReducer.isRecoverableThresholdDebit(persisted))
    }

    func testPersistedLegacyThresholdMarkerConsumesFallbackCreditAndClearsOwnership() {
        var state = SpikeState()
        SpikeReducer.apply(.monitoringStarted(runID: "run-1", activityName: "PagePassCreditRun-run-1", eventName: eventName("run-1", 120), deductionPath: .singleThresholdFallback, creditGrantSeconds: 120, thresholdSeconds: 120), to: &state)
        state.enforcementMode = .legacySelection
        SpikeReducer.apply(.intervalDidStart(runID: "run-1"), to: &state)
        SpikeReducer.apply(.creditAdded, to: &state)
        SpikeReducer.apply(.creditUnlockApplied(runID: "run-1"), to: &state)
        state.enforcementPending = true
        state.thresholdDebitPending = true
        state.isShielded = false

        XCTAssertTrue(SpikeReducer.isRecoverableThresholdDebit(state))
        SpikeReducer.apply(.thresholdReached(runID: "run-1", activityName: "PagePassCreditRun-run-1", eventName: eventName("run-1", 120)), to: &state)
        SpikeReducer.apply(.enforcementApplied(runID: "run-1"), to: &state)

        XCTAssertEqual(state.creditSeconds, 0)
        XCTAssertEqual(state.thresholdReachedCount, 1)
        XCTAssertFalse(state.thresholdDebitPending)
        XCTAssertTrue(state.isShielded)
        XCTAssertNil(state.activeRunID)
    }

    func testMissingInitialMonitorRecoveryIncludesZeroCreditArmedRun() {
        var state = SpikeState()
        SpikeReducer.apply(.monitoringStarted(runID: "run-1", activityName: "PagePassCreditRun-run-1", eventName: eventName("run-1", 60), deductionPath: .quantized, creditGrantSeconds: 120, thresholdSeconds: 60), to: &state)

        XCTAssertEqual(state.creditSeconds, 0)
        XCTAssertTrue(SpikeReducer.requiresMissingInitialMonitorRecovery(
            state,
            monitoredActivityNames: []
        ))
        XCTAssertFalse(SpikeReducer.requiresMissingInitialMonitorRecovery(
            state,
            monitoredActivityNames: ["PagePassCreditRun-run-1"]
        ))
    }

    func testSingleThresholdFallbackConsumesAllCreditAtOnce() {
        var state = SpikeState()
        SpikeReducer.apply(.monitoringStarted(runID: "run-1", activityName: "PagePassCreditRun-run-1", eventName: eventName("run-1", 120), deductionPath: .singleThresholdFallback, creditGrantSeconds: 120, thresholdSeconds: 120), to: &state)
        SpikeReducer.apply(.intervalDidStart(runID: "run-1"), to: &state)
        SpikeReducer.apply(.creditAdded, to: &state)
        SpikeReducer.apply(.creditUnlockApplied(runID: "run-1"), to: &state)

        SpikeReducer.apply(.thresholdReached(runID: "run-1", activityName: "PagePassCreditRun-run-1", eventName: eventName("run-1", 120)), to: &state)

        XCTAssertEqual(state.creditSeconds, 0)
        XCTAssertTrue(state.enforcementPending)
        SpikeReducer.apply(.enforcementApplied(runID: "run-1"), to: &state)
        XCTAssertTrue(state.isShielded)
        XCTAssertEqual(state.thresholdReachedCount, 1)
    }

    func testDuplicateCumulativeThresholdDoesNotDoubleDebit() {
        var state = SpikeState()
        SpikeReducer.apply(.monitoringStarted(runID: "run-1", activityName: "PagePassCreditRun-run-1", eventName: eventName("run-1", 60), deductionPath: .quantized, creditGrantSeconds: 120, thresholdSeconds: 60), to: &state)
        SpikeReducer.apply(.intervalDidStart(runID: "run-1"), to: &state)
        SpikeReducer.apply(.creditAdded, to: &state)
        SpikeReducer.apply(.creditUnlockApplied(runID: "run-1"), to: &state)

        SpikeReducer.apply(.thresholdReached(runID: "run-1", activityName: "PagePassCreditRun-run-1", eventName: eventName("run-1", 60)), to: &state)
        SpikeReducer.apply(.thresholdReached(runID: "run-1", activityName: "PagePassCreditRun-run-1", eventName: eventName("run-1", 60)), to: &state)

        XCTAssertEqual(state.creditSeconds, 60)
        XCTAssertFalse(state.isShielded)
        XCTAssertEqual(state.thresholdReachedCount, 1)
        XCTAssertEqual(state.activeEventName, eventName("run-1", 120))
    }

    func testDuplicateCreditGrantDoesNotRestoreConsumedCredit() {
        var state = SpikeState()
        SpikeReducer.apply(.monitoringStarted(runID: "run-1", activityName: "PagePassCreditRun-run-1", eventName: eventName("run-1", 60), deductionPath: .quantized, creditGrantSeconds: 120, thresholdSeconds: 60), to: &state)
        SpikeReducer.apply(.intervalDidStart(runID: "run-1"), to: &state)
        SpikeReducer.apply(.creditAdded, to: &state)
        SpikeReducer.apply(.creditUnlockApplied(runID: "run-1"), to: &state)
        SpikeReducer.apply(.thresholdReached(runID: "run-1", activityName: "PagePassCreditRun-run-1", eventName: eventName("run-1", 60)), to: &state)

        SpikeReducer.apply(.creditAdded, to: &state)

        XCTAssertEqual(state.creditSeconds, 60)
        XCTAssertTrue(state.creditWasActivated)
        XCTAssertEqual(state.thresholdReachedCount, 1)
    }

    func testIntervalEndConsumesRemainingCreditAndRequiresShieldConfirmation() {
        var state = SpikeState()
        SpikeReducer.apply(.monitoringStarted(runID: "run-1", activityName: "PagePassCreditRun-run-1", eventName: eventName("run-1", 60), deductionPath: .quantized, creditGrantSeconds: 120, thresholdSeconds: 60), to: &state)
        SpikeReducer.apply(.intervalDidStart(runID: "run-1"), to: &state)
        SpikeReducer.apply(.creditAdded, to: &state)

        SpikeReducer.apply(.intervalDidEnd(runID: "run-1"), to: &state)

        XCTAssertEqual(state.creditSeconds, 0)
        XCTAssertTrue(state.enforcementPending)
        XCTAssertFalse(state.isShielded)
        XCTAssertTrue(state.monitoringEnded)
        XCTAssertFalse(state.intervalDidStart)
        SpikeReducer.apply(.creditAdded, to: &state)
        XCTAssertEqual(state.creditSeconds, 0)
        SpikeReducer.apply(.enforcementApplied(runID: "run-1"), to: &state)
        XCTAssertTrue(state.isShielded)
        XCTAssertFalse(state.enforcementPending)
        XCTAssertFalse(state.thresholdDebitPending)
        XCTAssertNil(state.activeRunID)
        SpikeReducer.apply(.creditAdded, to: &state)
        XCTAssertEqual(state.creditSeconds, 0)
    }

    func testThresholdBeforeCreditInvalidatesRunAndPreventsUnlock() {
        var state = SpikeState()
        SpikeReducer.apply(.monitoringStarted(runID: "run-1", activityName: "PagePassCreditRun-run-1", eventName: eventName("run-1", 60), deductionPath: .quantized, creditGrantSeconds: 120, thresholdSeconds: 60), to: &state)
        SpikeReducer.apply(.intervalDidStart(runID: "run-1"), to: &state)

        SpikeReducer.apply(.thresholdReached(runID: "run-1", activityName: "PagePassCreditRun-run-1", eventName: eventName("run-1", 60)), to: &state)
        SpikeReducer.apply(.creditAdded, to: &state)

        XCTAssertTrue(state.monitoringCompromised)
        XCTAssertFalse(state.creditWasActivated)
        XCTAssertEqual(state.creditSeconds, 0)
        XCTAssertTrue(state.enforcementPending)
        XCTAssertFalse(state.isShielded)
        SpikeReducer.apply(.enforcementApplied(runID: "run-1"), to: &state)
        XCTAssertTrue(state.isShielded)
    }

    func testLegacyStateDecodeDefaultsMissingDeductionFields() throws {
        let data = """
        {
            "creditSeconds": 60,
            "isShielded": false,
            "activeRunID": "run-1",
            "activeActivityName": "PagePassCreditRun-run-1",
            "activeEventName": "limitedAppCredit-run-1",
            "intervalDidStart": true,
            "eventThresholdSeconds": 60,
            "scheduleIntervalDescription": "",
            "includesPastActivityEvidence": ""
        }
        """.data(using: .utf8)!

        let state = try JSONDecoder().decode(SpikeState.self, from: data)

        XCTAssertEqual(state.creditGrantSeconds, 0)
        XCTAssertEqual(state.debitQuantumSeconds, SpikeConstants.debitQuantumSeconds)
        XCTAssertEqual(state.deductionPath, .singleThresholdFallback)
        XCTAssertEqual(state.thresholdReachedCount, 0)
        XCTAssertFalse(state.creditWasActivated)
        XCTAssertFalse(state.monitoringCompromised)
        XCTAssertFalse(state.monitoringEnded)
        XCTAssertFalse(state.enforcementPending)
        XCTAssertFalse(state.isPersistentMeter)
        XCTAssertEqual(state.meterCapacitySeconds, 0)
        XCTAssertEqual(state.lastReachedCumulativeThresholdSeconds, 0)
        XCTAssertEqual(state.lastAppliedGrantSequence, 0)
    }

    func testStoreRoundTrip() throws {
        let suite = "SpikeStateStoreTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let store = SpikeStateStore(defaults: defaults)
        let state = SpikeState(creditSeconds: 60, isShielded: false, activeRunID: "run-1")

        try store.save(state)
        let loaded = try store.loadState()

        XCTAssertEqual(loaded, state)
    }

    func testAutomationOwnershipRoundTripsAndResetClearsIt() {
        let suite = "SpikeStateStoreAutomationLeaseTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let store = SpikeStateStore(defaults: defaults)

        store.saveAutomationLease("owner-a")
        store.saveConsumedAutomationNonce("nonce-a")
        XCTAssertEqual(store.loadAutomationLease(), "owner-a")
        XCTAssertEqual(store.loadConsumedAutomationNonce(), "nonce-a")

        store.reset()
        XCTAssertNil(store.loadAutomationLease())
        XCTAssertNil(store.loadConsumedAutomationNonce())
    }

    func testResetClearsFinalThresholdShieldIntent() throws {
        let suite = "SpikeStateStoreFinalIntentResetTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let store = SpikeStateStore(defaults: defaults)
        var state = SpikeState(activeRunID: "run-1")
        state.activeEventName = eventName("run-1", 60)
        try store.save(state)
        try store.enforceAndPersistFinalThresholdShieldIntent(
            runID: "run-1",
            eventName: eventName("run-1", 60)
        ) { _, _ in }
        XCTAssertNotNil(store.loadFinalThresholdShieldIntent())

        store.reset()

        XCTAssertNil(store.loadFinalThresholdShieldIntent())
    }

    func testAutomationSessionClaimIsAtomicAcrossLeaseAndNonceValidation() {
        let suite = "SpikeStateStoreAutomationLeaseClaimTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let store = SpikeStateStore(defaults: defaults)

        XCTAssertEqual(store.claimAutomationSession(lease: "owner-a", replacing: nil, replacingNonce: nil, nonce: "nonce-1"), .claimed)
        XCTAssertEqual(store.claimAutomationSession(lease: "owner-a", replacing: nil, replacingNonce: nil, nonce: "nonce-2"), .leaseRejected)
        XCTAssertEqual(store.claimAutomationSession(lease: "owner-b", replacing: nil, replacingNonce: nil, nonce: "nonce-2"), .leaseRejected)
        XCTAssertEqual(store.loadAutomationLease(), "owner-a")
        XCTAssertFalse(store.hasConsumedAutomationNonce("nonce-2"))
        XCTAssertEqual(store.claimAutomationSession(lease: "owner-b", replacing: "wrong-owner", replacingNonce: "nonce-1", nonce: "nonce-2"), .leaseRejected)
        XCTAssertEqual(store.claimAutomationSession(lease: "owner-b", replacing: "owner-a", replacingNonce: "wrong-nonce", nonce: "nonce-2"), .leaseRejected)
        XCTAssertEqual(store.claimAutomationSession(lease: "owner-b", replacing: "owner-a", replacingNonce: "nonce-1", nonce: "nonce-1"), .nonceRejected)
        XCTAssertEqual(store.loadAutomationLease(), "owner-a")
        XCTAssertEqual(store.claimAutomationSession(lease: "owner-b", replacing: "owner-a", replacingNonce: "nonce-1", nonce: "nonce-2"), .claimed)
        XCTAssertEqual(store.loadAutomationLease(), "owner-b")
        XCTAssertTrue(store.hasConsumedAutomationNonce("nonce-1"))
        XCTAssertTrue(store.hasConsumedAutomationNonce("nonce-2"))
    }

    func testStateMutationIsAtomicAcrossStoreInstancesSharingALock() throws {
        let suite = "SpikeStateStoreConcurrentMutationTests-\(UUID().uuidString)"
        let lockURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(suite).lock")
        let first = SpikeStateStore(
            defaults: UserDefaults(suiteName: suite)!,
            lockURL: lockURL
        )
        let second = SpikeStateStore(
            defaults: UserDefaults(suiteName: suite)!,
            lockURL: lockURL
        )
        try first.save(SpikeState())

        DispatchQueue.concurrentPerform(iterations: 2) { worker in
            let store = worker == 0 ? first : second
            for _ in 0..<100 {
                try! store.mutateState { state in
                    state.creditSeconds += 1
                }
            }
        }

        XCTAssertEqual(try first.loadState().creditSeconds, 200)
        try? FileManager.default.removeItem(at: lockURL)
    }

    func testRejectedCreditTransactionDoesNotRunUnlockSideEffect() throws {
        let suite = "SpikeStateStoreRejectedCreditTests-\(UUID().uuidString)"
        let store = SpikeStateStore(defaults: UserDefaults(suiteName: suite)!)
        var compromised = SpikeState()
        SpikeReducer.apply(.monitoringStarted(runID: "run-1", activityName: "PagePassCreditRun-run-1", eventName: eventName("run-1", 60), deductionPath: .singleThresholdFallback, creditGrantSeconds: 60, thresholdSeconds: 60), to: &compromised)
        SpikeReducer.apply(.intervalDidStart(runID: "run-1"), to: &compromised)
        SpikeReducer.apply(.thresholdReached(runID: "run-1", activityName: "PagePassCreditRun-run-1", eventName: eventName("run-1", 60)), to: &compromised)
        try store.save(compromised)
        var didActivateCredit = false
        var unlockSideEffectCount = 0

        let result = try store.mutateState(afterSave: { _ in
            guard didActivateCredit else { return }
            unlockSideEffectCount += 1
        }) { state in
            let wasActivated = state.creditWasActivated
            SpikeReducer.apply(.creditAdded, to: &state)
            didActivateCredit = !wasActivated && state.creditWasActivated
        }

        XCTAssertTrue(result.monitoringCompromised)
        XCTAssertEqual(result.creditSeconds, 0)
        XCTAssertEqual(unlockSideEffectCount, 0)
    }

    func testSynchronizationFailurePreventsSnapshotAfterSaveSideEffect() {
        let suite = "SpikeStateStoreSynchronizationFailureTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        var synchronizationCount = 0
        var unlockSideEffectCount = 0
        let store = SpikeStateStore(
            defaults: defaults,
            synchronize: {
                synchronizationCount += 1
                return synchronizationCount != 2
            }
        )

        XCTAssertThrowsError(
            try store.mutateStateWithEnforcementSnapshot(
                afterSave: { _, _ in
                    unlockSideEffectCount += 1
                },
                { state in
                    state.creditSeconds = 60
                }
            )
        ) { error in
            guard case SpikeStateStore.StoreError.persistenceSynchronizationFailed = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertEqual(unlockSideEffectCount, 0)
    }

    func testSnapshotUnlockHasNoFallibleSynchronizationAfterSideEffect() throws {
        let suite = "SpikeStateStoreSynchronizationOrderTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        var synchronizationCount = 0
        var unlockSideEffectCount = 0
        let store = SpikeStateStore(
            defaults: defaults,
            synchronize: {
                synchronizationCount += 1
                return true
            }
        )

        _ = try store.mutateStateWithEnforcementSnapshot(
            afterSave: { _, _ in
                unlockSideEffectCount += 1
            },
            { state in
                state.creditSeconds = 60
            }
        )

        XCTAssertEqual(synchronizationCount, 2)
        XCTAssertEqual(unlockSideEffectCount, 1)
    }

    func testSelectionPayloadExportImportRoundTripsEmptySelection() throws {
        let suite = "SpikeStateStoreSelectionPayloadTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let store = SpikeStateStore(defaults: defaults)

        let payload = try store.exportSelectionPayload(FamilyActivitySelection())
        let selection = try store.importSelectionPayload(payload)

        XCTAssertEqual(selection.applicationTokens.count, 0)
        XCTAssertEqual(selection.categoryTokens.count, 0)
        XCTAssertEqual(selection.webDomainTokens.count, 0)
    }

    @MainActor
    func testPickerSelectionRequiresExplicitApplicationSelection() {
        let suite = "SpikeViewModelSelectionTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let model = SpikeViewModel(store: SpikeStateStore(defaults: defaults))

        XCTAssertFalse(model.selection.includeEntireCategory)
    }

    func testAuthorizationStatusAllowsShieldingOnlyWhenApproved() {
        XCTAssertTrue(AuthorizationStatus.approved.allowsPagePassShielding)
        XCTAssertFalse(AuthorizationStatus.denied.allowsPagePassShielding)
        XCTAssertFalse(AuthorizationStatus.notDetermined.allowsPagePassShielding)
    }

    func testManagedRequestRejectsEmptySelection() {
        XCTAssertThrowsError(
            try ManagedAppPolicy.makeRequest(
                selection: FamilyActivitySelection(includeEntireCategory: false),
                existing: []
            )
        ) { error in
            XCTAssertEqual(error as? ManagedAppPolicyError, .invalidRequestSelection)
        }
    }

    func testParentCannotSetPendingAsDecision() {
        let record = managedRecord(status: .blocked, policyVersion: 1)

        XCTAssertThrowsError(
            try ManagedAppPolicy.setParentStatus(
                .pending,
                requestID: record.requestID,
                policyVersion: 2,
                records: [record]
            )
        ) { error in
            XCTAssertEqual(error as? ManagedAppPolicyError, .pendingIsNotAParentDecision)
        }
    }

    func testNewerParentPolicyReclassifiesStoredRequest() throws {
        let record = managedRecord(status: .pending, policyVersion: 0)
        let envelope = ParentPolicyEnvelope(
            schemaVersion: ParentPolicyEnvelope.currentSchemaVersion,
            policyVersion: 1,
            decidedAt: Date(timeIntervalSince1970: 100),
            decisions: [ManagedAppDecision(requestID: record.requestID, status: .earnedTime)]
        )

        let updated = try ManagedAppPolicy.applyPolicy(envelope, to: [record], currentPolicyVersion: 0)

        XCTAssertEqual(updated.first?.status, .earnedTime)
        XCTAssertEqual(updated.first?.policyVersion, 1)
        XCTAssertEqual(updated.first?.decidedAt, envelope.decidedAt)
    }

    func testStaleParentPolicyIsRejected() {
        let record = managedRecord(status: .earnedTime, policyVersion: 2)
        let envelope = ParentPolicyEnvelope(
            schemaVersion: ParentPolicyEnvelope.currentSchemaVersion,
            policyVersion: 1,
            decidedAt: Date(),
            decisions: [ManagedAppDecision(requestID: record.requestID, status: .blocked)]
        )

        XCTAssertThrowsError(
            try ManagedAppPolicy.applyPolicy(envelope, to: [record], currentPolicyVersion: 2)
        ) { error in
            XCTAssertEqual(error as? ManagedAppPolicyError, .stalePolicyVersion)
        }
    }

    func testSamePolicyVersionWithDifferentDecisionIsRejected() {
        let record = managedRecord(status: .earnedTime, policyVersion: 2)
        let envelope = ParentPolicyEnvelope(
            schemaVersion: ParentPolicyEnvelope.currentSchemaVersion,
            policyVersion: 2,
            decidedAt: Date(),
            decisions: [ManagedAppDecision(requestID: record.requestID, status: .blocked)]
        )

        XCTAssertThrowsError(
            try ManagedAppPolicy.applyPolicy(envelope, to: [record], currentPolicyVersion: 2)
        ) { error in
            XCTAssertEqual(error as? ManagedAppPolicyError, .policyVersionConflict)
        }
    }

    func testPolicyForUnknownRequestIsRejected() {
        let record = managedRecord(status: .pending, policyVersion: 0)
        let envelope = ParentPolicyEnvelope(
            schemaVersion: ParentPolicyEnvelope.currentSchemaVersion,
            policyVersion: 1,
            decidedAt: Date(),
            decisions: [ManagedAppDecision(requestID: UUID(), status: .alwaysAllowed)]
        )

        XCTAssertThrowsError(
            try ManagedAppPolicy.applyPolicy(envelope, to: [record], currentPolicyVersion: 0)
        ) { error in
            XCTAssertEqual(error as? ManagedAppPolicyError, .requestNotFound)
        }
    }

    func testDuplicatePolicyDecisionsAreRejectedWithoutCrashing() {
        let record = managedRecord(status: .pending, policyVersion: 0)
        let decision = ManagedAppDecision(requestID: record.requestID, status: .earnedTime)
        let envelope = ParentPolicyEnvelope(
            schemaVersion: ParentPolicyEnvelope.currentSchemaVersion,
            policyVersion: 1,
            decidedAt: Date(),
            decisions: [decision, decision]
        )

        XCTAssertThrowsError(
            try ManagedAppPolicy.applyPolicy(envelope, to: [record], currentPolicyVersion: 0)
        ) { error in
            XCTAssertEqual(error as? ManagedAppPolicyError, .duplicatePolicyDecision)
        }
    }

    func testMonitoringSelectionDoesNotOverwritePickerSelection() throws {
        let suite = "SpikeStateStoreMonitoringSelectionTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let store = SpikeStateStore(defaults: defaults)
        let pickerSelection = FamilyActivitySelection(includeEntireCategory: true)
        let monitoringSelection = FamilyActivitySelection(includeEntireCategory: false)

        try store.saveSelection(pickerSelection)
        try store.saveMonitoringSelection(monitoringSelection)

        XCTAssertTrue(try store.loadSelection().includeEntireCategory)
        XCTAssertFalse(try store.loadMonitoringSelection().includeEntireCategory)

        var snapshotSelection: FamilyActivitySelection?
        _ = try store.mutateStateWithEnforcementSnapshot(
            beforeSave: { _, snapshot in
                snapshotSelection = snapshot.monitoringSelection
            },
            { _ in }
        )
        XCTAssertFalse(try XCTUnwrap(snapshotSelection).includeEntireCategory)
    }

    func testManagedRecordsAndVersionShareOneEnforcementSnapshot() throws {
        let suite = "SpikeStateStoreManagedSnapshotTests-\(UUID().uuidString)"
        let store = SpikeStateStore(defaults: UserDefaults(suiteName: suite)!)
        let record = managedRecord(status: .earnedTime, policyVersion: 7)
        try store.saveManagedPolicy(records: [record], version: 7)
        var capturedRecords: [ManagedAppRecord] = []
        var capturedVersion = 0
        var afterSaveVersion = 0

        _ = try store.mutateStateWithEnforcementSnapshot(
            beforeSave: { _, snapshot in
                capturedRecords = snapshot.managedApps
                capturedVersion = snapshot.managedPolicyVersion
            },
            afterSave: { _, snapshot in
                afterSaveVersion = snapshot.managedPolicyVersion
            },
            { _ in }
        )

        XCTAssertEqual(capturedRecords, [record])
        XCTAssertEqual(capturedVersion, 7)
        XCTAssertEqual(afterSaveVersion, 7)
    }

    func testPolicyEnvelopePayloadRoundTrips() throws {
        let suite = "SpikeStateStorePolicyEnvelopeTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let store = SpikeStateStore(defaults: defaults)
        let record = managedRecord(status: .alwaysAllowed, policyVersion: 3)
        let envelope = try ManagedAppPolicy.makePolicyEnvelope(records: [record], policyVersion: 3)

        let payload = try store.exportPolicyEnvelope(envelope)
        let decoded = try store.importPolicyEnvelope(payload)

        XCTAssertEqual(decoded, envelope)
    }

    func testManagedTokenSetsExplicitlyShieldBlockedAndZeroCreditEarnedApps() throws {
        let blockedToken = try applicationToken(seed: 1)
        let earnedToken = try applicationToken(seed: 2)
        let alwaysAllowedToken = try applicationToken(seed: 3)
        let records = [
            managedRecord(status: .blocked, policyVersion: 1, applicationToken: blockedToken),
            managedRecord(status: .earnedTime, policyVersion: 1, applicationToken: earnedToken),
            managedRecord(status: .alwaysAllowed, policyVersion: 1, applicationToken: alwaysAllowedToken)
        ]

        let tokens = ManagedAppPolicy.tokenSets(from: records)

        XCTAssertEqual(tokens.blocked, [blockedToken])
        XCTAssertEqual(tokens.zeroCreditShields, [blockedToken, earnedToken])
        XCTAssertEqual(tokens.positiveCreditShields, [blockedToken])
        XCTAssertEqual(tokens.alwaysAllowed, [alwaysAllowedToken])
        XCTAssertEqual(tokens.positiveCreditExceptions, [alwaysAllowedToken, earnedToken])
        XCTAssertTrue(tokens.isWithinManagedSettingsLimits)
    }

    func testMonitoringSnapshotRequiresExactEarnedTokensAndPolicyVersion() throws {
        let earnedToken = try applicationToken(seed: 21)
        let blockedToken = try applicationToken(seed: 22)
        let records = [
            managedRecord(status: .earnedTime, policyVersion: 7, applicationToken: earnedToken),
            managedRecord(status: .blocked, policyVersion: 7, applicationToken: blockedToken)
        ]
        let selection = ManagedAppPolicy.monitoringSelection(from: [earnedToken])

        XCTAssertTrue(
            ManagedAppPolicy.matchesMonitoringSnapshot(
                records: records,
                policyVersion: 7,
                selection: selection,
                expectedPolicyVersion: 7
            )
        )
        XCTAssertFalse(
            ManagedAppPolicy.matchesMonitoringSnapshot(
                records: records,
                policyVersion: 8,
                selection: selection,
                expectedPolicyVersion: 7
            )
        )
    }

    func testMonitoringSnapshotRejectsEarnedStatusChange() throws {
        let token = try applicationToken(seed: 23)
        let selection = ManagedAppPolicy.monitoringSelection(from: [token])
        let changedRecords = [
            managedRecord(status: .blocked, policyVersion: 8, applicationToken: token)
        ]

        XCTAssertFalse(
            ManagedAppPolicy.matchesMonitoringSnapshot(
                records: changedRecords,
                policyVersion: 8,
                selection: selection,
                expectedPolicyVersion: 8
            )
        )
    }

    func testManagedStatusSwapChangesOnlyRequestedStatuses() {
        let earned = managedRecord(status: .earnedTime, policyVersion: 4)
        let alwaysAllowed = managedRecord(status: .alwaysAllowed, policyVersion: 4)
        let blocked = managedRecord(status: .blocked, policyVersion: 4)

        let updated = ManagedAppPolicy.swappingStatuses(
            .earnedTime,
            .blocked,
            in: [earned, alwaysAllowed, blocked]
        )

        XCTAssertEqual(updated?[0].status, .blocked)
        XCTAssertEqual(updated?[0].requestID, earned.requestID)
        XCTAssertEqual(updated?[1], alwaysAllowed)
        XCTAssertEqual(updated?[2].status, .earnedTime)
        XCTAssertEqual(updated?[2].requestID, blocked.requestID)
    }

    func testManagedStatusSwapRequiresBothStatuses() {
        let earned = managedRecord(status: .earnedTime, policyVersion: 4)

        XCTAssertNil(
            ManagedAppPolicy.swappingStatuses(
                .earnedTime,
                .blocked,
                in: [earned]
            )
        )
    }

    func testWallClockManualStopDebitsElapsedSessionTime() {
        let start = Date(timeIntervalSince1970: 1_000)
        var state = wallClockState(balance: 5 * 60 * 60, duration: 5 * 60 * 60, start: start)

        SpikeReducer.apply(
            .wallClockSessionStopped(runID: "session-1", at: start.addingTimeInterval(60 * 60)),
            to: &state
        )

        XCTAssertEqual(state.creditSeconds, 4 * 60 * 60)
        XCTAssertEqual(state.wallClockSession?.consumedSeconds, 60 * 60)
        XCTAssertEqual(state.wallClockSession?.status, .ended)
        XCTAssertTrue(state.enforcementPending)
        XCTAssertFalse(state.isShielded)
    }

    func testWallClockSelectedDurationExpiryPreservesUnusedBalance() {
        let start = Date(timeIntervalSince1970: 1_000)
        var state = wallClockState(balance: 5 * 60 * 60, duration: 60 * 60, start: start)

        SpikeReducer.apply(
            .intervalDidEnd(runID: "session-1"),
            to: &state,
            now: start.addingTimeInterval(60 * 60)
        )

        XCTAssertEqual(state.creditSeconds, 4 * 60 * 60)
        XCTAssertEqual(state.wallClockSession?.consumedSeconds, 60 * 60)
        XCTAssertEqual(state.wallClockSession?.status, .ended)
        XCTAssertTrue(state.enforcementPending)
    }

    func testWallClockMaximumDurationExpiryConsumesBalance() {
        let start = Date(timeIntervalSince1970: 1_000)
        var state = wallClockState(balance: 5 * 60 * 60, duration: 5 * 60 * 60, start: start)

        SpikeReducer.apply(
            .intervalDidEnd(runID: "session-1"),
            to: &state,
            now: start.addingTimeInterval(5 * 60 * 60)
        )
        SpikeReducer.apply(.enforcementApplied(runID: "session-1"), to: &state)

        XCTAssertEqual(state.creditSeconds, 0)
        XCTAssertTrue(state.isShielded)
        XCTAssertNil(state.activeRunID)
    }

    func testWallClockDuplicateEndDoesNotDoubleDebit() {
        let start = Date(timeIntervalSince1970: 1_000)
        var state = wallClockState(balance: 600, duration: 300, start: start)
        let end = start.addingTimeInterval(120)

        SpikeReducer.apply(.wallClockSessionStopped(runID: "session-1", at: end), to: &state)
        SpikeReducer.apply(.enforcementApplied(runID: "session-1"), to: &state)
        SpikeReducer.apply(.intervalDidEnd(runID: "session-1"), to: &state, now: start.addingTimeInterval(300))

        XCTAssertEqual(state.creditSeconds, 480)
        XCTAssertEqual(state.wallClockSession?.consumedSeconds, 120)
    }

    func testWallClockSessionCannotUnlockAfterExpiry() {
        let start = Date(timeIntervalSince1970: 1_000)
        var state = SpikeState()
        SpikeReducer.apply(
            .wallClockSessionPrepared(
                runID: "session-1",
                activityName: "PagePassCreditRun-session-1",
                balanceSeconds: 300,
                durationSeconds: 300,
                startedAt: start,
                expiresAt: start.addingTimeInterval(300)
            ),
            to: &state
        )

        SpikeReducer.apply(
            .wallClockSessionActivated(runID: "session-1", at: start.addingTimeInterval(301)),
            to: &state
        )

        XCTAssertEqual(state.wallClockSession?.status, .arming)
        XCTAssertTrue(state.isShielded)
        XCTAssertFalse(state.creditWasActivated)
    }

    func testWallClockSessionCodableRoundTrip() throws {
        let state = wallClockState(
            balance: 600,
            duration: 300,
            start: Date(timeIntervalSince1970: 1_000)
        )

        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(SpikeState.self, from: data)

        XCTAssertEqual(decoded, state)
    }

    private func managedRecord(
        status: ManagedAppStatus,
        policyVersion: Int,
        applicationToken: ApplicationToken? = nil
    ) -> ManagedAppRecord {
        var selection = FamilyActivitySelection(includeEntireCategory: false)
        if let applicationToken {
            selection.applicationTokens = [applicationToken]
        }
        return ManagedAppRecord(
            requestID: UUID(),
            requestedAt: Date(timeIntervalSince1970: 10),
            selection: selection,
            status: status,
            policyVersion: policyVersion,
            decidedAt: nil
        )
    }

    private func persistentMeterState(
        capacitySeconds: Int,
        quantumSeconds: Int
    ) -> SpikeState {
        var state = SpikeState()
        SpikeReducer.apply(
            .monitoringStarted(
                runID: "run-1",
                activityName: "PagePassCreditRun-run-1",
                eventName: eventName("run-1", quantumSeconds),
                deductionPath: .quantized,
                creditGrantSeconds: capacitySeconds,
                thresholdSeconds: quantumSeconds
            ),
            to: &state
        )
        SpikeReducer.apply(
            .persistentMeterConfigured(capacitySeconds: capacitySeconds),
            to: &state
        )
        SpikeReducer.apply(.intervalDidStart(runID: "run-1"), to: &state)
        return state
    }

    private func wallClockState(balance: Int, duration: Int, start: Date) -> SpikeState {
        var state = SpikeState()
        SpikeReducer.apply(
            .wallClockSessionPrepared(
                runID: "session-1",
                activityName: "PagePassCreditRun-session-1",
                balanceSeconds: balance,
                durationSeconds: duration,
                startedAt: start,
                expiresAt: start.addingTimeInterval(TimeInterval(duration))
            ),
            to: &state
        )
        SpikeReducer.apply(
            .wallClockSessionActivated(runID: "session-1", at: start),
            to: &state
        )
        return state
    }

    private func eventName(_ runID: String, _ cumulativeThresholdSeconds: Int) -> String {
        SpikeConstants.eventName(
            for: runID,
            cumulativeThresholdSeconds: cumulativeThresholdSeconds
        )
    }

    private func applicationToken(seed: UInt8) throws -> ApplicationToken {
        struct EncodedToken: Encodable {
            let data: Data
        }

        let encoded = try JSONEncoder().encode(EncodedToken(data: Data(repeating: seed, count: 128)))
        return try JSONDecoder().decode(ApplicationToken.self, from: encoded)
    }
}
