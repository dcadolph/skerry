import Foundation
import Testing

@testable import SkerryKit

@Suite struct NoteIndexTests {
    /// Builds an in-memory index seeded with a few notes.
    private func makeIndex() throws -> NoteIndex {
        let index = try NoteIndex(databasePath: ":memory:")
        var ferry = Note.Metadata()
        ferry.title = "Ferry timetable"
        ferry.tags = ["travel", "scotland"]
        try index.upsert(
            StoredNote(path: "travel/ferry.md", note: Note(metadata: ferry, body: "Oban to Mull."))
        )
        try index.upsert(
            StoredNote(path: "inbox.md", note: Note(body: "# Groceries\n\neggs and oats"))
        )
        return index
    }

    @Test func matchesTitleTagsAndBody() throws {
        let index = try makeIndex()
        #expect(try index.search("ferry").map(\.path) == ["travel/ferry.md"])
        #expect(try index.search("scotland").map(\.path) == ["travel/ferry.md"])
        #expect(try index.search("oats").map(\.path) == ["inbox.md"])
        #expect(try index.search("groceries").first?.title == "Groceries")
    }

    @Test func prefixQueryMatches() throws {
        let index = try makeIndex()
        #expect(try index.search("timeta").map(\.path) == ["travel/ferry.md"])
    }

    @Test func titleMatchesOutrankBodyMatches() throws {
        let index = try NoteIndex(databasePath: ":memory:")
        var titled = Note.Metadata()
        titled.title = "Harbor"
        try index.upsert(
            StoredNote(path: "titled.md", note: Note(metadata: titled, body: "a quiet morning"))
        )
        try index.upsert(
            StoredNote(path: "body.md", note: Note(body: "we reached the harbor at dusk"))
        )
        // Both notes contain "harbor", but the title hit must rank above the body hit.
        #expect(try index.search("harbor").map(\.path) == ["titled.md", "body.md"])
    }

    @Test func tagMatchesOutrankBodyMatches() throws {
        let index = try NoteIndex(databasePath: ":memory:")
        var tagged = Note.Metadata()
        tagged.tags = ["harbor"]
        try index.upsert(
            StoredNote(path: "tagged.md", note: Note(metadata: tagged, body: "a quiet morning"))
        )
        try index.upsert(
            StoredNote(path: "body.md", note: Note(body: "we reached the harbor at dusk"))
        )
        #expect(try index.search("harbor").first?.path == "tagged.md")
    }

    @Test func upsertReplacesExistingPath() throws {
        let index = try makeIndex()
        try index.upsert(StoredNote(path: "inbox.md", note: Note(body: "now about kayaks")))
        #expect(try index.search("oats").isEmpty)
        #expect(try index.search("kayaks").map(\.path) == ["inbox.md"])
    }

    @Test func removeDropsPath() throws {
        let index = try makeIndex()
        try index.remove("travel/ferry.md")
        #expect(try index.search("ferry").isEmpty)
    }

    @Test func searchReturnsAllHitsButSnippetsOnlyTheTopOnes() throws {
        let index = try NoteIndex(databasePath: ":memory:")
        for i in 0..<6 {
            var meta = Note.Metadata()
            meta.title = "Harbor \(i)"
            try index.upsert(
                StoredNote(path: "n\(i).md", note: Note(metadata: meta, body: "harbor tide table \(i)"))
            )
        }
        let hits = try index.search("harbor", snippetLimit: 2)
        // Every matching note comes back, so folder and filter intersection keeps full coverage.
        #expect(hits.count == 6)
        // Only the top hits carry a prebuilt excerpt; the costly snippet work is bounded.
        #expect(hits.filter { !$0.snippet.isEmpty }.count == 2)
    }

    @Test func operatorInputIsLiteralNotSyntax() throws {
        let index = try makeIndex()
        #expect(try index.search("NEAR(").isEmpty)
        #expect(try index.search("\"eggs").map(\.path) == ["inbox.md"])
        #expect(try index.search("").isEmpty)
    }

    @Test func scrubLeavesIndexQueryable() throws {
        let index = try makeIndex()
        try index.remove("travel/ferry.md")
        try index.scrub()
        #expect(try index.search("ferry").isEmpty)
        #expect(try index.search("oats").map(\.path) == ["inbox.md"])
    }

    @Test func searchReturnsHighlightedBodySnippet() throws {
        let index = try makeIndex()
        let hit = try #require(try index.search("oats").first)
        #expect(hit.snippet.contains("oats"))
        #expect(!hit.snippet.contains("\u{02}"))
        // The highlight range points at the matched term inside the snippet.
        let range = try #require(hit.highlights.first)
        let matched = (hit.snippet as NSString).substring(with: range)
        #expect(matched.lowercased() == "oats")
        #expect(!hit.fuzzy)
    }

    @Test func searchFallsBackToFuzzyOnTypos() throws {
        let index = try makeIndex()
        // "feryr" matches nothing exactly, so the fuzzy pass catches "Ferry timetable".
        let hits = try index.search("feryr")
        #expect(hits.map(\.path) == ["travel/ferry.md"])
        #expect(hits.first?.fuzzy == true)
    }

    @Test func parseSnippetSplitsMarksIntoRanges() {
        let (text, highlights) = NoteIndex.parseSnippet("eggs and \u{02}oats\u{03} today")
        #expect(text == "eggs and oats today")
        #expect(highlights == [NSRange(location: 9, length: 4)])
    }

    @Test func parseSnippetHandlesNoMarks() {
        let (text, highlights) = NoteIndex.parseSnippet("plain text")
        #expect(text == "plain text")
        #expect(highlights.isEmpty)
    }
}
