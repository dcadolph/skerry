import Foundation

/// MarkdownFootnotes builds footnote edits: a numbered reference at the caret paired with a
/// definition stub appended to the end of the note.
public enum MarkdownFootnotes {
    /// Matches every numeric footnote label, reference or definition.
    private static let labelPattern = try! NSRegularExpression(pattern: #"\[\^(\d+)\]"#)

    /// The next unused numeric footnote label in the text.
    public static func nextLabel(in text: String) -> String {
        let ns = text as NSString
        var highest = 0
        let whole = NSRange(location: 0, length: ns.length)
        for match in labelPattern.matches(in: text, range: whole) {
            highest = max(highest, Int(ns.substring(with: match.range(at: 1))) ?? 0)
        }
        return String(highest + 1)
    }

    /// Inserts a reference at the caret and a definition stub at the end, returning the new
    /// text and the caret offset placed after the definition marker, ready for typing.
    public static func insertEdit(text: String, caret: Int) -> (text: String, caret: Int) {
        let ns = text as NSString
        let clamped = min(max(caret, 0), ns.length)
        let label = nextLabel(in: text)
        var updated = ns.replacingCharacters(
            in: NSRange(location: clamped, length: 0), with: "[^\(label)]"
        )
        let separator = updated.hasSuffix("\n") ? "\n" : "\n\n"
        updated += separator + "[^\(label)]: "
        return (updated, (updated as NSString).length)
    }
}
