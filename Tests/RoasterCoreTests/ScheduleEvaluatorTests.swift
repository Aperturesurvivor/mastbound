import Foundation
import Testing
@testable import RoasterCore

private var testCalendar: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    return calendar
}

private func testDate(_ value: String) -> Date {
    ISO8601DateFormatter().date(from: value)!
}

@Test func overnightScheduleIsActiveOnBothSidesOfMidnight() throws {
    let schedule = BlockSchedule(startMinute: 22 * 60, endMinute: 7 * 60)
    #expect(try ScheduleEvaluator.activeInterval(
        at: testDate("2026-08-11T22:30:00Z"), schedule: schedule, calendar: testCalendar
    ) != nil)
    #expect(try ScheduleEvaluator.activeInterval(
        at: testDate("2026-08-12T06:59:00Z"), schedule: schedule, calendar: testCalendar
    ) != nil)
    #expect(try ScheduleEvaluator.activeInterval(
        at: testDate("2026-08-12T07:00:00Z"), schedule: schedule, calendar: testCalendar
    ) == nil)
}

@Test func afterMidnightUsesPriorDaysEnablement() throws {
    let schedule = BlockSchedule(startMinute: 22 * 60, endMinute: 7 * 60, weekdays: [3])
    #expect(try ScheduleEvaluator.activeInterval(
        at: testDate("2026-08-12T01:00:00Z"), schedule: schedule, calendar: testCalendar
    ) != nil)
    #expect(try ScheduleEvaluator.activeInterval(
        at: testDate("2026-08-13T01:00:00Z"), schedule: schedule, calendar: testCalendar
    ) == nil)
}
