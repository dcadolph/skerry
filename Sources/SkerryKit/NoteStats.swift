import Foundation

/// NoteStats summarizes the size and reading time of a note body.
public struct NoteStats: Equatable, Sendable {
    /// Number of words, counting only tokens that contain a letter or digit.
    public var words: Int
    /// Number of characters including whitespace.
    public var characters: Int
    /// Number of characters excluding whitespace.
    public var charactersNoSpaces: Int
    /// Estimated reading time in minutes, rounded up, zero for an empty note.
    public var readingMinutes: Int

    /// Words per minute used for the reading-time estimate, a common prose reading pace.
    private static let wordsPerMinute = 200

    /// Computes statistics for a note body. Markdown markers like `#` or `-` on their own do
    /// not count as words, so the count matches what a reader would tally.
    public init(body: String) {
        let tokens = body.split(whereSeparator: { $0.isWhitespace })
            .filter { token in token.contains { $0.isLetter || $0.isNumber } }
        words = tokens.count
        // A new note is seeded with an empty heading ("# ") so the first line typed becomes the
        // title. That scaffold is not content, so an untouched note counts as empty rather than
        // reporting the two marker characters.
        let stripped = body.trimmingCharacters(in: .whitespacesAndNewlines)
        let emptyScaffold = stripped.allSatisfy { $0 == "#" }
        characters = emptyScaffold ? 0 : body.count
        charactersNoSpaces = emptyScaffold ? 0 : body.reduce(0) { $0 + ($1.isWhitespace ? 0 : 1) }
        readingMinutes = words == 0
            ? 0
            : Int((Double(words) / Double(Self.wordsPerMinute)).rounded(.up))
    }
}
