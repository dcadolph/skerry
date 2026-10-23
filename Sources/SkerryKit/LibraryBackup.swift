import Foundation

/// LibraryBackup copies a library into a destination as browsable folder snapshots.
///
/// Backups are plain folder trees, not archives, so they open in Finder, the Files app,
/// iCloud Drive, or a NAS share with no tool required. The rebuildable `.skerry` cache is
/// left out; everything else, including the trash, is copied.
public enum LibraryBackup {
    /// A single backup snapshot on disk.
    public struct Snapshot: Equatable, Sendable {
        /// Folder name of the snapshot, an ISO 8601 timestamp.
        public var name: String
        /// Absolute URL of the snapshot folder.
        public var url: URL
        /// When the snapshot was taken, parsed from its name.
        public var date: Date

        /// Creates a snapshot record.
        public init(name: String, url: URL, date: Date) {
            self.name = name
            self.url = url
            self.date = date
        }
    }

    /// Folder inside the destination that holds every snapshot.
    public static let containerName = "Skerry Backups"

    /// Entries that are never copied because they are rebuildable cache.
    private static let skipped: Set<String> = [".skerry"]

    /// Prefix for the temporary copies a restore stages before swapping them into place.
    private static let restorePrefix = ".skerry-restore-"

    /// Copies the library into a new timestamped snapshot and returns its folder.
    @discardableResult
    public static func backUp(library: URL, to destination: URL, named name: String) throws -> URL {
        let container = destination.appendingPathComponent(containerName, isDirectory: true)
        let snapshot = container.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: snapshot, withIntermediateDirectories: true)
        let entries = try FileManager.default.contentsOfDirectory(
            at: library, includingPropertiesForKeys: nil
        )
        for entry in entries where !skipped.contains(entry.lastPathComponent) {
            let target = snapshot.appendingPathComponent(entry.lastPathComponent)
            try FileManager.default.copyItem(at: entry, to: target)
        }
        return snapshot
    }

    /// Lists every snapshot in a destination, most recent first.
    public static func snapshots(in destination: URL) -> [Snapshot] {
        let container = destination.appendingPathComponent(containerName, isDirectory: true)
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: container, includingPropertiesForKeys: [.isDirectoryKey]
        ) else { return [] }
        var result: [Snapshot] = []
        for entry in entries {
            let values = try? entry.resourceValues(forKeys: [.isDirectoryKey])
            guard values?.isDirectory == true else { continue }
            let name = entry.lastPathComponent
            guard let date = parseName(name) else { continue }
            result.append(Snapshot(name: name, url: entry, date: date))
        }
        return result.sorted { $0.date > $1.date }
    }

    /// Restores a snapshot into a library so the library ends up matching the snapshot exactly.
    ///
    /// Restore is an exact replace, not a merge: entries the snapshot omits are removed, so the
    /// library reproduces the snapshot's state instead of keeping notes created after it. Every
    /// snapshot entry is first copied to a temporary sibling; only once all copies succeed are
    /// they swapped into place, so the slow, failure-prone copying never touches a live file and a
    /// failure there leaves the library untouched. Each swap is an atomic rename, so a reader never
    /// sees a half-written note. The rebuildable `.skerry` cache is left in place and rebuilds on
    /// the next open.
    public static func restore(_ snapshot: URL, into library: URL) throws {
        let fm = FileManager.default
        clearRestoreTemporaries(in: library)

        let wanted = try fm.contentsOfDirectory(at: snapshot, includingPropertiesForKeys: nil)
            .filter { !skipped.contains($0.lastPathComponent) }
        let wantedNames = Set(wanted.map(\.lastPathComponent))

        // Stage every snapshot entry beside the library before mutating anything.
        var staged: [(temp: URL, target: URL)] = []
        do {
            for entry in wanted {
                let temp = library.appendingPathComponent(restorePrefix + UUID().uuidString)
                try fm.copyItem(at: entry, to: temp)
                staged.append((temp, library.appendingPathComponent(entry.lastPathComponent)))
            }
        } catch {
            for item in staged { try? fm.removeItem(at: item.temp) }
            throw error
        }

        // Swap each staged copy into place, then drop entries the snapshot does not contain.
        for item in staged {
            if fm.fileExists(atPath: item.target.path) {
                _ = try fm.replaceItemAt(item.target, withItemAt: item.temp)
            } else {
                try fm.moveItem(at: item.temp, to: item.target)
            }
        }
        let current = try fm.contentsOfDirectory(at: library, includingPropertiesForKeys: nil)
        for entry in current {
            let name = entry.lastPathComponent
            guard !skipped.contains(name), !name.hasPrefix(restorePrefix) else { continue }
            if !wantedNames.contains(name) { try fm.removeItem(at: entry) }
        }
    }

    /// Removes any staging copies an interrupted restore left behind in the library root.
    private static func clearRestoreTemporaries(in library: URL) {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: library, includingPropertiesForKeys: nil
        ) else { return }
        for entry in entries where entry.lastPathComponent.hasPrefix(restorePrefix) {
            try? fm.removeItem(at: entry)
        }
    }

    /// Deletes the oldest snapshots beyond a keep count; returns how many were removed.
    @discardableResult
    public static func prune(in destination: URL, keeping keep: Int) throws -> Int {
        let all = snapshots(in: destination)
        guard all.count > keep else { return 0 }
        var removed = 0
        for snapshot in all.dropFirst(keep) {
            try FileManager.default.removeItem(at: snapshot.url)
            removed += 1
        }
        return removed
    }

    /// Parses a snapshot folder name back into a date, tolerating names with or without the
    /// fractional seconds newer snapshots carry.
    private static func parseName(_ name: String) -> Date? {
        let iso = name.replacingOccurrences(of: "_", with: ":")
        if let date = try? Date(iso, strategy: .iso8601) { return date }
        return try? Date(iso, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true))
    }

    /// Formats a date into a file-name-safe snapshot name. Fractional seconds keep two backups
    /// taken in the same second, such as an auto-backup and a manual one, from colliding.
    public static func name(for date: Date) -> String {
        date.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true))
            .replacingOccurrences(of: ":", with: "_")
    }
}
