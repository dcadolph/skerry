import Foundation

/// SearchQuery splits a search string into structural filters and full-text terms, the
/// Bear-style at-operators: `@todo project` finds notes with open tasks matching
/// "project", `#work` narrows to a tag.
public struct SearchQuery: Equatable, Sendable {
    /// A structural filter inside a query.
    public enum Filter: Equatable, Sendable {
        /// Notes with an unchecked task.
        case todo
        /// Notes with a checked task.
        case done
        /// Notes with an image link.
        case images
        /// Notes with a non-image file link.
        case files
        /// Pinned notes.
        case pinned
        /// Starred notes.
        case starred
        /// Encrypted notes.
        case encrypted
        /// Locked notes.
        case locked
        /// Notes carrying a tag, descendants included.
        case tag(String)
    }

    /// Structural filters, in query order.
    public var filters: [Filter]
    /// Remaining full-text terms joined by spaces; empty when the query was all filters.
    public var text: String

    /// Creates a query.
    public init(filters: [Filter] = [], text: String = "") {
        self.filters = filters
        self.text = text
    }

    /// Parses user input into filters and full-text terms.
    public static func parse(_ input: String) -> SearchQuery {
        var filters: [Filter] = []
        var terms: [String] = []
        for token in input.split(separator: " ") {
            switch token.lowercased() {
            case "@todo", "@task", "@tasks":
                filters.append(.todo)
            case "@done":
                filters.append(.done)
            case "@image", "@images":
                filters.append(.images)
            case "@file", "@files":
                filters.append(.files)
            case "@pinned":
                filters.append(.pinned)
            case "@starred":
                filters.append(.starred)
            case "@encrypted":
                filters.append(.encrypted)
            case "@locked":
                filters.append(.locked)
            default:
                if token.lowercased().hasPrefix("@tag:"), token.count > 5 {
                    filters.append(.tag(String(token.dropFirst(5))))
                } else if token.hasPrefix("#"), token.count > 1 {
                    filters.append(.tag(String(token.dropFirst())))
                } else {
                    terms.append(String(token))
                }
            }
        }
        return SearchQuery(filters: filters, text: terms.joined(separator: " "))
    }
}

/// NoteQueries answers the structural questions search filters ask of a note body.
public enum NoteQueries {
    /// Matches an unchecked task line.
    private static let openTaskPattern = try! NSRegularExpression(
        pattern: #"^\s{0,8}[-*+] \[ \] "#, options: [.anchorsMatchLines]
    )
    /// Matches a checked task line.
    private static let doneTaskPattern = try! NSRegularExpression(
        pattern: #"^\s{0,8}[-*+] \[[xX]\] "#, options: [.anchorsMatchLines]
    )
    /// Matches a non-image markdown link; group 1 is the target.
    private static let fileLinkPattern = try! NSRegularExpression(
        pattern: #"(?<!\!)\[[^\]\n]*\]\(([^)\n]+)\)"#
    )

    /// Whether a body has an unchecked task.
    public static func hasOpenTasks(_ body: String) -> Bool {
        firstMatch(openTaskPattern, in: body) != nil
    }

    /// Whether a body has a checked task.
    public static func hasDoneTasks(_ body: String) -> Bool {
        firstMatch(doneTaskPattern, in: body) != nil
    }

    /// Number of unchecked task lines in a body.
    public static func openTaskCount(_ body: String) -> Int {
        matchCount(openTaskPattern, in: body)
    }

    /// Number of checked task lines in a body.
    public static func doneTaskCount(_ body: String) -> Int {
        matchCount(doneTaskPattern, in: body)
    }

    /// Whether a body links to an image.
    public static func hasImages(_ body: String) -> Bool {
        firstMatch(MarkdownScanner.imagePattern, in: body) != nil
    }

    /// Whether a body links to a local non-image file.
    public static func hasFileLinks(_ body: String) -> Bool {
        let ns = body as NSString
        let whole = NSRange(location: 0, length: ns.length)
        for match in fileLinkPattern.matches(in: body, range: whole) {
            let target = ns.substring(with: match.range(at: 1))
                .trimmingCharacters(in: .whitespaces)
            if !target.contains("://"), !target.hasPrefix("#") {
                return true
            }
        }
        return false
    }

    /// First match of a pattern over a whole string.
    private static func firstMatch(
        _ pattern: NSRegularExpression, in text: String
    ) -> NSTextCheckingResult? {
        pattern.firstMatch(
            in: text, range: NSRange(location: 0, length: (text as NSString).length)
        )
    }

    /// Number of matches of a pattern over a whole string.
    private static func matchCount(_ pattern: NSRegularExpression, in text: String) -> Int {
        pattern.numberOfMatches(
            in: text, range: NSRange(location: 0, length: (text as NSString).length)
        )
    }
}
