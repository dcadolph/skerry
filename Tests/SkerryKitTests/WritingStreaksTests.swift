import Foundation
import Testing

@testable import SkerryKit

@Suite struct WritingStreaksTests {
    /// Fixed UTC calendar so results do not depend on the machine's zone.
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    /// A UTC moment on a given day, mid-morning.
    private func day(_ year: Int, _ month: Int, _ day: Int, hour: Int = 9) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    @Test func emptyHistoryHasNoStreaks() {
        let result = WritingStreaks.compute(from: [], now: day(2026, 7, 20), calendar: calendar)
        #expect(result == WritingStreaks.Result(activeDays: 0, current: 0, longest: 0))
    }

    @Test func singleWriteTodayCountsOne() {
        let result = WritingStreaks.compute(
            from: [day(2026, 7, 20)], now: day(2026, 7, 20, hour: 22), calendar: calendar
        )
        #expect(result == WritingStreaks.Result(activeDays: 1, current: 1, longest: 1))
    }

    @Test func consecutiveDaysThroughTodayAllCount() {
        let dates = [day(2026, 7, 17), day(2026, 7, 18), day(2026, 7, 19), day(2026, 7, 20)]
        let result = WritingStreaks.compute(from: dates, now: day(2026, 7, 20), calendar: calendar)
        #expect(result == WritingStreaks.Result(activeDays: 4, current: 4, longest: 4))
    }

    @Test func nothingYetTodayKeepsYesterdayStreakAlive() {
        let dates = [day(2026, 7, 18), day(2026, 7, 19)]
        let result = WritingStreaks.compute(from: dates, now: day(2026, 7, 20), calendar: calendar)
        #expect(result.current == 2)
    }

    @Test func fullMissedDayEndsTheCurrentStreak() {
        let dates = [day(2026, 7, 15), day(2026, 7, 16), day(2026, 7, 17)]
        let result = WritingStreaks.compute(from: dates, now: day(2026, 7, 20), calendar: calendar)
        #expect(result == WritingStreaks.Result(activeDays: 3, current: 0, longest: 3))
    }

    @Test func longestRunSurvivesLaterGaps() {
        let dates = [
            day(2026, 6, 1), day(2026, 6, 2), day(2026, 6, 3), day(2026, 6, 4), day(2026, 6, 5),
            day(2026, 7, 19), day(2026, 7, 20),
        ]
        let result = WritingStreaks.compute(from: dates, now: day(2026, 7, 20), calendar: calendar)
        #expect(result == WritingStreaks.Result(activeDays: 7, current: 2, longest: 5))
    }

    @Test func manyWritesInOneDayCountOnce() {
        let dates = [
            day(2026, 7, 20, hour: 1), day(2026, 7, 20, hour: 12), day(2026, 7, 20, hour: 23),
            day(2026, 7, 19, hour: 5), day(2026, 7, 19, hour: 18),
        ]
        let result = WritingStreaks.compute(from: dates, now: day(2026, 7, 20), calendar: calendar)
        #expect(result == WritingStreaks.Result(activeDays: 2, current: 2, longest: 2))
    }

    @Test func taskCountsMatchCheckboxLines() {
        let body = """
        # List

        - [ ] eggs
        - [x] milk
        * [ ] bread
        + [X] jam
        - [not a task]
        plain line
        """
        #expect(NoteQueries.openTaskCount(body) == 2)
        #expect(NoteQueries.doneTaskCount(body) == 2)
        #expect(NoteQueries.openTaskCount("") == 0)
    }
}
