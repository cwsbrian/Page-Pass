import DeviceActivity
import FamilyControls
import Foundation

struct ActivityMonitorService {
    enum PreparationError: Error {
        case invalidCumulativeConfiguration
        case invalidScheduleDate
    }

    enum RegistrationError: LocalizedError {
        case eventMismatch
        case scheduleMismatch

        var errorDescription: String? {
            switch self {
            case .eventMismatch:
                "DeviceActivityCenter did not preserve the requested event configuration"
            case .scheduleMismatch:
                "DeviceActivityCenter did not preserve the requested wall-clock schedule"
            }
        }
    }

    private let center = DeviceActivityCenter()

    struct PreparedRun {
        let runID: String
        let names: SpikeConstants.RunNames
        let activity: DeviceActivityName
        let finalEventName: DeviceActivityEvent.Name
        let schedule: DeviceActivitySchedule
        let events: [DeviceActivityEvent.Name: DeviceActivityEvent]
        let logicalThresholdSeconds: Int
        let logicalThresholds: [Int]
        let intervalStart: Date
        let intervalEnd: Date
        let scheduleDescription: String
        let includesPastActivityEvidence: String
        let eventConfigurationDescription: String
    }

    struct PreparedWallClockSession {
        let runID: String
        let activity: DeviceActivityName
        let schedule: DeviceActivitySchedule
        let intervalStart: Date
        let intervalEnd: Date
        let scheduleDescription: String
    }

    func prepareWallClockSession(
        runID: String,
        durationSeconds: Int,
        now: Date = Date(),
        calendar: Calendar = .current
    ) throws -> PreparedWallClockSession {
        guard durationSeconds >= SpikeConstants.minimumWallClockSessionSeconds,
              let startDate = calendar.date(byAdding: .second, value: -1, to: now),
              let endDate = calendar.date(byAdding: .second, value: durationSeconds, to: now) else {
            throw PreparationError.invalidScheduleDate
        }
        let schedule = DeviceActivitySchedule(
            intervalStart: scheduleDateComponents(for: startDate, calendar: calendar),
            intervalEnd: scheduleDateComponents(for: endDate, calendar: calendar),
            repeats: false
        )
        guard schedule.nextInterval != nil else {
            throw PreparationError.invalidScheduleDate
        }
        return PreparedWallClockSession(
            runID: runID,
            activity: DeviceActivityName(SpikeConstants.names(for: runID).activity),
            schedule: schedule,
            intervalStart: now,
            intervalEnd: endDate,
            scheduleDescription: "wall-clock session from \(now.formatted()) to \(endDate.formatted()); duration=\(durationSeconds)s; events=0"
        )
    }

    func startWallClockSession(_ session: PreparedWallClockSession) throws {
        let staleActivities = center.activities.filter { $0.rawValue.hasPrefix(SpikeConstants.activityPrefix) }
        center.stopMonitoring(staleActivities)
        try center.startMonitoring(session.activity, during: session.schedule, events: [:])
        guard center.activities.contains(session.activity),
              center.schedule(for: session.activity) == session.schedule,
              center.events(for: session.activity).isEmpty else {
            center.stopMonitoring([session.activity])
            throw RegistrationError.scheduleMismatch
        }
    }

    func prepareRun(
        runID: String,
        selection: FamilyActivitySelection,
        includesMeasurementGrace: Bool = true,
        creditGrantSeconds: Int,
        debitQuantumSeconds: Int,
        monitoringCeilingSeconds: Int? = nil,
        deductionPath: AutomaticDeductionPath,
        now: Date = Date(),
        calendar: Calendar = .current
    ) throws -> PreparedRun {
        let thresholdCeilingSeconds = monitoringCeilingSeconds ?? creditGrantSeconds
        guard creditGrantSeconds >= 0,
              (creditGrantSeconds > 0 || monitoringCeilingSeconds != nil),
              SpikeConstants.isValidCumulativeConfiguration(
            creditGrantSeconds: thresholdCeilingSeconds,
            debitQuantumSeconds: debitQuantumSeconds,
            deductionPath: deductionPath
        ) else {
            throw PreparationError.invalidCumulativeConfiguration
        }
        let names = SpikeConstants.names(for: runID)
        let activity = DeviceActivityName(names.activity)
        let thresholds = SpikeConstants.cumulativeThresholds(
            creditGrantSeconds: thresholdCeilingSeconds,
            debitQuantumSeconds: debitQuantumSeconds,
            deductionPath: deductionPath
        )
        precondition(!thresholds.isEmpty)
        let logicalThresholdSeconds = thresholds[0]

        guard let startDate = calendar.date(
            byAdding: .second,
            value: SpikeConstants.monitoringStartLeadSeconds,
            to: now
        ) else {
            throw PreparationError.invalidScheduleDate
        }
        let start = scheduleDateComponents(for: startDate, calendar: calendar)
        let scheduleDurationSeconds = max(
            SpikeConstants.minimumMonitoringWindowSeconds,
            thresholdCeilingSeconds + 60 * 60
        )
        guard let endDate = calendar.date(
            byAdding: .second,
            value: scheduleDurationSeconds,
            to: startDate
        ) else {
            throw PreparationError.invalidScheduleDate
        }
        let end = scheduleDateComponents(for: endDate, calendar: calendar)
        let schedule = DeviceActivitySchedule(intervalStart: start, intervalEnd: end, repeats: false)
        let nextIntervalEvidence = schedule.nextInterval.map {
            "next interval=\($0.start.formatted()) to \($0.end.formatted())"
        } ?? "next interval=nil"

        let pastActivityEvidence: String
        if #available(iOS 17.4, *) {
            pastActivityEvidence = "includesPastActivity=false"
        } else {
            pastActivityEvidence = "includesPastActivity unavailable; require fresh intervalDidStart evidence"
        }
        let events = Dictionary(uniqueKeysWithValues: thresholds.map { threshold in
            let eventName = DeviceActivityEvent.Name(
                SpikeConstants.eventName(
                    for: runID,
                    cumulativeThresholdSeconds: threshold
                )
            )
            let event = makeEvent(
                selection: selection,
                thresholdSeconds: SpikeConstants.deviceActivityThresholdSeconds(
                    for: threshold,
                    includesMeasurementGrace: includesMeasurementGrace
                )
            )
            return (eventName, event)
        })
        let firstEventName = DeviceActivityEvent.Name(
            SpikeConstants.eventName(
                for: runID,
                cumulativeThresholdSeconds: logicalThresholdSeconds
            )
        )
        let firstEvent = events[firstEventName]!
        let eventConfigurationDescription = eventConfigurationDescription(firstEvent)

        return PreparedRun(
            runID: runID,
            names: names,
            activity: activity,
            finalEventName: firstEventName,
            schedule: schedule,
            events: events,
            logicalThresholdSeconds: logicalThresholdSeconds,
            logicalThresholds: thresholds,
            intervalStart: startDate,
            intervalEnd: endDate,
            scheduleDescription: "\(scheduleDurationSeconds)s absolute non-repeating schedule from \(startDate.formatted()) to \(endDate.formatted()); \(nextIntervalEvidence); cumulative thresholds=\(thresholds); monitoring ceiling=\(thresholdCeilingSeconds)s; start lead=\(SpikeConstants.monitoringStartLeadSeconds)s; one-time measurement grace=\(includesMeasurementGrace ? SpikeConstants.measurementGraceSeconds : 0)s",
            includesPastActivityEvidence: pastActivityEvidence,
            eventConfigurationDescription: eventConfigurationDescription
        )
    }

    func startRun(_ run: PreparedRun) throws -> String {
        let staleActivities = center.activities.filter { $0.rawValue.hasPrefix(SpikeConstants.activityPrefix) }
        center.stopMonitoring(staleActivities)
        center.stopMonitoring([run.activity])
        try center.startMonitoring(run.activity, during: run.schedule, events: run.events)

        let registeredEvents = center.events(for: run.activity)
        guard registeredEvents == run.events,
              let registeredEvent = registeredEvents[run.finalEventName] else {
            center.stopMonitoring([run.activity])
            throw RegistrationError.eventMismatch
        }
        return eventConfigurationDescription(registeredEvent)
    }

    func startRun(
        _ run: PreparedRun,
        replacing activities: [DeviceActivityName]
    ) throws {
        center.stopMonitoring(Array(Set(activities + [run.activity])))
        try center.startMonitoring(run.activity, during: run.schedule, events: run.events)
    }

    func stopRun(_ activity: DeviceActivityName) {
        center.stopMonitoring([activity])
    }

    private func makeEvent(
        selection: FamilyActivitySelection,
        thresholdSeconds: Int
    ) -> DeviceActivityEvent {
        let threshold = normalizedDurationComponents(seconds: thresholdSeconds)
        if #available(iOS 17.4, *) {
            return DeviceActivityEvent(
                applications: selection.applicationTokens,
                threshold: threshold,
                includesPastActivity: false
            )
        }
        return DeviceActivityEvent(
            applications: selection.applicationTokens,
            threshold: threshold
        )
    }

    private func normalizedDurationComponents(seconds: Int) -> DateComponents {
        DateComponents(
            hour: seconds / (60 * 60),
            minute: (seconds % (60 * 60)) / 60,
            second: seconds % 60
        )
    }

    private func eventConfigurationDescription(_ event: DeviceActivityEvent) -> String {
        let threshold = event.threshold
        return "applications=\(event.applications.count); categories=\(event.categories.count); web domains=\(event.webDomains.count); includesAllActivity=\(event.includesAllActivity); threshold=\(threshold.hour ?? 0)h\(threshold.minute ?? 0)m\(threshold.second ?? 0)s"
    }

    private func scheduleDateComponents(for date: Date, calendar: Calendar) -> DateComponents {
        var components = calendar.dateComponents(
            [.era, .year, .month, .day, .hour, .minute, .second],
            from: date
        )
        components.calendar = calendar
        components.timeZone = calendar.timeZone
        return components
    }
}
