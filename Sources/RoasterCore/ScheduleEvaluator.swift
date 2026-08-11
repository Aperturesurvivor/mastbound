import Foundation

public enum ScheduleEvaluator {
    public static func activeInterval(
        at date: Date,
        schedule: BlockSchedule,
        calendar inputCalendar: Calendar = .autoupdatingCurrent
    ) throws -> DateInterval? {
        try schedule.validate()
        var calendar = inputCalendar
        if calendar.timeZone.identifier == "GMT" && inputCalendar == .autoupdatingCurrent {
            calendar.timeZone = .autoupdatingCurrent
        }

        let components = calendar.dateComponents([.weekday, .hour, .minute], from: date)
        guard let weekday = components.weekday,
              let hour = components.hour,
              let minute = components.minute else {
            throw RoasterError.invalidSchedule("Could not resolve the current local time.")
        }
        let minuteOfDay = hour * 60 + minute

        if schedule.startMinute < schedule.endMinute {
            guard schedule.weekdays.contains(weekday),
                  minuteOfDay >= schedule.startMinute,
                  minuteOfDay < schedule.endMinute else { return nil }
            let day = calendar.startOfDay(for: date)
            return try interval(startDay: day, schedule: schedule, calendar: calendar)
        }

        if minuteOfDay >= schedule.startMinute {
            guard schedule.weekdays.contains(weekday) else { return nil }
            let day = calendar.startOfDay(for: date)
            return try interval(startDay: day, schedule: schedule, calendar: calendar)
        }

        guard minuteOfDay < schedule.endMinute,
              let priorDay = calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: date)) else {
            return nil
        }
        let priorWeekday = calendar.component(.weekday, from: priorDay)
        guard schedule.weekdays.contains(priorWeekday) else { return nil }
        return try interval(startDay: priorDay, schedule: schedule, calendar: calendar)
    }

    private static func interval(
        startDay: Date,
        schedule: BlockSchedule,
        calendar: Calendar
    ) throws -> DateInterval {
        guard let start = calendar.date(
            byAdding: .minute,
            value: schedule.startMinute,
            to: startDay
        ) else {
            throw RoasterError.invalidSchedule("Could not resolve the schedule start.")
        }

        let endDay: Date
        if schedule.startMinute > schedule.endMinute {
            guard let nextDay = calendar.date(byAdding: .day, value: 1, to: startDay) else {
                throw RoasterError.invalidSchedule("Could not resolve the next calendar day.")
            }
            endDay = nextDay
        } else {
            endDay = startDay
        }

        guard let end = calendar.date(
            byAdding: .minute,
            value: schedule.endMinute,
            to: endDay
        ), end > start else {
            throw RoasterError.invalidSchedule("Could not resolve the schedule end.")
        }
        return DateInterval(start: start, end: end)
    }
}
