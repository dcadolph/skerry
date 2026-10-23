import Foundation
import Testing

@testable import SkerryKit

@Suite struct NoteImporterTests {
    @Test func inlineTagsBecomeMetadataTags() {
        let result = NoteImporter.importMarkdown(
            "# Trip\n\nBooked the ferry. #travel #scotland/skye", fileName: "trip.md"
        )
        #expect(result.note.metadata.tags == ["travel", "scotland/skye"])
    }

    @Test func headingIsNotMistakenForATag() {
        // A heading has a space after the hash, so it must never be read as a tag.
        let result = NoteImporter.importMarkdown("# Heading\n\n## Sub\n\nBody.", fileName: "n.md")
        #expect(result.note.metadata.tags.isEmpty)
    }

    @Test func firstHeadingBecomesTheFileStem() {
        let result = NoteImporter.importMarkdown("# Ferry Times\n\nBody.", fileName: "raw-note.md")
        #expect(result.name == "Ferry Times")
    }

    @Test func fileNameSeedsTheStemWithoutAHeading() {
        let result = NoteImporter.importMarkdown("Just body text.", fileName: "My Note.md")
        #expect(result.name == "My Note")
    }

    @Test func frontMatterTagsMergeWithInlineTagsWithoutDuplicates() {
        let text = "---\ntags: [work, travel]\n---\n\n# Plan\n\n#Travel #budget"
        let result = NoteImporter.importMarkdown(text, fileName: "plan.md")
        // Front matter order first, inline appended, case-insensitive dedupe keeps first casing.
        #expect(result.note.metadata.tags == ["work", "travel", "budget"])
    }

    @Test func fileDatesFillInMissingTimestamps() {
        let created = Date(timeIntervalSince1970: 1_600_000_000)
        let modified = Date(timeIntervalSince1970: 1_600_100_000)
        let result = NoteImporter.importMarkdown(
            "# X\n\nBody.", fileName: "x.md", created: created, modified: modified
        )
        #expect(result.note.metadata.created == created)
        #expect(result.note.metadata.updated == modified)
    }

    @Test func slashesInTheTitleAreSanitizedOutOfTheStem() {
        let result = NoteImporter.importMarkdown("# A/B: Notes\n\nBody.", fileName: "n.md")
        #expect(!result.name.contains("/"))
        #expect(!result.name.contains(":"))
    }

    @Test func everyImportGetsAStableIdentity() {
        let result = NoteImporter.importMarkdown("# X\n\nBody.", fileName: "x.md")
        #expect(result.note.metadata.id != nil)
    }
}
