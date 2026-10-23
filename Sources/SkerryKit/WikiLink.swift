import Foundation

/// WikiLink splits a wiki-link target into the note it points at and an optional heading within
/// that note, so `[[Note#Heading]]` opens Note and scrolls to Heading. The note part is
/// everything before the first `#`; an empty note part (`[[#Heading]]`) means the note the link
/// is written in. Splitting lives in one place so the link graph, resolution, styling, and
/// export all agree on where the note ends and the heading begins.
public enum WikiLink {
    /// The note and heading a wiki target names.
    public struct Target: Equatable, Sendable {
        /// Note the link points at; empty means the note the link is written in.
        public let note: String
        /// Heading within the note, nil when the target names none.
        public let heading: String?

        /// Creates a target.
        public init(note: String, heading: String?) {
            self.note = note
            self.heading = heading
        }
    }

    /// Splits a raw wiki target, the bracket-trimmed text inside `[[...]]`, into its note and
    /// heading. The first `#` divides them; whitespace around each side is trimmed, and a
    /// trailing `#` with nothing after it names no heading.
    public static func split(_ target: String) -> Target {
        guard let hash = target.firstIndex(of: "#") else {
            return Target(note: target.trimmingCharacters(in: .whitespaces), heading: nil)
        }
        let note = target[..<hash].trimmingCharacters(in: .whitespaces)
        let heading = target[target.index(after: hash)...].trimmingCharacters(in: .whitespaces)
        return Target(note: note, heading: heading.isEmpty ? nil : heading)
    }
}
