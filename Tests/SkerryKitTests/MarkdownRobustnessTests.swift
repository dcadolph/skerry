import Foundation
import Testing

@testable import SkerryKit

@Suite struct MarkdownRobustnessTests {
    @Test func formatEditIsIdempotent() {
        let text = "| a | long header |\n| --- | :---: |\n| cell | b |"
        let (_, formatted) = MarkdownTables.formatEdit(in: text, at: 0)!
        #expect(MarkdownTables.formatEdit(in: formatted, at: 0) == nil)
    }

    @Test func tabWalksEveryCellThenGrowsARow() {
        let text = "| a | b |\n| --- | --- |\n| c | d |"
        let ns = text as NSString
        var caret = ns.range(of: "a").location
        var hops = 0
        while hops < 10 {
            guard let result = MarkdownTables.tabEdit(in: text, at: caret, backward: false),
                result.edit == nil
            else { break }
            caret = result.caret
            hops += 1
        }
        // Three forward hops cover b, c, d; the next one wants to grow a row.
        #expect(hops == 3)
        let growth = MarkdownTables.tabEdit(in: text, at: caret, backward: false)
        #expect(growth?.edit != nil)
    }

    @Test func backTabFromFirstCellGoesNowhere() {
        let text = "| a | b |"
        let ns = text as NSString
        let first = ns.range(of: "a").location
        #expect(MarkdownTables.tabEdit(in: text, at: first, backward: true) == nil)
    }

    @Test func tableCellsEscapeHTML() {
        let html = MarkdownHTML.fragment("| <script>alert(1)</script> |\n| --- |\n| & |")
        #expect(!html.contains("<script>"))
        #expect(html.contains("&lt;script&gt;"))
        #expect(html.contains("<td>&amp;</td>"))
    }

    @Test func headerAndDelimiterOnlyTableRenders() {
        let html = MarkdownHTML.fragment("| h |\n| --- |")
        #expect(html.contains("<thead>"))
        #expect(!html.contains("<tbody>"))
    }

    @Test func tableInsideFencedCodeStaysCode() {
        let text = "```\n| not | a | table |\n```\n"
        let kinds = MarkdownScanner.scan(text).map(\.kind)
        #expect(!kinds.contains(.tablePipe))
        #expect(kinds.contains(.fencedCode))
        let html = MarkdownHTML.fragment(text)
        #expect(!html.contains("<table>"))
        #expect(html.contains("<pre>"))
    }

    @Test func newlineActionOnDelimiterRowInsertsRow() {
        let text = "| a | b |\n| --- | --- |"
        let action = MarkdownEditing.newlineAction(text: text, caret: (text as NSString).length)
        #expect(action == .insert("\n|   |   |"))
    }

    @Test func duplicateFootnoteReferencesShareOneNumber() {
        let html = MarkdownHTML.fragment("first[^a] and again[^a]\n\n[^a]: shared source")
        let supCount = html.components(separatedBy: "<sup>").count - 1
        #expect(supCount == 2)
        #expect(html.contains(">1</a></sup>"))
        #expect(!html.contains(">2</a></sup>"))
        let listItems = html.components(separatedBy: "<li id=\"fn-a\">").count - 1
        #expect(listItems == 1)
    }

    @Test func footnoteDefinitionRendersInlineMarkdown() {
        let html = MarkdownHTML.fragment("claim[^1]\n\n[^1]: see **the book**")
        #expect(html.contains("<strong>the book</strong>"))
    }

    @Test func footnoteInsideTableCellRenders() {
        let html = MarkdownHTML.fragment("| fact[^1] |\n| --- |\n| x |\n\n[^1]: source")
        #expect(html.contains("<sup>"))
        #expect(html.contains("<li id=\"fn-1\">"))
    }

    @Test func footnoteInsertEditsCompose() {
        // Insert twice; the second gets the next number and both definitions survive.
        let (first, caret) = MarkdownFootnotes.insertEdit(text: "one two", caret: 3)
        let (second, _) = MarkdownFootnotes.insertEdit(text: first, caret: caret)
        #expect(second.contains("[^1]"))
        #expect(second.contains("[^2]: "))
        #expect(second.contains("[^1]: "))
    }

    @Test func escapedPipeSurvivesFormatting() {
        let text = #"| a \| x | b |"#
        let cells = MarkdownTables.cells(ofRow: text)
        #expect(cells == [#"a \| x"#, "b"])
        let (_, formatted) = MarkdownTables.formatEdit(
            in: text + "\n| --- | --- |", at: 0
        )!
        #expect(formatted.contains(#"a \| x"#))
    }
}
