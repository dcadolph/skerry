import CryptoKit
import Foundation
import Testing

@testable import SkerryKit

@Suite struct SyncEngineTests {
    /// Two device libraries and a shared folder remote, all in temporary directories.
    private struct Rig {
        let deviceA: URL
        let deviceB: URL
        let remote: FolderSyncRemote
        let key = SymmetricKey(size: .bits256)

        init() throws {
            let base = FileManager.default.temporaryDirectory
                .appendingPathComponent("skerry-sync-\(UUID().uuidString)")
            deviceA = base.appendingPathComponent("a")
            deviceB = base.appendingPathComponent("b")
            let shared = base.appendingPathComponent("remote")
            for url in [deviceA, deviceB, shared] {
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            }
            remote = FolderSyncRemote(base: shared)
        }

        /// Writes a library file on one device.
        func write(_ text: String, to path: String, on device: URL) throws {
            let url = device.appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try text.write(to: url, atomically: true, encoding: .utf8)
        }

        /// Reads a library file, nil when missing.
        func read(_ path: String, on device: URL) -> String? {
            try? String(contentsOf: device.appendingPathComponent(path), encoding: .utf8)
        }

        /// Syncs one device with the shared remote.
        @discardableResult
        func sync(_ device: URL, at date: Date = Date()) async throws -> SyncEngine.Result {
            try await SyncEngine.sync(library: device, remote: remote, key: key, now: date)
        }
    }

    @Test func createFlowsFromOneDeviceToTheOther() async throws {
        let rig = try Rig()
        try rig.write("# Hello", to: "hello.md", on: rig.deviceA)
        let up = try await rig.sync(rig.deviceA)
        #expect(up.uploaded == 1)
        let down = try await rig.sync(rig.deviceB)
        #expect(down.downloaded == 1)
        #expect(rig.read("hello.md", on: rig.deviceB) == "# Hello")
    }

    @Test func editFlowsBack() async throws {
        let rig = try Rig()
        try rig.write("v1", to: "note.md", on: rig.deviceA)
        try await rig.sync(rig.deviceA)
        try await rig.sync(rig.deviceB)
        try rig.write("v2 edited on b", to: "note.md", on: rig.deviceB)
        try await rig.sync(rig.deviceB)
        let result = try await rig.sync(rig.deviceA)
        #expect(result.downloaded == 1)
        #expect(rig.read("note.md", on: rig.deviceA) == "v2 edited on b")
    }

    @Test func deleteAndTombstonePropagate() async throws {
        let rig = try Rig()
        try rig.write("temp", to: "gone.md", on: rig.deviceA)
        try await rig.sync(rig.deviceA)
        try await rig.sync(rig.deviceB)
        try FileManager.default.removeItem(at: rig.deviceA.appendingPathComponent("gone.md"))
        let del = try await rig.sync(rig.deviceA)
        #expect(del.deletedRemote == 1)
        let other = try await rig.sync(rig.deviceB)
        #expect(other.deletedLocal == 1)
        #expect(rig.read("gone.md", on: rig.deviceB) == nil)
        // The deleted file was parked, not destroyed.
        let parked = rig.deviceB
            .appendingPathComponent(".skerry")
            .appendingPathComponent("sync-deleted")
        let parkedEntries = (try? FileManager.default.contentsOfDirectory(atPath: parked.path)) ?? []
        #expect(parkedEntries.count == 1)
    }

    @Test func editBeatsDelete() async throws {
        let rig = try Rig()
        try rig.write("keep me", to: "note.md", on: rig.deviceA)
        try await rig.sync(rig.deviceA)
        try await rig.sync(rig.deviceB)
        // A deletes; B edits before hearing about it.
        try FileManager.default.removeItem(at: rig.deviceA.appendingPathComponent("note.md"))
        try await rig.sync(rig.deviceA)
        try rig.write("edited after delete", to: "note.md", on: rig.deviceB)
        let result = try await rig.sync(rig.deviceB)
        #expect(result.uploaded == 1)
        let back = try await rig.sync(rig.deviceA)
        #expect(back.downloaded == 1)
        #expect(rig.read("note.md", on: rig.deviceA) == "edited after delete")
    }

    @Test func simultaneousEditsKeepBothAsConflictCopy() async throws {
        let rig = try Rig()
        try rig.write("base", to: "note.md", on: rig.deviceA)
        try await rig.sync(rig.deviceA)
        try await rig.sync(rig.deviceB)
        try rig.write("a version", to: "note.md", on: rig.deviceA)
        try rig.write("b version", to: "note.md", on: rig.deviceB)
        try await rig.sync(rig.deviceA)
        let result = try await rig.sync(rig.deviceB)
        #expect(result.conflicts == 1)
        #expect(rig.read("note.md", on: rig.deviceB) == "b version")
        let names = try FileManager.default.contentsOfDirectory(atPath: rig.deviceB.path)
        let conflictName = names.first { $0.contains("(conflict") }
        #expect(conflictName != nil)
        #expect(rig.read(conflictName!, on: rig.deviceB) == "a version")
        // The next pass carries both the winner and the copy back to device A.
        let back = try await rig.sync(rig.deviceA)
        #expect(back.downloaded == 2)
        #expect(rig.read("note.md", on: rig.deviceA) == "b version")
    }

    @Test func identicalContentAdoptsWithoutConflict() async throws {
        let rig = try Rig()
        try rig.write("same words", to: "note.md", on: rig.deviceA)
        try rig.write("same words", to: "note.md", on: rig.deviceB)
        try await rig.sync(rig.deviceA)
        let result = try await rig.sync(rig.deviceB)
        #expect(result.conflicts == 0)
        #expect(result.downloaded == 0)
        #expect(result.uploaded == 0)
    }

    @Test func assetsInFoldersRoundTrip() async throws {
        let rig = try Rig()
        try rig.write("binary-ish", to: "assets/pic.png", on: rig.deviceA)
        try rig.write("nested", to: "work/plan.md", on: rig.deviceA)
        try await rig.sync(rig.deviceA)
        let result = try await rig.sync(rig.deviceB)
        #expect(result.downloaded == 2)
        #expect(rig.read("assets/pic.png", on: rig.deviceB) == "binary-ish")
        #expect(rig.read("work/plan.md", on: rig.deviceB) == "nested")
    }

    @Test func remoteHoldsOnlyCiphertextAndOpaqueNames() async throws {
        let rig = try Rig()
        try rig.write("secret plans", to: "Secret Plans.md", on: rig.deviceA)
        try await rig.sync(rig.deviceA)
        let objects = rig.remote.base
            .appendingPathComponent("Skerry Sync")
            .appendingPathComponent("objects")
        let names = try FileManager.default.contentsOfDirectory(atPath: objects.path)
        #expect(names.count == 1)
        #expect(!names[0].contains("Secret"))
        let blob = try Data(contentsOf: objects.appendingPathComponent(names[0]))
        #expect(!String(decoding: blob, as: UTF8.self).contains("secret plans"))
    }

    @Test func wrongKeyIsRefused() async throws {
        let rig = try Rig()
        try rig.write("mine", to: "note.md", on: rig.deviceA)
        try await rig.sync(rig.deviceA)
        await #expect(throws: SyncEngine.SyncError.wrongKey) {
            _ = try await SyncEngine.sync(
                library: rig.deviceB, remote: rig.remote, key: SymmetricKey(size: .bits256)
            )
        }
    }

    @Test func keyfileUploadsAndFetches() async throws {
        let rig = try Rig()
        let keyfileBytes = Data("{\"fake\":\"keyfile\"}".utf8)
        _ = try await SyncEngine.sync(
            library: rig.deviceA, remote: rig.remote, key: rig.key, keyfile: keyfileBytes
        )
        let fetched = try await SyncEngine.fetchKeyfile(remote: rig.remote)
        #expect(fetched == keyfileBytes)
    }

    @Test func hiddenAndCacheEntriesStayLocal() async throws {
        let rig = try Rig()
        try rig.write("cache", to: ".skerry/index.db", on: rig.deviceA)
        try rig.write("trashed", to: ".trash/old.md", on: rig.deviceA)
        try rig.write("real", to: "real.md", on: rig.deviceA)
        let result = try await rig.sync(rig.deviceA)
        #expect(result.uploaded == 1)
    }
}
