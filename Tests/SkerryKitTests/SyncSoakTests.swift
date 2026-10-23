import CryptoKit
import Foundation
import Testing

@testable import SkerryKit

/// Whether the opt-in soak suites run; they need the rclone binary and real sockets.
private let soakEnabled = ProcessInfo.processInfo.environment["SKERRY_SOAK"] == "1"

/// RcloneServer runs one rclone serve subprocess for a test and stops it after.
///
/// rclone's WebDAV and S3 servers are independent third-party implementations, so these
/// suites prove the sync engine against software that behaves like real NAS firmware
/// rather than against our own test doubles.
private final class RcloneServer {
    /// The running rclone process.
    private let process: Process
    /// Root directory the server exposes.
    let root: URL
    /// Port the server listens on.
    let port: Int

    /// Absolute path of the rclone binary, from the environment or common installs.
    static var binary: String? {
        if let custom = ProcessInfo.processInfo.environment["SKERRY_RCLONE"] { return custom }
        return ["/opt/homebrew/bin/rclone", "/usr/local/bin/rclone"]
            .first { FileManager.default.fileExists(atPath: $0) }
    }

    /// Launches `rclone serve` for a mode and waits until the port answers.
    init(mode: [String], port: Int) throws {
        guard let binary = Self.binary else {
            throw SoakError.missingRclone
        }
        self.port = port
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("skerry-soak-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = ["serve"] + mode + [root.path, "--addr", "127.0.0.1:\(port)"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
    }

    /// Polls until the server answers HTTP, up to a deadline.
    func waitUntilReady() async throws {
        let url = URL(string: "http://127.0.0.1:\(port)/")!
        for _ in 0..<100 {
            do {
                let (_, response) = try await URLSession.shared.data(from: url)
                if response is HTTPURLResponse { return }
            } catch {
                try await Task.sleep(nanoseconds: 100_000_000)
            }
        }
        throw SoakError.serverNeverAnswered
    }

    /// Stops the server and removes its directory.
    func stop() {
        process.terminate()
        process.waitUntilExit()
        try? FileManager.default.removeItem(at: root)
    }

    /// Failures setting up the soak environment.
    enum SoakError: Error {
        /// rclone is not installed; brew install rclone, or set SKERRY_RCLONE.
        case missingRclone
        /// The served port never answered within the deadline.
        case serverNeverAnswered
    }
}

/// SeededRandom is a tiny deterministic generator so soak runs reproduce exactly.
private struct SeededRandom {
    /// Generator state.
    var state: UInt64

    /// Next raw value.
    mutating func next() -> UInt64 {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return state
    }

    /// Uniform value in 0..<bound.
    mutating func below(_ bound: Int) -> Int {
        Int(next() % UInt64(bound))
    }
}

/// Marker planted in every soak note body; finding it in a remote file means plaintext
/// leaked to storage that must only ever hold ciphertext.
private let sentinel = "SKERRYSOAKSENTINEL"

@Suite(.enabled(if: soakEnabled), .serialized) struct SyncSoakTests {
    @Test func rcloneWebDAVSpeaksTheFullStory() async throws {
        let server = try RcloneServer(
            mode: ["webdav", "--user", "skerry", "--pass", "soak-password"], port: 42_611
        )
        defer { server.stop() }
        try await server.waitUntilReady()
        let config = WebDAVClient.Config(
            baseURL: URL(string: "http://127.0.0.1:\(server.port)/")!,
            username: "skerry", password: "soak-password"
        )
        try await SyncDrive.runTwoDeviceStory(over: WebDAVSyncRemote(config: config))
    }

    @Test func rcloneS3SpeaksTheFullStory() async throws {
        let server = try RcloneServer(
            mode: ["s3", "--auth-key", "soakaccess,soaksecret"], port: 42_612
        )
        defer { server.stop() }
        try FileManager.default.createDirectory(
            at: server.root.appendingPathComponent("skerrybucket"),
            withIntermediateDirectories: true
        )
        try await server.waitUntilReady()
        let config = S3Client.Config(
            endpoint: URL(string: "http://127.0.0.1:\(server.port)")!,
            region: "us-east-1", bucket: "skerrybucket",
            accessKeyID: "soakaccess", secretAccessKey: "soaksecret"
        )
        try await SyncDrive.runTwoDeviceStory(over: S3SyncRemote(config: config))
    }

    @Test func webDAVChurnConvergesAndLeaksNothing() async throws {
        let server = try RcloneServer(
            mode: ["webdav", "--user", "skerry", "--pass", "soak-password"], port: 42_613
        )
        defer { server.stop() }
        try await server.waitUntilReady()
        let config = WebDAVClient.Config(
            baseURL: URL(string: "http://127.0.0.1:\(server.port)/")!,
            username: "skerry", password: "soak-password"
        )
        try await churn(over: WebDAVSyncRemote(config: config), seed: 7, rounds: 12)
        try assertNoPlaintext(under: server.root)
    }

    @Test func s3ChurnConvergesAndLeaksNothing() async throws {
        let server = try RcloneServer(
            mode: ["s3", "--auth-key", "soakaccess,soaksecret"], port: 42_614
        )
        defer { server.stop() }
        try FileManager.default.createDirectory(
            at: server.root.appendingPathComponent("skerrybucket"),
            withIntermediateDirectories: true
        )
        try await server.waitUntilReady()
        let config = S3Client.Config(
            endpoint: URL(string: "http://127.0.0.1:\(server.port)")!,
            region: "us-east-1", bucket: "skerrybucket",
            accessKeyID: "soakaccess", secretAccessKey: "soaksecret"
        )
        try await churn(over: S3SyncRemote(config: config), seed: 11, rounds: 8)
        try assertNoPlaintext(under: server.root)
    }

    /// Rounds of randomized concurrent edits on two devices, synced after every round,
    /// ending in quiet rounds that must converge to identical trees with no residue.
    private func churn(over remote: some SyncRemote, seed: UInt64, rounds: Int) async throws {
        let key = SymmetricKey(size: .bits256)
        let deviceA = try SyncDrive.makeLibrary()
        let deviceB = try SyncDrive.makeLibrary()
        var random = SeededRandom(state: seed)

        try SyncDrive.write(note(body: "first paragraph\n\nlast paragraph"),
            to: "Note 0.md", in: deviceA)
        _ = try await SyncEngine.sync(library: deviceA, remote: remote, key: key)
        _ = try await SyncEngine.sync(library: deviceB, remote: remote, key: key)

        for round in 1...rounds {
            for (label, device) in [("A", deviceA), ("B", deviceB)] {
                try mutate(
                    device, label: label, round: round, random: &random,
                    mergeFriendly: label == "A"
                )
            }
            _ = try await SyncEngine.sync(library: deviceA, remote: remote, key: key)
            _ = try await SyncEngine.sync(library: deviceB, remote: remote, key: key)
            _ = try await SyncEngine.sync(library: deviceA, remote: remote, key: key)
        }

        // Quiet rounds: with no new edits, both devices settle into identical trees.
        for _ in 0..<2 {
            let quietA = try await SyncEngine.sync(library: deviceA, remote: remote, key: key)
            let quietB = try await SyncEngine.sync(library: deviceB, remote: remote, key: key)
            _ = quietA
            _ = quietB
        }
        let finalA = try await SyncEngine.sync(library: deviceA, remote: remote, key: key)
        let finalB = try await SyncEngine.sync(library: deviceB, remote: remote, key: key)
        #expect(finalA.isQuiet, "device A still churning after quiet rounds: \(finalA)")
        #expect(finalB.isQuiet, "device B still churning after quiet rounds: \(finalB)")
        let treeA = try tree(of: deviceA)
        let treeB = try tree(of: deviceB)
        if treeA != treeB {
            let onlyA = Set(treeA.keys).subtracting(treeB.keys).sorted()
            let onlyB = Set(treeB.keys).subtracting(treeA.keys).sorted()
            let differing = treeA.keys
                .filter { treeB[$0] != nil && treeB[$0] != treeA[$0] }.sorted()
            print("SOAK DIVERGENCE onlyA=\(onlyA) onlyB=\(onlyB) differing=\(differing)")
        }
        #expect(treeA == treeB)
    }

    /// One device's randomized round: edits, creations, deletions, and binary blobs.
    private func mutate(
        _ device: URL, label: String, round: Int, random: inout SeededRandom,
        mergeFriendly: Bool
    ) throws {
        switch random.below(6) {
        case 0, 1:
            // Edit a shared note at one end, so simultaneous edits usually merge.
            let existing = SyncDrive.read("Note 0.md", in: device) ?? note(body: "seed")
            let edited = mergeFriendly
                ? "edited by \(label) round \(round)\n\n" + existing
                : existing + "\n\nedited by \(label) round \(round)"
            try SyncDrive.write(edited, to: "Note 0.md", in: device)
        case 2, 3:
            try SyncDrive.write(
                note(body: "fresh from \(label) round \(round)"),
                to: "\(label) Round \(round).md", in: device
            )
        case 4:
            var bytes = Data(count: 2048)
            for index in bytes.indices { bytes[index] = UInt8(random.below(256)) }
            try bytes.write(
                to: device.appendingPathComponent("blob \(label) \(round).bin")
            )
        default:
            let names = (try? FileManager.default.contentsOfDirectory(atPath: device.path))
                ?? []
            if let victim = names.first(where: {
                $0.hasSuffix(".md") && $0 != "Note 0.md" && !$0.contains("(conflict")
            }) {
                try? FileManager.default.removeItem(
                    at: device.appendingPathComponent(victim)
                )
            }
        }
    }

    /// A soak note body carrying the plaintext sentinel.
    private func note(body: String) -> String {
        "# Soak\n\n\(sentinel)\n\n\(body)\n"
    }

    /// Relative path to content hash for every visible file in a library. Symlinks are
    /// resolved on both sides so the /private alias of the temp directory cannot skew
    /// the relative paths and sneak device-local .skerry files into the comparison.
    private func tree(of library: URL) throws -> [String: String] {
        var result: [String: String] = [:]
        let root = library.resolvingSymlinksInPath().path
        let enumerator = FileManager.default.enumerator(
            at: library, includingPropertiesForKeys: [.isRegularFileKey]
        )
        while let entry = enumerator?.nextObject() as? URL {
            let full = entry.resolvingSymlinksInPath().path
            guard full.hasPrefix(root + "/") else { continue }
            let relative = String(full.dropFirst(root.count + 1))
            guard !relative.hasPrefix(".skerry") else { continue }
            guard (try? entry.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile
                == true
            else { continue }
            let digest = SHA256.hash(data: try Data(contentsOf: entry))
            result[relative] = digest.map { String(format: "%02x", $0) }.joined()
        }
        return result
    }

    /// Scans every file the server holds; the sentinel appearing anywhere means note
    /// plaintext reached storage that must only ever hold ciphertext.
    private func assertNoPlaintext(under root: URL) throws {
        let marker = Data(sentinel.utf8)
        let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.isRegularFileKey]
        )
        while let entry = enumerator?.nextObject() as? URL {
            guard (try? entry.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile
                == true
            else { continue }
            let bytes = try Data(contentsOf: entry)
            #expect(bytes.range(of: marker) == nil, "plaintext leaked into \(entry.path)")
        }
    }
}

@Suite(.enabled(if: soakEnabled)) struct PerfBaselineTests {
    @Test func tenThousandNotesLoadAndSearchInsideBudgets() throws {
        let library = try SyncDrive.makeLibrary()
        for index in 0..<10_000 {
            let folder = "Folder \(index % 40)"
            try SyncDrive.write(
                "# Note \(index)\n\nParagraph about harbor \(index) and puffins.\n\n"
                    + "Second paragraph with tide tables and rope inventory number \(index).\n",
                to: "\(folder)/Note \(index).md", in: library
            )
        }

        let store = try NoteStore(root: library)
        let loadStart = ContinuousClock.now
        let paths = try store.notePaths()
        var loaded = 0
        for path in paths {
            _ = try store.load(path)
            loaded += 1
        }
        let loadTime = ContinuousClock.now - loadStart
        #expect(loaded == 10_000)

        let indexStart = ContinuousClock.now
        let index = try NoteIndex(libraryRoot: library)
        for path in paths {
            try index.upsert(try store.load(path))
        }
        let indexTime = ContinuousClock.now - indexStart

        let searchStart = ContinuousClock.now
        let hits = try index.search("tide tables")
        let searchTime = ContinuousClock.now - searchStart

        print("PERF load=\(loadTime) index=\(indexTime) search=\(searchTime) hits=\(hits.count)")
        #expect(loadTime < .seconds(10), "10k-note load took \(loadTime)")
        #expect(indexTime < .seconds(30), "10k-note index build took \(indexTime)")
        #expect(searchTime < .milliseconds(250), "search took \(searchTime)")
        #expect(!hits.isEmpty)
    }
}
