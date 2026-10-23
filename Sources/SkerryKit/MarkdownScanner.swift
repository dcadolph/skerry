import Foundation

/// MarkdownScanner finds the spans of Markdown syntax an editor wants to style.
///
/// The scanner is deliberately not a full CommonMark parser. It recognizes the constructs
/// Skerry highlights, line by line, and reports them as UTF-16 ranges ready for TextKit.
/// Asterisk emphasis only; underscores are left as prose.
public enum MarkdownScanner {
    /// Kind of Markdown construct a token represents.
    public enum TokenKind: Hashable, Sendable {
        /// ATX heading line; level is the number of leading `#` characters, 1 through 6.
        case heading(level: Int)
        /// `**bold**` span, delimiters included.
        case bold
        /// `*italic*` span, delimiters included.
        case italic
        /// Backtick code span, delimiters included.
        case inlineCode
        /// Line inside a fenced code block, fence lines included.
        case fencedCode
        /// `[text](url)` link, brackets and parentheses included.
        case link
        /// `[[note name]]` wiki link to another note, brackets included.
        case wikiLink
        /// Leading list bullet or ordered-list number, marker only.
        case listMarker
        /// `[ ]` or `[x]` checkbox after a list bullet; the box characters only.
        case taskMarker(checked: Bool)
        /// Content text of a checked task item, styled as done.
        case taskDone
        /// Blockquote line starting with `>`.
        case blockquote
        /// One `|` delimiter inside a table row.
        case tablePipe
        /// Whole table delimiter row like `| --- | :---: |`.
        case tableDelimiterRow
        /// Whole table header row, the row directly above the delimiter row.
        case tableHeader
        /// `[^label]` footnote reference span, brackets included.
        case footnoteReference
        /// `[^label]:` marker opening a footnote definition line.
        case footnoteDefinition
        /// Inline `#tag` or `#nested/tag`, hash included.
        case tag
        /// `![alt](path)` image link, bang and parentheses included.
        case image
        /// `==highlighted==` span, delimiters included.
        case highlightMark
        /// A keyword inside a fenced code block.
        case codeKeyword
        /// A string literal inside a fenced code block.
        case codeString
        /// A comment inside a fenced code block.
        case codeComment
        /// A number literal inside a fenced code block.
        case codeNumber
        /// `> [!kind] title` line opening a callout block.
        case calloutHeader
    }

    /// One styled span in the scanned text.
    public struct Token: Equatable, Sendable {
        /// What the span is.
        public let kind: TokenKind
        /// UTF-16 range of the span, delimiters included.
        public let range: NSRange

        /// Creates a token over a UTF-16 range.
        public init(kind: TokenKind, range: NSRange) {
            self.kind = kind
            self.range = range
        }
    }

    /// Matches `**bold**` spans without eating surrounding asterisks.
    private static let boldPattern = try! NSRegularExpression(
        pattern: #"\*\*(?=\S)(?:[^*\n]|\*(?!\*))+?(?<=\S)\*\*"#
    )
    /// Matches `*italic*` spans that are not part of a bold delimiter.
    private static let italicPattern = try! NSRegularExpression(
        pattern: #"(?<!\*)\*(?![\s*])(?:[^*\n])+?(?<![\s*])\*(?!\*)"#
    )
    /// Matches single-backtick code spans.
    private static let codePattern = try! NSRegularExpression(
        pattern: #"`[^`\n]+`"#
    )
    /// Matches inline links.
    private static let linkPattern = try! NSRegularExpression(
        pattern: #"\[[^\]\n]*\]\([^)\n]*\)"#
    )
    /// Matches image links; group 1 is the path.
    public static let imagePattern = try! NSRegularExpression(
        pattern: #"!\[[^\]\n]*\]\(([^)\n]+)\)"#
    )
    /// Matches `==highlight==` spans without eating surrounding equals signs.
    private static let highlightPattern = try! NSRegularExpression(
        pattern: #"==(?=\S)(?:[^=\n]|=(?!=))+?(?<=\S)=="#
    )
    /// Matches a callout opener; group 1 is the kind, group 2 the optional title.
    public static let calloutPattern = try! NSRegularExpression(
        pattern: #"^>\s*\[!([A-Za-z]+)\]\s*(.*)$"#
    )
    /// Matches wiki links to other notes.
    private static let wikiLinkPattern = try! NSRegularExpression(
        pattern: #"\[\[[^\[\]\n]+\]\]"#
    )
    /// Matches a leading list marker: bullet or ordered number.
    private static let listMarkerPattern = try! NSRegularExpression(
        pattern: #"^\s{0,8}(?:[-*+]|\d{1,4}\.)(?=\s)"#
    )
    /// Matches a task item: bullet, checkbox group, then content. Groups: box, content.
    static let taskPattern = try! NSRegularExpression(
        pattern: #"^\s{0,8}[-*+] (\[[ xX]\])( +)(.*)$"#
    )
    /// Matches a footnote reference, excluding the definition marker's trailing colon.
    private static let footnoteReferencePattern = try! NSRegularExpression(
        pattern: #"\[\^[^\]\s]+\](?!:)"#
    )
    /// Matches the marker opening a footnote definition line.
    private static let footnoteDefinitionPattern = try! NSRegularExpression(
        pattern: #"^\[\^[^\]\s]+\]:"#
    )
    /// Matches an inline hashtag: `#tag`, `#nested/tag`, or `#tag-name`, starting after
    /// whitespace or the line start and ending on a word character.
    static let tagPattern = try! NSRegularExpression(
        pattern: #"(?<![\w#])#([\p{L}\p{N}_](?:[\p{L}\p{N}_\-/]*[\p{L}\p{N}_])?)"#
    )

    /// Scans text and returns every styled span, in document order.
    public static func scan(_ text: String) -> [Token] {
        let ns = text as NSString
        var tokens: [Token] = []
        var insideFence = false
        var fenceLanguage = ""
        var lineStart = 0
        while lineStart < ns.length {
            var start = 0
            var end = 0
            var contentsEnd = 0
            ns.getLineStart(
                &start, end: &end, contentsEnd: &contentsEnd,
                for: NSRange(location: lineStart, length: 0)
            )
            let lineRange = NSRange(location: start, length: contentsEnd - start)
            let line = ns.substring(with: lineRange)
            defer { lineStart = end }

            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                insideFence.toggle()
                fenceLanguage = insideFence
                    ? String(trimmed.dropFirst(3))
                        .trimmingCharacters(in: .whitespaces)
                        .split(separator: " ").first.map(String.init) ?? ""
                    : ""
                tokens.append(Token(kind: .fencedCode, range: lineRange))
                continue
            }
            if insideFence {
                tokens.append(Token(kind: .fencedCode, range: lineRange))
                for span in CodeHighlighter.spans(line: line, language: fenceLanguage) {
                    let kind: TokenKind
                    switch span.kind {
                    case .keyword: kind = .codeKeyword
                    case .string: kind = .codeString
                    case .comment: kind = .codeComment
                    case .number: kind = .codeNumber
                    }
                    tokens.append(Token(
                        kind: kind,
                        range: NSRange(
                            location: lineRange.location + span.range.location,
                            length: span.range.length
                        )
                    ))
                }
                continue
            }
            if let heading = headingToken(line: line, lineRange: lineRange) {
                tokens.append(heading)
                continue
            }
            if trimmed.hasPrefix(">") {
                let whole = NSRange(location: 0, length: (trimmed as NSString).length)
                if calloutPattern.firstMatch(in: trimmed, range: whole) != nil {
                    tokens.append(Token(kind: .calloutHeader, range: lineRange))
                } else {
                    tokens.append(Token(kind: .blockquote, range: lineRange))
                }
                continue
            }
            if MarkdownTables.isTableLine(line) {
                tokens.append(
                    contentsOf: tableTokens(line: line, lineRange: lineRange, ns: ns, nextLineStart: end)
                )
                continue
            }
            if let definition = footnoteDefinitionPattern.firstMatch(
                in: line, range: NSRange(location: 0, length: (line as NSString).length)
            ) {
                tokens.append(
                    Token(
                        kind: .footnoteDefinition,
                        range: NSRange(
                            location: lineRange.location + definition.range.location,
                            length: definition.range.length
                        )
                    )
                )
            }
            tokens.append(contentsOf: inlineTokens(line: line, lineRange: lineRange))
        }
        return tokens
    }

    /// Returns a heading token when the line is an ATX heading, nil otherwise.
    private static func headingToken(line: String, lineRange: NSRange) -> Token? {
        var level = 0
        var index = line.startIndex
        while index < line.endIndex, line[index] == "#" {
            level += 1
            index = line.index(after: index)
        }
        guard (1...6).contains(level) else { return nil }
        guard index == line.endIndex || line[index] == " " else { return nil }
        return Token(kind: .heading(level: level), range: lineRange)
    }

    /// Scans one prose line for inline constructs and the leading list marker.
    private static func inlineTokens(line: String, lineRange: NSRange) -> [Token] {
        var tokens: [Token] = []
        let whole = NSRange(location: 0, length: (line as NSString).length)
        func collect(_ pattern: NSRegularExpression, _ kind: TokenKind) {
            for match in pattern.matches(in: line, range: whole) {
                let shifted = NSRange(
                    location: lineRange.location + match.range.location,
                    length: match.range.length
                )
                tokens.append(Token(kind: kind, range: shifted))
            }
        }
        collect(listMarkerPattern, .listMarker)
        if let task = taskPattern.firstMatch(in: line, range: whole) {
            let box = task.range(at: 1)
            let boxText = (line as NSString).substring(with: box)
            let checked = boxText.lowercased() == "[x]"
            tokens.append(
                Token(
                    kind: .taskMarker(checked: checked),
                    range: NSRange(location: lineRange.location + box.location, length: box.length)
                )
            )
            let content = task.range(at: 3)
            if checked, content.length > 0 {
                tokens.append(
                    Token(
                        kind: .taskDone,
                        range: NSRange(
                            location: lineRange.location + content.location, length: content.length
                        )
                    )
                )
            }
        }
        collect(codePattern, .inlineCode)
        collect(wikiLinkPattern, .wikiLink)
        collect(imagePattern, .image)
        collect(linkPattern, .link)
        // The bracket half of an image link also matches the link pattern; the image
        // token owns that span.
        let imageRanges = tokens.filter { $0.kind == .image }.map(\.range)
        tokens.removeAll { token in
            token.kind == .link && imageRanges.contains { image in
                NSIntersectionRange(image, token.range).length == token.range.length
            }
        }
        collect(boldPattern, .bold)
        collect(italicPattern, .italic)
        collect(highlightPattern, .highlightMark)
        collect(footnoteReferencePattern, .footnoteReference)
        let codeRanges = tokens.filter { $0.kind == .inlineCode }.map(\.range)
        for match in tagPattern.matches(in: line, range: whole) {
            let shifted = NSRange(
                location: lineRange.location + match.range.location,
                length: match.range.length
            )
            let localRange = match.range
            // A hash inside a code span is code, not a tag.
            let insideCode = codeRanges.contains { code in
                NSIntersectionRange(code, NSRange(
                    location: lineRange.location + localRange.location,
                    length: localRange.length
                )).length > 0
            }
            if !insideCode {
                tokens.append(Token(kind: .tag, range: shifted))
            }
        }
        return tokens.sorted { $0.range.location < $1.range.location }
    }

    /// Distinct inline hashtags in a text, hash stripped, in order of first appearance.
    /// Tags inside code spans and fenced code do not count, matching what `scan` styles.
    public static func inlineTags(in text: String) -> [String] {
        var seen: Set<String> = []
        var tags: [String] = []
        let ns = text as NSString
        for token in scan(text) where token.kind == .tag {
            let name = String(ns.substring(with: token.range).dropFirst())
            let key = name.lowercased()
            if !seen.contains(key) {
                seen.insert(key)
                tags.append(name)
            }
        }
        return tags
    }

    /// Tokens for a table row: the whole delimiter row, or each pipe plus a header marker
    /// when the next line is the delimiter, plus normal inline tokens inside cells.
    private static func tableTokens(
        line: String, lineRange: NSRange, ns: NSString, nextLineStart: Int
    ) -> [Token] {
        if MarkdownTables.isDelimiterRow(line) {
            return [Token(kind: .tableDelimiterRow, range: lineRange)]
        }
        var tokens: [Token] = []
        if nextLineStart < ns.length {
            var start = 0
            var end = 0
            var contentsEnd = 0
            ns.getLineStart(
                &start, end: &end, contentsEnd: &contentsEnd,
                for: NSRange(location: nextLineStart, length: 0)
            )
            let next = ns.substring(with: NSRange(location: start, length: contentsEnd - start))
            if MarkdownTables.isDelimiterRow(next) {
                tokens.append(Token(kind: .tableHeader, range: lineRange))
            }
        }
        let lineNS = line as NSString
        var escaped = false
        for position in 0..<lineNS.length {
            let char = lineNS.character(at: position)
            if escaped {
                escaped = false
            } else if char == 0x5C {
                escaped = true
            } else if char == 0x7C {
                tokens.append(
                    Token(
                        kind: .tablePipe,
                        range: NSRange(location: lineRange.location + position, length: 1)
                    )
                )
            }
        }
        tokens.append(contentsOf: inlineTokens(line: line, lineRange: lineRange))
        return tokens
    }
}
