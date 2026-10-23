import Foundation
import Testing

@testable import SkerryKit

@Suite struct SearchFuzzyTests {
    @Test func rankFindsSingleCharacterTypos() {
        let matches = SearchFuzzy.rank(
            query: "harbr", candidates: ["Harbor Notes", "Grocery List", "Ferry Times"]
        )
        #expect(matches.map(\.index) == [0])
        #expect(matches.first?.distance == 1)
    }

    @Test func rankMatchesAnyWordOfACandidate() {
        // "meeting" is an interior word of the title, matched at distance zero.
        let matches = SearchFuzzy.rank(query: "meeting", candidates: ["Weekly Meeting Notes"])
        #expect(matches.map(\.index) == [0])
        #expect(matches.first?.distance == 0)
    }

    @Test func rankRejectsFarMisses() {
        let matches = SearchFuzzy.rank(query: "xyz", candidates: ["Harbor Notes", "Ferry Times"])
        #expect(matches.isEmpty)
    }

    @Test func rankOrdersByDistanceThenLength() {
        let matches = SearchFuzzy.rank(
            query: "harbor", candidates: ["Harbor", "Harber Long Title"]
        )
        // Exact match first, then the near miss.
        #expect(matches.map(\.index) == [0, 1])
        #expect(matches.first?.distance == 0)
    }

    @Test func rankRejectsEmptyQuery() {
        #expect(SearchFuzzy.rank(query: "", candidates: ["Anything"]).isEmpty)
    }

    @Test func rankStaysStrictForShortQueries() {
        // A one-edit budget for short queries keeps noise out.
        #expect(SearchFuzzy.rank(query: "cat", candidates: ["dog"]).isEmpty)
        #expect(SearchFuzzy.rank(query: "cat", candidates: ["cot"]).map(\.index) == [0])
    }
}
