import CryptoKit
import Foundation
import Testing

@testable import SkerryKit

/// SlowRemote delays object traffic so a pass can be made to outlive a short lock lifetime,
/// which is the condition audit finding F8 was about. Lock traffic is deliberately not delayed,
/// so the heartbeat keeps its own timing and the test measures the pass rather than the lock.
struct SlowRemote: SyncRemote, LockingSyncRemote {
    /// Remote doing the real work.
    let inner: FolderSyncRemote
    /// Delay added to every operation that is not lock traffic.
    let delay: Duration

    /// Whether a path is the advisory lock rather than library content.
    private func isLock(_ path: String) -> Bool { path == SyncEngine.lockPath }

    func download(_ path: String) async throws -> Data? {
        if !isLock(path) { try? await Task.sleep(for: delay) }
        return try await inner.download(path)
    }

    func upload(_ data: Data, to path: String) async throws {
        if !isLock(path) { try? await Task.sleep(for: delay) }
        try await inner.upload(data, to: path)
    }

    func delete(_ path: String) async throws {
        try await inner.delete(path)
    }

    func createExclusive(_ data: Data, at path: String) async throws -> Bool {
        try await inner.createExclusive(data, at: path)
    }
}

/// Proves F8: a pass that runs longer than the lock lifetime keeps its lock rather than having
/// it stolen, and a pass that does lose its lock stops instead of reconciling alongside the
/// device that took it.
struct SyncLockRenewalTests {
    /// Builds a library, a remote folder, and a slowed remote over it.
    private func makeRig(
        delay: Duration
    ) throws -> (library: URL, folder: URL, remote: SlowRemote, key: SymmetricKey) {
        let library = try SyncDrive.makeLibrary()
        let folder = try SyncDrive.makeLibrary()
        let remote = SlowRemote(inner: FolderSyncRemote(base: folder), delay: delay)
        return (library, folder, remote, SymmetricKey(size: .bits256))
    }

    /// The lock file inside a remote folder.
    private func lockFile(in folder: URL) -> URL {
        folder.appendingPathComponent(SyncEngine.lockPath)
    }

    /// The stamp currently written into the lock, nil when there is no lock.
    private func lockStamp(in folder: URL) -> Double? {
        guard let data = try? Data(contentsOf: lockFile(in: folder)) else { return nil }
        let text = String(decoding: data, as: UTF8.self)
        guard let separator = text.lastIndex(of: ":") else { return Double(text) }
        return Double(text[text.index(after: separator)...])
    }

    @Test func aSlowPassRenewsItsLockInsteadOfLosingIt() async throws {
        let rig = try makeRig(delay: .milliseconds(120))
        // Enough files that the delay adds up to a pass far longer than the lifetime below.
        for index in 0..<12 {
            try SyncDrive.write("note \(index)", to: "note\(index).md", in: rig.library)
        }

        async let pass = SyncEngine.sync(
            library: rig.library, remote: rig.remote, key: rig.key,
            lifetime: 0.5, refresh: 0.1
        )

        // Sample the stamp early and late. A renewed lock advances; the old behavior left the
        // acquisition stamp frozen and the lock aged out mid-pass.
        try await Task.sleep(for: .milliseconds(250))
        let early = lockStamp(in: rig.folder)
        try await Task.sleep(for: .milliseconds(700))
        let late = lockStamp(in: rig.folder)

        let result = try await pass
        #expect(result.uploaded == 12)

        let earlyStamp = try #require(early, "the pass should hold a lock while it runs")
        let lateStamp = try #require(late, "the lock should still be held later in the pass")
        #expect(
            lateStamp > earlyStamp,
            "the lock stamp never advanced, so a pass longer than the lifetime would be stolen"
        )
        // The pass cleans up after itself.
        #expect(lockStamp(in: rig.folder) == nil)
    }

    @Test func aSecondDeviceCannotStealTheLockFromARunningPass() async throws {
        let rig = try makeRig(delay: .milliseconds(120))
        for index in 0..<12 {
            try SyncDrive.write("note \(index)", to: "note\(index).md", in: rig.library)
        }
        let other = try SyncDrive.makeLibrary()
        try SyncDrive.write("from the other device", to: "other.md", in: other)

        async let pass = SyncEngine.sync(
            library: rig.library, remote: rig.remote, key: rig.key,
            lifetime: 0.5, refresh: 0.1
        )

        // Well past the lifetime, so without renewal the second device would steal the lock.
        try await Task.sleep(for: .milliseconds(800))
        let blocked = try await SyncEngine.sync(
            library: other, remote: rig.remote, key: rig.key, lifetime: 0.5, refresh: 0.1
        )

        let result = try await pass
        #expect(result.uploaded == 12)
        #expect(blocked.isQuiet, "the second device stole a live lock and reconciled alongside")
    }

    @Test func aPassStopsWhenAnotherDeviceTakesItsLock() async throws {
        let rig = try makeRig(delay: .milliseconds(120))
        for index in 0..<12 {
            try SyncDrive.write("note \(index)", to: "note\(index).md", in: rig.library)
        }

        async let pass = SyncEngine.sync(
            library: rig.library, remote: rig.remote, key: rig.key,
            lifetime: 60, refresh: 0.1
        )

        // Forge a takeover: overwrite the lock with a different owner, as an eventually
        // consistent store could allow even though the conditional create should not.
        try await Task.sleep(for: .milliseconds(300))
        let foreign = "another-device:\(Date().timeIntervalSince1970)"
        try Data(foreign.utf8).write(to: lockFile(in: rig.folder))

        var thrown: Error?
        do {
            _ = try await pass
        } catch {
            thrown = error
        }
        #expect(
            thrown as? SyncEngine.SyncError == .lockLost,
            "the pass carried on after losing its lock, got \(String(describing: thrown))"
        )
        // The other device's lock survives, since releasing only removes a lock we still own.
        let held = try #require(try? Data(contentsOf: lockFile(in: rig.folder)))
        #expect(String(decoding: held, as: UTF8.self).hasPrefix("another-device:"))
    }

    @Test func anOwnerlessLockFromAnOlderBuildStillAgesOut() async throws {
        let rig = try makeRig(delay: .zero)
        try SyncDrive.write("keep me", to: "note.md", in: rig.library)
        // A lock in the old stamp-only format, far older than any lifetime.
        try FileManager.default.createDirectory(
            at: lockFile(in: rig.folder).deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("0".utf8).write(to: lockFile(in: rig.folder))

        let result = try await SyncEngine.sync(
            library: rig.library, remote: rig.remote, key: rig.key
        )
        #expect(result.uploaded == 1, "an ownerless stale lock wedged sync instead of aging out")
    }
}
