import Foundation
import Testing

@testable import SkerryKit

@Suite struct HTMLToMarkdownTests {
    @Test func headingsParagraphsAndEmphasisConvert() {
        let html = "<h1>Title</h1><p>Some <strong>bold</strong> and <em>italic</em> words.</p>"
        let markdown = HTMLToMarkdown.convert(html)
        #expect(markdown.hasPrefix("# Title"))
        #expect(markdown.contains("**bold**"))
        #expect(markdown.contains("*italic*"))
    }

    @Test func linksAndImagesConvert() {
        let html = #"<p>Read <a href="https://example.com/post">the post</a>.</p><img src="https://example.com/pic.png">"#
        let markdown = HTMLToMarkdown.convert(html)
        #expect(markdown.contains("[the post](https://example.com/post)"))
        #expect(markdown.contains("![](https://example.com/pic.png)"))
    }

    @Test func listsAndQuotesConvert() {
        let html = "<ul><li>one</li><li>two</li></ul><blockquote>wise words</blockquote>"
        let markdown = HTMLToMarkdown.convert(html)
        #expect(markdown.contains("- one"))
        #expect(markdown.contains("- two"))
        #expect(markdown.contains("> wise words"))
    }

    @Test func codeBlocksSurvive() {
        let html = "<pre><code>let x = 1\nlet y = 2</code></pre><p>and <code>inline</code></p>"
        let markdown = HTMLToMarkdown.convert(html)
        #expect(markdown.contains("```\nlet x = 1\nlet y = 2\n```"))
        #expect(markdown.contains("`inline`"))
    }

    @Test func scriptsStylesAndCommentsVanish() {
        let html = "<script>alert(1)</script><style>p{}</style><!-- hidden --><p>kept</p>"
        let markdown = HTMLToMarkdown.convert(html)
        #expect(markdown == "kept")
    }

    @Test func entitiesDecode() {
        let markdown = HTMLToMarkdown.convert("<p>Fish &amp; chips &mdash; &#8220;good&#x201D;&nbsp;&gt;</p>")
        #expect(markdown == "Fish & chips \u{2014} \u{201C}good\u{201D} >")
    }

    @Test func htmlSniffingIsConservative() {
        #expect(HTMLToMarkdown.looksLikeHTML("<p>real markup</p>"))
        #expect(HTMLToMarkdown.looksLikeHTML("text with <div class=\"x\">"))
        #expect(!HTMLToMarkdown.looksLikeHTML("plain words about 2 < 3 things"))
        #expect(!HTMLToMarkdown.looksLikeHTML("markdown with [links](url)"))
    }

    @Test func pageTitlesExtractAndDecode() {
        let html = "<html><head><title>  Fish &amp; Chips \n Weekly  </title></head><body></body></html>"
        #expect(HTMLToMarkdown.pageTitle(in: html) == "Fish & Chips Weekly")
        #expect(HTMLToMarkdown.pageTitle(in: "<p>no title here</p>") == nil)
        #expect(HTMLToMarkdown.pageTitle(in: "<title></title>") == nil)
    }

    @Test func fullPageBoilerplateReducesToArticle() {
        let html = """
        <html><head><title>T</title><style>body{}</style></head><body>
        <nav><a href="/">home</a></nav>
        <article><h2>The Point</h2><p>First para.</p><p>Second para.</p></article>
        <footer>copyright</footer>
        </body></html>
        """
        let markdown = HTMLToMarkdown.convert(html)
        #expect(markdown.contains("## The Point"))
        #expect(markdown.contains("First para."))
        #expect(!markdown.contains("home"))
        #expect(!markdown.contains("copyright"))
    }
}
