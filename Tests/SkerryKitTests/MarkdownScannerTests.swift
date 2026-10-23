import Foundation
import Testing

@testable import SkerryKit

@Suite struct MarkdownScannerTests {
    /// Convenience: kinds of every token over a text, in order.
    private func kinds(_ text: String) -> [MarkdownScanner.TokenKind] {
        MarkdownScanner.scan(text).map(\.kind)
    }

    /// Convenience: substring a token covers.
    private func covered(_ text: String, _ token: MarkdownScanner.Token) -> String {
        (text as NSString).substring(with: token.range)
    }

    @Test func headingLevelsAndBounds() {
        let text = "# One\n\n### Three\n####### seven is prose\n#nospace\n"
        let tokens = MarkdownScanner.scan(text)
        // A hash glued to a word with no space is an inline tag, not a heading.
        #expect(tokens.map(\.kind) == [.heading(level: 1), .heading(level: 3), .tag])
        #expect(covered(text, tokens[0]) == "# One")
        #expect(covered(text, tokens[1]) == "### Three")
        #expect(covered(text, tokens[2]) == "#nospace")
    }

    @Test func fencedBlockSuppressesInlineScanning() {
        let text = "```\n**not bold** `not code`\n```\nafter *real*\n"
        let tokens = MarkdownScanner.scan(text)
        // Prose styling stays out of the fence; code coloring may appear instead.
        #expect(!tokens.contains { $0.kind == .bold })
        #expect(!tokens.contains { $0.kind == .inlineCode })
        #expect(tokens.filter { $0.kind == .fencedCode }.count == 3)
        let italic = tokens.first { $0.kind == .italic }
        #expect(italic.map { covered(text, $0) } == "*real*")
    }

    @Test func unterminatedFenceRunsToEnd() {
        let text = "```swift\nlet x = 1\n"
        let found = kinds(text)
        #expect(found.filter { $0 == .fencedCode }.count == 2)
        #expect(found.contains(.codeKeyword))
    }

    @Test func boldItalicCodeLinkSpans() {
        let text = "mix **bold** and *ital* with `code` and [a](b)\n"
        let tokens = MarkdownScanner.scan(text)
        let spans = tokens.map { covered(text, $0) }
        #expect(spans == ["`code`", "[a](b)", "**bold**", "*ital*"].sorted {
            (text as NSString).range(of: $0).location < (text as NSString).range(of: $1).location
        })
        #expect(Set(tokens.map(\.kind)) == [.bold, .italic, .inlineCode, .link])
    }

    @Test func boldIsNotAlsoItalic() {
        let text = "**only bold**\n"
        #expect(kinds(text) == [.bold])
    }

    @Test func listMarkersAndBlockquotes() {
        let text = "- item\n2. numbered\n> quoted line\n"
        let tokens = MarkdownScanner.scan(text)
        #expect(tokens.map(\.kind) == [.listMarker, .listMarker, .blockquote])
        #expect(covered(text, tokens[0]) == "-")
        #expect(covered(text, tokens[1]) == "2.")
        #expect(covered(text, tokens[2]) == "> quoted line")
    }

    @Test func wikiLinksAndRegularLinksCoexist() {
        let text = "see [[Ferry Plan]] and [docs](https://example.com) and [[a b]]\n"
        let tokens = MarkdownScanner.scan(text)
        let wikis = tokens.filter { $0.kind == .wikiLink }.map { covered(text, $0) }
        #expect(wikis == ["[[Ferry Plan]]", "[[a b]]"])
        #expect(tokens.filter { $0.kind == .link }.count == 1)
        #expect(kinds("no [[unclosed link\n").isEmpty)
    }

    @Test func plainProseYieldsNothing() {
        #expect(kinds("just words, an asterisk * alone, 3.14 pi\n").isEmpty)
    }

    @Test func rangesAreUTF16Correct() {
        let text = "emoji 🐟 then **bold**\n"
        let tokens = MarkdownScanner.scan(text)
        #expect(tokens.count == 1)
        #expect(covered(text, tokens[0]) == "**bold**")
    }
}
