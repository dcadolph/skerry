import Foundation

/// EncryptedBackup seals a whole library into a single encrypted file and restores it.
///
/// Where [LibraryBackup] writes a browsable folder, this packs the library into one sealed blob
/// with AES-256-GCM, so a copy on a cloud drive, a NAS, or a stolen disk reveals nothing, not
/// even file names. The passphrase is the user's alone; a client without it can copy and move
/// the backup but cannot read it. This is how a plain note stays protected once it leaves the
/// device, closing the gap that per-note encryption leaves for unencrypted notes.
public enum EncryptedBackup {
    /// Errors raised while sealing or restoring a backup.
    public enum BackupError: Error, Equatable {
        /// The library path is missing or not a directory.
        case notADirectory
        /// The decrypted payload was not a valid library archive.
        case corrupt
    }

    /// Folder inside the destination that holds sealed snapshots.
    public static let containerName = "Skerry Encrypted Backups"
    /// Extension marking a sealed snapshot file.
    public static let fileExtension = "skerrybackup"
    /// Entries never included, matching the plaintext backup: the rebuildable cache.
    private static let skipped: Set<String> = [".skerry"]

    /// Prefix for the temporary copies a restore stages before swapping them into place.
    private static let restorePrefix = ".skerry-restore-"

    /// A single sealed snapshot on disk.
    public struct Snapshot: Equatable, Sendable {
        /// Timestamp-based file name without extension.
        public var name: String
        /// Absolute URL of the sealed file.
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

    /// Seals the library into encrypted bytes, for callers that write elsewhere, such as a
    /// WebDAV server, rather than a local file.
    public static func sealedData(of library: URL, passphrase: String) throws -> Data {
        try NoteCrypto.seal(archiveData(of: library), passphrase: passphrase)
    }

    /// Restores a library from sealed bytes.
    public static func restore(from data: Data, into library: URL, passphrase: String) throws {
        try unpack(NoteCrypto.unseal(data, passphrase: passphrase), into: library)
    }

    /// Seals the library into a single encrypted snapshot file and returns its URL.
    @discardableResult
    public static func seal(
        library: URL, to destination: URL, named name: String, passphrase: String
    ) throws -> URL {
        let sealed = try sealedData(of: library, passphrase: passphrase)
        let container = destination.appendingPathComponent(containerName, isDirectory: true)
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        let file = container.appendingPathComponent(name).appendingPathExtension(fileExtension)
        try sealed.write(to: file, options: .atomic)
        return file
    }

    /// Restores a sealed snapshot file into a library, overwriting entries it contains.
    public static func restore(_ sealed: URL, into library: URL, passphrase: String) throws {
        try restore(from: Data(contentsOf: sealed), into: library, passphrase: passphrase)
    }

    /// Lists every sealed snapshot in a destination, most recent first.
    public static func snapshots(in destination: URL) -> [Snapshot] {
        let container = destination.appendingPathComponent(containerName, isDirectory: true)
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: container, includingPropertiesForKeys: nil
        ) else { return [] }
        var result: [Snapshot] = []
        for entry in entries where entry.pathExtension == fileExtension {
            let name = entry.deletingPathExtension().lastPathComponent
            guard let date = parseName(name) else { continue }
            result.append(Snapshot(name: name, url: entry, date: date))
        }
        return result.sorted { $0.date > $1.date }
    }

    /// Deletes the oldest sealed snapshots beyond a keep count; returns how many were removed.
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

    /// Formats a date into a file-name-safe snapshot name with fractional seconds.
    public static func name(for date: Date) -> String {
        date.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true))
            .replacingOccurrences(of: ":", with: "_")
    }

    /// Parses a snapshot file name, extension included, back into its date. Exposed so a remote
    /// listing such as WebDAV can date its entries.
    public static func date(fromFileName fileName: String) -> Date? {
        parseName((fileName as NSString).deletingPathExtension)
    }

    /// Serializes the library tree, minus the rebuildable cache, into one blob.
    private static func archiveData(of library: URL) throws -> Data {
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: library.path, isDirectory: &isDirectory)
        guard exists, isDirectory.boolValue else { throw BackupError.notADirectory }
        let root = FileWrapper(directoryWithFileWrappers: [:])
        let entries = try FileManager.default.contentsOfDirectory(
            at: library, includingPropertiesForKeys: nil
        )
        for entry in entries where !skipped.contains(entry.lastPathComponent) {
            let child = try FileWrapper(url: entry, options: .immediate)
            child.preferredFilename = entry.lastPathComponent
            root.addFileWrapper(child)
        }
        guard let data = root.serializedRepresentation else { throw BackupError.corrupt }
        return data
    }

    /// Reconstructs the library tree from a decrypted archive blob, exactly and atomically.
    ///
    /// Like the plaintext restore, this is an exact replace: entries the archive omits are removed
    /// so the library reproduces the snapshot instead of merging into the current tree. Every entry
    /// is written to a temporary sibling first and only swapped into place once all writes succeed,
    /// so a failed write leaves the library untouched and no reader sees a half-written note. The
    /// rebuildable `.skerry` cache is left in place.
    private static func unpack(_ archive: Data, into library: URL) throws {
        guard let root = FileWrapper(serializedRepresentation: archive), root.isDirectory else {
            throw BackupError.corrupt
        }
        let fm = FileManager.default
        try fm.createDirectory(at: library, withIntermediateDirectories: true)
        clearRestoreTemporaries(in: library)

        let children = root.fileWrappers ?? [:]
        let wantedNames = Set(children.keys)

        var staged: [(temp: URL, target: URL)] = []
        do {
            for (name, child) in children {
                let temp = library.appendingPathComponent(restorePrefix + UUID().uuidString)
                try child.write(to: temp, options: [], originalContentsURL: nil)
                staged.append((temp, library.appendingPathComponent(name)))
            }
        } catch {
            for item in staged { try? fm.removeItem(at: item.temp) }
            throw error
        }

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

    /// Parses a snapshot file name back into a date, with or without fractional seconds.
    private static func parseName(_ name: String) -> Date? {
        let iso = name.replacingOccurrences(of: "_", with: ":")
        if let date = try? Date(iso, strategy: .iso8601) { return date }
        return try? Date(iso, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true))
    }
}
