import Foundation
import Testing

@testable import SkerryKit

@Suite struct CodeHighlighterTests {
    /// Spans mapped to covered text and kind.
    private func spans(_ line: String, _ language: String) -> [(String, CodeHighlighter.Kind)] {
        let ns = line as NSString
        return CodeHighlighter.spans(line: line, language: language)
            .map { (ns.substring(with: $0.range), $0.kind) }
    }

    @Test func swiftKeywordsStringsAndNumbers() {
        let line = #"let count = 42 // total"#
        let found = spans(line, "swift")
        #expect(found.contains { $0 == ("let", .keyword) })
        #expect(found.contains { $0 == ("42", .number) })
        #expect(found.contains { $0 == ("// total", .comment) })
    }

    @Test func stringsClaimTheirContent() {
        let found = spans(#"print("hello // not comment")"#, "python")
        #expect(found.contains { $0 == ("\"hello // not comment\"", .string) })
        #expect(!found.contains { $0.1 == .comment })
    }

    @Test func hashCommentsForPythonSlashForGo() {
        #expect(spans("x = 1  # note", "python").contains { $0 == ("# note", .comment) })
        #expect(spans("x := 1 // note", "go").contains { $0 == ("// note", .comment) })
        // Python code with a slash pair is division, not a comment.
        #expect(!spans("y = a // b", "python").contains { $0.1 == .comment })
    }

    @Test func keywordsInsideCommentsDoNotDouble() {
        let found = spans("// return early", "swift")
        #expect(found.count == 1)
        #expect(found[0].1 == .comment)
    }

    @Test func unknownLanguageStillGetsStringsAndNumbers() {
        let found = spans(#"value = "text" + 7"#, "brainfuzz")
        #expect(found.contains { $0 == ("\"text\"", .string) })
        #expect(found.contains { $0 == ("7", .number) })
        #expect(!found.contains { $0.1 == .keyword })
    }

    @Test func scannerColorsInsideFences() {
        let text = "```swift\nlet x = \"hi\" // note\n```\n"
        let kinds = MarkdownScanner.scan(text).map(\.kind)
        #expect(kinds.contains(.codeKeyword))
        #expect(kinds.contains(.codeString))
        #expect(kinds.contains(.codeComment))
        #expect(kinds.contains(.fencedCode))
    }

    @Test func fenceWithoutLanguageGetsNoKeywords() {
        let text = "```\nlet x = 1\n```\n"
        let kinds = MarkdownScanner.scan(text).map(\.kind)
        #expect(!kinds.contains(.codeKeyword))
        #expect(kinds.contains(.codeNumber))
    }

    @Test func highlightSpansTokenizeAndRender() {
        let text = "note ==the key point== here\n"
        let tokens = MarkdownScanner.scan(text)
        let marks = tokens.filter { $0.kind == .highlightMark }
        #expect(marks.count == 1)
        #expect((text as NSString).substring(with: marks[0].range) == "==the key point==")
        let html = MarkdownHTML.fragment("a ==b== c")
        #expect(html.contains("<mark>b</mark>"))
    }
}
