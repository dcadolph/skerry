import Foundation
import Testing

@testable import SkerryKit

@Suite struct FrontMatterTests {
    @Test func parsesFullBlock() {
        let text = """
            ---
            id: 7A0E38D2-4CBB-4E30-9A57-2A9F3D1B6C11
            title: "Ferry: timetable"
            tags: [travel, scotland]
            starred: true
            created: 2026-07-13T09:30:00Z
            zettel: 20260713a
            ---

            # Ferry timetable research

            Body.
            """
        let note = FrontMatter.parseNote(text)
        #expect(note.metadata.id?.uuidString == "7A0E38D2-4CBB-4E30-9A57-2A9F3D1B6C11")
        #expect(note.metadata.title == "Ferry: timetable")
        #expect(note.metadata.tags == ["travel", "scotland"])
        #expect(note.metadata.starred)
        #expect(!note.metadata.pinned)
        #expect(note.metadata.created != nil)
        #expect(note.metadata.unknown.count == 1)
        #expect(note.metadata.unknown.first?.key == "zettel")
        #expect(note.body.hasPrefix("# Ferry timetable research"))
    }

    @Test func plainFileHasEmptyMetadata() {
        let note = FrontMatter.parseNote("just markdown\n")
        #expect(note.metadata == Note.Metadata())
        #expect(note.body == "just markdown\n")
    }

    @Test func unterminatedBlockIsBody() {
        let text = "---\ntitle: dangling\nno closing line"
        let note = FrontMatter.parseNote(text)
        #expect(note.metadata.title == nil)
        #expect(note.body == text)
    }

    @Test func roundTripPreservesEverything() {
        var metadata = Note.Metadata()
        metadata.id = UUID()
        metadata.title = "Notes: #1, \"quoted\""
        metadata.tags = ["a", "b c"]
        metadata.starred = true
        metadata.archived = true
        metadata.created = FrontMatter.parseDate("2026-07-13T09:30:00Z")
        metadata.unknown = [(key: "zettel", rawValue: "20260713a")]
        let original = Note(metadata: metadata, body: "Body line.\n")

        let reparsed = FrontMatter.parseNote(FrontMatter.serializeNote(original))
        #expect(reparsed == original)
    }

    @Test func emptyMetadataSerializesToBareBody() {
        let note = Note(metadata: Note.Metadata(), body: "only body\n")
        #expect(FrontMatter.serializeNote(note) == "only body\n")
    }

    @Test func displayTitleFallsBackToFirstH1() {
        let note = FrontMatter.parseNote("intro text\n\n# Actual Title\n\nmore")
        #expect(note.displayTitle == "Actual Title")
    }

    @Test func tagsWithCommasSurviveRoundTrip() {
        var metadata = Note.Metadata()
        metadata.tags = ["plain", "a, b", "c"]
        let note = Note(metadata: metadata, body: "body\n")
        let reparsed = FrontMatter.parseNote(FrontMatter.serializeNote(note))
        #expect(reparsed.metadata.tags == ["plain", "a, b", "c"])
    }

    @Test func bodyOpeningWithARuleIsNotEatenAsFrontMatter() {
        let text = "---\nSome intro text.\n---\nMore body.\n"
        let note = FrontMatter.parseNote(text)
        #expect(note.metadata == Note.Metadata())
        #expect(note.body == text)
    }
}
