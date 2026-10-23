import Foundation

/// MarkdownHTML converts a note body to HTML. It is a focused block-and-inline renderer
/// covering the constructs Skerry writes: headings, emphasis, code, lists, task lists,
/// blockquotes, horizontal rules, links, and wiki links. It is not a full CommonMark
/// implementation, but it round-trips everything the editor produces.
public enum MarkdownHTML {
    /// Renders Markdown to an HTML fragment, without a surrounding document.
    public static func fragment(_ markdown: String) -> String {
        var html: [String] = []
        // Footnote definitions render at the end, so collect them first and keep the
        // remaining lines for block rendering.
        var definitions: [String: String] = [:]
        var lines: [String] = []
        for line in markdown.components(separatedBy: "\n") {
            if let (id, text) = footnoteDefinition(line.trimmingCharacters(in: .whitespaces)) {
                definitions[id] = text
            } else {
                lines.append(line)
            }
        }
        let footnotes = FootnoteContext(definitions: definitions)
        var index = 0
        var listStack: [String] = []
        var slugCounts: [String: Int] = [:]

        func closeLists(to depth: Int) {
            while listStack.count > depth { html.append("</\(listStack.removeLast())>") }
        }

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("```") {
                closeLists(to: 0)
                var code: [String] = []
                index += 1
                while index < lines.count,
                    !lines[index].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    code.append(escape(lines[index]))
                    index += 1
                }
                html.append("<pre><code>\(code.joined(separator: "\n"))</code></pre>")
                index += 1
                continue
            }

            if trimmed.isEmpty {
                closeLists(to: 0)
                index += 1
                continue
            }

            if let (level, text) = heading(trimmed) {
                closeLists(to: 0)
                let id = uniqueSlug(text, counts: &slugCounts)
                let idAttribute = id.isEmpty ? "" : " id=\"\(id)\""
                html.append("<h\(level)\(idAttribute)>\(inline(text, footnotes: footnotes))</h\(level)>")
                index += 1
                continue
            }

            if trimmed == "---" || trimmed == "***" || trimmed == "___" {
                closeLists(to: 0)
                html.append("<hr>")
                index += 1
                continue
            }

            if trimmed.hasPrefix(">") {
                closeLists(to: 0)
                var quoteLines: [String] = []
                while index < lines.count {
                    let raw = lines[index].trimmingCharacters(in: .whitespaces)
                    guard raw.hasPrefix(">") else { break }
                    quoteLines.append(
                        String(raw.dropFirst()).trimmingCharacters(in: .whitespaces)
                    )
                    index += 1
                }
                html.append(quoteHTML(quoteLines, footnotes: footnotes))
                continue
            }

            if trimmed.hasPrefix("|") {
                closeLists(to: 0)
                var block: [String] = []
                while index < lines.count {
                    let row = lines[index].trimmingCharacters(in: .whitespaces)
                    guard row.hasPrefix("|") else { break }
                    block.append(row)
                    index += 1
                }
                html.append(tableHTML(block, footnotes: footnotes))
                continue
            }

            if let item = listItem(line) {
                let tag = item.ordered ? "ol" : "ul"
                if listStack.last != tag {
                    closeLists(to: 0)
                    html.append("<\(tag)>")
                    listStack.append(tag)
                }
                if let checked = item.task {
                    let box = checked ? "checked" : ""
                    html.append(
                        "<li><input type=\"checkbox\" disabled \(box)> "
                            + "\(inline(item.text, footnotes: footnotes))</li>"
                    )
                } else {
                    html.append("<li>\(inline(item.text, footnotes: footnotes))</li>")
                }
                index += 1
                continue
            }

            closeLists(to: 0)
            html.append("<p>\(inline(trimmed, footnotes: footnotes))</p>")
            index += 1
        }
        closeLists(to: 0)
        if !footnotes.order.isEmpty {
            var items: [String] = []
            for id in footnotes.order {
                let text = definitions[id] ?? ""
                let safe = attributeSafe(id)
                items.append(
                    "<li id=\"fn-\(safe)\">\(inline(text)) "
                        + "<a href=\"#fnref-\(safe)\">&#8617;</a></li>"
                )
            }
            html.append("<hr>")
            html.append("<ol class=\"footnotes\">\n\(items.joined(separator: "\n"))\n</ol>")
        }
        return html.joined(separator: "\n")
    }

    /// FootnoteContext tracks reference order while a fragment renders.
    private final class FootnoteContext {
        /// Definition text by footnote id.
        let definitions: [String: String]
        /// Ids in order of first reference.
        var order: [String] = []

        /// Creates a context over the collected definitions.
        init(definitions: [String: String]) {
            self.definitions = definitions
        }

        /// The display number for an id, assigning the next one on first use.
        func number(for id: String) -> Int {
            if let existing = order.firstIndex(of: id) { return existing + 1 }
            order.append(id)
            return order.count
        }
    }

    /// Callout kinds mapped to their display label and accent color.
    static let calloutKinds: [String: (label: String, color: String)] = [
        "note": ("Note", "#3B82C4"),
        "info": ("Info", "#3B82C4"),
        "tip": ("Tip", "#3E9B72"),
        "important": ("Important", "#7E6BF2"),
        "warning": ("Warning", "#E0A83C"),
        "caution": ("Caution", "#F2603F"),
    ]

    /// Matches a callout opener on an already de-quoted first line.
    private static let calloutOpener = try! NSRegularExpression(
        pattern: #"^\[!([A-Za-z]+)\]\s*(.*)$"#
    )

    /// Renders gathered quote lines: a styled callout when the first line opens one,
    /// else one joined blockquote.
    private static func quoteHTML(_ lines: [String], footnotes: FootnoteContext) -> String {
        guard let first = lines.first else { return "" }
        let ns = first as NSString
        let whole = NSRange(location: 0, length: ns.length)
        if let match = calloutOpener.firstMatch(in: first, range: whole) {
            let kind = ns.substring(with: match.range(at: 1)).lowercased()
            let title = ns.substring(with: match.range(at: 2))
            let style = calloutKinds[kind] ?? calloutKinds["note"]!
            let heading = title.isEmpty ? style.label : title
            let body = lines.dropFirst()
                .map { inline($0, footnotes: footnotes) }
                .joined(separator: "<br>")
            var block = "<div class=\"callout\" style=\"border-left-color: \(style.color)\">"
            block += "<p class=\"callout-title\" style=\"color: \(style.color)\">"
                + inline(heading, footnotes: footnotes) + "</p>"
            if !body.isEmpty { block += "<p>\(body)</p>" }
            block += "</div>"
            return block
        }
        let joined = lines.map { inline($0, footnotes: footnotes) }.joined(separator: "<br>")
        return "<blockquote>\(joined)</blockquote>"
    }

    /// Splits a `[^id]: text` line into id and text, nil for other lines.
    private static func footnoteDefinition(_ line: String) -> (String, String)? {
        let pattern = try! NSRegularExpression(pattern: #"^\[\^([^\]\s]+)\]:\s*(.*)$"#)
        let range = NSRange(location: 0, length: (line as NSString).length)
        guard let match = pattern.firstMatch(in: line, range: range) else { return nil }
        let ns = line as NSString
        return (ns.substring(with: match.range(at: 1)), ns.substring(with: match.range(at: 2)))
    }

    /// Renders a run of pipe-table lines, honoring the delimiter row's alignments.
    private static func tableHTML(_ rows: [String], footnotes: FootnoteContext) -> String {
        var alignments: [MarkdownTables.Alignment] = []
        var headerRows: [[String]] = []
        var bodyRows: [[String]] = []
        var sawDelimiter = false
        for (index, row) in rows.enumerated() {
            if !sawDelimiter, index == 1, MarkdownTables.isDelimiterRow(row) {
                sawDelimiter = true
                alignments = MarkdownTables.alignments(ofDelimiterRow: row)
                continue
            }
            let cells = MarkdownTables.cells(ofRow: row)
                .map { $0.replacingOccurrences(of: "\\|", with: "|") }
            if index == 0 {
                headerRows.append(cells)
            } else {
                bodyRows.append(cells)
            }
        }
        if !sawDelimiter {
            bodyRows = headerRows + bodyRows
            headerRows = []
        }
        func style(_ column: Int) -> String {
            guard column < alignments.count else { return "" }
            switch alignments[column] {
            case .left: return " style=\"text-align: left\""
            case .center: return " style=\"text-align: center\""
            case .right: return " style=\"text-align: right\""
            case .none: return ""
            }
        }
        func rowHTML(_ cells: [String], tag: String) -> String {
            let rendered = cells.enumerated()
                .map { column, cell in
                    "<\(tag)\(style(column))>\(inline(cell, footnotes: footnotes))</\(tag)>"
                }
                .joined()
            return "<tr>\(rendered)</tr>"
        }
        var parts: [String] = ["<table>"]
        if !headerRows.isEmpty {
            parts.append("<thead>" + headerRows.map { rowHTML($0, tag: "th") }.joined() + "</thead>")
        }
        if !bodyRows.isEmpty {
            parts.append("<tbody>" + bodyRows.map { rowHTML($0, tag: "td") }.joined() + "</tbody>")
        }
        parts.append("</table>")
        return parts.joined()
    }

    /// Rewrites footnote references as superscript anchors, leaving undefined ones literal.
    private static func footnoteRefs(_ text: String, _ footnotes: FootnoteContext) -> String {
        let regex = try! NSRegularExpression(pattern: #"\[\^([^\]\s]+)\](?!:)"#)
        let ns = text as NSString
        var output = ""
        var cursor = 0
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            output += ns.substring(
                with: NSRange(location: cursor, length: match.range.location - cursor)
            )
            let id = ns.substring(with: match.range(at: 1))
            if footnotes.definitions[id] != nil {
                let number = footnotes.number(for: id)
                let safe = attributeSafe(id)
                output += "<sup><a href=\"#fn-\(safe)\" id=\"fnref-\(safe)\">\(number)</a></sup>"
            } else {
                output += ns.substring(with: match.range)
            }
            cursor = match.range.location + match.range.length
        }
        output += ns.substring(from: cursor)
        return output
    }

    /// Makes a footnote id safe for a quoted, already `&<>`-escaped attribute.
    private static func attributeSafe(_ id: String) -> String {
        id.replacingOccurrences(of: "\"", with: "")
    }

    /// Wraps a rendered fragment in a full HTML document with light, readable styling.
    public static func document(title: String, markdown: String) -> String {
        """
        <!doctype html>
        <html>
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\(escape(title))</title>
        <style>
        body { font: -apple-system, system-ui, sans-serif; max-width: 40rem;
          margin: 2rem auto; padding: 0 1rem; line-height: 1.55; color: #1a1a1a; }
        h1, h2, h3 { line-height: 1.25; }
        pre { background: #f4f4f5; padding: 0.75rem 1rem; border-radius: 8px; overflow-x: auto; }
        code { font-family: ui-monospace, monospace; font-size: 0.9em; }
        blockquote { border-left: 3px solid #d4d4d8; margin: 0; padding-left: 1rem; color: #52525b; }
        hr { border: none; border-top: 1px solid #e4e4e7; margin: 1.5rem 0; }
        a { color: #c0603c; }
        ul, ol { padding-left: 1.4rem; }
        table { border-collapse: collapse; margin: 1rem 0; }
        th, td { border: 1px solid #d4d4d8; padding: 0.35rem 0.6rem; text-align: left; }
        th { background: #f4f4f5; }
        .footnotes { font-size: 0.9em; color: #52525b; }
        sup a { text-decoration: none; }
        mark { background: #fde68a; padding: 0 2px; border-radius: 3px; }
        .callout { border-left: 3px solid #3B82C4; background: rgba(120, 120, 128, 0.08);
          padding: 0.6rem 1rem; border-radius: 6px; margin: 1rem 0; }
        .callout-title { font-weight: 600; margin: 0 0 0.25rem; }
        </style>
        </head>
        <body>
        \(fragment(markdown))
        </body>
        </html>
        """
    }

    /// Parses an ATX heading into its level and text.
    private static func heading(_ line: String) -> (Int, String)? {
        var level = 0
        var rest = Substring(line)
        while rest.first == "#" {
            level += 1
            rest = rest.dropFirst()
        }
        guard (1...6).contains(level), rest.first == " " else { return nil }
        return (level, String(rest.dropFirst()))
    }

    /// A parsed list item: its text, whether it is ordered, and any task state.
    private struct Item {
        var text: String
        var ordered: Bool
        var task: Bool?
    }

    /// Parses a list line into an item, or nil when the line is not a list item.
    private static func listItem(_ line: String) -> Item? {
        let pattern = try! NSRegularExpression(pattern: #"^\s{0,8}([-*+]|\d{1,9}\.)\s+(.*)$"#)
        let range = NSRange(location: 0, length: (line as NSString).length)
        guard let match = pattern.firstMatch(in: line, range: range) else { return nil }
        let ns = line as NSString
        let marker = ns.substring(with: match.range(at: 1))
        var text = ns.substring(with: match.range(at: 2))
        var task: Bool?
        if text.hasPrefix("[ ] ") || text.hasPrefix("[x] ") || text.hasPrefix("[X] ") {
            task = text.lowercased().hasPrefix("[x]")
            text = String(text.dropFirst(4))
        }
        return Item(text: text, ordered: marker.hasSuffix("."), task: task)
    }

    /// Renders inline Markdown within already block-scoped text.
    private static func inline(_ text: String, footnotes: FootnoteContext? = nil) -> String {
        var result = escape(text)
        if let footnotes {
            result = footnoteRefs(result, footnotes)
        }
        result = replace(result, #"\*\*(.+?)\*\*"#, "<strong>$1</strong>")
        result = replace(result, #"(?<!\*)\*(?!\s)(.+?)(?<!\s)\*(?!\*)"#, "<em>$1</em>")
        result = replace(result, #"~~(.+?)~~"#, "<del>$1</del>")
        result = replace(result, #"==(.+?)=="#, "<mark>$1</mark>")
        result = replace(result, #"`([^`]+)`"#, "<code>$1</code>")
        result = wikiLinks(result)
        result = linkify(result, pattern: #"\[([^\]]+)\]\(([^)]+)\)"#, hrefGroup: 2, textGroup: 1)
        return result
    }

    /// Rewrites a link pattern as an anchor, escaping the URL for its quoted attribute and
    /// dropping unsafe schemes, so exported HTML cannot carry script injected through a link.
    /// The input text is already escaped for `&`, `<`, and `>`, so only quotes need escaping.
    private static func linkify(
        _ text: String, pattern: String, hrefGroup: Int, textGroup: Int
    ) -> String {
        let regex = try! NSRegularExpression(pattern: pattern)
        let ns = text as NSString
        var output = ""
        var cursor = 0
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let gap = NSRange(location: cursor, length: match.range.location - cursor)
            output += ns.substring(with: gap)
            let href = safeHref(ns.substring(with: match.range(at: hrefGroup)))
            let label = ns.substring(with: match.range(at: textGroup))
            output += "<a href=\"\(href)\">\(label)</a>"
            cursor = match.range.location + match.range.length
        }
        output += ns.substring(from: cursor)
        return output
    }

    /// Escapes a URL for a double-quoted attribute and blanks unsafe schemes. The input is
    /// already `&<>`-escaped, so scheme checks and quote escaping are all that remain.
    private static func safeHref(_ url: String) -> String {
        let trimmed = url.trimmingCharacters(in: .whitespaces)
        let lowered = trimmed.lowercased()
        let unsafe = lowered.hasPrefix("javascript:") || lowered.hasPrefix("vbscript:")
            || (lowered.hasPrefix("data:") && !lowered.hasPrefix("data:image/"))
        let safe = unsafe ? "" : trimmed
        return safe.replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// Rewrites `[[Note#Heading]]` wiki links as anchors. The note becomes the href and a
    /// heading, when present, a slug fragment matching the exported heading ids, so a
    /// `[[#Heading]]` link inside a document lands on that heading. The label stays readable.
    /// Runs on already-escaped text, so the note and heading are safe to place in the label.
    private static func wikiLinks(_ text: String) -> String {
        let regex = try! NSRegularExpression(pattern: #"\[\[([^\]]+)\]\]"#)
        let ns = text as NSString
        var output = ""
        var cursor = 0
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            output += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            let target = WikiLink.split(ns.substring(with: match.range(at: 1)))
            var href = safeHref(target.note)
            var label = target.note
            if let heading = target.heading {
                href += "#" + slug(heading)
                label = target.note.isEmpty ? heading : "\(target.note) › \(heading)"
            }
            output += "<a href=\"\(href)\">\(label)</a>"
            cursor = match.range.location + match.range.length
        }
        output += ns.substring(from: cursor)
        return output
    }

    /// A URL-fragment slug for a heading: lowercased, alphanumerics kept, every other run
    /// collapsed to a single hyphen.
    private static func slug(_ text: String) -> String {
        var out = ""
        var pendingHyphen = false
        for character in text.lowercased() {
            if character.isLetter || character.isNumber {
                if pendingHyphen, !out.isEmpty { out.append("-") }
                out.append(character)
                pendingHyphen = false
            } else {
                pendingHyphen = true
            }
        }
        return out
    }

    /// A unique heading id, disambiguating slugs that repeat within one document.
    private static func uniqueSlug(_ text: String, counts: inout [String: Int]) -> String {
        let base = slug(text)
        guard !base.isEmpty else { return "" }
        let seen = counts[base, default: 0]
        counts[base] = seen + 1
        return seen == 0 ? base : "\(base)-\(seen)"
    }

    /// Applies one regex replacement over a string.
    private static func replace(_ text: String, _ pattern: String, _ template: String) -> String {
        let regex = try! NSRegularExpression(pattern: pattern)
        let range = NSRange(location: 0, length: (text as NSString).length)
        return regex.stringByReplacingMatches(
            in: text, range: range, withTemplate: template
        )
    }

    /// Escapes the HTML-significant characters in raw text.
    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}
