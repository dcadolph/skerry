import Foundation
import Testing

@testable import SkerryKit

@Suite struct MarkdownTablesTests {
    @Test func cellsSplitOnUnescapedPipes() {
        #expect(MarkdownTables.cells(ofRow: "| a | b |") == ["a", "b"])
        #expect(MarkdownTables.cells(ofRow: "| a | b") == ["a", "b"])
        #expect(MarkdownTables.cells(ofRow: #"| a \| x | b |"#) == [#"a \| x"#, "b"])
        #expect(MarkdownTables.cells(ofRow: "| a |  |") == ["a", ""])
        #expect(MarkdownTables.cells(ofRow: "no pipes").isEmpty)
    }

    @Test func delimiterRowsAreRecognized() {
        #expect(MarkdownTables.isDelimiterRow("| --- | --- |"))
        #expect(MarkdownTables.isDelimiterRow("| :--- | :---: | ---: |"))
        #expect(!MarkdownTables.isDelimiterRow("| a | b |"))
        #expect(!MarkdownTables.isDelimiterRow("| --- | b |"))
        #expect(!MarkdownTables.isDelimiterRow("plain text"))
    }

    @Test func alignmentsParseFromDelimiterRow() {
        let alignments = MarkdownTables.alignments(ofDelimiterRow: "| :--- | :---: | ---: | --- |")
        #expect(alignments == [.left, .center, .right, .none])
    }

    @Test func blockRangeSpansContiguousTableLines() {
        let text = "before\n| a | b |\n| --- | --- |\n| 1 | 2 |\nafter"
        let ns = text as NSString
        let inTable = ns.range(of: "| 1 |").location
        let block = MarkdownTables.blockRange(in: text, at: inTable)
        #expect(block != nil)
        #expect(ns.substring(with: block!) == "| a | b |\n| --- | --- |\n| 1 | 2 |")
        #expect(MarkdownTables.blockRange(in: text, at: 2) == nil)
    }

    @Test func formatEditAlignsColumns() {
        let text = "| a | long header |\n| --- | :---: |\n| cell | b |"
        let (range, formatted) = MarkdownTables.formatEdit(in: text, at: 0)!
        #expect(range == NSRange(location: 0, length: (text as NSString).length))
        #expect(formatted == """
        | a    | long header |
        | ---- | :---------: |
        | cell |      b      |
        """)
    }

    @Test func formatEditReturnsNilWhenAlreadyFormatted() {
        let text = "| a    | long header |\n| ---- | :---------: |\n| cell |      b      |"
        #expect(MarkdownTables.formatEdit(in: text, at: 0) == nil)
    }

    @Test func formatEditPadsShortRows() {
        let text = "| a | b |\n| --- | --- |\n| only |"
        let (_, formatted) = MarkdownTables.formatEdit(in: text, at: 0)!
        #expect(formatted == """
        | a    | b   |
        | ---- | --- |
        | only |     |
        """)
    }

    @Test func tabMovesToNextCell() {
        let text = "| aa | bb |\n| --- | --- |\n| cc | dd |"
        let ns = text as NSString
        let inFirst = ns.range(of: "aa").location
        let result = MarkdownTables.tabEdit(in: text, at: inFirst, backward: false)!
        #expect(result.edit == nil)
        #expect(result.caret == ns.range(of: "bb").location)
    }

    @Test func tabSkipsDelimiterRow() {
        let text = "| aa | bb |\n| --- | --- |\n| cc | dd |"
        let ns = text as NSString
        let inSecond = ns.range(of: "bb").location
        let result = MarkdownTables.tabEdit(in: text, at: inSecond, backward: false)!
        #expect(result.edit == nil)
        #expect(result.caret == ns.range(of: "cc").location)
    }

    @Test func tabPastLastCellAppendsRow() {
        let text = "| aa | bb |\n| --- | --- |\n| cc | dd |"
        let ns = text as NSString
        let inLast = ns.range(of: "dd").location
        let result = MarkdownTables.tabEdit(in: text, at: inLast, backward: false)!
        let edit = result.edit
        #expect(edit != nil)
        #expect(edit!.0 == NSRange(location: ns.length, length: 0))
        #expect(edit!.1 == "\n|   |   |")
        #expect(result.caret == ns.length + 2)
    }

    @Test func backTabMovesToPreviousCell() {
        let text = "| aa | bb |\n| --- | --- |\n| cc | dd |"
        let ns = text as NSString
        let inThird = ns.range(of: "cc").location
        let result = MarkdownTables.tabEdit(in: text, at: inThird, backward: true)!
        #expect(result.edit == nil)
        #expect(result.caret == ns.range(of: "bb").location)
    }

    @Test func tabOutsideTableReturnsNil() {
        #expect(MarkdownTables.tabEdit(in: "plain prose", at: 3, backward: false) == nil)
    }

    @Test func skeletonBuildsHeaderDelimiterAndBody() {
        #expect(MarkdownTables.skeleton(columns: 2, rows: 1) == """
        | Column 1 | Column 2 |
        | --- | --- |
        |   |   |
        """)
    }

    @Test func newlineInTableInsertsFreshRow() {
        let text = "| a | b |"
        let action = MarkdownEditing.newlineAction(text: text, caret: (text as NSString).length)
        #expect(action == .insert("\n|   |   |"))
    }

    @Test func newlineOnEmptyRowExitsTable() {
        let text = "| a | b |\n|   |   |"
        let ns = text as NSString
        let action = MarkdownEditing.newlineAction(text: text, caret: ns.length)
        #expect(action == .replaceRange(NSRange(location: 10, length: 9), with: ""))
    }

    @Test func scannerEmitsTableTokens() {
        let text = "| head | er |\n| --- | --- |\n| a | b |\n"
        let tokens = MarkdownScanner.scan(text)
        let kinds = tokens.map(\.kind)
        #expect(kinds.contains(.tableHeader))
        #expect(kinds.contains(.tableDelimiterRow))
        #expect(kinds.filter { $0 == .tablePipe }.count == 6)
    }

    @Test func scannerStylesInlineInsideCells() {
        let text = "| **bold** | plain |\n"
        let kinds = MarkdownScanner.scan(text).map(\.kind)
        #expect(kinds.contains(.bold))
        #expect(!kinds.contains(.tableHeader))
    }

    @Test func htmlRendersTableWithAlignment() {
        let html = MarkdownHTML.fragment("| h1 | h2 |\n| :---: | --- |\n| a | b |")
        #expect(html.contains("<table>"))
        #expect(html.contains("<th style=\"text-align: center\">h1</th>"))
        #expect(html.contains("<th>h2</th>"))
        #expect(html.contains("<td style=\"text-align: center\">a</td>"))
        #expect(html.contains("</table>"))
    }

    @Test func htmlRendersHeaderlessTableAsBody() {
        let html = MarkdownHTML.fragment("| a | b |\n| c | d |")
        #expect(!html.contains("<thead>"))
        #expect(html.contains("<td>a</td>"))
        #expect(html.contains("<td>d</td>"))
    }

    @Test func htmlUnescapesPipesInCells() {
        let html = MarkdownHTML.fragment(#"| a \| x |"#)
        #expect(html.contains("<td>a | x</td>"))
    }
}
