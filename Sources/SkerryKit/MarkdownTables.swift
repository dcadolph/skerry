import Foundation

/// MarkdownTables understands pipe-table blocks: finding them, splitting rows into cells,
/// aligning table source, and stepping the caret between cells the way table editors do.
public enum MarkdownTables {
    /// Column alignment declared by the delimiter row.
    public enum Alignment: Equatable, Sendable {
        /// No alignment declared; renderers use their default.
        case none
        /// `:---` left alignment.
        case left
        /// `:---:` center alignment.
        case center
        /// `---:` right alignment.
        case right
    }

    /// Reports whether a line belongs to a pipe table.
    public static func isTableLine(_ line: String) -> Bool {
        line.trimmingCharacters(in: .whitespaces).hasPrefix("|")
    }

    /// Whether a row is a header delimiter like `| --- | :---: |`.
    public static func isDelimiterRow(_ line: String) -> Bool {
        let parsed = cells(ofRow: line)
        guard !parsed.isEmpty else { return false }
        return parsed.allSatisfy { cell in
            let trimmed = cell.trimmingCharacters(in: .whitespaces)
            guard trimmed.contains("-") else { return false }
            return trimmed.range(of: "^:?-+:?$", options: .regularExpression) != nil
        }
    }

    /// Splits a table row into trimmed cell texts. Boundary pipes are dropped, an escaped
    /// `\|` stays inside its cell, and a blank tail after the final pipe is not a cell.
    public static func cells(ofRow line: String) -> [String] {
        var rest = Substring(line.trimmingCharacters(in: .whitespaces))
        guard rest.hasPrefix("|") else { return [] }
        rest = rest.dropFirst()
        var cells: [String] = []
        var current = ""
        var escaped = false
        for char in rest {
            if escaped {
                current.append(char)
                escaped = false
            } else if char == "\\" {
                current.append(char)
                escaped = true
            } else if char == "|" {
                cells.append(current)
                current = ""
            } else {
                current.append(char)
            }
        }
        if !current.trimmingCharacters(in: .whitespaces).isEmpty || !rest.hasSuffix("|") {
            cells.append(current)
        }
        return cells.map { $0.trimmingCharacters(in: .whitespaces) }
    }

    /// Alignments declared by a delimiter row, one per cell.
    public static func alignments(ofDelimiterRow line: String) -> [Alignment] {
        cells(ofRow: line).map { cell in
            let trimmed = cell.trimmingCharacters(in: .whitespaces)
            let leading = trimmed.hasPrefix(":")
            let trailing = trimmed.hasSuffix(":")
            if leading && trailing { return .center }
            if leading { return .left }
            if trailing { return .right }
            return .none
        }
    }

    /// UTF-16 range of the contiguous run of table lines containing the offset, spanning
    /// whole lines without the last line's newline. Nil when the offset is not in a table.
    public static func blockRange(in text: String, at offset: Int) -> NSRange? {
        let ns = text as NSString
        guard ns.length > 0 else { return nil }
        let probe = min(max(offset, 0), ns.length)
        let anchor = probe == ns.length ? probe - 1 : probe
        let caretLine = ns.lineRange(for: NSRange(location: anchor, length: 0))
        guard isTableLine(ns.substring(with: caretLine)) else { return nil }
        var start = caretLine.location
        while start > 0 {
            let previous = ns.lineRange(for: NSRange(location: start - 1, length: 0))
            guard isTableLine(ns.substring(with: previous)) else { break }
            start = previous.location
        }
        var lastLine = caretLine
        while lastLine.location + lastLine.length < ns.length {
            let next = ns.lineRange(
                for: NSRange(location: lastLine.location + lastLine.length, length: 0)
            )
            guard isTableLine(ns.substring(with: next)) else { break }
            lastLine = next
        }
        var lineStart = 0
        var lineEnd = 0
        var contentsEnd = 0
        ns.getLineStart(
            &lineStart, end: &lineEnd, contentsEnd: &contentsEnd,
            for: NSRange(location: lastLine.location, length: 0)
        )
        return NSRange(location: start, length: contentsEnd - start)
    }

    /// UTF-16 ranges of each cell's content within a row line, pipes excluded, relative to
    /// the line. A blank tail after the final pipe is not a cell.
    static func cellRanges(ofLine line: String) -> [NSRange] {
        let ns = line as NSString
        var pipes: [Int] = []
        var escaped = false
        for position in 0..<ns.length {
            let char = ns.character(at: position)
            if escaped {
                escaped = false
            } else if char == 0x5C {
                escaped = true
            } else if char == 0x7C {
                pipes.append(position)
            }
        }
        guard !pipes.isEmpty else { return [] }
        let tail = ns.substring(from: pipes[pipes.count - 1] + 1)
            .trimmingCharacters(in: .whitespaces)
        var ranges: [NSRange] = []
        for (index, pipe) in pipes.enumerated() {
            let contentStart = pipe + 1
            let contentEnd = index + 1 < pipes.count ? pipes[index + 1] : ns.length
            if index + 1 == pipes.count, tail.isEmpty { break }
            ranges.append(NSRange(location: contentStart, length: max(contentEnd - contentStart, 0)))
        }
        return ranges
    }

    /// A blank table row with the given column count.
    public static func emptyRow(columns: Int) -> String {
        "|" + String(repeating: "   |", count: max(columns, 1))
    }

    /// A fresh table: header row, delimiter row, and blank body rows.
    public static func skeleton(columns: Int = 2, rows: Int = 1) -> String {
        let count = max(columns, 1)
        let header = "| " + (1...count).map { "Column \($0)" }.joined(separator: " | ") + " |"
        let delimiter = "|" + String(repeating: " --- |", count: count)
        let body = Array(repeating: emptyRow(columns: count), count: max(rows, 1))
        return ([header, delimiter] + body).joined(separator: "\n")
    }

    /// Rewrites the table block containing the offset with padded, aligned columns.
    /// Returns the block range and its replacement, or nil outside a table or when the
    /// block is already formatted.
    public static func formatEdit(in text: String, at offset: Int) -> (NSRange, String)? {
        guard let block = blockRange(in: text, at: offset) else { return nil }
        let source = (text as NSString).substring(with: block)
        let lines = source.components(separatedBy: "\n")
        var rows = lines.map(cells(ofRow:))
        guard let columns = rows.map(\.count).max(), columns > 0 else { return nil }

        var alignments = [Alignment](repeating: .none, count: columns)
        var delimiterIndex: Int?
        for (index, line) in lines.enumerated() where isDelimiterRow(line) {
            delimiterIndex = index
            for (column, alignment) in Self.alignments(ofDelimiterRow: line).enumerated()
            where column < columns {
                alignments[column] = alignment
            }
            break
        }

        for index in rows.indices {
            while rows[index].count < columns { rows[index].append("") }
        }
        var widths = [Int](repeating: 3, count: columns)
        for (index, row) in rows.enumerated() where index != delimiterIndex {
            for (column, cell) in row.enumerated() {
                widths[column] = max(widths[column], cell.count)
            }
        }

        var output: [String] = []
        for (index, row) in rows.enumerated() {
            let cells: [String]
            if index == delimiterIndex {
                cells = alignments.enumerated().map { column, alignment in
                    delimiterCell(width: widths[column], alignment: alignment)
                }
            } else {
                cells = row.enumerated().map { column, cell in
                    pad(cell, to: widths[column], alignment: alignments[column])
                }
            }
            output.append("| " + cells.joined(separator: " | ") + " |")
        }
        let formatted = output.joined(separator: "\n")
        guard formatted != source else { return nil }
        return (block, formatted)
    }

    /// Caret motion for Tab inside a table: the next or previous cell's content, hopping
    /// over the delimiter row and growing a fresh row when tabbing past the last cell.
    /// Returns the edit to apply first, when one is needed, and the caret offset after it.
    /// Nil when the offset is not inside a table.
    public static func tabEdit(
        in text: String, at offset: Int, backward: Bool
    ) -> (edit: (NSRange, String)?, caret: Int)? {
        guard let block = blockRange(in: text, at: offset) else { return nil }
        let ns = text as NSString
        var cells: [NSRange] = []
        var columns = 1
        var cursor = block.location
        while cursor < block.location + block.length {
            var lineStart = 0
            var lineEnd = 0
            var contentsEnd = 0
            ns.getLineStart(
                &lineStart, end: &lineEnd, contentsEnd: &contentsEnd,
                for: NSRange(location: cursor, length: 0)
            )
            let line = ns.substring(with: NSRange(location: lineStart, length: contentsEnd - lineStart))
            if !isDelimiterRow(line) {
                let ranges = cellRanges(ofLine: line)
                columns = max(columns, ranges.count)
                cells.append(contentsOf: ranges.map {
                    NSRange(location: lineStart + $0.location, length: $0.length)
                })
            }
            guard lineEnd > cursor else { break }
            cursor = lineEnd
        }
        guard !cells.isEmpty else { return nil }

        let containing = cells.firstIndex {
            offset >= $0.location && offset <= $0.location + $0.length
        }
        if backward {
            let target: Int
            if let containing {
                target = containing - 1
            } else {
                target = (cells.lastIndex { $0.location + $0.length <= offset } ?? 0)
            }
            guard target >= 0 else { return nil }
            return (nil, contentCaret(in: cells[target], of: ns))
        }
        let target: Int
        if let containing {
            target = containing + 1
        } else {
            target = cells.firstIndex { $0.location >= offset } ?? cells.count
        }
        if target < cells.count {
            return (nil, contentCaret(in: cells[target], of: ns))
        }
        let insertion = NSRange(location: block.location + block.length, length: 0)
        let row = "\n" + emptyRow(columns: columns)
        return ((insertion, row), insertion.location + 2)
    }

    /// Caret offset at the start of a cell's trimmed content, or just inside a blank cell.
    private static func contentCaret(in cell: NSRange, of text: NSString) -> Int {
        var position = cell.location
        let end = cell.location + cell.length
        while position < end, text.character(at: position) == 0x20 {
            position += 1
        }
        if position == end {
            return min(cell.location + 1, end)
        }
        return position
    }

    /// A delimiter cell of the given width carrying an alignment's colons.
    private static func delimiterCell(width: Int, alignment: Alignment) -> String {
        switch alignment {
        case .none: return String(repeating: "-", count: width)
        case .left: return ":" + String(repeating: "-", count: max(width - 1, 2))
        case .right: return String(repeating: "-", count: max(width - 1, 2)) + ":"
        case .center: return ":" + String(repeating: "-", count: max(width - 2, 1)) + ":"
        }
    }

    /// Pads a cell to a width per its column alignment.
    private static func pad(_ cell: String, to width: Int, alignment: Alignment) -> String {
        let gap = max(width - cell.count, 0)
        switch alignment {
        case .right:
            return String(repeating: " ", count: gap) + cell
        case .center:
            let leading = gap / 2
            return String(repeating: " ", count: leading) + cell
                + String(repeating: " ", count: gap - leading)
        case .left, .none:
            return cell + String(repeating: " ", count: gap)
        }
    }
}
