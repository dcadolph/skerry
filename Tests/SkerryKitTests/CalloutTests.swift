import Foundation
import Testing

@testable import SkerryKit

@Suite struct CalloutTests {
    @Test func calloutHeaderTokenizes() {
        let text = "> [!warning] Check the tide\n> before you launch\n"
        let kinds = MarkdownScanner.scan(text).map(\.kind)
        #expect(kinds == [.calloutHeader, .blockquote])
    }

    @Test func plainQuotesStayQuotes() {
        let kinds = MarkdownScanner.scan("> just a quote\n").map(\.kind)
        #expect(kinds == [.blockquote])
    }

    @Test func calloutRendersWithKindColorAndTitle() {
        let html = MarkdownHTML.fragment("> [!tip] Pack light\n> One bag is enough.")
        #expect(html.contains("class=\"callout\""))
        #expect(html.contains("Pack light"))
        #expect(html.contains("One bag is enough."))
        #expect(html.contains(MarkdownHTML.calloutKinds["tip"]!.color))
        #expect(!html.contains("[!tip]"))
    }

    @Test func calloutWithoutTitleUsesTheKindLabel() {
        let html = MarkdownHTML.fragment("> [!important]\n> Read this first.")
        #expect(html.contains(">Important</p>"))
    }

    @Test func unknownKindFallsBackToNote() {
        let html = MarkdownHTML.fragment("> [!banana] Odd one\n> body")
        #expect(html.contains(MarkdownHTML.calloutKinds["note"]!.color))
        #expect(html.contains("Odd one"))
    }

    @Test func multiLineQuotesJoinIntoOneBlock() {
        let html = MarkdownHTML.fragment("> first line\n> second line")
        let blocks = html.components(separatedBy: "<blockquote>").count - 1
        #expect(blocks == 1)
        #expect(html.contains("first line<br>second line"))
    }
}
