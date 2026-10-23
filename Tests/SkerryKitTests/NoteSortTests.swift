import Foundation
import Testing

@testable import SkerryKit

@Suite struct NoteSortTests {
    /// Builds a stored note with explicit title, dates, and pin state.
    private func note(
        _ path: String, title: String, created: Date, updated: Date, pinned: Bool = false
    ) -> StoredNote {
        var meta = Note.Metadata()
        meta.title = title
        meta.created = created
        meta.updated = updated
        meta.pinned = pinned
        return StoredNote(path: path, note: Note(metadata: meta, body: ""))
    }

    @Test func updatedSortsRecentFirstWithPinnedAbove() {
        let base = Date(timeIntervalSince1970: 1_000_000)
        let old = note("a.md", title: "Alpha", created: base, updated: base)
        let recent = note("b.md", title: "Beta", created: base, updated: base.addingTimeInterval(100))
        let pinnedOld = note("c.md", title: "Gamma", created: base, updated: base, pinned: true)
        // Pinned leads regardless of date; among the rest, the newer edit wins.
        #expect(NoteSort.updated.sorted([old, recent, pinnedOld]).map(\.path) == ["c.md", "b.md", "a.md"])
    }

    @Test func titleSortsAlphabeticallyCaseInsensitive() {
        let base = Date(timeIntervalSince1970: 1_000_000)
        let notes = [
            note("a.md", title: "Zebra", created: base, updated: base),
            note("b.md", title: "apple", created: base, updated: base),
            note("c.md", title: "Mango", created: base, updated: base),
        ]
        #expect(NoteSort.title.sorted(notes).map(\.path) == ["b.md", "c.md", "a.md"])
    }

    @Test func createdSortsNewestFirst() {
        let base = Date(timeIntervalSince1970: 1_000_000)
        let older = note("a.md", title: "Alpha", created: base, updated: base)
        let newer = note("b.md", title: "Beta", created: base.addingTimeInterval(500), updated: base)
        #expect(NoteSort.created.sorted([older, newer]).map(\.path) == ["b.md", "a.md"])
    }
}
