import Foundation

/// MarkdownFolding maps a document's headings to the body regions they can hide.
/// Folding is a view-time act: the text never changes, only what the editor draws.
public enum MarkdownFolding {
    /// Section is one foldable heading with the body lines beneath it.
    public struct Section: Equatable, Sendable {
        /// The heading's own line, terminator included.
        public let headingLine: NSRange
        /// Everything under the heading up to the next heading of equal or higher
        /// rank; empty when the heading has no body.
        public let body: NSRange
        /// The heading's trimmed text, hashes included.
        public let title: String
        /// A stable key fold state hangs on. It joins the heading's occurrence index among
        /// same-text headings to the title, so folding one `## Notes` never folds another
        /// (finding F4), while surviving edits that do not add or remove an identical heading
        /// above it.
        public let foldID: String
    }

    /// Heading is one heading line and its text, whether or not it has a body. Wiki
    /// `#heading` targets and heading completion resolve against these, so a heading
    /// with nothing under it still counts, unlike a foldable Section.
    public struct Heading: Equatable, Sendable {
        /// The heading's own line, terminator included.
        public let line: NSRange
        /// The heading text with its leading hashes and surrounding whitespace removed.
        public let text: String
        /// Heading rank, 1 through 6, the count of leading hashes; drives outline indent.
        public let level: Int

        /// Creates a heading.
        public init(line: NSRange, text: String, level: Int) {
            self.line = line
            self.text = text
            self.level = level
        }
    }

    /// Matches a heading line and captures its hash run.
    private static let headingPattern = try! NSRegularExpression(
        pattern: #"^(#{1,6}) "#
    )

    /// Scans every heading line, top to bottom, capturing its line range, hash-run
    /// length, and full line content. Shared by the section and heading views.
    private static func scan(_ text: String) -> [(line: NSRange, level: Int, content: String)] {
        let ns = text as NSString
        var headings: [(line: NSRange, level: Int, content: String)] = []
        var position = 0
        while position < ns.length {
            let line = ns.lineRange(for: NSRange(location: position, length: 0))
            let content = ns.substring(with: line)
            if let match = headingPattern.firstMatch(
                in: content, range: NSRange(location: 0, length: (content as NSString).length)
            ) {
                headings.append((line: line, level: match.range(at: 1).length, content: content))
            }
            position = line.location + max(line.length, 1)
        }
        return headings
    }

    /// Every heading in a document, top to bottom, whether or not it has a body. The text
    /// is stripped of hashes and surrounding whitespace, ready to match a wiki target.
    public static func headings(in text: String) -> [Heading] {
        scan(text).map { Heading(line: $0.line, text: headingText($0.content), level: $0.level) }
    }

    /// The heading text of a heading line, its leading hashes and surrounding whitespace
    /// removed. The form a wiki `#heading` target names and an HTML slug derives from.
    public static func headingText(_ line: String) -> String {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        return String(trimmed.drop { $0 == "#" }).trimmingCharacters(in: .whitespaces)
    }

    /// The first heading whose text matches a bare name, case-insensitive; nil when none
    /// matches. The name carries no leading hashes, as a wiki `#heading` target does not.
    public static func heading(named name: String, in text: String) -> Heading? {
        let wanted = name.trimmingCharacters(in: .whitespaces).lowercased()
        guard !wanted.isEmpty else { return nil }
        return headings(in: text).first { $0.text.lowercased() == wanted }
    }

    /// Every foldable section in a document, top to bottom.
    public static func sections(in text: String) -> [Section] {
        let ns = text as NSString
        let scanned = scan(text)
        var result: [Section] = []
        var occurrences: [String: Int] = [:]
        for (index, heading) in scanned.enumerated() {
            let title = heading.content.trimmingCharacters(in: .whitespacesAndNewlines)
            let bodyStart = heading.line.location + heading.line.length
            var bodyEnd = ns.length
            for later in scanned.dropFirst(index + 1) where later.level <= heading.level {
                bodyEnd = later.line.location
                break
            }
            let body = NSRange(location: bodyStart, length: max(bodyEnd - bodyStart, 0))
            guard body.length > 0 else { continue }
            let occurrence = occurrences[title, default: 0]
            occurrences[title] = occurrence + 1
            result.append(Section(
                headingLine: heading.line, body: body, title: title,
                foldID: "\(occurrence)\u{1}\(title)"
            ))
        }
        return result
    }

    /// The section whose heading line or body contains the caret, innermost first,
    /// nil when the caret sits above every heading.
    public static func section(atCaret caret: Int, in text: String) -> Section? {
        let all = sections(in: text)
        let position = max(caret, 0)
        var best: Section?
        for section in all {
            let start = section.headingLine.location
            let end = section.body.location + section.body.length
            guard position >= start, position <= end else { continue }
            // Later sections start deeper, so the last hit is the innermost.
            best = section
        }
        return best
    }

    /// The body ranges hidden for a set of folded section ids, in document order.
    public static func foldedBodies(in text: String, foldedIDs: Set<String>) -> [NSRange] {
        guard !foldedIDs.isEmpty else { return [] }
        return sections(in: text)
            .filter { foldedIDs.contains($0.foldID) }
            .map(\.body)
    }
}
