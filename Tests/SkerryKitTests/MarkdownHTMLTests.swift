import Foundation
import Testing

@testable import SkerryKit

@Suite struct MarkdownHTMLTests {
    @Test func headingsAndParagraphs() {
        let html = MarkdownHTML.fragment("# Title\n\nA paragraph.")
        #expect(html.contains("<h1 id=\"title\">Title</h1>"))
        #expect(html.contains("<p>A paragraph.</p>"))
    }

    @Test func inlineEmphasisAndCode() {
        let html = MarkdownHTML.fragment("Some **bold**, *italic*, `code`, and ~~gone~~.")
        #expect(html.contains("<strong>bold</strong>"))
        #expect(html.contains("<em>italic</em>"))
        #expect(html.contains("<code>code</code>"))
        #expect(html.contains("<del>gone</del>"))
    }

    @Test func bulletAndTaskLists() {
        let html = MarkdownHTML.fragment("- one\n- two")
        #expect(html.contains("<ul>"))
        #expect(html.contains("<li>one</li>"))
        let tasks = MarkdownHTML.fragment("- [ ] open\n- [x] done")
        #expect(tasks.contains("<input type=\"checkbox\" disabled > open"))
        #expect(tasks.contains("<input type=\"checkbox\" disabled checked> done"))
    }

    @Test func codeBlockPreservesContent() {
        let html = MarkdownHTML.fragment("```\nlet x = 1 < 2\n```")
        #expect(html.contains("<pre><code>let x = 1 &lt; 2</code></pre>"))
    }

    @Test func linksWikiLinksAndRules() {
        let html = MarkdownHTML.fragment("See [docs](https://x.y) and [[Note]].\n\n---")
        #expect(html.contains("<a href=\"https://x.y\">docs</a>"))
        #expect(html.contains("<a href=\"Note\">Note</a>"))
        #expect(html.contains("<hr>"))
    }

    @Test func htmlIsEscaped() {
        let html = MarkdownHTML.fragment("a < b & c > d")
        #expect(html.contains("a &lt; b &amp; c &gt; d"))
    }

    @Test func documentWrapsFragment() {
        let doc = MarkdownHTML.document(title: "T", markdown: "# H")
        #expect(doc.contains("<!doctype html>"))
        #expect(doc.contains("<title>T</title>"))
        #expect(doc.contains("<h1 id=\"h\">H</h1>"))
    }

    @Test func linkURLsAreAttributeEscaped() {
        let html = MarkdownHTML.fragment("[x](http://a\" onmouseover=\"alert(1)")
        #expect(!html.contains("onmouseover=\"alert"))
        #expect(html.contains("&quot;"))
    }

    @Test func unsafeLinkSchemesAreNeutralized() {
        let html = MarkdownHTML.fragment("[x](javascript:alert(1)")
        #expect(!html.lowercased().contains("javascript:"))
        #expect(html.contains("<a href=\"\">x</a>"))
    }
}
