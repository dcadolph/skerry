import Foundation
import Testing

@testable import SkerryKit

@Suite struct WikiLinkTests {
    @Test func splitSeparatesNoteAndHeading() {
        #expect(WikiLink.split("Harbor Plan") == WikiLink.Target(note: "Harbor Plan", heading: nil))
        #expect(WikiLink.split("Harbor#Plans") == WikiLink.Target(note: "Harbor", heading: "Plans"))
        #expect(
            WikiLink.split("Harbor # Sub Plans ")
                == WikiLink.Target(note: "Harbor", heading: "Sub Plans")
        )
        #expect(WikiLink.split("#Local") == WikiLink.Target(note: "", heading: "Local"))
        #expect(WikiLink.split("Harbor#") == WikiLink.Target(note: "Harbor", heading: nil))
    }

    @Test func backlinksResolveThroughAHeadingFragment() {
        var graph = LinkGraph()
        graph.update(path: "a.md", body: "see [[Harbor#Plans]] and [[Ferry]]")
        #expect(graph.sources(linkingTo: ["harbor"]).contains("a.md"))
        #expect(graph.sources(linkingTo: ["ferry"]).contains("a.md"))
        // The fragment is stripped, so the graph is not keyed by "harbor#plans".
        #expect(graph.sources(linkingTo: ["harbor#plans"]).isEmpty)
    }

    @Test func htmlHeadingsCarrySlugIds() {
        let html = MarkdownHTML.fragment("# Harbor Notes\n\ntext\n\n## Sub Heading!\n")
        #expect(html.contains("<h1 id=\"harbor-notes\">"))
        #expect(html.contains("<h2 id=\"sub-heading\">"))
    }

    @Test func duplicateHtmlHeadingsGetUniqueIds() {
        let html = MarkdownHTML.fragment("# Notes\n\na\n\n# Notes\n\nb\n")
        #expect(html.contains("id=\"notes\""))
        #expect(html.contains("id=\"notes-1\""))
    }

    @Test func wikiLinkToHeadingBecomesAFragmentHref() {
        let html = MarkdownHTML.fragment("jump to [[#Sub Heading]] and [[Harbor#Plans]].")
        #expect(html.contains("href=\"#sub-heading\""))
        #expect(html.contains("href=\"Harbor#plans\""))
        // A plain wiki link still renders exactly as before.
        #expect(MarkdownHTML.fragment("[[Ferry]]").contains("<a href=\"Ferry\">Ferry</a>"))
    }
}
