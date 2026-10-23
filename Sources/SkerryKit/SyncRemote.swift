import Foundation

/// SyncRemote is the storage a library syncs through: three file operations are enough,
/// because the sealed manifest carries the listing. Everything written through this
/// protocol is already ciphertext.
public protocol SyncRemote: Sendable {
    /// Downloads bytes at a path; nil when the path does not exist.
    func download(_ path: String) async throws -> Data?
    /// Uploads bytes to a path, creating intermediate folders, replacing any existing file.
    func upload(_ data: Data, to path: String) async throws
    /// Deletes the file at a path; a missing file is not an error.
    func delete(_ path: String) async throws
}

/// LockingSyncRemote is a remote that can create an object only when the path is absent, so
/// sync can hold an advisory lock and serialize reconciliation across devices. It closes the
/// concurrent lost update where two devices reconcile against each other's stale view and one
/// overwrites the other's object. Remotes that do not adopt it fall back to the unlocked path.
public protocol LockingSyncRemote: SyncRemote {
    /// Atomically creates the object only if the path is absent. Returns true when this call
    /// created it and false when it already existed. Throws only on a transport failure, never
    /// because the object already exists.
    func createExclusive(_ data: Data, at path: String) async throws -> Bool
}

/// FolderSyncRemote syncs through a folder: an iCloud Drive folder, a mounted NAS share,
/// or anything else reachable in Files or Finder.
public struct FolderSyncRemote: SyncRemote {
    /// Folder everything lives under.
    public let base: URL

    /// Creates a remote over a base folder.
    public init(base: URL) {
        self.base = base
    }

    public func download(_ path: String) async throws -> Data? {
        let url = resolve(path)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try Data(contentsOf: url)
    }

    public func upload(_ data: Data, to path: String) async throws {
        let url = resolve(path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try data.write(to: url, options: .atomic)
    }

    public func delete(_ path: String) async throws {
        let url = resolve(path)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    /// Resolves a slash-separated path against the base folder.
    private func resolve(_ path: String) -> URL {
        path.split(separator: "/").reduce(base) { $0.appendingPathComponent(String($1)) }
    }
}

extension FolderSyncRemote: LockingSyncRemote {
    /// Creates the lock file atomically. `withoutOverwriting` fails rather than replacing an
    /// existing file, which is the atomic create the advisory lock needs on a local or mounted
    /// filesystem. (An iCloud Drive folder is only eventually consistent, so the guarantee is
    /// best-effort there; WebDAV and S3 back the lock with a conditional write instead.)
    public func createExclusive(_ data: Data, at path: String) async throws -> Bool {
        let url = resolve(path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        do {
            try data.write(to: url, options: .withoutOverwriting)
            return true
        } catch let error as NSError
            where error.domain == NSCocoaErrorDomain && error.code == NSFileWriteFileExistsError {
            return false
        }
    }
}

/// WebDAVSyncRemote syncs through a WebDAV server: a NAS, Nextcloud, or iDrive.
public struct WebDAVSyncRemote: SyncRemote {
    /// Underlying WebDAV client.
    private let client: WebDAVClient

    /// Creates a remote over a WebDAV configuration.
    public init(config: WebDAVClient.Config) {
        client = WebDAVClient(config: config)
    }

    public func download(_ path: String) async throws -> Data? {
        do {
            return try await client.download(path)
        } catch WebDAVClient.WebDAVError.status(404) {
            return nil
        }
    }

    public func upload(_ data: Data, to path: String) async throws {
        // Each parent collection is created on the way in; existing ones answer success.
        var parent = ""
        for component in path.split(separator: "/").dropLast() {
            parent += (parent.isEmpty ? "" : "/") + component
            try await client.makeCollection(parent)
        }
        try await client.upload(data, to: path)
    }

    public func delete(_ path: String) async throws {
        do {
            try await client.delete(path)
        } catch WebDAVClient.WebDAVError.status(404) {
            // Already gone.
        }
    }
}

/// S3SyncRemote syncs through any S3-compatible bucket: Backblaze, Wasabi, iDrive e2, AWS.
public struct S3SyncRemote: SyncRemote {
    /// Underlying S3 client.
    private let client: S3Client

    /// Creates a remote over an S3 configuration.
    public init(config: S3Client.Config) {
        client = S3Client(config: config)
    }

    public func download(_ path: String) async throws -> Data? {
        do {
            return try await client.getObject(key: path)
        } catch S3Client.S3Error.status(404) {
            return nil
        }
    }

    public func upload(_ data: Data, to path: String) async throws {
        try await client.putObject(key: path, data: data)
    }

    public func delete(_ path: String) async throws {
        do {
            try await client.deleteObject(key: path)
        } catch S3Client.S3Error.status(404) {
            // Already gone.
        }
    }
}

extension WebDAVSyncRemote: LockingSyncRemote {
    /// Creates the lock through a conditional PUT, making each parent collection first the way a
    /// normal upload does.
    public func createExclusive(_ data: Data, at path: String) async throws -> Bool {
        var parent = ""
        for component in path.split(separator: "/").dropLast() {
            parent += (parent.isEmpty ? "" : "/") + component
            try await client.makeCollection(parent)
        }
        return try await client.createExclusive(data, to: path)
    }
}

extension S3SyncRemote: LockingSyncRemote {
    /// Creates the lock through a conditional PUT; S3 keys are flat, so no parent is needed.
    public func createExclusive(_ data: Data, at path: String) async throws -> Bool {
        try await client.putObjectExclusive(key: path, data: data)
    }
}
