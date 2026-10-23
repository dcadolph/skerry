import Foundation

/// MarkdownEditing decides how structural editing keystrokes behave, the way dedicated
/// note editors do: lists continue themselves and empty items end their list.
public enum MarkdownEditing {
    /// What the editor should do in place of a plain newline.
    public enum NewlineAction: Equatable {
        /// Insert this text at the caret; includes the newline and the next marker.
        case insert(String)
        /// Replace this range with the text, used to clear the marker of an empty item.
        case replaceRange(NSRange, with: String)
        /// No structure at the caret; let the platform insert a plain newline.
        case plain
    }

    /// Matches a task line: indent, bullet, checkbox, spacing, then content. Groups:
    /// indent, bullet, box, content. Checked before the plain list pattern so a checkbox
    /// item continues as a fresh checkbox rather than a bare bullet.
    private static let taskLinePattern = try! NSRegularExpression(
        pattern: #"^(\s{0,8})([-*+]) \[[ xX]\]( +)(.*)$"#
    )
    /// Matches a list line: indent, bullet or ordered marker, spacing, then content.
    private static let listLinePattern = try! NSRegularExpression(
        pattern: #"^(\s{0,8})([-*+]|\d{1,9}\.)( +)(.*)$"#
    )
    /// Matches a blockquote line: indent, one angle marker, optional space, content.
    private static let quoteLinePattern = try! NSRegularExpression(
        pattern: #"^(\s{0,8}> ?)(.*)$"#
    )

    /// Whether one edit can change styling far from itself, forcing a whole-document
    /// restyle. Backticks are the trigger: they open and close inline code and fences,
    /// whose state reaches to the end of the document. Everything else styles locally.
    public static func editRequiresFullRestyle(
        replacing affected: NSRange, with replacement: String, in text: String
    ) -> Bool {
        if replacement.contains("`") { return true }
        let ns = text as NSString
        guard affected.location >= 0, affected.location + affected.length <= ns.length else {
            return true
        }
        return ns.substring(with: affected).contains("`")
    }

    /// The paragraph-aligned range around an edit that needs restyling: the edited
    /// paragraphs plus one neighbor each way, so spacing and table-header styling that
    /// depend on adjacent lines stay right.
    public static func paragraphsAround(_ range: NSRange, in text: String) -> NSRange {
        let ns = text as NSString
        let clamped = NSIntersectionRange(
            NSRange(location: 0, length: ns.length),
            NSRange(location: min(max(range.location, 0), ns.length), length: max(range.length, 0))
        )
        var result = ns.paragraphRange(for: clamped)
        if result.location > 0 {
            let before = ns.paragraphRange(for: NSRange(location: result.location - 1, length: 0))
            result = NSUnionRange(result, before)
        }
        let end = result.location + result.length
        if end < ns.length {
            let after = ns.paragraphRange(for: NSRange(location: end, length: 0))
            result = NSUnionRange(result, after)
        }
        return result
    }

    /// The minimal edit to flip a task checkbox when the offset falls on its marker.
    /// Returns the box range and its replacement, or nil when the offset is not on a box.
    public static func taskToggleEdit(text: String, at offset: Int) -> (NSRange, String)? {
        let ns = text as NSString
        guard offset >= 0, offset <= ns.length else { return nil }
        var lineStart = 0
        var lineEnd = 0
        var contentsEnd = 0
        ns.getLineStart(
            &lineStart, end: &lineEnd, contentsEnd: &contentsEnd,
            for: NSRange(location: min(offset, ns.length), length: 0)
        )
        let lineRange = NSRange(location: lineStart, length: contentsEnd - lineStart)
        let line = ns.substring(with: lineRange)
        let whole = NSRange(location: 0, length: (line as NSString).length)
        guard let match = MarkdownScanner.taskPattern.firstMatch(in: line, range: whole) else {
            return nil
        }
        let box = match.range(at: 1)
        let boxRange = NSRange(location: lineStart + box.location, length: box.length)
        // A tap anywhere on the marker line's leading run through the box toggles it.
        guard offset >= lineStart, offset <= boxRange.location + boxRange.length else {
            return nil
        }
        let checked = (line as NSString).substring(with: box).lowercased() == "[x]"
        return (boxRange, checked ? "[ ]" : "[x]")
    }

    /// Toggles the checkbox of a task line when the offset falls on its box, else nil.
    /// Returns the whole updated text so the editor can replace its contents.
    public static func toggleTask(text: String, at offset: Int) -> String? {
        guard let (range, replacement) = taskToggleEdit(text: text, at: offset) else { return nil }
        return (text as NSString).replacingCharacters(in: range, with: replacement)
    }

    /// Returns the action for pressing return with the caret at a UTF-16 offset.
    public static func newlineAction(text: String, caret: Int) -> NewlineAction {
        let ns = text as NSString
        guard caret >= 0, caret <= ns.length else { return .plain }
        var lineStart = 0
        var lineEnd = 0
        var contentsEnd = 0
        ns.getLineStart(
            &lineStart, end: &lineEnd, contentsEnd: &contentsEnd,
            for: NSRange(location: min(caret, ns.length), length: 0)
        )
        let lineRange = NSRange(location: lineStart, length: contentsEnd - lineStart)
        let line = ns.substring(with: lineRange)
        let whole = NSRange(location: 0, length: (line as NSString).length)

        if MarkdownTables.isTableLine(line) {
            let cells = MarkdownTables.cells(ofRow: line)
            if !cells.isEmpty, cells.allSatisfy(\.isEmpty), !MarkdownTables.isDelimiterRow(line) {
                return .replaceRange(lineRange, with: "")
            }
            return .insert("\n" + MarkdownTables.emptyRow(columns: max(cells.count, 1)))
        }

        if let match = taskLinePattern.firstMatch(in: line, range: whole) {
            let indent = (line as NSString).substring(with: match.range(at: 1))
            let bullet = (line as NSString).substring(with: match.range(at: 2))
            let content = (line as NSString).substring(with: match.range(at: 4))
            if content.trimmingCharacters(in: .whitespaces).isEmpty {
                let markerLength = match.range(at: 4).location
                return .replaceRange(
                    NSRange(location: lineStart, length: markerLength), with: ""
                )
            }
            return .insert("\n\(indent)\(bullet) [ ] ")
        }

        if let match = listLinePattern.firstMatch(in: line, range: whole) {
            let indent = (line as NSString).substring(with: match.range(at: 1))
            let marker = (line as NSString).substring(with: match.range(at: 2))
            let content = (line as NSString).substring(with: match.range(at: 4))
            if content.trimmingCharacters(in: .whitespaces).isEmpty {
                let markerLength = match.range(at: 4).location
                return .replaceRange(
                    NSRange(location: lineStart, length: markerLength), with: ""
                )
            }
            let nextMarker: String
            if marker.hasSuffix(".") {
                let number = Int(marker.dropLast()) ?? 0
                nextMarker = "\(number + 1)."
            } else {
                nextMarker = marker
            }
            return .insert("\n\(indent)\(nextMarker) ")
        }

        if let match = quoteLinePattern.firstMatch(in: line, range: whole) {
            let prefix = (line as NSString).substring(with: match.range(at: 1))
            let content = (line as NSString).substring(with: match.range(at: 2))
            if content.trimmingCharacters(in: .whitespaces).isEmpty {
                return .replaceRange(
                    NSRange(location: lineStart, length: match.range(at: 1).length), with: ""
                )
            }
            return .insert("\n\(prefix)")
        }

        return .plain
    }
}
