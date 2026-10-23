import Foundation
import Testing

@testable import SkerryKit

@Suite struct LibraryBackupTests {
    /// Builds a throwaway directory for one test.
    private func makeDir() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("skerry-backup-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func backUpCopiesNotesAndSkipsCache() throws {
        let library = try makeDir()
        let destination = try makeDir()
        defer {
            try? FileManager.default.removeItem(at: library)
            try? FileManager.default.removeItem(at: destination)
        }
        try "note one".write(
            to: library.appendingPathComponent("a.md"), atomically: true, encoding: .utf8
        )
        try FileManager.default.createDirectory(
            at: library.appendingPathComponent(".skerry"), withIntermediateDirectories: true
        )
        try "cache".write(
            to: library.appendingPathComponent(".skerry/index.db"), atomically: true, encoding: .utf8
        )

        let snapshot = try LibraryBackup.backUp(
            library: library, to: destination, named: LibraryBackup.name(for: Date(timeIntervalSince1970: 1_700_000_000))
        )
        #expect(FileManager.default.fileExists(atPath: snapshot.appendingPathComponent("a.md").path))
        #expect(!FileManager.default.fileExists(atPath: snapshot.appendingPathComponent(".skerry").path))
    }

    @Test func snapshotsListSortedAndRestoreRoundTrips() throws {
        let library = try makeDir()
        let destination = try makeDir()
        defer {
            try? FileManager.default.removeItem(at: library)
            try? FileManager.default.removeItem(at: destination)
        }
        try "v1".write(
            to: library.appendingPathComponent("note.md"), atomically: true, encoding: .utf8
        )
        let early = LibraryBackup.name(for: Date(timeIntervalSince1970: 1_000_000_000))
        let late = LibraryBackup.name(for: Date(timeIntervalSince1970: 2_000_000_000))
        try LibraryBackup.backUp(library: library, to: destination, named: early)
        // Change the note, take a second snapshot.
        try "v2".write(
            to: library.appendingPathComponent("note.md"), atomically: true, encoding: .utf8
        )
        try LibraryBackup.backUp(library: library, to: destination, named: late)

        let snapshots = LibraryBackup.snapshots(in: destination)
        #expect(snapshots.map(\.name) == [late, early])

        // Restoring the earlier snapshot brings back v1.
        try LibraryBackup.restore(snapshots[1].url, into: library)
        #expect(try String(contentsOf: library.appendingPathComponent("note.md")) == "v1")
    }

    @Test func restoreIsExactReplaceAndKeepsCache() throws {
        let library = try makeDir()
        let destination = try makeDir()
        let fm = FileManager.default
        defer {
            try? fm.removeItem(at: library)
            try? fm.removeItem(at: destination)
        }
        try "v1".write(
            to: library.appendingPathComponent("note.md"), atomically: true, encoding: .utf8
        )
        try fm.createDirectory(
            at: library.appendingPathComponent(".skerry"), withIntermediateDirectories: true
        )
        try "cache".write(
            to: library.appendingPathComponent(".skerry/index.db"), atomically: true, encoding: .utf8
        )

        let name = LibraryBackup.name(for: Date(timeIntervalSince1970: 1_700_000_000))
        let snapshot = try LibraryBackup.backUp(library: library, to: destination, named: name)

        // After the snapshot: edit one note and add another the snapshot never saw.
        try "v2".write(
            to: library.appendingPathComponent("note.md"), atomically: true, encoding: .utf8
        )
        try "new".write(
            to: library.appendingPathComponent("extra.md"), atomically: true, encoding: .utf8
        )

        try LibraryBackup.restore(snapshot, into: library)

        // The edited note reverts, the note added after the snapshot is gone (exact replace, not a
        // merge), and the rebuildable cache is left untouched.
        #expect(try String(contentsOf: library.appendingPathComponent("note.md")) == "v1")
        #expect(!fm.fileExists(atPath: library.appendingPathComponent("extra.md").path))
        #expect(fm.fileExists(atPath: library.appendingPathComponent(".skerry/index.db").path))
    }

    @Test func pruneKeepsNewest() throws {
        let library = try makeDir()
        let destination = try makeDir()
        defer {
            try? FileManager.default.removeItem(at: library)
            try? FileManager.default.removeItem(at: destination)
        }
        try "x".write(
            to: library.appendingPathComponent("n.md"), atomically: true, encoding: .utf8
        )
        for seconds in [1_000, 2_000, 3_000, 4_000] {
            try LibraryBackup.backUp(
                library: library, to: destination,
                named: LibraryBackup.name(for: Date(timeIntervalSince1970: TimeInterval(seconds)))
            )
        }
        let removed = try LibraryBackup.prune(in: destination, keeping: 2)
        #expect(removed == 2)
        #expect(LibraryBackup.snapshots(in: destination).count == 2)
    }

    @Test func snapshotNameRoundTripsWithFractionalSeconds() throws {
        let destination = try makeDir()
        defer { try? FileManager.default.removeItem(at: destination) }
        let when = Date(timeIntervalSince1970: 1_700_000_000.5)
        let container = destination.appendingPathComponent(
            LibraryBackup.containerName, isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: container.appendingPathComponent(LibraryBackup.name(for: when)),
            withIntermediateDirectories: true
        )
        let snapshots = LibraryBackup.snapshots(in: destination)
        #expect(snapshots.count == 1)
        #expect(abs(snapshots[0].date.timeIntervalSince1970 - when.timeIntervalSince1970) < 0.01)
    }
}
