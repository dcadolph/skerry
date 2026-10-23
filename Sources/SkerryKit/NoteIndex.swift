import Foundation
import SQLite3

/// NoteIndex is the rebuildable FTS5 search index stored in `.skerry/index.db`.
///
/// The index is a cache over the library files. Deleting the database loses nothing; any
/// client rebuilds it by re-indexing the notes on disk.
public final class NoteIndex {
    /// Errors raised by index operations.
    public enum IndexError: Error {
        /// SQLite reported a failure; the message comes from the database handle.
        case sqlite(String)
    }

    /// A single search result.
    public struct Hit: Equatable, Sendable {
        /// Path of the note file relative to the library root.
        public var path: String
        /// Resolved display title at index time, empty when the note has none.
        public var title: String
        /// Body excerpt around the strongest match, marks stripped, empty when none.
        public var snippet: String
        /// UTF-16 ranges within `snippet` covering the matched terms, for emphasis.
        public var highlights: [NSRange]
        /// Whether the hit came from the fuzzy fallback rather than an exact term match.
        public var fuzzy: Bool

        /// Creates a hit; snippet, highlights, and the fuzzy flag default to empty.
        public init(
            path: String, title: String, snippet: String = "",
            highlights: [NSRange] = [], fuzzy: Bool = false
        ) {
            self.path = path
            self.title = title
            self.snippet = snippet
            self.highlights = highlights
            self.fuzzy = fuzzy
        }
    }

    /// Marks FTS5 wraps around a matched term in a snippet, stripped before display. These
    /// are control characters that never occur in note text, so parsing them back is exact.
    private static let matchOpen = "\u{02}"
    /// Closing partner of ``matchOpen``.
    private static let matchClose = "\u{03}"

    /// Column weights for bm25 relevance, in table-declaration order: path (unindexed),
    /// title, tags, body, extras. A title hit outweighs a tag hit, which outweighs a body or
    /// attachment-text hit, so the note a query most likely means rises even when the same
    /// word is common across many bodies. A constant, so it is safe to inline into SQL.
    private static let rankExpression = "bm25(notes, 0.0, 10.0, 6.0, 1.0, 1.0)"

    /// Destructor flag telling SQLite to copy bound text before returning.
    private static let transientDestructor = unsafeBitCast(
        OpaquePointer(bitPattern: -1), to: sqlite3_destructor_type.self
    )

    /// Open database handle.
    private var db: OpaquePointer?

    /// Opens or creates the index database inside a library root.
    public convenience init(libraryRoot: URL) throws {
        let cacheDir = libraryRoot.appendingPathComponent(".skerry")
        try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        try self.init(databasePath: cacheDir.appendingPathComponent("index.db").path)
    }

    /// Opens or creates the index database at an explicit path; `:memory:` works for tests.
    public init(databasePath: String) throws {
        guard sqlite3_open(databasePath, &db) == SQLITE_OK else {
            let message = String(cString: sqlite3_errmsg(db))
            sqlite3_close(db)
            throw IndexError.sqlite(message)
        }
        // Zero freed pages on delete so a note's text does not linger in the file after the
        // note is removed or encrypted. This is the search cache, and it must never become a
        // second, unprotected copy of an encrypted note's contents.
        try execute("PRAGMA secure_delete = ON")
        try migrate()
    }

    /// Creates or upgrades the schema. Version 2 added the attachment text column; the
    /// index is a rebuildable cache, so an upgrade drops and recreates the table and the
    /// caller's next full re-index fills it back in.
    private func migrate() throws {
        if try userVersion() < 2 {
            try execute("DROP TABLE IF EXISTS notes")
            try execute("PRAGMA user_version = 2")
        }
        try execute(
            """
            CREATE VIRTUAL TABLE IF NOT EXISTS notes
            USING fts5(path UNINDEXED, title, tags, body, extras)
            """
        )
    }

    /// Reads the schema version stamped on the database.
    private func userVersion() throws -> Int {
        let statement = try prepare("PRAGMA user_version")
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int(statement, 0))
    }

    deinit {
        sqlite3_close(db)
    }

    /// Inserts or replaces the indexed content for a note path. Extras carry searchable
    /// text that lives outside the body, such as text extracted from attachments.
    public func upsert(_ stored: StoredNote, extras: String = "") throws {
        try remove(stored.path)
        let insert = try prepare(
            "INSERT INTO notes (path, title, tags, body, extras) VALUES (?, ?, ?, ?, ?)"
        )
        defer { sqlite3_finalize(insert) }
        bind(stored.path, to: insert, at: 1)
        bind(stored.note.displayTitle ?? "", to: insert, at: 2)
        bind(stored.note.metadata.tags.joined(separator: " "), to: insert, at: 3)
        bind(stored.note.body, to: insert, at: 4)
        bind(extras, to: insert, at: 5)
        guard sqlite3_step(insert) == SQLITE_DONE else { throw currentError() }
    }

    /// Removes a note path from the index.
    public func remove(_ path: String) throws {
        let delete = try prepare("DELETE FROM notes WHERE path = ?")
        defer { sqlite3_finalize(delete) }
        bind(path, to: delete, at: 1)
        guard sqlite3_step(delete) == SQLITE_DONE else { throw currentError() }
    }

    /// Compacts the index and reclaims freed pages so deleted content, such as a note's text
    /// from before it was encrypted, cannot be carved out of the database file afterward.
    ///
    /// FTS5 keeps a deleted row's term postings in unmerged segments until a merge rewrites
    /// them, so an `optimize` merges every segment and applies the deletes, and `VACUUM` then
    /// rewrites the file without the freed pages.
    public func scrub() throws {
        try execute("INSERT INTO notes(notes) VALUES('optimize')")
        try execute("VACUUM")
    }

    /// Runs a full-text query over titles, tags, and bodies, best matches first. A snippet is
    /// the expensive part of a hit, so snippets are built only for the top `snippetLimit` hits
    /// by rank, the ones a result list actually shows. Lower-ranked hits still come back, just
    /// without a prebuilt excerpt, so callers keep full match coverage for counting and for
    /// folder or filter intersection. When nothing matches exactly, a typo-tolerant pass over
    /// titles catches near misses.
    public func search(_ query: String, snippetLimit: Int = 200) throws -> [Hit] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return [] }
        let match = ftsQuery(for: trimmed)
        guard !match.isEmpty else { return [] }

        // Snippets for the top hits only. snippet() runs once per emitted row, so a bounded
        // snippet query keeps a match-everything search from building thousands of excerpts.
        var snippets: [String: (text: String, highlights: [NSRange])] = [:]
        let topSelect = try prepare(
            """
            SELECT path, snippet(notes, 3, ?, ?, '…', 12)
            FROM notes WHERE notes MATCH ? ORDER BY \(Self.rankExpression) LIMIT ?
            """
        )
        defer { sqlite3_finalize(topSelect) }
        bind(Self.matchOpen, to: topSelect, at: 1)
        bind(Self.matchClose, to: topSelect, at: 2)
        bind(match, to: topSelect, at: 3)
        sqlite3_bind_int(topSelect, 4, Int32(max(0, snippetLimit)))
        while sqlite3_step(topSelect) == SQLITE_ROW {
            snippets[column(topSelect, at: 0)] = Self.parseSnippet(column(topSelect, at: 1))
        }

        // Every hit in rank order, carrying a prebuilt snippet when one was made for it.
        let allSelect = try prepare(
            "SELECT path, title FROM notes WHERE notes MATCH ? ORDER BY \(Self.rankExpression)"
        )
        defer { sqlite3_finalize(allSelect) }
        bind(match, to: allSelect, at: 1)
        var hits: [Hit] = []
        while sqlite3_step(allSelect) == SQLITE_ROW {
            let path = column(allSelect, at: 0)
            let found = snippets[path]
            hits.append(
                Hit(
                    path: path, title: column(allSelect, at: 1),
                    snippet: found?.text ?? "", highlights: found?.highlights ?? []
                )
            )
        }
        if hits.isEmpty { return fuzzyFallback(for: trimmed) }
        return hits
    }

    /// Splits an FTS5 snippet into plain display text and the UTF-16 ranges of its matches.
    static func parseSnippet(_ raw: String) -> (text: String, highlights: [NSRange]) {
        guard raw.contains(matchOpen) else { return (raw, []) }
        var text = ""
        var highlights: [NSRange] = []
        var runStart = 0
        var inMatch = false
        for character in raw {
            let piece = String(character)
            if piece == matchOpen {
                runStart = (text as NSString).length
                inMatch = true
            } else if piece == matchClose {
                let end = (text as NSString).length
                if inMatch, end > runStart {
                    highlights.append(NSRange(location: runStart, length: end - runStart))
                }
                inMatch = false
            } else {
                text += piece
            }
        }
        return (text, highlights)
    }

    /// Titles that are a small edit distance from the query, the typo-tolerant fallback used
    /// only when exact matching finds nothing. Bounded so a huge library stays responsive.
    private func fuzzyFallback(for query: String) -> [Hit] {
        let rows = allTitles()
        let ranked = SearchFuzzy.rank(query: query, candidates: rows.map(\.title))
        var hits: [Hit] = []
        for match in ranked.prefix(20) {
            let row = rows[match.index]
            hits.append(Hit(path: row.path, title: row.title, snippet: "", fuzzy: true))
        }
        return hits
    }

    /// Every indexed note's path and title, for the fuzzy fallback.
    private func allTitles() -> [(path: String, title: String)] {
        guard let select = try? prepare("SELECT path, title FROM notes") else { return [] }
        defer { sqlite3_finalize(select) }
        var rows: [(path: String, title: String)] = []
        while sqlite3_step(select) == SQLITE_ROW {
            rows.append((path: column(select, at: 0), title: column(select, at: 1)))
        }
        return rows
    }

    /// Converts user input to an FTS5 prefix query, quoting each term to disarm operators.
    ///
    /// Terms made up entirely of quote characters are dropped rather than emitted as an empty
    /// phrase, so input like a lone `"` yields an empty query the caller can short-circuit instead
    /// of a phrase that only ever matches nothing.
    func ftsQuery(for input: String) -> String {
        input.split(separator: " ")
            .filter { $0.contains { $0 != "\"" } }
            .map { "\"\($0.replacingOccurrences(of: "\"", with: "\"\""))\"*" }
            .joined(separator: " ")
    }

    /// Runs a statement that takes no bindings and returns no rows.
    private func execute(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw currentError() }
    }

    /// Prepares a statement, throwing on syntax or schema errors.
    private func prepare(_ sql: String) throws -> OpaquePointer? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw currentError()
        }
        return statement
    }

    /// Binds a Swift string to a statement parameter with copy semantics.
    private func bind(_ value: String, to statement: OpaquePointer?, at index: Int32) {
        sqlite3_bind_text(statement, index, value, -1, Self.transientDestructor)
    }

    /// Reads a text column from the current row, empty when NULL.
    private func column(_ statement: OpaquePointer?, at index: Int32) -> String {
        guard let text = sqlite3_column_text(statement, index) else { return "" }
        return String(cString: text)
    }

    /// Wraps the current SQLite error message.
    private func currentError() -> IndexError {
        .sqlite(String(cString: sqlite3_errmsg(db)))
    }
}
