import CryptoKit
import Foundation
import Testing

@testable import SkerryKit

/// ThrottlingRemote fails its first few operations the way a rate-limited provider does,
/// then serves normally, so a test can prove that a sync interrupted by a transient
/// provider failure surfaces the error and converges on retry with nothing lost.
final class ThrottlingRemote: SyncRemote, @unchecked Sendable {
    /// Error the throttle throws, standing in for a 429 or a 503.
    struct RateLimited: Error {}

    /// Remote doing the real work.
    private let inner: FolderSyncRemote
    /// Guards the countdown.
    private let lock = NSLock()
    /// Operations still set to fail before the throttle lifts.
    private var failuresLeft = 0

    /// Wraps a folder remote.
    init(inner: FolderSyncRemote) {
        self.inner = inner
    }

    /// Makes the next `count` operations of any kind fail with a rate-limit error.
    func throttleNext(_ count: Int) {
        lock.withLock { failuresLeft = count }
    }

    /// Whether this operation should fail, advancing the countdown.
    private func throttled() -> Bool {
        lock.withLock {
            guard failuresLeft > 0 else { return false }
            failuresLeft -= 1
            return true
        }
    }

    func download(_ path: String) async throws -> Data? {
        if throttled() { throw RateLimited() }
        return try await inner.download(path)
    }

    func upload(_ data: Data, to path: String) async throws {
        if throttled() { throw RateLimited() }
        try await inner.upload(data, to: path)
    }

    func delete(_ path: String) async throws {
        if throttled() { throw RateLimited() }
        try await inner.delete(path)
    }
}

/// PinnedManifestRemote serves a fixed, stale copy of the manifest on download while
/// writing through to the real remote. That is exactly what one device sees when a second
/// device is syncing at the same instant: it reads the listing that was current when it
/// started, not the one the other device just wrote. It makes the otherwise timing-dependent
/// concurrent-sync race deterministic and repeatable.
final class PinnedManifestRemote: SyncRemote, @unchecked Sendable {
    /// Remote doing the real work.
    private let inner: FolderSyncRemote
    /// Guards the pinned bytes.
    private let lock = NSLock()
    /// Stale manifest served on download; nil passes through to the real remote.
    private var pinned: Data?

    /// Wraps a folder remote.
    init(inner: FolderSyncRemote) {
        self.inner = inner
    }

    /// Freezes the manifest a racing device reads, until ``unpin()``.
    func pin(_ manifest: Data) {
        lock.withLock { pinned = manifest }
    }

    /// Stops serving the stale manifest.
    func unpin() {
        lock.withLock { pinned = nil }
    }

    func download(_ path: String) async throws -> Data? {
        if path == SyncEngine.manifestPath, let stale = lock.withLock({ pinned }) {
            return stale
        }
        return try await inner.download(path)
    }

    func upload(_ data: Data, to path: String) async throws {
        try await inner.upload(data, to: path)
    }

    func delete(_ path: String) async throws {
        try await inner.delete(path)
    }
}

@Suite struct SyncAdversarialTests {
    /// Two libraries and a shared folder remote, the two-device rig these tests share.
    private struct Rig {
        let deviceA: URL
        let deviceB: URL
        let remoteFolder: URL
        let remote: FolderSyncRemote
        let key = SymmetricKey(size: .bits256)

        init() throws {
            deviceA = try SyncDrive.makeLibrary()
            deviceB = try SyncDrive.makeLibrary()
            remoteFolder = try SyncDrive.makeLibrary()
            remote = FolderSyncRemote(base: remoteFolder)
        }

        /// The sealed manifest file inside the remote folder.
        var manifestFile: URL {
            remoteFolder
                .appendingPathComponent("Skerry Sync")
                .appendingPathComponent("manifest.skmanifest")
        }
    }

    @Test func throttledProviderSurfacesErrorThenConvergesOnRetry() async throws {
        let rig = try Rig()
        let throttle = ThrottlingRemote(inner: rig.remote)
        try SyncDrive.write("keep me safe", to: "note.md", in: rig.deviceA)

        // The provider rate-limits the first request; the sync fails and touches nothing.
        throttle.throttleNext(1)
        await #expect(throws: ThrottlingRemote.RateLimited.self) {
            _ = try await SyncEngine.sync(library: rig.deviceA, remote: throttle, key: rig.key)
        }
        #expect(SyncDrive.read("note.md", in: rig.deviceA) == "keep me safe")

        // Once the throttle lifts, a retry converges and the other device pulls the note.
        _ = try await SyncEngine.sync(library: rig.deviceA, remote: throttle, key: rig.key)
        let arrived = try await SyncEngine.sync(library: rig.deviceB, remote: rig.remote, key: rig.key)
        #expect(arrived.downloaded == 1)
        #expect(SyncDrive.read("note.md", in: rig.deviceB) == "keep me safe")
    }

    @Test func throttledDownloadOnPullConvergesOnRetry() async throws {
        let rig = try Rig()
        try SyncDrive.write("published", to: "note.md", in: rig.deviceA)
        _ = try await SyncEngine.sync(library: rig.deviceA, remote: rig.remote, key: rig.key)

        // Device B is throttled on its first pull request; it fails, then converges on retry.
        let throttle = ThrottlingRemote(inner: rig.remote)
        throttle.throttleNext(1)
        await #expect(throws: ThrottlingRemote.RateLimited.self) {
            _ = try await SyncEngine.sync(library: rig.deviceB, remote: throttle, key: rig.key)
        }
        let arrived = try await SyncEngine.sync(library: rig.deviceB, remote: throttle, key: rig.key)
        #expect(arrived.downloaded == 1)
        #expect(SyncDrive.read("note.md", in: rig.deviceB) == "published")
    }

    // MARK: - F1: stale-read lost update on a non-locking remote

    /// Documents the residual F1 hazard. The advisory lock (the lock tests below) serializes
    /// reconciliation on a locking remote, so two devices syncing at once can no longer overwrite
    /// each other. This test instead uses a NON-locking remote that also serves a stale manifest,
    /// modeling an eventually consistent store where a stale read loses an edit even without
    /// contention: the device that read the old listing overwrites the other, and the disjoint
    /// edit is not even kept as a conflict copy. The lock narrows this to eventual-consistency
    /// stragglers rather than the common concurrent case; a strongly consistent locking remote
    /// (WebDAV or S3 with the conditional create) closes it.
    @Test func concurrentEditReproducesTheKnownLostUpdateGap() async throws {
        let rig = try Rig()
        let pinned = PinnedManifestRemote(inner: rig.remote)

        // Both devices start from a shared, synced base.
        try SyncDrive.write("base line one\nbase line two", to: "note.md", in: rig.deviceA)
        _ = try await SyncEngine.sync(library: rig.deviceA, remote: rig.remote, key: rig.key)
        _ = try await SyncEngine.sync(library: rig.deviceB, remote: rig.remote, key: rig.key)
        #expect(SyncDrive.read("note.md", in: rig.deviceB) == "base line one\nbase line two")

        // The listing device B holds as it begins its racing sync, before A's write lands.
        let staleManifest = try Data(contentsOf: rig.manifestFile)

        // A edits the first line and syncs; A's version reaches the remote.
        try SyncDrive.write("A changed line one\nbase line two", to: "note.md", in: rig.deviceA)
        _ = try await SyncEngine.sync(library: rig.deviceA, remote: rig.remote, key: rig.key)

        // B edits a different line and syncs against its stale listing, so it never sees A's
        // version and overwrites it on the remote.
        try SyncDrive.write("base line one\nB changed line two", to: "note.md", in: rig.deviceB)
        pinned.pin(staleManifest)
        _ = try await SyncEngine.sync(library: rig.deviceB, remote: pinned, key: rig.key)

        // A syncs again against the real remote and finds only B's version. A's edit is gone.
        _ = try await SyncEngine.sync(library: rig.deviceA, remote: rig.remote, key: rig.key)

        // KNOWN GAP (F1): A's disjoint edit was lost with no conflict copy.
        #expect(SyncDrive.read("note.md", in: rig.deviceA) == "base line one\nB changed line two")
        let conflictCopies = (try? FileManager.default.contentsOfDirectory(atPath: rig.deviceA.path))?
            .filter { $0.contains("conflict") } ?? []
        #expect(conflictCopies.isEmpty)
    }

    /// The companion to the gap test: when the two syncs do NOT overlap, the same two disjoint
    /// edits merge cleanly and both survive. This is the behavior the product actually
    /// advertises, and it holds as long as writes are serialized.
    @Test func serializedDisjointEditsMergeCleanly() async throws {
        let rig = try Rig()
        try SyncDrive.write("base line one\nbase line two", to: "note.md", in: rig.deviceA)
        _ = try await SyncEngine.sync(library: rig.deviceA, remote: rig.remote, key: rig.key)
        _ = try await SyncEngine.sync(library: rig.deviceB, remote: rig.remote, key: rig.key)

        // A edits line one and syncs first.
        try SyncDrive.write("A changed line one\nbase line two", to: "note.md", in: rig.deviceA)
        _ = try await SyncEngine.sync(library: rig.deviceA, remote: rig.remote, key: rig.key)

        // B edits line two and syncs after, seeing A's version, so the two merge.
        try SyncDrive.write("base line one\nB changed line two", to: "note.md", in: rig.deviceB)
        let merged = try await SyncEngine.sync(library: rig.deviceB, remote: rig.remote, key: rig.key)
        #expect(merged.merged == 1)
        #expect(SyncDrive.read("note.md", in: rig.deviceB) == "A changed line one\nB changed line two")

        // A pulls the merged result, so both devices converge with neither edit lost.
        _ = try await SyncEngine.sync(library: rig.deviceA, remote: rig.remote, key: rig.key)
        #expect(SyncDrive.read("note.md", in: rig.deviceA) == "A changed line one\nB changed line two")
    }

    // MARK: - F2 and F3: conflict-copy identity

    /// An encrypted note forked on two devices keeps both, and the conflict copy must take a
    /// fresh id. Reusing the original's id makes convergeEncryptedNames collide on `<id>.md`
    /// and fail on every unlock (finding F2).
    @Test func encryptedConflictCopyGetsAFreshID() async throws {
        let rig = try Rig()
        let noteKey = SymmetricKey(size: .bits256)
        let originalID = UUID()
        func envelope(_ body: String) throws -> String {
            var note = Note()
            note.metadata.id = originalID
            note.metadata.title = "Harbor"
            note.body = body
            return FrontMatter.serializeNote(try EncryptedNote.seal(note, key: noteKey))
        }

        try SyncDrive.write(try envelope("base"), to: "\(originalID).md", in: rig.deviceA)
        _ = try await SyncEngine.sync(library: rig.deviceA, remote: rig.remote, key: rig.key)
        _ = try await SyncEngine.sync(library: rig.deviceB, remote: rig.remote, key: rig.key)

        try SyncDrive.write(try envelope("device A body"), to: "\(originalID).md", in: rig.deviceA)
        _ = try await SyncEngine.sync(library: rig.deviceA, remote: rig.remote, key: rig.key)
        try SyncDrive.write(try envelope("device B body"), to: "\(originalID).md", in: rig.deviceB)
        let result = try await SyncEngine.sync(library: rig.deviceB, remote: rig.remote, key: rig.key)

        #expect(result.conflicts == 1)
        let files = try FileManager.default.contentsOfDirectory(atPath: rig.deviceB.path)
        let copyName = try #require(files.first { $0.contains("(conflict") })
        let copyText = try String(
            contentsOf: rig.deviceB.appendingPathComponent(copyName), encoding: .utf8
        )
        let copy = FrontMatter.parseNote(copyText)
        #expect(copy.metadata.encrypted)
        #expect(copy.metadata.id != nil)
        #expect(copy.metadata.id != originalID)
    }

    /// The conflict-copy name carries a digest of the copied content, so different forked
    /// content yields different names and object ids. Without it two devices forking the same
    /// note in one second collide on the copy and lose one side (finding F3).
    @Test func conflictCopyNameVariesWithContent() async throws {
        let stamp = Date(timeIntervalSince1970: 1_700_000_000)
        func copyName(theirs: String) async throws -> String {
            let rig = try Rig()
            try SyncDrive.write("base", to: "note.md", in: rig.deviceA)
            _ = try await SyncEngine.sync(
                library: rig.deviceA, remote: rig.remote, key: rig.key, now: stamp
            )
            _ = try await SyncEngine.sync(
                library: rig.deviceB, remote: rig.remote, key: rig.key, now: stamp
            )
            try SyncDrive.write(theirs, to: "note.md", in: rig.deviceA)
            _ = try await SyncEngine.sync(
                library: rig.deviceA, remote: rig.remote, key: rig.key, now: stamp
            )
            try SyncDrive.write("device B line", to: "note.md", in: rig.deviceB)
            _ = try await SyncEngine.sync(
                library: rig.deviceB, remote: rig.remote, key: rig.key, now: stamp
            )
            let copies = (try FileManager.default.contentsOfDirectory(atPath: rig.deviceB.path))
                .filter { $0.contains("(conflict") }
            return try #require(copies.first)
        }
        let one = try await copyName(theirs: "device A content one")
        let two = try await copyName(theirs: "device A content two")
        #expect(one != two)
    }

    // MARK: - F1: the advisory lock that serializes concurrent syncs

    /// A fresh lock held by another device makes a sync a quiet no-op, so it cannot overwrite
    /// the other device's object. After the lock clears the two disjoint edits merge and neither
    /// is lost, which is the concurrent case finding F1 was about.
    @Test func aFreshLockBlocksASyncFromClobbering() async throws {
        let rig = try Rig()
        try SyncDrive.write("base line one\nbase line two", to: "note.md", in: rig.deviceA)
        _ = try await SyncEngine.sync(library: rig.deviceA, remote: rig.remote, key: rig.key)
        _ = try await SyncEngine.sync(library: rig.deviceB, remote: rig.remote, key: rig.key)

        // A edits and syncs, so the remote holds A's version.
        try SyncDrive.write("A changed line one\nbase line two", to: "note.md", in: rig.deviceA)
        _ = try await SyncEngine.sync(library: rig.deviceA, remote: rig.remote, key: rig.key)

        // Another device is mid-sync: plant a fresh lock on the remote.
        let now = Date()
        let planted = try await rig.remote.createExclusive(
            Data("\(now.timeIntervalSince1970)".utf8), at: SyncEngine.lockPath
        )
        #expect(planted)

        // B edits and tries to sync; the fresh lock makes it a quiet no-op that touches nothing.
        try SyncDrive.write("base line one\nB changed line two", to: "note.md", in: rig.deviceB)
        let blocked = try await SyncEngine.sync(
            library: rig.deviceB, remote: rig.remote, key: rig.key, now: now
        )
        #expect(blocked.isQuiet)

        // Release the lock; B now merges with A's version and both edits survive.
        try await rig.remote.delete(SyncEngine.lockPath)
        _ = try await SyncEngine.sync(library: rig.deviceB, remote: rig.remote, key: rig.key)
        #expect(SyncDrive.read("note.md", in: rig.deviceB) == "A changed line one\nB changed line two")
        _ = try await SyncEngine.sync(library: rig.deviceA, remote: rig.remote, key: rig.key)
        #expect(SyncDrive.read("note.md", in: rig.deviceA) == "A changed line one\nB changed line two")
    }

    /// An abandoned lock from a crashed device is stolen once it ages past its lifetime, so a
    /// crash mid-sync cannot wedge every future sync.
    @Test func aStaleLockIsStolen() async throws {
        let rig = try Rig()
        try SyncDrive.write("keep me", to: "note.md", in: rig.deviceA)
        // A lock stamped at the epoch is far older than the lifetime.
        _ = try await rig.remote.createExclusive(Data("0".utf8), at: SyncEngine.lockPath)
        let result = try await SyncEngine.sync(library: rig.deviceA, remote: rig.remote, key: rig.key)
        #expect(result.uploaded == 1)
    }
}
