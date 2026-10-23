import CryptoKit
import Foundation
import Testing

@testable import SkerryKit

/// FlakyRemote wraps a real remote and fails chosen operations, to prove a sync
/// interrupted at any point never loses data and the next pass converges.
final class FlakyRemote: SyncRemote, @unchecked Sendable {
    /// Error the injected failures throw.
    struct InjectedFailure: Error {}

    /// Remote doing the real work.
    private let inner: FolderSyncRemote
    /// Guards the failure predicate.
    private let lock = NSLock()
    /// Uploads whose path matches fail; nil disables injection.
    private var failUploadMatching: ((String) -> Bool)?
    /// Countdown of uploads to allow before every upload fails; nil disables.
    private var uploadsBeforeFailure: Int?

    /// Creates a wrapper over a folder remote.
    init(inner: FolderSyncRemote) {
        self.inner = inner
    }

    /// Fails every upload whose remote path satisfies the predicate.
    func failUploads(matching predicate: @escaping (String) -> Bool) {
        lock.lock()
        failUploadMatching = predicate
        lock.unlock()
    }

    /// Allows a number of uploads, then fails every one after.
    func failAfterUploads(_ count: Int) {
        lock.lock()
        uploadsBeforeFailure = count
        lock.unlock()
    }

    /// Stops injecting failures.
    func heal() {
        lock.lock()
        failUploadMatching = nil
        uploadsBeforeFailure = nil
        lock.unlock()
    }

    /// Whether the next upload of this path should fail, advancing the countdown.
    private func shouldFailUpload(of path: String) -> Bool {
        lock.withLock {
            if failUploadMatching?(path) ?? false { return true }
            if let remaining = uploadsBeforeFailure {
                if remaining <= 0 { return true }
                uploadsBeforeFailure = remaining - 1
            }
            return false
        }
    }

    func download(_ path: String) async throws -> Data? {
        try await inner.download(path)
    }

    func upload(_ data: Data, to path: String) async throws {
        if shouldFailUpload(of: path) { throw InjectedFailure() }
        try await inner.upload(data, to: path)
    }

    func delete(_ path: String) async throws {
        try await inner.delete(path)
    }
}

@Suite struct SyncEngineFaultTests {
    /// Two libraries, a folder-backed remote, and a flaky wrapper over it.
    private struct Rig {
        let deviceA: URL
        let deviceB: URL
        let remoteFolder: URL
        let remote: FolderSyncRemote
        let flaky: FlakyRemote
        let key = SymmetricKey(size: .bits256)

        init() throws {
            deviceA = try SyncDrive.makeLibrary()
            deviceB = try SyncDrive.makeLibrary()
            remoteFolder = try SyncDrive.makeLibrary()
            remote = FolderSyncRemote(base: remoteFolder)
            flaky = FlakyRemote(inner: remote)
        }

        /// Path of the sealed manifest inside the remote folder.
        var manifestFile: URL {
            remoteFolder
                .appendingPathComponent("Skerry Sync")
                .appendingPathComponent("manifest.skmanifest")
        }
    }

    @Test func failedManifestUploadLosesNothingAndHeals() async throws {
        let rig = try Rig()
        try SyncDrive.write("first", to: "one.md", in: rig.deviceA)
        _ = try await SyncEngine.sync(library: rig.deviceA, remote: rig.remote, key: rig.key)
        let manifestBefore = try Data(contentsOf: rig.manifestFile)

        // A second sync writes a new file but the manifest upload dies.
        try SyncDrive.write("second", to: "two.md", in: rig.deviceA)
        rig.flaky.failUploads { $0.hasSuffix("manifest.skmanifest") }
        await #expect(throws: FlakyRemote.InjectedFailure.self) {
            _ = try await SyncEngine.sync(library: rig.deviceA, remote: rig.flaky, key: rig.key)
        }

        // The old manifest still stands, both local files still stand.
        #expect(try Data(contentsOf: rig.manifestFile) == manifestBefore)
        #expect(SyncDrive.read("one.md", in: rig.deviceA) == "first")
        #expect(SyncDrive.read("two.md", in: rig.deviceA) == "second")

        // A healed pass converges, and the other device sees everything.
        rig.flaky.heal()
        _ = try await SyncEngine.sync(library: rig.deviceA, remote: rig.flaky, key: rig.key)
        let result = try await SyncEngine.sync(library: rig.deviceB, remote: rig.remote, key: rig.key)
        #expect(result.downloaded == 2)
    }

    @Test func crashMidwayThroughObjectUploadsHeals() async throws {
        let rig = try Rig()
        for step in 0..<5 {
            try SyncDrive.write("note \(step)", to: "note-\(step).md", in: rig.deviceA)
        }
        rig.flaky.failAfterUploads(2)
        await #expect(throws: FlakyRemote.InjectedFailure.self) {
            _ = try await SyncEngine.sync(library: rig.deviceA, remote: rig.flaky, key: rig.key)
        }
        rig.flaky.heal()
        _ = try await SyncEngine.sync(library: rig.deviceA, remote: rig.flaky, key: rig.key)
        let result = try await SyncEngine.sync(library: rig.deviceB, remote: rig.remote, key: rig.key)
        #expect(result.downloaded == 5)
        for step in 0..<5 {
            #expect(SyncDrive.read("note-\(step).md", in: rig.deviceB) == "note \(step)")
        }
    }

    @Test func tamperedManifestIsRejectedWithoutTouchingLocalFiles() async throws {
        let rig = try Rig()
        try SyncDrive.write("mine", to: "note.md", in: rig.deviceA)
        _ = try await SyncEngine.sync(library: rig.deviceA, remote: rig.remote, key: rig.key)

        var bytes = try Data(contentsOf: rig.manifestFile)
        bytes[bytes.count / 2] ^= 0xFF
        try bytes.write(to: rig.manifestFile)

        try SyncDrive.write("edited after tamper", to: "note.md", in: rig.deviceA)
        await #expect(throws: SyncEngine.SyncError.wrongKey) {
            _ = try await SyncEngine.sync(library: rig.deviceA, remote: rig.remote, key: rig.key)
        }
        #expect(SyncDrive.read("note.md", in: rig.deviceA) == "edited after tamper")
    }

    @Test func tamperedObjectIsRejectedWithoutTouchingLocalFiles() async throws {
        let rig = try Rig()
        try SyncDrive.write("original", to: "note.md", in: rig.deviceA)
        _ = try await SyncEngine.sync(library: rig.deviceA, remote: rig.remote, key: rig.key)

        let objects = rig.remoteFolder
            .appendingPathComponent("Skerry Sync")
            .appendingPathComponent("objects")
        let objectFile = try FileManager.default.contentsOfDirectory(
            at: objects, includingPropertiesForKeys: nil
        )[0]
        var bytes = try Data(contentsOf: objectFile)
        bytes[bytes.count / 2] ^= 0xFF
        try bytes.write(to: objectFile)

        await #expect(throws: SyncEngine.SyncError.wrongKey) {
            _ = try await SyncEngine.sync(library: rig.deviceB, remote: rig.remote, key: rig.key)
        }
        #expect(SyncDrive.read("note.md", in: rig.deviceB) == nil)
    }

    @Test func maliciousManifestPathCannotEscapeTheLibrary() async throws {
        let rig = try Rig()
        // An attacker with the vault key is out of scope, but the traversal guard should
        // still refuse a manifest whose path climbs out of the library.
        let evilPath = "../escaped-\(UUID().uuidString).md"
        let id = SyncEngine.objectID(for: evilPath)
        let manifest = SyncEngine.Manifest(
            version: 1,
            entries: [
                id: SyncEngine.Manifest.Entry(
                    path: evilPath, hash: "0000", updated: 0, deleted: false, deletedAt: nil
                )
            ]
        )
        let sealedManifest = try NoteCrypto.seal(
            JSONEncoder().encode(manifest), key: rig.key
        )
        try await rig.remote.upload(sealedManifest, to: "Skerry Sync/manifest.skmanifest")
        let sealedObject = try NoteCrypto.seal(Data("evil".utf8), key: rig.key)
        try await rig.remote.upload(sealedObject, to: "Skerry Sync/objects/" + id)

        await #expect(throws: SyncEngine.SyncError.corruptManifest) {
            _ = try await SyncEngine.sync(library: rig.deviceB, remote: rig.remote, key: rig.key)
        }
        let escaped = rig.deviceB.deletingLastPathComponent()
            .appendingPathComponent(String(evilPath.dropFirst(3)))
        #expect(!FileManager.default.fileExists(atPath: escaped.path))
    }

    @Test func corruptLocalStateSelfHealsWithoutDataMovement() async throws {
        let rig = try Rig()
        try SyncDrive.write("stable", to: "note.md", in: rig.deviceA)
        _ = try await SyncEngine.sync(library: rig.deviceA, remote: rig.remote, key: rig.key)

        let stateFile = rig.deviceA
            .appendingPathComponent(".skerry")
            .appendingPathComponent("sync-state.json")
        try Data("not json at all".utf8).write(to: stateFile)

        let result = try await SyncEngine.sync(library: rig.deviceA, remote: rig.remote, key: rig.key)
        #expect(result.isQuiet)
        #expect(SyncDrive.read("note.md", in: rig.deviceA) == "stable")
    }

    @Test func manifestRegressionReseedsFromLocalState() async throws {
        let rig = try Rig()
        try SyncDrive.write("early", to: "early.md", in: rig.deviceA)
        _ = try await SyncEngine.sync(library: rig.deviceA, remote: rig.remote, key: rig.key)
        let staleManifest = try Data(contentsOf: rig.manifestFile)

        // A adds another file; then a racing device overwrites the manifest with the
        // stale copy, losing A's second entry from the listing.
        try SyncDrive.write("late", to: "late.md", in: rig.deviceA)
        _ = try await SyncEngine.sync(library: rig.deviceA, remote: rig.remote, key: rig.key)
        try staleManifest.write(to: rig.manifestFile)

        // A's next pass notices the manifest lost its file and re-seeds it.
        let reseed = try await SyncEngine.sync(library: rig.deviceA, remote: rig.remote, key: rig.key)
        #expect(reseed.uploaded == 1)
        let arrived = try await SyncEngine.sync(library: rig.deviceB, remote: rig.remote, key: rig.key)
        #expect(arrived.downloaded == 2)
        #expect(SyncDrive.read("late.md", in: rig.deviceB) == "late")
    }

    @Test func wipedRemoteReseedsEverything() async throws {
        let rig = try Rig()
        try SyncDrive.write("keep", to: "a.md", in: rig.deviceA)
        try SyncDrive.write("keep too", to: "b/c.md", in: rig.deviceA)
        _ = try await SyncEngine.sync(library: rig.deviceA, remote: rig.remote, key: rig.key)

        try FileManager.default.removeItem(
            at: rig.remoteFolder.appendingPathComponent("Skerry Sync")
        )
        let reseed = try await SyncEngine.sync(library: rig.deviceA, remote: rig.remote, key: rig.key)
        #expect(reseed.uploaded == 2)
        let arrived = try await SyncEngine.sync(library: rig.deviceB, remote: rig.remote, key: rig.key)
        #expect(arrived.downloaded == 2)
    }

    @Test func sealedNoteFilesNeverAppearAsPlaintextOnTheRemote() async throws {
        let rig = try Rig()
        // A note sealed under the vault master key, exactly as the app writes it.
        let noteKey = SymmetricKey(size: .bits256)
        var note = Note()
        note.metadata.id = UUID()
        note.metadata.title = "Very secret title"
        note.body = "the secret body"
        let envelope = try EncryptedNote.seal(note, key: noteKey)
        let fileText = FrontMatter.serializeNote(envelope)
        try SyncDrive.write(fileText, to: "\(note.metadata.id!.uuidString).md", in: rig.deviceA)

        _ = try await SyncEngine.sync(library: rig.deviceA, remote: rig.remote, key: rig.key)

        // Walk every byte on the remote: with the transport layer unsealed using the sync
        // key, the inner note stays ciphertext; without it, everything is ciphertext.
        var checked = 0
        for url in regularFiles(under: rig.remoteFolder) {
            let raw = try Data(contentsOf: url)
            #expect(!String(decoding: raw, as: UTF8.self).contains("secret"))
            if let transportOpened = try? NoteCrypto.unseal(raw, key: rig.key) {
                let text = String(decoding: transportOpened, as: UTF8.self)
                #expect(!text.contains("Very secret title"))
                #expect(!text.contains("the secret body"))
            }
            checked += 1
        }
        #expect(checked >= 2)
    }

    @Test func tombstonesExpireAfterTheirLifetime() async throws {
        let rig = try Rig()
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        try SyncDrive.write("temp", to: "gone.md", in: rig.deviceA)
        _ = try await SyncEngine.sync(
            library: rig.deviceA, remote: rig.remote, key: rig.key, now: start
        )
        try FileManager.default.removeItem(at: rig.deviceA.appendingPathComponent("gone.md"))
        _ = try await SyncEngine.sync(
            library: rig.deviceA, remote: rig.remote, key: rig.key,
            now: start.addingTimeInterval(60)
        )

        // Just before expiry the tombstone survives a pass; just after, it is dropped.
        _ = try await SyncEngine.sync(
            library: rig.deviceA, remote: rig.remote, key: rig.key,
            now: start.addingTimeInterval(SyncEngine.tombstoneLifetime - 3600)
        )
        var manifest = try unsealManifest(rig)
        #expect(manifest.entries.values.contains { $0.deleted })

        _ = try await SyncEngine.sync(
            library: rig.deviceA, remote: rig.remote, key: rig.key,
            now: start.addingTimeInterval(SyncEngine.tombstoneLifetime + 3600)
        )
        manifest = try unsealManifest(rig)
        #expect(!manifest.entries.values.contains { $0.deleted })
    }

    @Test func hundredFileLibraryRoundTrips() async throws {
        let rig = try Rig()
        for step in 0..<100 {
            let folder = step % 3 == 0 ? "" : "folder-\(step % 5)/"
            try SyncDrive.write(
                "content of note \(step)", to: "\(folder)note-\(step).md", in: rig.deviceA
            )
        }
        let up = try await SyncEngine.sync(library: rig.deviceA, remote: rig.remote, key: rig.key)
        #expect(up.uploaded == 100)
        let down = try await SyncEngine.sync(library: rig.deviceB, remote: rig.remote, key: rig.key)
        #expect(down.downloaded == 100)
        let again = try await SyncEngine.sync(library: rig.deviceA, remote: rig.remote, key: rig.key)
        #expect(again.isQuiet)
        #expect(SyncDrive.read("folder-1/note-1.md", in: rig.deviceB) == "content of note 1")
    }

    /// Downloads and unseals the current remote manifest.
    private func unsealManifest(_ rig: Rig) throws -> SyncEngine.Manifest {
        let sealed = try Data(contentsOf: rig.manifestFile)
        let bytes = try NoteCrypto.unseal(sealed, key: rig.key)
        return try JSONDecoder().decode(SyncEngine.Manifest.self, from: bytes)
    }

    /// Every regular file under a folder, collected synchronously.
    private func regularFiles(under root: URL) -> [URL] {
        guard let walker = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.isRegularFileKey]
        ) else { return [] }
        var files: [URL] = []
        for case let url as URL in walker {
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey])
            if values?.isRegularFile == true { files.append(url) }
        }
        return files
    }
}
