import DeviceActivity
import Foundation
import PagePassCore

struct EarnedTimeScheduler {
    enum SchedulerError: LocalizedError {
        case invalidDuration
        case invalidSchedule
        case registrationMismatch

        var errorDescription: String? {
            switch self {
            case .invalidDuration: "The Earned Time duration is invalid."
            case .invalidSchedule: "The Earned Time schedule could not be created."
            case .registrationMismatch: "Screen Time did not preserve the requested schedule."
            }
        }
    }

    private let center = DeviceActivityCenter()

    func start(
        sessionID: UUID,
        durationSeconds: Int,
        now: Date = Date(),
        calendar: Calendar = .current
    ) throws {
        guard durationSeconds >= EarnedTimeSessionRules.minimumDurationSeconds else {
            throw SchedulerError.invalidDuration
        }
        guard let scheduleStart = calendar.date(byAdding: .second, value: -1, to: now),
              let scheduleEnd = calendar.date(byAdding: .second, value: durationSeconds, to: now) else {
            throw SchedulerError.invalidSchedule
        }

        let schedule = DeviceActivitySchedule(
            intervalStart: dateComponents(for: scheduleStart, calendar: calendar),
            intervalEnd: dateComponents(for: scheduleEnd, calendar: calendar),
            repeats: false
        )
        guard schedule.nextInterval != nil else {
            throw SchedulerError.invalidSchedule
        }

        let activity = PagePassScreenTime.activityName(for: sessionID)
        let stale = center.activities.filter(PagePassScreenTime.isEarnedTimeActivity)
        center.stopMonitoring(stale)
        try center.startMonitoring(activity, during: schedule, events: [:])

        guard center.activities.contains(activity),
              center.schedule(for: activity) == schedule,
              center.events(for: activity).isEmpty else {
            center.stopMonitoring([activity])
            throw SchedulerError.registrationMismatch
        }
    }

    func stop(sessionID: UUID) {
        center.stopMonitoring([PagePassScreenTime.activityName(for: sessionID)])
    }

    private func dateComponents(
        for date: Date,
        calendar: Calendar
    ) -> DateComponents {
        var components = calendar.dateComponents(
            [.calendar, .timeZone, .era, .year, .month, .day, .hour, .minute, .second],
            from: date
        )
        components.nanosecond = nil
        components.weekday = nil
        return components
    }
}

