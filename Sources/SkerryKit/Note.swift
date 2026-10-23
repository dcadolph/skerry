import Foundation

/// Note is a single Markdown note: parsed front matter metadata plus the Markdown body.
public struct Note: Equatable, Sendable {
    /// Metadata is the typed front matter of a note.
    public struct Metadata: Equatable, Sendable {
        /// Stable identity that survives renames and moves.
        public var id: UUID?
        /// Display title; nil means fall back to the first H1, then the file name.
        public var title: String?
        /// Case-insensitive tag names.
        public var tags: [String]
        /// Whether the note appears in the starred view.
        public var starred: Bool
        /// Whether the note pins to the top of its folder listing.
        public var pinned: Bool
        /// Whether the note is hidden from normal views.
        public var archived: Bool
        /// Whether opening the note requires device-owner authentication.
        public var locked: Bool
        /// Whether the body on disk is passphrase-encrypted ciphertext.
        public var encrypted: Bool
        /// Creation time; nil means fall back to file birth time.
        public var created: Date?
        /// Last content change; nil means fall back to file mtime.
        public var updated: Date?
        /// Front matter keys this client does not understand, preserved verbatim on rewrite.
        public var unknown: [(key: String, rawValue: String)]

        /// Creates metadata with everything empty or false.
        public init() {
            tags = []
            starred = false
            pinned = false
            archived = false
            locked = false
            encrypted = false
            unknown = []
        }

        public static func == (lhs: Metadata, rhs: Metadata) -> Bool {
            lhs.id == rhs.id && lhs.title == rhs.title && lhs.tags == rhs.tags
                && lhs.starred == rhs.starred && lhs.pinned == rhs.pinned
                && lhs.archived == rhs.archived && lhs.locked == rhs.locked
                && lhs.encrypted == rhs.encrypted
                && lhs.created == rhs.created && lhs.updated == rhs.updated
                && lhs.unknown.map(\.key) == rhs.unknown.map(\.key)
                && lhs.unknown.map(\.rawValue) == rhs.unknown.map(\.rawValue)
        }
    }

    /// Typed front matter of the note.
    public var metadata: Metadata
    /// Markdown body without the front matter block.
    public var body: String

    /// Creates a note from metadata and a Markdown body.
    public init(metadata: Metadata = Metadata(), body: String = "") {
        self.metadata = metadata
        self.body = body
    }

    /// Resolved display title: explicit title, else the first H1 in the body, else nil.
    public var displayTitle: String? {
        if let title = metadata.title, !title.isEmpty { return title }
        for line in body.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("# ") {
                return String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }
}
