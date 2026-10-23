import Foundation

/// SearchFuzzy ranks candidate strings by how close they are to a query, so a mistyped
/// search still surfaces the note the user meant. It is the fallback the index reaches for
/// only when exact and prefix matching find nothing, so its cost is paid rarely.
public enum SearchFuzzy {
    /// One ranked candidate: its position in the input list and its edit distance.
    public struct Match: Equatable, Sendable {
        /// Index of the candidate in the list handed to ``rank(query:candidates:)``.
        public let index: Int
        /// Best edit distance found between the query and the candidate.
        public let distance: Int

        /// Creates a match.
        public init(index: Int, distance: Int) {
            self.index = index
            self.distance = distance
        }
    }

    /// Candidates within an edit-distance budget of the query, closest first. The budget
    /// scales with query length so short queries stay strict and long ones tolerate more
    /// slips. Each candidate is judged by its closest word as well as the whole string, so a
    /// query matches one word of a multi-word title.
    public static func rank(query: String, candidates: [String]) -> [Match] {
        let needle = query.lowercased()
        guard !needle.isEmpty else { return [] }
        let budget = needle.count <= 3 ? 1 : needle.count <= 6 ? 2 : 3
        var matches: [Match] = []
        for (index, candidate) in candidates.enumerated() {
            let distance = bestDistance(needle: needle, haystack: candidate, budget: budget)
            if distance <= budget {
                matches.append(Match(index: index, distance: distance))
            }
        }
        return matches.sorted {
            $0.distance != $1.distance
                ? $0.distance < $1.distance
                : candidates[$0.index].count < candidates[$1.index].count
        }
    }

    /// The smallest edit distance between the needle and the whole candidate or any single
    /// word of it, giving up as soon as the budget is beaten so long strings stay cheap.
    private static func bestDistance(needle: String, haystack: String, budget: Int) -> Int {
        let whole = haystack.lowercased()
        var best = boundedDistance(needle, whole, budget: budget)
        if best == 0 { return 0 }
        for word in whole.split(whereSeparator: { !$0.isLetter && !$0.isNumber }) {
            best = min(best, boundedDistance(needle, String(word), budget: budget))
            if best == 0 { break }
        }
        return best
    }

    /// Levenshtein distance capped at a budget: returns budget + 1 the moment every cell in
    /// a row exceeds the budget, so a far-off candidate never pays for the full matrix.
    private static func boundedDistance(_ lhs: String, _ rhs: String, budget: Int) -> Int {
        let a = Array(lhs.unicodeScalars)
        let b = Array(rhs.unicodeScalars)
        if abs(a.count - b.count) > budget { return budget + 1 }
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var previous = Array(0...b.count)
        var current = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            current[0] = i
            var rowBest = current[0]
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
                rowBest = min(rowBest, current[j])
            }
            if rowBest > budget { return budget + 1 }
            swap(&previous, &current)
        }
        return previous[b.count]
    }
}
