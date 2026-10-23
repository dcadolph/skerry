import CryptoKit
import Foundation
import Testing

@testable import SkerryKit

/// Proves the F1 acceptance condition: two devices editing one note from a common base, with
/// passes that genuinely overlap in wall-clock time, never lose an edit silently.
///
/// The existing soak drives devices sequentially and awaits each full pass, so passes never
/// overlap and it cannot exercise this. These tests start both passes before either finishes,
/// then let the devices settle the way the app would, and assert on what survived.
struct SyncConcurrencyTests {
    /// What a run of the overlapping scenario ended up with.
    struct Outcome {
        /// Whether the text on either device carries the edit device A made.
        var keptA = false
        /// Whether the text on either device carries the edit device B made.
        var keptB = false
        /// Whether a conflict copy was written, which is an acceptable way to keep both.
        var conflictCopy = false
        /// Errors thrown by either overlapping pass, tolerated as long as nothing is lost.
        var errors: [String] = []

        /// No edit vanished: both survive somewhere, or a conflict copy holds the loser.
        var nothingLost: Bool { (keptA && keptB) || conflictCopy }
    }

    /// Text each device starts from.
    static let base = "base line one\nbase line two"
    /// Device A rewrites the first line only.
    static let editA = "A changed line one\nbase line two"
    /// Device B rewrites the second line only, so the two edits are disjoint and mergeable.
    static let editB = "base line one\nB changed line two"

    /// Runs one overlapping round against a remote and reports what survived.
    ///
    /// Both devices reach a common base, both edit the same note in different places, and both
    /// passes start before either completes. Afterward each device syncs again the way the app
    /// does on its next tick, so a pass that a held lock turned into a no-op still converges.
    static func runOverlappingRound(over remote: some SyncRemote) async throws -> Outcome {
        let key = SymmetricKey(size: .bits256)
        let deviceA = try SyncDrive.makeLibrary()
        let deviceB = try SyncDrive.makeLibrary()

        try SyncDrive.write(base, to: "note.md", in: deviceA)
        _ = try await SyncEngine.sync(library: deviceA, remote: remote, key: key)
        _ = try await SyncEngine.sync(library: deviceB, remote: remote, key: key)
        #expect(SyncDrive.read("note.md", in: deviceB) == base)

        try SyncDrive.write(editA, to: "note.md", in: deviceA)
        try SyncDrive.write(editB, to: "note.md", in: deviceB)

        var outcome = Outcome()

        // The overlap. Both passes are in flight at once rather than one after the other.
        async let passA: Void = {
            _ = try await SyncEngine.sync(library: deviceA, remote: remote, key: key)
        }()
        async let passB: Void = {
            _ = try await SyncEngine.sync(library: deviceB, remote: remote, key: key)
        }()
        do {
            _ = try await (passA, passB)
        } catch {
            outcome.errors.append(String(describing: error))
        }

        // Settle. A pass blocked by a held lock did nothing, and the app retries on its next
        // tick, so give both devices room to converge before judging the result.
        for _ in 0..<3 {
            _ = try? await SyncEngine.sync(library: deviceA, remote: remote, key: key)
            _ = try? await SyncEngine.sync(library: deviceB, remote: remote, key: key)
        }

        for library in [deviceA, deviceB] {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: library.path)) ?? []
            for name in names where name.hasSuffix(".md") {
                guard let text = SyncDrive.read(name, in: library) else { continue }
                if text.contains("A changed line one") { outcome.keptA = true }
                if text.contains("B changed line two") { outcome.keptB = true }
                if name.contains("conflict") { outcome.conflictCopy = true }
            }
        }
        return outcome
    }

    /// Repeats the overlapping round enough times to hit a spread of interleavings, since the
    /// race depends on timing and a single pass proves very little.
    ///
    /// Each round gets a fresh remote from the factory, because a round seals its manifest with
    /// its own key and a reused remote would fail the next round on the old key rather than on
    /// anything the test is trying to measure.
    static func assertNoLossOverRounds(
        _ rounds: Int, label: String, makeRemote: () throws -> any SyncRemote
    ) async throws {
        var lost = 0
        var merged = 0
        var viaConflictCopy = 0
        for round in 0..<rounds {
            let outcome = try await runOverlappingRound(over: makeRemote())
            if !outcome.nothingLost {
                lost += 1
                Issue.record(
                    """
                    \(label) round \(round) lost an edit. \
                    keptA=\(outcome.keptA) keptB=\(outcome.keptB) \
                    conflictCopy=\(outcome.conflictCopy) errors=\(outcome.errors)
                    """
                )
            } else if outcome.keptA && outcome.keptB {
                merged += 1
            } else {
                viaConflictCopy += 1
            }
        }
        #expect(lost == 0, "\(label): \(lost) of \(rounds) rounds lost an edit")
        #expect(merged + viaConflictCopy == rounds)
    }

    @Test func overlappingPassesLoseNothingOverAFolder() async throws {
        try await Self.assertNoLossOverRounds(12, label: "folder") {
            FolderSyncRemote(base: try SyncDrive.makeLibrary())
        }
    }

    @Test func overlappingPassesLoseNothingOverWebDAV() async throws {
        var servers: [TestWebDAVServer] = []
        defer { servers.forEach { $0.stop() } }
        try await Self.assertNoLossOverRounds(8, label: "webdav") {
            let server = try TestWebDAVServer()
            servers.append(server)
            return WebDAVSyncRemote(
                config: WebDAVClient.Config(
                    baseURL: server.baseURL, username: server.username, password: server.password
                )
            )
        }
    }

    @Test func overlappingPassesLoseNothingOverS3() async throws {
        var servers: [TestS3Server] = []
        defer { servers.forEach { $0.stop() } }
        try await Self.assertNoLossOverRounds(8, label: "s3") {
            let server = try TestS3Server()
            servers.append(server)
            return S3SyncRemote(
                config: S3Client.Config(
                    endpoint: server.endpoint, region: server.region, bucket: server.bucket,
                    accessKeyID: server.accessKey, secretAccessKey: server.secret
                )
            )
        }
    }

    /// The control, and the reason the three tests above mean anything.
    ///
    /// A remote with no exclusive create cannot serialize anything, so the identical scenario
    /// loses an edit. Observed at 12 of 12 rounds. That pins the advisory lock as the thing
    /// doing the work rather than luck in the scheduler. It is also the shape of the residual
    /// risk on an eventually consistent folder target, where the atomic create is only best
    /// effort, so if this control ever stops losing edits the safe results need re-reading.
    @Test func overlapWithoutALockLosesAnEdit() async throws {
        var lost = 0
        for _ in 0..<12 {
            let unlocked = NonLockingRemote(
                inner: FolderSyncRemote(base: try SyncDrive.makeLibrary())
            )
            let outcome = try await Self.runOverlappingRound(over: unlocked)
            if !outcome.nothingLost { lost += 1 }
        }
        #expect(lost > 0, "the unserialized path lost nothing, so the locking tests prove less")
    }
}

/// NonLockingRemote hides a remote's exclusive create, so the engine falls back to its
/// unserialized path. Used as the control in the concurrency tests.
struct NonLockingRemote: SyncRemote {
    /// Remote doing the real work.
    let inner: FolderSyncRemote

    func download(_ path: String) async throws -> Data? { try await inner.download(path) }
    func upload(_ data: Data, to path: String) async throws { try await inner.upload(data, to: path) }
    func delete(_ path: String) async throws { try await inner.delete(path) }
}
