import Foundation
import Testing

@testable import SkerryKit

@Suite struct NoteStatsTests {
    @Test func countsWordsIgnoringMarkers() {
        let stats = NoteStats(body: "# Title\n\nHello world, this is a note.")
        // The lone # is not a word; the seven prose tokens are.
        #expect(stats.words == 7)
    }

    @Test func emptyBodyHasNoWordsOrReadingTime() {
        let stats = NoteStats(body: "   \n\t  ")
        #expect(stats.words == 0)
        #expect(stats.readingMinutes == 0)
        #expect(stats.charactersNoSpaces == 0)
    }

    @Test func readingTimeRoundsUp() {
        let body = Array(repeating: "word", count: 201).joined(separator: " ")
        let stats = NoteStats(body: body)
        #expect(stats.words == 201)
        #expect(stats.readingMinutes == 2)
    }

    @Test func characterCountsWithAndWithoutSpaces() {
        let stats = NoteStats(body: "a b  c")
        #expect(stats.characters == 6)
        #expect(stats.charactersNoSpaces == 3)
    }

    @Test func emptyHeadingScaffoldCountsAsEmpty() {
        // A new note starts life as "# " so the first line typed becomes the title. Untouched, it
        // should read as empty rather than reporting the two marker characters.
        let stats = NoteStats(body: "# ")
        #expect(stats.words == 0)
        #expect(stats.characters == 0)
        #expect(stats.charactersNoSpaces == 0)
    }
}
