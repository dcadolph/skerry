import Foundation
import Testing

@testable import SkerryKit

@Suite struct NoteStoreTests {
    /// Creates a throwaway library root for one test.
    private func makeLibrary() throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("skerry-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test func scanFindsNotesAndSkipsReservedEntries() throws {
        let root = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try NoteStore(root: root)

        try store.save(Note(body: "a"), to: "inbox.md")
        try store.save(Note(body: "b"), to: "projects/skerry/plan.md")
        for hidden in [".skerry/cache.md", "assets/readme.md", ".hidden/x.md"] {
            let url = root.appendingPathComponent(hidden)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try "ignored".write(to: url, atomically: true, encoding: .utf8)
        }

        #expect(try store.notePaths() == ["inbox.md", "projects/skerry/plan.md"])
    }

    @Test func saveThenLoadRoundTrips() throws {
        let root = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try NoteStore(root: root)

        var metadata = Note.Metadata()
        metadata.title = "Plan"
        metadata.tags = ["skerry"]
        metadata.pinned = true
        let note = Note(metadata: metadata, body: "Ship phase one.\n")

        try store.save(note, to: "plan.md")
        let loaded = try store.load("plan.md")
        #expect(loaded.note == note)
        #expect(loaded.path == "plan.md")
    }

    @Test func rejectsEscapingAndReservedPaths() throws {
        let root = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try NoteStore(root: root)

        for bad in ["../outside.md", ".skerry/index.md", "assets/note.md", ".hidden.md"] {
            #expect(throws: NoteStore.StoreError.self) {
                try store.save(Note(body: "x"), to: bad)
            }
        }
    }

    @Test func missingRootThrows() {
        let missing = URL(fileURLWithPath: "/nonexistent/skerry-\(UUID().uuidString)")
        #expect(throws: NoteStore.StoreError.self) { try NoteStore(root: missing) }
    }

    @Test func loadFillsFileDateFallbacks() throws {
        let root = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try NoteStore(root: root)

        try store.save(Note(body: "plain body, no front matter\n"), to: "plain.md")
        let loaded = try store.load("plain.md")
        #expect(loaded.note.metadata.updated == nil)
        #expect(loaded.fileModified != nil)
        #expect(loaded.updated > Date().addingTimeInterval(-60))
        #expect(loaded.created > Date().addingTimeInterval(-60))
    }

    @Test func moveRelocatesAndRefusesOverwrite() throws {
        let root = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try NoteStore(root: root)

        try store.save(Note(body: "a"), to: "one.md")
        try store.save(Note(body: "b"), to: "two.md")
        try store.move(from: "one.md", to: "archive/renamed.md")
        #expect(try store.notePaths() == ["archive/renamed.md", "two.md"])
        #expect(try store.load("archive/renamed.md").note.body == "a")
        #expect(throws: (any Error).self) {
            try store.move(from: "archive/renamed.md", to: "two.md")
        }
        #expect(throws: (any Error).self) {
            try store.move(from: "two.md", to: ".skerry/two.md")
        }
    }

    @Test func scanAndSaveHandleAllNoteFormats() throws {
        let root = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try NoteStore(root: root)

        var starred = Note.Metadata()
        starred.starred = true
        try store.save(Note(metadata: starred, body: "plain\n"), to: "a.txt")
        try store.save(Note(metadata: starred, body: "<p>hi</p>\n"), to: "b.html")
        try store.save(Note(body: "# md\n"), to: "c.md")
        try "ignored".write(
            to: root.appendingPathComponent("d.pdf"), atomically: true, encoding: .utf8
        )

        #expect(try store.notePaths() == ["a.txt", "b.html", "c.md"])
        #expect(try store.load("a.txt").note.metadata.starred)
        let html = try String(
            contentsOf: root.appendingPathComponent("b.html"), encoding: .utf8
        )
        #expect(html == "<p>hi</p>\n")
    }

    @Test func trashRecoverAndPurge() throws {
        let root = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try NoteStore(root: root)

        var meta = Note.Metadata()
        meta.tags = ["keep"]
        try store.save(Note(metadata: meta, body: "body one\n"), to: "projects/one.md")
        let deletedAt = Date(timeIntervalSince1970: 1_700_000_000)
        try store.moveToTrash("projects/one.md", deletedAt: deletedAt)

        // Original gone, trash holds one entry with its origin and content intact.
        #expect(try store.notePaths().isEmpty)
        let trashed = try store.trashedNotes()
        #expect(trashed.count == 1)
        #expect(trashed[0].originalPath == "projects/one.md")
        #expect(trashed[0].deletedAt == deletedAt)
        #expect(trashed[0].note.body == "body one\n")
        #expect(trashed[0].note.metadata.tags == ["keep"])

        // Recovery restores it to the original path, cleaning the trash markers.
        let restored = try store.recoverFromTrash(id: trashed[0].id)
        #expect(restored == "projects/one.md")
        #expect(try store.notePaths() == ["projects/one.md"])
        #expect(try store.trashedNotes().isEmpty)
        #expect(try store.load("projects/one.md").note.metadata.tags == ["keep"])
    }

    @Test func purgeTrashRemovesOldEntries() throws {
        let root = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try NoteStore(root: root)

        try store.save(Note(body: "old\n"), to: "old.md")
        try store.save(Note(body: "new\n"), to: "new.md")
        try store.moveToTrash("old.md", deletedAt: Date(timeIntervalSince1970: 1_000_000))
        try store.moveToTrash("new.md", deletedAt: Date(timeIntervalSince1970: 2_000_000_000))

        let purged = try store.purgeTrash(deletedBefore: Date(timeIntervalSince1970: 1_500_000_000))
        #expect(purged == 1)
        #expect(try store.trashedNotes().map(\.originalPath) == ["new.md"])
    }

    @Test func saveAssetUniquifiesAndSanitizes() throws {
        let root = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try NoteStore(root: root)

        let first = try store.saveAsset(Data([1]), preferredName: "shot.png")
        let second = try store.saveAsset(Data([2]), preferredName: "shot.png")
        let weird = try store.saveAsset(Data([3]), preferredName: "../evil:name.png")
        #expect(first == "assets/shot.png")
        #expect(second == "assets/shot-2.png")
        #expect(weird == "assets/attachment")
        #expect(try Data(contentsOf: root.appendingPathComponent(second)) == Data([2]))
    }

    @Test func folderPathsIncludesEmptyAndSkipsReserved() throws {
        let root = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try NoteStore(root: root)

        try store.save(Note(body: "x"), to: "projects/skerry/plan.md")
        for dir in ["empty", ".skerry/cache", "assets/img", ".hidden/deep"] {
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent(dir), withIntermediateDirectories: true
            )
        }

        #expect(try store.folderPaths() == ["empty", "projects", "projects/skerry"])
    }
}
