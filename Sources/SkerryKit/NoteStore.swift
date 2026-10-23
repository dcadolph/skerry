import Foundation

/// StoredNote is a note joined with its location inside a library.
public struct StoredNote: Equatable, Sendable {
    /// Path of the note file relative to the library root.
    public var path: String
    /// Parsed note content.
    public var note: Note
    /// File creation time, the fallback when front matter has no `created`.
    public var fileCreated: Date?
    /// File modification time, the fallback when front matter has no `updated`.
    public var fileModified: Date?

    /// Creates a stored note from a relative path and parsed content.
    public init(path: String, note: Note, fileCreated: Date? = nil, fileModified: Date? = nil) {
        self.path = path
        self.note = note
        self.fileCreated = fileCreated
        self.fileModified = fileModified
    }

    /// Effective creation time: front matter first, then the file, then distant past.
    public var created: Date { note.metadata.created ?? fileCreated ?? .distantPast }
    /// Effective update time: front matter first, then the file, then distant past.
    public var updated: Date { note.metadata.updated ?? fileModified ?? .distantPast }
}

/// TrashedNote is a note held in the library trash with its origin and deletion time.
public struct TrashedNote: Equatable, Sendable {
    /// Identifier and file name stem inside the trash folder.
    public var id: String
    /// Path the note occupied before deletion, where recovery restores it.
    public var originalPath: String
    /// When the note was moved to the trash.
    public var deletedAt: Date
    /// Parsed note content, kept for previews and recovery.
    public var note: Note

    /// Creates a trashed note record.
    public init(id: String, originalPath: String, deletedAt: Date, note: Note) {
        self.id = id
        self.originalPath = originalPath
        self.deletedAt = deletedAt
        self.note = note
    }
}

/// NoteStore reads and writes notes inside a library folder as defined in FORMAT.md.
public struct NoteStore: Sendable {
    /// Errors raised by library operations.
    public enum StoreError: Error, Equatable {
        /// The library root does not exist or is not a directory.
        case notADirectory(String)
        /// A note path escapes the library root or targets a reserved entry.
        case invalidPath(String)
    }

    /// Absolute URL of the library root.
    public let root: URL

    /// Reserved top-level entries that never hold notes.
    private static let reservedRootEntries: Set<String> = [".skerry", "assets"]

    /// File extensions treated as notes; Markdown is the default for new notes.
    public static let noteExtensions: Set<String> = ["md", "markdown", "txt", "html"]

    /// Extensions whose files carry front matter on save; HTML stays body-only.
    private static let frontMatterExtensions: Set<String> = ["md", "markdown", "txt"]

    /// Creates a store over an existing library root directory.
    public init(root: URL) throws {
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory)
        guard exists, isDirectory.boolValue else {
            throw StoreError.notADirectory(root.path)
        }
        self.root = root.standardizedFileURL
    }

    /// Lists relative paths of every note file in the library, sorted for stable output.
    public func notePaths() throws -> [String] {
        var paths: [String] = []
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .nameKey]
        guard let walker = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: keys, options: []
        ) else {
            throw StoreError.notADirectory(root.path)
        }
        for case let url as URL in walker {
            let values = try url.resourceValues(forKeys: Set(keys))
            let name = values.name ?? url.lastPathComponent
            if values.isDirectory == true {
                let relative = relativePath(of: url)
                if name.hasPrefix(".") || Self.reservedRootEntries.contains(relative) {
                    walker.skipDescendants()
                }
                continue
            }
            guard values.isRegularFile == true,
                Self.noteExtensions.contains(url.pathExtension.lowercased()),
                !name.hasPrefix(".")
            else { continue }
            paths.append(relativePath(of: url))
        }
        return paths.sorted()
    }

    /// Loads and parses the note at a relative path, capturing file dates for fallbacks.
    public func load(_ path: String) throws -> StoredNote {
        let url = try noteURL(for: path)
        let text = try String(contentsOf: url, encoding: .utf8)
        let values = try? url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
        return StoredNote(
            path: path,
            note: FrontMatter.parseNote(text),
            fileCreated: values?.creationDate,
            fileModified: values?.contentModificationDate
        )
    }

    /// Absolute URL of the trash folder; a dotfile so note scans skip it.
    private var trashURL: URL { root.appendingPathComponent(".trash", isDirectory: true) }

    /// Front matter key recording where a trashed note came from.
    private static let trashedFromKey = "trashedFrom"
    /// Front matter key recording when a note was trashed.
    private static let trashedAtKey = "trashedAt"

    /// Moves a note into the trash, recording its origin and deletion time in the file.
    public func moveToTrash(_ path: String, deletedAt: Date) throws {
        let source = try noteURL(for: path)
        let text = try String(contentsOf: source, encoding: .utf8)
        var note = FrontMatter.parseNote(text)
        note.metadata.unknown.removeAll {
            $0.key == Self.trashedFromKey || $0.key == Self.trashedAtKey
        }
        note.metadata.unknown.append(
            (key: Self.trashedFromKey, rawValue: FrontMatter.quoteIfNeeded(path))
        )
        note.metadata.unknown.append(
            (key: Self.trashedAtKey, rawValue: FrontMatter.formatDate(deletedAt))
        )
        try FileManager.default.createDirectory(at: trashURL, withIntermediateDirectories: true)
        let destination = trashURL.appendingPathComponent(UUID().uuidString + ".md")
        try FrontMatter.serializeNote(note).write(to: destination, atomically: true, encoding: .utf8)
        try FileManager.default.removeItem(at: source)
    }

    /// Lists every trashed note, most recently deleted first.
    public func trashedNotes() throws -> [TrashedNote] {
        guard FileManager.default.fileExists(atPath: trashURL.path) else { return [] }
        let files = try FileManager.default.contentsOfDirectory(
            at: trashURL, includingPropertiesForKeys: nil
        )
        var result: [TrashedNote] = []
        for file in files where file.pathExtension.lowercased() == "md" {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            var note = FrontMatter.parseNote(text)
            let from = note.metadata.unknown.first { $0.key == Self.trashedFromKey }
            let at = note.metadata.unknown.first { $0.key == Self.trashedAtKey }
            let deletedAt = at.flatMap { FrontMatter.parseDate(FrontMatter.unquote($0.rawValue)) }
            note.metadata.unknown.removeAll {
                $0.key == Self.trashedFromKey || $0.key == Self.trashedAtKey
            }
            result.append(
                TrashedNote(
                    id: file.deletingPathExtension().lastPathComponent,
                    originalPath: from.map { FrontMatter.unquote($0.rawValue) }
                        ?? file.deletingPathExtension().lastPathComponent + ".md",
                    deletedAt: deletedAt ?? .distantPast,
                    note: note
                )
            )
        }
        return result.sorted { $0.deletedAt > $1.deletedAt }
    }

    /// Restores a trashed note to its original path, uniquified on collision.
    /// Returns the path it was restored to.
    @discardableResult
    public func recoverFromTrash(id: String) throws -> String {
        let file = trashURL.appendingPathComponent(id + ".md")
        let text = try String(contentsOf: file, encoding: .utf8)
        var note = FrontMatter.parseNote(text)
        let originalPath = note.metadata.unknown
            .first { $0.key == Self.trashedFromKey }
            .map { FrontMatter.unquote($0.rawValue) } ?? (id + ".md")
        note.metadata.unknown.removeAll {
            $0.key == Self.trashedFromKey || $0.key == Self.trashedAtKey
        }
        var target = originalPath
        var counter = 2
        while FileManager.default.fileExists(
            atPath: root.appendingPathComponent(target).path
        ) {
            let stem = (originalPath as NSString).deletingPathExtension
            let ext = (originalPath as NSString).pathExtension
            target = "\(stem) \(counter).\(ext)"
            counter += 1
        }
        try save(note, to: target)
        try FileManager.default.removeItem(at: file)
        return target
    }

    /// Permanently removes one note from the trash.
    public func purgeFromTrash(id: String) throws {
        let file = trashURL.appendingPathComponent(id + ".md")
        if FileManager.default.fileExists(atPath: file.path) {
            try FileManager.default.removeItem(at: file)
        }
    }

    /// Permanently removes trashed notes deleted before a cutoff; returns the count purged.
    @discardableResult
    public func purgeTrash(deletedBefore cutoff: Date) throws -> Int {
        var purged = 0
        for trashed in try trashedNotes() where trashed.deletedAt < cutoff {
            try purgeFromTrash(id: trashed.id)
            purged += 1
        }
        return purged
    }

    /// Lists relative paths of every folder in the library, empty folders included.
    public func folderPaths() throws -> [String] {
        var paths: [String] = []
        let keys: [URLResourceKey] = [.isDirectoryKey, .nameKey]
        guard let walker = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: keys, options: []
        ) else {
            throw StoreError.notADirectory(root.path)
        }
        for case let url as URL in walker {
            let values = try url.resourceValues(forKeys: Set(keys))
            guard values.isDirectory == true else { continue }
            let name = values.name ?? url.lastPathComponent
            let relative = relativePath(of: url)
            if name.hasPrefix(".") || Self.reservedRootEntries.contains(relative) {
                walker.skipDescendants()
                continue
            }
            paths.append(relative)
        }
        return paths.sorted()
    }

    /// The exact file text ``save(_:to:)`` writes for a note at a path. Formats outside the
    /// front matter set (HTML) carry the body verbatim.
    public func serializedText(_ note: Note, for path: String) -> String {
        let ext = (path as NSString).pathExtension.lowercased()
        return Self.frontMatterExtensions.contains(ext)
            ? FrontMatter.serializeNote(note)
            : note.body
    }

    /// Serializes and writes a note to a relative path, creating parent folders as needed.
    /// Returns the text written, so callers can record it without re-serializing.
    @discardableResult
    public func save(_ note: Note, to path: String) throws -> String {
        let url = try noteURL(for: path)
        let parent = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let text = serializedText(note, for: path)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return text
    }

    /// Writes attachment data into the assets folder and returns its root-relative path.
    /// The preferred name is sanitized and uniquified so existing assets never get replaced.
    public func saveAsset(_ data: Data, preferredName: String) throws -> String {
        let assetsDir = root.appendingPathComponent("assets", isDirectory: true)
        try FileManager.default.createDirectory(at: assetsDir, withIntermediateDirectories: true)
        let cleaned = preferredName
            .components(separatedBy: CharacterSet(charactersIn: "/\\:"))
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespaces)
        let fallback = cleaned.isEmpty || cleaned.hasPrefix(".") ? "attachment" : cleaned
        let stem = (fallback as NSString).deletingPathExtension
        let ext = (fallback as NSString).pathExtension
        var name = fallback
        var counter = 2
        while FileManager.default.fileExists(atPath: assetsDir.appendingPathComponent(name).path) {
            name = ext.isEmpty ? "\(stem)-\(counter)" : "\(stem)-\(counter).\(ext)"
            counter += 1
        }
        try data.write(to: assetsDir.appendingPathComponent(name))
        return "assets/\(name)"
    }

    /// Moves a note file to a new relative path, creating parent folders as needed.
    /// Fails when the destination already exists so notes are never silently replaced.
    public func move(from oldPath: String, to newPath: String) throws {
        let source = try noteURL(for: oldPath)
        let destination = try noteURL(for: newPath)
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw StoreError.invalidPath(newPath)
        }
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try FileManager.default.moveItem(at: source, to: destination)
    }

    /// Resolves a relative note path to an absolute URL, rejecting escapes and reserved entries.
    func noteURL(for path: String) throws -> URL {
        let url = root.appendingPathComponent(path).standardizedFileURL
        guard url.path.hasPrefix(root.path + "/") else { throw StoreError.invalidPath(path) }
        let firstComponent = path.split(separator: "/").first.map(String.init) ?? path
        guard !Self.reservedRootEntries.contains(firstComponent), !path.hasPrefix(".") else {
            throw StoreError.invalidPath(path)
        }
        return url
    }

    /// Returns the path of a URL relative to the library root.
    private func relativePath(of url: URL) -> String {
        let full = url.standardizedFileURL.path
        guard full.hasPrefix(root.path + "/") else { return full }
        return String(full.dropFirst(root.path.count + 1))
    }
}
