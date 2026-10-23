import Foundation
import Testing

@testable import SkerryKit

@Suite struct EncryptedBackupTests {
    /// Builds a throwaway directory for one test.
    private func makeDir() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("skerry-encbackup-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func sealAndRestoreRoundTrips() throws {
        let library = try makeDir()
        let destination = try makeDir()
        let restored = try makeDir()
        defer {
            for url in [library, destination, restored] {
                try? FileManager.default.removeItem(at: url)
            }
        }
        try "hello body".write(
            to: library.appendingPathComponent("a.md"), atomically: true, encoding: .utf8
        )
        try FileManager.default.createDirectory(
            at: library.appendingPathComponent("sub"), withIntermediateDirectories: true
        )
        try "nested".write(
            to: library.appendingPathComponent("sub/b.md"), atomically: true, encoding: .utf8
        )
        try FileManager.default.createDirectory(
            at: library.appendingPathComponent(".skerry"), withIntermediateDirectories: true
        )
        try "cache".write(
            to: library.appendingPathComponent(".skerry/index.db"), atomically: true, encoding: .utf8
        )

        let file = try EncryptedBackup.seal(
            library: library, to: destination,
            named: EncryptedBackup.name(for: Date(timeIntervalSince1970: 1_700_000_000)),
            passphrase: "correct horse battery"
        )

        // The sealed file is ciphertext: the note body never appears in it.
        let raw = try Data(contentsOf: file)
        #expect(!String(decoding: raw, as: UTF8.self).contains("hello body"))

        try EncryptedBackup.restore(file, into: restored, passphrase: "correct horse battery")
        #expect(try String(contentsOf: restored.appendingPathComponent("a.md")) == "hello body")
        #expect(try String(contentsOf: restored.appendingPathComponent("sub/b.md")) == "nested")
        // The rebuildable cache is left out of the backup.
        #expect(!FileManager.default.fileExists(atPath: restored.appendingPathComponent(".skerry").path))
    }

    @Test func sealedDataRoundTripsWithoutAFile() throws {
        let library = try makeDir()
        let restored = try makeDir()
        defer {
            try? FileManager.default.removeItem(at: library)
            try? FileManager.default.removeItem(at: restored)
        }
        try "over the wire".write(
            to: library.appendingPathComponent("n.md"), atomically: true, encoding: .utf8
        )
        let sealed = try EncryptedBackup.sealedData(of: library, passphrase: "k")
        #expect(!String(decoding: sealed, as: UTF8.self).contains("over the wire"))
        try EncryptedBackup.restore(from: sealed, into: restored, passphrase: "k")
        #expect(try String(contentsOf: restored.appendingPathComponent("n.md")) == "over the wire")
    }

    @Test func wrongPassphraseCannotRestore() throws {
        let library = try makeDir()
        let destination = try makeDir()
        let out = try makeDir()
        defer {
            for url in [library, destination, out] {
                try? FileManager.default.removeItem(at: url)
            }
        }
        try "secret".write(
            to: library.appendingPathComponent("n.md"), atomically: true, encoding: .utf8
        )
        let file = try EncryptedBackup.seal(
            library: library, to: destination, named: "snap", passphrase: "right"
        )
        #expect(throws: NoteCrypto.CryptoError.self) {
            try EncryptedBackup.restore(file, into: out, passphrase: "wrong")
        }
    }

    @Test func snapshotsSortedAndPruneKeepsNewest() throws {
        let library = try makeDir()
        let destination = try makeDir()
        defer {
            try? FileManager.default.removeItem(at: library)
            try? FileManager.default.removeItem(at: destination)
        }
        try "x".write(
            to: library.appendingPathComponent("n.md"), atomically: true, encoding: .utf8
        )
        var names: [String] = []
        for seconds in [1_000, 2_000, 3_000] {
            let name = EncryptedBackup.name(for: Date(timeIntervalSince1970: TimeInterval(seconds)))
            names.append(name)
            try EncryptedBackup.seal(
                library: library, to: destination, named: name, passphrase: "k"
            )
        }
        #expect(EncryptedBackup.snapshots(in: destination).map(\.name) == names.reversed())
        let removed = try EncryptedBackup.prune(in: destination, keeping: 2)
        #expect(removed == 1)
        #expect(EncryptedBackup.snapshots(in: destination).count == 2)
    }
}
