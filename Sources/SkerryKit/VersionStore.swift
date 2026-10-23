import CryptoKit
import Foundation

/// VersionStore keeps bounded per-note snapshots inside the library cache so an earlier
/// state of a note can be browsed and restored.
///
/// A snapshot holds the exact bytes the note file carried on disk, so an encrypted note's
/// history is a history of sealed envelopes, never plaintext. Versions live under
/// `.skerry/versions/<key>` where the key is a hash of the note path, and the whole tree is
/// rebuildable cache: deleting it loses history but never notes.
public struct VersionStore: Sendable {
    /// One saved version of a note.
    public struct Version: Equatable, Sendable, Identifiable {
        /// File name of the snapshot without extension, an ISO timestamp.
        public var name: String
        /// When the version was recorded.
        public var date: Date
        /// Absolute URL of the snapshot file.
        public var url: URL

        /// Stable identity for lists.
        public var id: String { url.path }

        /// Creates a version record.
        public init(name: String, date: Date, url: URL) {
            self.name = name
            self.date = date
            self.url = url
        }
    }

    /// Folder holding every note's version folder.
    private let root: URL
    /// Most versions kept per note before the oldest are pruned.
    public var limit: Int
    /// Minimum gap between snapshots. A save inside the window replaces the latest version
    /// instead of adding one, so a burst of typing becomes a single history entry.
    public var coalesceInterval: TimeInterval

    /// Creates a store inside a library's cache folder.
    public init(libraryRoot: URL, limit: Int = 50, coalesceInterval: TimeInterval = 600) {
        root = libraryRoot
            .appendingPathComponent(".skerry", isDirectory: true)
            .appendingPathComponent("versions", isDirectory: true)
        self.limit = limit
        self.coalesceInterval = coalesceInterval
    }

    /// Records the on-disk text of a note as a version.
    ///
    /// A text identical to the latest version records nothing. With coalescing on, a save
    /// arriving within the coalesce window replaces the latest version rather than adding
    /// one. The oldest versions beyond the limit are pruned.
    public func record(
        path: String, text: String, at date: Date = Date(), coalescing: Bool = true
    ) throws {
        let folder = folderURL(for: path)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let existing = versions(for: path)
        if let latest = existing.first {
            if (try? String(contentsOf: latest.url, encoding: .utf8)) == text { return }
            if coalescing, date.timeIntervalSince(latest.date) < coalesceInterval {
                try? FileManager.default.removeItem(at: latest.url)
            }
        }
        var name = Self.name(for: date)
        var counter = 2
        while FileManager.default.fileExists(
            atPath: folder.appendingPathComponent(name + ".md").path
        ) {
            name = Self.name(for: date) + "-\(counter)"
            counter += 1
        }
        let file = folder.appendingPathComponent(name + ".md")
        try text.write(to: file, atomically: true, encoding: .utf8)
        for stale in versions(for: path).dropFirst(limit) {
            try? FileManager.default.removeItem(at: stale.url)
        }
    }

    /// Lists the versions of a note, newest first.
    public func versions(for path: String) -> [Version] {
        let folder = folderURL(for: path)
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: nil
        ) else { return [] }
        var result: [Version] = []
        for entry in entries where entry.pathExtension == "md" {
            let name = entry.deletingPathExtension().lastPathComponent
            guard let date = parseName(name) else { continue }
            result.append(Version(name: name, date: date, url: entry))
        }
        return result.sorted { $0.date > $1.date }
    }

    /// Reads the text of a recorded version.
    public func text(of version: Version) throws -> String {
        try String(contentsOf: version.url, encoding: .utf8)
    }

    /// Moves a note's history when the note file moves, so renames keep their versions.
    public func move(from oldPath: String, to newPath: String) {
        let source = folderURL(for: oldPath)
        let destination = folderURL(for: newPath)
        guard FileManager.default.fileExists(atPath: source.path) else { return }
        if FileManager.default.fileExists(atPath: destination.path) {
            // Both paths have history; fold the old files into the new folder.
            let entries = (try? FileManager.default.contentsOfDirectory(
                at: source, includingPropertiesForKeys: nil
            )) ?? []
            for entry in entries {
                try? FileManager.default.moveItem(
                    at: entry, to: destination.appendingPathComponent(entry.lastPathComponent)
                )
            }
            try? FileManager.default.removeItem(at: source)
            return
        }
        try? FileManager.default.moveItem(at: source, to: destination)
    }

    /// Removes every version of a note.
    public func removeAll(for path: String) {
        try? FileManager.default.removeItem(at: folderURL(for: path))
    }

    /// Folder holding one note's versions, keyed by a hash so the tree stays flat and an
    /// encrypted note's history folder does not leak its path.
    private func folderURL(for path: String) -> URL {
        let digest = SHA256.hash(data: Data(path.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return root.appendingPathComponent(String(digest.prefix(32)), isDirectory: true)
    }

    /// Formats a date into a file-name-safe version name with fractional seconds.
    static func name(for date: Date) -> String {
        date.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true))
            .replacingOccurrences(of: ":", with: "_")
    }

    /// Parses a version file name back into a date, tolerating a collision suffix. A clean
    /// name ends in `Z`, so stripping a trailing `-<digits>` only ever removes the suffix.
    private func parseName(_ name: String) -> Date? {
        let base = name.replacingOccurrences(
            of: #"-\d+$"#, with: "", options: .regularExpression
        )
        let iso = base.replacingOccurrences(of: "_", with: ":")
        if let date = try? Date(iso, strategy: .iso8601) { return date }
        return try? Date(
            iso, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)
        )
    }
}
