import CryptoKit
import Foundation
import Testing

@testable import SkerryKit

@Suite struct SyncMergeTests {
    /// Two libraries and a shared folder remote.
    private struct Rig {
        let deviceA: URL
        let deviceB: URL
        let remote: FolderSyncRemote
        let key = SymmetricKey(size: .bits256)

        init() throws {
            deviceA = try SyncDrive.makeLibrary()
            deviceB = try SyncDrive.makeLibrary()
            remote = FolderSyncRemote(base: try SyncDrive.makeLibrary())
        }

        @discardableResult
        func sync(_ device: URL) async throws -> SyncEngine.Result {
            try await SyncEngine.sync(library: device, remote: remote, key: key)
        }

        /// File names at a device's root.
        func names(on device: URL) throws -> [String] {
            try FileManager.default.contentsOfDirectory(atPath: device.path)
        }
    }

    @Test func disjointSimultaneousEditsMergeWithoutCopies() async throws {
        let rig = try Rig()
        let base = "# Plan\n\nfirst paragraph\n\nsecond paragraph\n"
        try SyncDrive.write(base, to: "plan.md", in: rig.deviceA)
        try await rig.sync(rig.deviceA)
        try await rig.sync(rig.deviceB)

        try SyncDrive.write(
            "# Plan\n\nfirst paragraph edited on A\n\nsecond paragraph\n",
            to: "plan.md", in: rig.deviceA
        )
        try SyncDrive.write(
            "# Plan\n\nfirst paragraph\n\nsecond paragraph edited on B\n",
            to: "plan.md", in: rig.deviceB
        )
        try await rig.sync(rig.deviceA)
        let merged = try await rig.sync(rig.deviceB)
        #expect(merged.merged == 1)
        #expect(merged.conflicts == 0)
        let back = try await rig.sync(rig.deviceA)
        #expect(back.conflicts == 0)

        let expected = "# Plan\n\nfirst paragraph edited on A\n\nsecond paragraph edited on B\n"
        #expect(SyncDrive.read("plan.md", in: rig.deviceA) == expected)
        #expect(SyncDrive.read("plan.md", in: rig.deviceB) == expected)
        #expect(!(try rig.names(on: rig.deviceA)).contains { $0.contains("(conflict") })
        #expect(!(try rig.names(on: rig.deviceB)).contains { $0.contains("(conflict") })
    }

    @Test func overlappingEditsStillKeepBothCopies() async throws {
        let rig = try Rig()
        try SyncDrive.write("only line\n", to: "note.md", in: rig.deviceA)
        try await rig.sync(rig.deviceA)
        try await rig.sync(rig.deviceB)

        try SyncDrive.write("A rewrote this\n", to: "note.md", in: rig.deviceA)
        try SyncDrive.write("B rewrote this\n", to: "note.md", in: rig.deviceB)
        try await rig.sync(rig.deviceA)
        let result = try await rig.sync(rig.deviceB)
        #expect(result.conflicts == 1)
        #expect(result.merged == 0)
        #expect((try rig.names(on: rig.deviceB)).contains { $0.contains("(conflict") })
    }

    @Test func withoutAStoredBaseTheCopyPathStillApplies() async throws {
        let rig = try Rig()
        try SyncDrive.write("shared\n", to: "note.md", in: rig.deviceA)
        try await rig.sync(rig.deviceA)
        try await rig.sync(rig.deviceB)
        // Simulate a device upgraded mid-flight: its merge base vanishes.
        try? FileManager.default.removeItem(
            at: rig.deviceB
                .appendingPathComponent(".skerry")
                .appendingPathComponent("sync-base")
        )
        try SyncDrive.write("shared\nA extra\n", to: "note.md", in: rig.deviceA)
        try SyncDrive.write("shared\nB extra\n", to: "note.md", in: rig.deviceB)
        try await rig.sync(rig.deviceA)
        let result = try await rig.sync(rig.deviceB)
        #expect(result.merged == 0)
        #expect(result.conflicts == 1)
    }

    @Test func nonTextFilesNeverMerge() async throws {
        let rig = try Rig()
        try SyncDrive.write("binaryish", to: "assets/blob.png", in: rig.deviceA)
        try await rig.sync(rig.deviceA)
        try await rig.sync(rig.deviceB)
        try SyncDrive.write("binaryish A", to: "assets/blob.png", in: rig.deviceA)
        try SyncDrive.write("binaryish B", to: "assets/blob.png", in: rig.deviceB)
        try await rig.sync(rig.deviceA)
        let result = try await rig.sync(rig.deviceB)
        #expect(result.merged == 0)
        #expect(result.conflicts == 1)
    }

    @Test func mergedTextSurvivesFurtherRounds() async throws {
        let rig = try Rig()
        try SyncDrive.write("a\nb\nc\n", to: "note.md", in: rig.deviceA)
        try await rig.sync(rig.deviceA)
        try await rig.sync(rig.deviceB)
        try SyncDrive.write("a edited\nb\nc\n", to: "note.md", in: rig.deviceA)
        try SyncDrive.write("a\nb\nc edited\n", to: "note.md", in: rig.deviceB)
        try await rig.sync(rig.deviceA)
        _ = try await rig.sync(rig.deviceB)
        _ = try await rig.sync(rig.deviceA)
        // A quiet extra round proves the merge settled.
        let settleA = try await rig.sync(rig.deviceA)
        let settleB = try await rig.sync(rig.deviceB)
        #expect(settleA.isQuiet)
        #expect(settleB.isQuiet)
        #expect(
            SyncDrive.read("note.md", in: rig.deviceA)
                == SyncDrive.read("note.md", in: rig.deviceB)
        )
    }
}
