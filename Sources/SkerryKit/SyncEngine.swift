import CryptoKit
import Foundation

/// SyncEngine reconciles a library with an encrypted copy on storage the user owns, which
/// is how Skerry syncs between devices without an account or a server of ours.
///
/// Every note and asset is sealed under the vault master key before upload, and the file
/// listing itself travels inside a sealed manifest, so the remote only ever holds
/// ciphertext under opaque object names. Reconciliation is a three-way merge against the
/// last-synced state: edits flow both ways, deletes propagate, an edit beats a delete, and
/// a file changed on two devices at once keeps both versions, the remote one as a conflict
/// copy. A file another device deleted is parked under `.skerry/sync-deleted` for 30 days
/// rather than destroyed.
public enum SyncEngine {
    /// Errors sync surfaces beyond plain transport failures.
    public enum SyncError: Error, Equatable {
        /// The remote manifest does not decrypt under this vault's master key: the remote
        /// belongs to a different vault.
        case wrongKey
        /// The remote manifest decrypted but could not be parsed.
        case corruptManifest
        /// Another device took this pass's advisory lock while the pass was still running, so
        /// the pass stopped rather than reconcile alongside it and risk losing an edit.
        case lockLost
    }

    /// Counts of what one sync pass did.
    public struct Result: Equatable, Sendable {
        /// Files sealed and uploaded.
        public var uploaded = 0
        /// Files downloaded and unsealed into the library.
        public var downloaded = 0
        /// Local files parked because another device deleted them.
        public var deletedLocal = 0
        /// Remote objects removed because this device deleted them.
        public var deletedRemote = 0
        /// Files kept in both versions after simultaneous edits.
        public var conflicts = 0
        /// Simultaneous edits reconciled line by line into one text.
        public var merged = 0

        /// Creates an empty result.
        public init() {}

        /// Whether the pass moved anything at all.
        public var isQuiet: Bool {
            uploaded == 0 && downloaded == 0 && deletedLocal == 0
                && deletedRemote == 0 && conflicts == 0 && merged == 0
        }
    }

    /// Folder on the remote that holds everything sync writes.
    public static let remoteRoot = "Skerry Sync"
    /// Remote path of the sealed manifest.
    static let manifestPath = remoteRoot + "/manifest.skmanifest"
    /// Remote path of the wrapped vault keyfile, synced verbatim since it is already
    /// passphrase-wrapped by design.
    public static let keyfilePath = remoteRoot + "/keyfile.skerryvault"
    /// Remote folder holding sealed objects.
    static let objectsRoot = remoteRoot + "/objects"
    /// How long a delete marker and a parked deleted file live before cleanup.
    static let tombstoneLifetime: TimeInterval = 30 * 24 * 3600
    /// Remote path of the advisory lock a locking remote uses to serialize sync passes.
    static let lockPath = remoteRoot + "/lock"
    /// A held lock older than this is treated as a crashed device's and stolen.
    public static let lockLifetime: TimeInterval = 5 * 60
    /// How often a running pass restamps its own lock. Comfortably shorter than the lifetime,
    /// so several refreshes in a row must fail before another device may steal the lock. A pass
    /// that legitimately outlives the lifetime therefore keeps its lock instead of losing it.
    public static let lockRefresh: TimeInterval = 60

    /// The sealed manifest listing every synced file.
    struct Manifest: Codable {
        /// One synced file, or the tombstone of a deleted one.
        struct Entry: Codable {
            /// Library-relative path of the file.
            var path: String
            /// Hex SHA-256 of the plaintext file bytes.
            var hash: String
            /// Last modification, seconds since 1970.
            var updated: TimeInterval
            /// Whether this entry marks a deletion.
            var deleted: Bool
            /// When the deletion happened, for tombstone expiry.
            var deletedAt: TimeInterval?
        }
        /// Format version.
        var version: Int
        /// Entries keyed by object id.
        var entries: [String: Entry]
    }

    /// What this device knew after its last sync, stored in the library cache.
    struct State: Codable {
        /// Last-synced knowledge of one file.
        struct Entry: Codable {
            /// Library-relative path of the file.
            var path: String
            /// Local content hash at last sync.
            var hash: String
            /// Manifest content hash at last sync.
            var remoteHash: String
        }
        /// Entries keyed by object id.
        var entries: [String: Entry] = [:]
        /// When the last successful sync finished.
        var lastSync: TimeInterval?
    }

    /// One local file eligible for sync.
    struct LocalFile {
        /// Library-relative path.
        var path: String
        /// Hex SHA-256 of the file bytes.
        var hash: String
        /// File modification time.
        var modified: Date
    }

    /// Downloads the wrapped vault keyfile from a remote, nil when none is there. A new
    /// device adopts this before its first sync so both sides share one master key.
    public static func fetchKeyfile(remote: some SyncRemote) async throws -> Data? {
        try await remote.download(keyfilePath)
    }

    /// Runs one full sync pass and returns what it did. New uploads seal with the given
    /// cipher; downloads open either cipher, so mixed-cipher remotes just work.
    /// - Parameters:
    ///   - lifetime: How stale a held lock must be before another device may steal it.
    ///   - refresh: How often this pass restamps its own lock while it runs.
    public static func sync(
        library: URL, remote: some SyncRemote, key: SymmetricKey,
        keyfile: Data? = nil, cipher: NoteCrypto.Cipher = .aesGCM, now: Date = Date(),
        lifetime: TimeInterval = lockLifetime, refresh: TimeInterval = lockRefresh
    ) async throws -> Result {
        // A locking remote serializes reconciliation, so two devices never overwrite each
        // other's objects. A fresh lock held by another device makes this pass a quiet no-op
        // that the caller retries later; an abandoned lock is stolen after its lifetime.
        guard let locker = remote as? LockingSyncRemote else {
            return try await reconcile(
                library: library, remote: remote, key: key,
                keyfile: keyfile, cipher: cipher, now: now
            )
        }
        guard let token = try await acquireLock(locker, now: now, lifetime: lifetime) else {
            return Result()
        }
        do {
            // The pass and its own heartbeat run together. The heartbeat restamps the lock so a
            // pass slower than the lifetime keeps it, and throws if another device took the
            // lock anyway, which cancels the pass rather than letting two devices reconcile at
            // once. Whichever finishes first ends the group.
            let result = try await withThrowingTaskGroup(of: Result?.self) { group in
                group.addTask {
                    try await reconcile(
                        library: library, remote: remote, key: key,
                        keyfile: keyfile, cipher: cipher, now: now
                    )
                }
                group.addTask {
                    try await holdLock(locker, token: token, every: refresh)
                    return nil
                }
                defer { group.cancelAll() }
                while let outcome = try await group.next() {
                    if let outcome { return outcome }
                }
                throw SyncError.lockLost
            }
            await releaseLock(locker, token: token)
            return result
        } catch {
            await releaseLock(locker, token: token)
            throw error
        }
    }

    /// Runs one full reconciliation pass. Callers go through ``sync(library:remote:key:keyfile:cipher:now:)``,
    /// which wraps this in an advisory lock when the remote supports one so concurrent passes
    /// cannot lose an edit.
    private static func reconcile(
        library: URL, remote: some SyncRemote, key: SymmetricKey,
        keyfile: Data? = nil, cipher: NoteCrypto.Cipher = .aesGCM, now: Date = Date()
    ) async throws -> Result {
        var result = Result()
        var state = loadState(in: library)
        var manifest = try await loadManifest(remote: remote, key: key)
        let local = try localFiles(in: library)

        var ids = Set(local.keys)
        ids.formUnion(manifest.entries.keys)
        ids.formUnion(state.entries.keys)

        for id in ids.sorted() {
            let localFile = local[id]
            let remoteEntry = manifest.entries[id]
            let known = state.entries[id]
            let liveRemoteHash = remoteEntry?.deleted == false ? remoteEntry?.hash : nil

            if let localFile, liveRemoteHash == nil {
                let localChanged = localFile.hash != known?.hash
                if remoteEntry?.deleted == true, !localChanged {
                    // Another device deleted it and nothing changed here: honor the delete.
                    try parkDeleted(localFile.path, in: library, at: now)
                    removeBase(id: id, in: library)
                    state.entries[id] = nil
                    result.deletedLocal += 1
                } else {
                    // New here, or edited since the delete: this copy wins.
                    try await uploadFile(
                        localFile, id: id, library: library, remote: remote, key: key,
                        cipher: cipher, manifest: &manifest, state: &state
                    )
                    result.uploaded += 1
                }
                continue
            }

            if localFile == nil, let remoteEntry, let liveRemoteHash {
                if known == nil || liveRemoteHash != known?.remoteHash {
                    // New on the remote, or edited there after this device deleted it.
                    try await downloadFile(
                        remoteEntry, id: id, to: remoteEntry.path, library: library,
                        remote: remote, key: key, state: &state
                    )
                    result.downloaded += 1
                } else if let known {
                    // Deleted here and untouched there: propagate the delete.
                    try await remote.delete(objectsRoot + "/" + id)
                    manifest.entries[id] = Manifest.Entry(
                        path: known.path, hash: known.remoteHash,
                        updated: now.timeIntervalSince1970, deleted: true,
                        deletedAt: now.timeIntervalSince1970
                    )
                    removeBase(id: id, in: library)
                    state.entries[id] = nil
                    result.deletedRemote += 1
                }
                continue
            }

            if let localFile, let remoteEntry, let liveRemoteHash {
                if localFile.hash == liveRemoteHash {
                    state.entries[id] = State.Entry(
                        path: localFile.path, hash: localFile.hash, remoteHash: liveRemoteHash
                    )
                    continue
                }
                let localChanged = localFile.hash != known?.hash
                let remoteChanged = liveRemoteHash != known?.remoteHash
                if localChanged, remoteChanged {
                    // Edited on both sides. Disjoint line edits merge cleanly through
                    // the last-synced base; only real overlaps keep both copies.
                    var mergedCleanly = false
                    if let sealed = try await remote.download(objectsRoot + "/" + id),
                        let theirBytes = try? NoteCrypto.unsealAny(sealed, key: key) {
                        if isMergeableText(localFile.path),
                            let baseText = readBase(id: id, in: library),
                            let mineData = try? Data(
                                contentsOf: resolve(localFile.path, in: library)
                            ),
                            let mineText = String(data: mineData, encoding: .utf8),
                            let theirText = String(data: theirBytes, encoding: .utf8) {
                            let outcome = TextMerge.merge(
                                base: baseText, mine: mineText, theirs: theirText
                            )
                            if outcome.conflicts == 0 {
                                let mergedData = Data(outcome.merged.utf8)
                                try write(mergedData, to: localFile.path, in: library)
                                let mergedFile = LocalFile(
                                    path: localFile.path, hash: hexSHA256(mergedData),
                                    modified: now
                                )
                                try await uploadFile(
                                    mergedFile, id: id, library: library, remote: remote,
                                    key: key, cipher: cipher,
                                    manifest: &manifest, state: &state
                                )
                                result.merged += 1
                                mergedCleanly = true
                            }
                        }
                        if !mergedCleanly {
                            let stableHash = hexSHA256(theirBytes)
                            let copyBytes = reassignedConflictID(theirBytes, hash: stableHash)
                            let copyPath = conflictCopyPath(
                                for: remoteEntry.path, in: library, at: now,
                                disambiguator: UInt32(stableHash.prefix(8), radix: 16) ?? 0
                            )
                            try write(copyBytes, to: copyPath, in: library)
                            let copy = LocalFile(
                                path: copyPath, hash: hexSHA256(copyBytes), modified: now
                            )
                            try await uploadFile(
                                copy, id: objectID(for: copyPath), library: library,
                                remote: remote, key: key, cipher: cipher,
                                manifest: &manifest, state: &state
                            )
                            result.conflicts += 1
                            result.uploaded += 1
                        }
                    }
                    if !mergedCleanly {
                        try await uploadFile(
                            localFile, id: id, library: library, remote: remote, key: key,
                            cipher: cipher, manifest: &manifest, state: &state
                        )
                        result.uploaded += 1
                    }
                } else if localChanged {
                    try await uploadFile(
                        localFile, id: id, library: library, remote: remote, key: key,
                        cipher: cipher, manifest: &manifest, state: &state
                    )
                    result.uploaded += 1
                } else if remoteChanged {
                    try await downloadFile(
                        remoteEntry, id: id, to: localFile.path, library: library,
                        remote: remote, key: key, state: &state
                    )
                    result.downloaded += 1
                } else {
                    state.entries[id] = State.Entry(
                        path: localFile.path, hash: localFile.hash, remoteHash: liveRemoteHash
                    )
                }
                continue
            }

            // Nothing lives on either side: drop stale state and let tombstones age out.
            state.entries[id] = nil
        }

        // Expired tombstones fall out of the manifest.
        manifest.entries = manifest.entries.filter { _, entry in
            guard entry.deleted else { return true }
            let deletedAt = entry.deletedAt ?? 0
            return now.timeIntervalSince1970 - deletedAt < tombstoneLifetime
        }

        if let keyfile {
            let remoteKeyfile = try await remote.download(keyfilePath)
            if remoteKeyfile != keyfile {
                try await remote.upload(keyfile, to: keyfilePath)
            }
        }

        let encoded = try JSONEncoder().encode(manifest)
        let sealed = try NoteCrypto.seal(encoded, key: key, cipher: cipher)
        try await remote.upload(sealed, to: manifestPath)

        state.lastSync = now.timeIntervalSince1970
        saveState(state, in: library)
        sweepParked(in: library, olderThan: now.addingTimeInterval(-tombstoneLifetime))
        return result
    }

    /// Seals and uploads one local file, then records it in the manifest and state.
    private static func uploadFile(
        _ file: LocalFile, id: String, library: URL, remote: some SyncRemote,
        key: SymmetricKey, cipher: NoteCrypto.Cipher = .aesGCM,
        manifest: inout Manifest, state: inout State
    ) async throws {
        let bytes = try Data(contentsOf: resolve(file.path, in: library))
        let sealed = try NoteCrypto.seal(bytes, key: key, cipher: cipher)
        try await remote.upload(sealed, to: objectsRoot + "/" + id)
        writeBaseIfMergeable(bytes, path: file.path, id: id, in: library)
        manifest.entries[id] = Manifest.Entry(
            path: file.path, hash: file.hash,
            updated: file.modified.timeIntervalSince1970, deleted: false, deletedAt: nil
        )
        state.entries[id] = State.Entry(path: file.path, hash: file.hash, remoteHash: file.hash)
    }

    /// Downloads and unseals one object into the library, then records it in state.
    private static func downloadFile(
        _ entry: Manifest.Entry, id: String, to path: String, library: URL,
        remote: some SyncRemote, key: SymmetricKey, state: inout State
    ) async throws {
        guard let sealed = try await remote.download(objectsRoot + "/" + id) else { return }
        let bytes: Data
        do {
            bytes = try NoteCrypto.unsealAny(sealed, key: key)
        } catch {
            throw SyncError.wrongKey
        }
        try write(bytes, to: path, in: library)
        writeBaseIfMergeable(bytes, path: path, id: id, in: library)
        state.entries[id] = State.Entry(path: path, hash: entry.hash, remoteHash: entry.hash)
    }

    /// Loads and unseals the remote manifest; a missing one means a fresh remote.
    private static func loadManifest(
        remote: some SyncRemote, key: SymmetricKey
    ) async throws -> Manifest {
        guard let sealed = try await remote.download(manifestPath) else {
            return Manifest(version: 1, entries: [:])
        }
        let bytes: Data
        do {
            bytes = try NoteCrypto.unsealAny(sealed, key: key)
        } catch {
            throw SyncError.wrongKey
        }
        do {
            return try JSONDecoder().decode(Manifest.self, from: bytes)
        } catch {
            throw SyncError.corruptManifest
        }
    }

    /// LockOwner is what the advisory lock carries: who holds it and when they last said so.
    ///
    /// The identity matters as much as the timestamp. Without it a pass cannot tell its own
    /// lock from one another device took after stealing it, so it would go on refreshing and
    /// finally deleting a lock that is no longer its own.
    private struct LockOwner {
        /// Unique per acquisition.
        let id: String
        /// When the holder last stamped the lock.
        let stamp: TimeInterval

        /// Wire form, the id then the stamp.
        var encoded: Data { Data("\(id):\(stamp)".utf8) }

        /// Reads the wire form, nil when the bytes are not a lock at all.
        static func decode(_ data: Data) -> LockOwner? {
            let text = String(decoding: data, as: UTF8.self)
            if let separator = text.lastIndex(of: ":"),
                let stamp = Double(text[text.index(after: separator)...]) {
                return LockOwner(id: String(text[..<separator]), stamp: stamp)
            }
            // A lock written before owners existed holds only a stamp. Read it as ownerless so
            // it can still age out and be stolen rather than wedging sync forever.
            if let stamp = Double(text) { return LockOwner(id: "", stamp: stamp) }
            return nil
        }
    }

    /// Acquires the advisory sync lock and returns this pass's owner id, nil when another device
    /// holds a fresh lock and the caller should skip this pass. A lock older than its lifetime
    /// belongs to a crashed device and is stolen.
    private static func acquireLock(
        _ remote: any LockingSyncRemote, now: Date, lifetime: TimeInterval
    ) async throws -> String? {
        let mine = LockOwner(id: UUID().uuidString, stamp: now.timeIntervalSince1970)
        if try await remote.createExclusive(mine.encoded, at: lockPath) { return mine.id }
        guard let held = try await remote.download(lockPath),
            let holder = LockOwner.decode(held),
            now.timeIntervalSince1970 - holder.stamp > lifetime
        else { return nil }
        try await remote.delete(lockPath)
        return try await remote.createExclusive(mine.encoded, at: lockPath) ? mine.id : nil
    }

    /// Restamps this pass's lock until the surrounding task is cancelled.
    ///
    /// This is what keeps a slow pass from having its lock stolen out from under it. A large
    /// library, a slow NAS, or a phone pushing attachments over cellular can all outrun the
    /// lifetime, and before this the lock simply expired mid-pass and a second device started
    /// reconciling alongside the first. Throws ``SyncError/lockLost`` if the lock is gone or now
    /// belongs to someone else, which cancels the pass rather than letting both run.
    private static func holdLock(
        _ remote: any LockingSyncRemote, token: String, every refresh: TimeInterval
    ) async throws {
        while true {
            do {
                try await Task.sleep(for: .seconds(refresh))
            } catch {
                return  // Cancelled because the pass finished. Nothing to report.
            }
            guard let held = try? await remote.download(lockPath),
                let holder = LockOwner.decode(held), holder.id == token
            else { throw SyncError.lockLost }
            let renewed = LockOwner(id: token, stamp: Date().timeIntervalSince1970)
            try? await remote.upload(renewed.encoded, to: lockPath)
        }
    }

    /// Releases the lock, but only while this pass still owns it, so a pass that already lost
    /// its lock cannot delete the one the other device is now holding.
    private static func releaseLock(_ remote: any LockingSyncRemote, token: String) async {
        guard let held = try? await remote.download(lockPath),
            let holder = LockOwner.decode(held), holder.id == token
        else { return }
        try? await remote.delete(lockPath)
    }

    /// Lists every syncable file in the library keyed by object id. Hidden entries, the
    /// cache, and the trash stay out; the keyfile travels separately.
    static func localFiles(in library: URL) throws -> [String: LocalFile] {
        var files: [String: LocalFile] = [:]
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .nameKey,
            .contentModificationDateKey]
        guard let walker = FileManager.default.enumerator(
            at: library, includingPropertiesForKeys: keys, options: []
        ) else { return files }
        let rootPath = library.standardizedFileURL.path
        for case let url as URL in walker {
            let values = try url.resourceValues(forKeys: Set(keys))
            let name = values.name ?? url.lastPathComponent
            if values.isDirectory == true {
                if name.hasPrefix(".") { walker.skipDescendants() }
                continue
            }
            guard values.isRegularFile == true, !name.hasPrefix(".") else { continue }
            let full = url.standardizedFileURL.path
            guard full.hasPrefix(rootPath + "/") else { continue }
            let path = String(full.dropFirst(rootPath.count + 1))
            guard let data = try? Data(contentsOf: url) else { continue }
            files[objectID(for: path)] = LocalFile(
                path: path,
                hash: hexSHA256(data),
                modified: values.contentModificationDate ?? .distantPast
            )
        }
        return files
    }

    /// Opaque object id for a library path, so remote names reveal nothing.
    static func objectID(for path: String) -> String {
        String(hexSHA256(Data(path.utf8)).prefix(32))
    }

    /// Lowercase hex SHA-256 of bytes.
    private static func hexSHA256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Where the local sync state lives.
    private static func stateURL(in library: URL) -> URL {
        library
            .appendingPathComponent(".skerry", isDirectory: true)
            .appendingPathComponent("sync-state.json")
    }

    /// Loads this device's last-synced state, empty on first sync.
    static func loadState(in library: URL) -> State {
        guard let data = try? Data(contentsOf: stateURL(in: library)),
            let decoded = try? JSONDecoder().decode(State.self, from: data)
        else { return State() }
        return decoded
    }

    /// Persists this device's sync state.
    private static func saveState(_ state: State, in library: URL) {
        let url = stateURL(in: library)
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        if let data = try? JSONEncoder().encode(state) {
            try? data.write(to: url, options: .atomic)
        }
    }

    /// Extensions eligible for line merging. Encrypted envelopes are .md files too, but
    /// their ciphertext lines always overlap wholly, so they fall through to conflict
    /// copies on their own.
    private static let mergeableExtensions: Set<String> = ["md", "markdown", "txt"]
    /// Largest file the merge path will consider.
    private static let mergeableByteLimit = 1_000_000

    /// Whether a path is text the engine may line-merge.
    private static func isMergeableText(_ path: String) -> Bool {
        mergeableExtensions.contains((path as NSString).pathExtension.lowercased())
    }

    /// Where the last-synced copy of a mergeable file lives, the merge base.
    private static func baseURL(id: String, in library: URL) -> URL {
        library
            .appendingPathComponent(".skerry", isDirectory: true)
            .appendingPathComponent("sync-base", isDirectory: true)
            .appendingPathComponent(id)
    }

    /// Stores the last-synced bytes of a mergeable file for future three-way merges.
    private static func writeBaseIfMergeable(
        _ data: Data, path: String, id: String, in library: URL
    ) {
        guard isMergeableText(path), data.count <= mergeableByteLimit,
            String(data: data, encoding: .utf8) != nil
        else { return }
        let url = baseURL(id: id, in: library)
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try? data.write(to: url, options: .atomic)
    }

    /// Reads the merge base for an object, nil when none was stored.
    private static func readBase(id: String, in library: URL) -> String? {
        guard let data = try? Data(contentsOf: baseURL(id: id, in: library)) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Drops the merge base for an object.
    private static func removeBase(id: String, in library: URL) {
        try? FileManager.default.removeItem(at: baseURL(id: id, in: library))
    }

    /// Moves a locally deleted file into the parking folder instead of destroying it.
    private static func parkDeleted(_ path: String, in library: URL, at now: Date) throws {
        let parking = library
            .appendingPathComponent(".skerry", isDirectory: true)
            .appendingPathComponent("sync-deleted", isDirectory: true)
        try FileManager.default.createDirectory(at: parking, withIntermediateDirectories: true)
        let stamp = now.formatted(.iso8601).replacingOccurrences(of: ":", with: "_")
        let name = stamp + "-" + (path as NSString).lastPathComponent
        let source = resolve(path, in: library)
        guard FileManager.default.fileExists(atPath: source.path) else { return }
        try FileManager.default.moveItem(at: source, to: parking.appendingPathComponent(name))
    }

    /// Removes parked deletions older than the tombstone lifetime.
    private static func sweepParked(in library: URL, olderThan cutoff: Date) {
        let parking = library
            .appendingPathComponent(".skerry", isDirectory: true)
            .appendingPathComponent("sync-deleted", isDirectory: true)
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: parking, includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return }
        for entry in entries {
            let values = try? entry.resourceValues(forKeys: [.contentModificationDateKey])
            guard let modified = values?.contentModificationDate, modified < cutoff else { continue }
            try? FileManager.default.removeItem(at: entry)
        }
    }

    /// A path for the conflict copy of a file, stamped with the sync time and a number derived
    /// from the copied content. The number makes the name deterministic across devices, so two
    /// peers that fork the same note within one second name the copy identically and converge on
    /// one object instead of overwriting each other's copy (finding F3). It sits in the single
    /// numeric slot the conflict-review filename parser already allows after the timestamp.
    private static func conflictCopyPath(
        for path: String, in library: URL, at now: Date, disambiguator: UInt32
    ) -> String {
        let ns = path as NSString
        let stem = ns.deletingPathExtension
        let ext = ns.pathExtension
        let stamp = now.formatted(
            .iso8601.year().month().day().timeSeparator(.omitted).time(includingFractionalSeconds: false)
        ).replacingOccurrences(of: ":", with: "")
        func candidate(_ token: UInt64) -> String {
            ext.isEmpty
                ? "\(stem) (conflict \(stamp) \(token))"
                : "\(stem) (conflict \(stamp) \(token)).\(ext)"
        }
        var token = UInt64(disambiguator)
        while FileManager.default.fileExists(atPath: resolve(candidate(token), in: library).path) {
            token += 1
        }
        return candidate(token)
    }

    /// Gives an encrypted conflict copy its own identity. The other device's envelope still
    /// carries the original note's cleartext id, so without this every unlock would try to
    /// rename the copy onto the original's `<id>.md`, fail, and surface an error (finding F2).
    /// The fresh id derives from the sealed content, so both devices pick the same id and
    /// converge on one copy. Plain-text and binary payloads pass through untouched. The id is
    /// clear front matter outside the GCM tag, so rewriting it never disturbs the ciphertext.
    private static func reassignedConflictID(_ bytes: Data, hash: String) -> Data {
        guard let text = String(data: bytes, encoding: .utf8) else { return bytes }
        var note = FrontMatter.parseNote(text)
        guard note.metadata.encrypted, note.metadata.id != nil else { return bytes }
        note.metadata.id = stableID(from: hash)
        return Data(FrontMatter.serializeNote(note).utf8)
    }

    /// A deterministic UUID drawn from a content hash, shaped from its first 32 hex digits so
    /// the same content yields the same id on every device.
    private static func stableID(from hash: String) -> UUID {
        let hex = String(hash.prefix(32))
        guard hex.count == 32 else { return UUID() }
        func part(_ lower: Int, _ upper: Int) -> String {
            let start = hex.index(hex.startIndex, offsetBy: lower)
            let end = hex.index(hex.startIndex, offsetBy: upper)
            return String(hex[start..<end])
        }
        let shaped = "\(part(0, 8))-\(part(8, 12))-\(part(12, 16))-\(part(16, 20))-\(part(20, 32))"
        return UUID(uuidString: shaped) ?? UUID()
    }

    /// Writes bytes to a library-relative path, creating parent folders. Manifest paths
    /// are authenticated ciphertext, but escapes are rejected anyway as defense in depth.
    private static func write(_ bytes: Data, to path: String, in library: URL) throws {
        let url = resolve(path, in: library)
        guard url.standardizedFileURL.path.hasPrefix(library.standardizedFileURL.path + "/")
        else { throw SyncError.corruptManifest }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try bytes.write(to: url, options: .atomic)
    }

    /// Resolves a library-relative path against the library root.
    private static func resolve(_ path: String, in library: URL) -> URL {
        path.split(separator: "/").reduce(library) { $0.appendingPathComponent(String($1)) }
    }
}
