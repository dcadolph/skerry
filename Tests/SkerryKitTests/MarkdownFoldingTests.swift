import Foundation
import Testing

@testable import SkerryKit

@Suite struct MarkdownFoldingTests {
    private let document = """
    intro line

    # Harbor
    rope note
    tar note

    ## Supplies
    twine

    # Weather
    fog tomorrow
    """

    @Test func sectionsNestByHeadingRank() {
        let sections = MarkdownFolding.sections(in: document)
        #expect(sections.map(\.title) == ["# Harbor", "## Supplies", "# Weather"])
        let ns = document as NSString
        let harbor = sections[0]
        // Harbor's body runs to the next same-rank heading, Supplies included.
        #expect(ns.substring(with: harbor.body).contains("twine"))
        #expect(!ns.substring(with: harbor.body).contains("# Weather"))
        let supplies = sections[1]
        #expect(ns.substring(with: supplies.body) == "twine\n\n")
    }

    @Test func caretFindsItsInnermostSection() {
        let ns = document as NSString
        let twine = ns.range(of: "twine").location
        #expect(MarkdownFolding.section(atCaret: twine, in: document)?.title == "## Supplies")
        let rope = ns.range(of: "rope").location
        #expect(MarkdownFolding.section(atCaret: rope, in: document)?.title == "# Harbor")
        #expect(MarkdownFolding.section(atCaret: 0, in: document) == nil)
    }

    @Test func foldedBodiesFollowFoldIDs() {
        let weather = MarkdownFolding.sections(in: document).first { $0.title == "# Weather" }
        let bodies = MarkdownFolding.foldedBodies(
            in: document, foldedIDs: [weather?.foldID ?? ""]
        )
        #expect(bodies.count == 1)
        #expect((document as NSString).substring(with: bodies[0]) == "fog tomorrow")
        #expect(MarkdownFolding.foldedBodies(in: document, foldedIDs: []).isEmpty)
    }

    @Test func identicalHeadingsFoldIndependently() {
        let doc = "## Notes\nalpha\n## Other\nx\n## Notes\nbeta\n"
        let notes = MarkdownFolding.sections(in: doc).filter { $0.title == "## Notes" }
        #expect(notes.count == 2)
        #expect(notes[0].foldID != notes[1].foldID)
        // Folding the first "## Notes" hides only its body, not the identical one below it.
        let folded = MarkdownFolding.foldedBodies(in: doc, foldedIDs: [notes[0].foldID])
        #expect(folded.count == 1)
        #expect((doc as NSString).substring(with: folded[0]) == "alpha\n")
    }

    @Test func headingWithoutBodyDoesNotFold() {
        // The first heading has no body before the next same-rank heading, and the
        // second ends the document with nothing under it, so neither is foldable.
        let sections = MarkdownFolding.sections(in: "# Lonely\n# Also Lonely")
        #expect(sections.isEmpty)
    }

    @Test func headingsIncludeBodylessOnes() {
        let doc = "# Lonely\n## Supplies\ntwine\n# Also Lonely"
        #expect(MarkdownFolding.headings(in: doc).map(\.text) == ["Lonely", "Supplies", "Also Lonely"])
        #expect(MarkdownFolding.headings(in: doc).map(\.level) == [1, 2, 1])
        // "Also Lonely" ends the document with nothing under it, so it folds nowhere and
        // never becomes a section, yet still counts as a heading above.
        #expect(MarkdownFolding.sections(in: doc).map(\.title) == ["# Lonely", "## Supplies"])
    }

    @Test func headingLookupMatchesBareName() {
        let doc = "# Harbor\nrope\n## Supplies\ntwine\n"
        let ns = doc as NSString
        let supplies = MarkdownFolding.heading(named: "supplies", in: doc)
        #expect(supplies?.text == "Supplies")
        let suppliesLine = ns.substring(with: supplies?.line ?? NSRange())
        #expect(suppliesLine.contains("## Supplies"))
        #expect(MarkdownFolding.heading(named: "  Harbor ", in: doc)?.text == "Harbor")
        #expect(MarkdownFolding.heading(named: "missing", in: doc) == nil)
        #expect(MarkdownFolding.heading(named: "", in: doc) == nil)
    }

    @Test func headingTextStripsHashes() {
        #expect(MarkdownFolding.headingText("### Weather ") == "Weather")
        #expect(MarkdownFolding.headingText("# Harbor\n") == "Harbor")
    }

    @Test func restyleStaysLocalExceptForBackticks() {
        let text = "first\n\nsecond paragraph\n\nthird\n"
        let ns = text as NSString
        let edit = ns.range(of: "second")
        #expect(!MarkdownEditing.editRequiresFullRestyle(
            replacing: edit, with: "SECOND", in: text
        ))
        #expect(MarkdownEditing.editRequiresFullRestyle(
            replacing: edit, with: "`code`", in: text
        ))
        let fence = ns.range(of: "second paragraph")
        let backticked = "first\n\n```swift\n\n```\n\nthird\n"
        #expect(MarkdownEditing.editRequiresFullRestyle(
            replacing: (backticked as NSString).range(of: "```swift"),
            with: "x", in: backticked
        ))
        _ = fence
    }

    @Test func paragraphsAroundExpandsOneEachWay() {
        let text = "alpha\nbeta\ngamma\ndelta\n"
        let ns = text as NSString
        let around = MarkdownEditing.paragraphsAround(ns.range(of: "gamma"), in: text)
        let covered = ns.substring(with: around)
        #expect(covered == "beta\ngamma\ndelta\n")
        let atStart = MarkdownEditing.paragraphsAround(ns.range(of: "alpha"), in: text)
        #expect(ns.substring(with: atStart) == "alpha\nbeta\n")
        let pastEnd = MarkdownEditing.paragraphsAround(
            NSRange(location: ns.length + 5, length: 3), in: text
        )
        #expect(pastEnd.location + pastEnd.length <= ns.length)
    }
}
