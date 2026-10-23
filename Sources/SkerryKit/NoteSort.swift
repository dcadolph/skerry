import Foundation

/// NoteSort is the order the note list uses when no search is active. Pinned notes always
/// lead; the chosen key orders the rest, with the file path as a stable final tiebreaker.
public enum NoteSort: String, CaseIterable, Sendable {
    /// Most recently edited first.
    case updated
    /// Most recently created first.
    case created
    /// Title A to Z, case-insensitive.
    case title

    /// Sorts notes pinned-first, then by the chosen key, then by path so equal notes never
    /// swap places between renders.
    public func sorted(_ notes: [StoredNote]) -> [StoredNote] {
        notes.sorted { first, second in
            if first.note.metadata.pinned != second.note.metadata.pinned {
                return first.note.metadata.pinned
            }
            switch self {
            case .updated:
                if first.updated != second.updated { return first.updated > second.updated }
            case .created:
                if first.created != second.created { return first.created > second.created }
            case .title:
                let left = (first.note.displayTitle ?? "").lowercased()
                let right = (second.note.displayTitle ?? "").lowercased()
                if left != right { return left < right }
            }
            return first.path < second.path
        }
    }
}
