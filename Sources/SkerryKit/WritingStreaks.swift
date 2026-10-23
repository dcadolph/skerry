import Foundation

/// WritingStreaks turns the days a library was written in into streak numbers.
public enum WritingStreaks {
    /// Result summarizes the writing days handed to compute.
    public struct Result: Equatable, Sendable {
        /// Distinct calendar days with any writing.
        public let activeDays: Int
        /// Consecutive days ending today or yesterday; zero once a full day is missed.
        public let current: Int
        /// Longest consecutive-day run anywhere in history.
        public let longest: Int

        /// Creates a result; public so tests and callers can state expectations.
        public init(activeDays: Int, current: Int, longest: Int) {
            self.activeDays = activeDays
            self.current = current
            self.longest = longest
        }
    }

    /// Computes streaks from the moments notes were created or edited. A day with no
    /// writing yet does not break the streak until it is over, so the current streak
    /// may end on yesterday.
    public static func compute(
        from dates: [Date], now: Date = Date(), calendar: Calendar = .current
    ) -> Result {
        let days = Set(dates.map { calendar.startOfDay(for: $0) })
        guard !days.isEmpty else { return Result(activeDays: 0, current: 0, longest: 0) }
        let sorted = days.sorted()
        var longest = 1
        var run = 1
        for (previous, day) in zip(sorted, sorted.dropFirst()) {
            if calendar.date(byAdding: .day, value: 1, to: previous) == day {
                run += 1
                longest = max(longest, run)
            } else {
                run = 1
            }
        }
        var cursor = calendar.startOfDay(for: now)
        if !days.contains(cursor) {
            cursor = calendar.date(byAdding: .day, value: -1, to: cursor) ?? cursor
        }
        var current = 0
        while days.contains(cursor) {
            current += 1
            guard let previous = calendar.date(byAdding: .day, value: -1, to: cursor) else { break }
            cursor = previous
        }
        return Result(activeDays: days.count, current: current, longest: longest)
    }
}
