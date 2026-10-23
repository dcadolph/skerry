import CryptoKit
import Foundation
import Testing

@testable import SkerryKit

/// Shared helpers for driving the full sync engine over any remote.
enum SyncDrive {
    /// Creates a fresh library folder.
    static func makeLibrary() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("skerry-lib-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Writes a library file.
    static func write(_ text: String, to path: String, in library: URL) throws {
        let url = library.appendingPathComponent(path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Reads a library file, nil when missing.
    static func read(_ path: String, in library: URL) -> String? {
        try? String(contentsOf: library.appendingPathComponent(path), encoding: .utf8)
    }

    /// Runs the standard two-device story over a remote: create, edit back, delete, and a
    /// conflict, asserting convergence at every step. This is the same scenario as the
    /// folder-remote suite, so every backend proves the same behavior.
    static func runTwoDeviceStory(over remote: some SyncRemote) async throws {
        let key = SymmetricKey(size: .bits256)
        let deviceA = try makeLibrary()
        let deviceB = try makeLibrary()

        // Create on A, arrive on B.
        try write("# Plan\n\nbuy rope", to: "Harbor Plan.md", in: deviceA)
        try write("cache", to: ".skerry/index.db", in: deviceA)
        let up = try await SyncEngine.sync(library: deviceA, remote: remote, key: key)
        #expect(up.uploaded == 1)
        let down = try await SyncEngine.sync(library: deviceB, remote: remote, key: key)
        #expect(down.downloaded == 1)
        #expect(read("Harbor Plan.md", in: deviceB) == "# Plan\n\nbuy rope")

        // Edit on B, flow back to A.
        try write("# Plan\n\nbuy rope and tar", to: "Harbor Plan.md", in: deviceB)
        _ = try await SyncEngine.sync(library: deviceB, remote: remote, key: key)
        let back = try await SyncEngine.sync(library: deviceA, remote: remote, key: key)
        #expect(back.downloaded == 1)
        #expect(read("Harbor Plan.md", in: deviceA) == "# Plan\n\nbuy rope and tar")

        // Simultaneous edits keep both copies.
        try write("a says", to: "Harbor Plan.md", in: deviceA)
        try write("b says", to: "Harbor Plan.md", in: deviceB)
        _ = try await SyncEngine.sync(library: deviceA, remote: remote, key: key)
        let conflicted = try await SyncEngine.sync(library: deviceB, remote: remote, key: key)
        #expect(conflicted.conflicts == 1)
        _ = try await SyncEngine.sync(library: deviceA, remote: remote, key: key)
        let namesA = try FileManager.default.contentsOfDirectory(atPath: deviceA.path)
        #expect(namesA.contains { $0.contains("(conflict") })
        #expect(read("Harbor Plan.md", in: deviceA) == "b says")

        // Delete on A, honored on B.
        try FileManager.default.removeItem(at: deviceA.appendingPathComponent("Harbor Plan.md"))
        _ = try await SyncEngine.sync(library: deviceA, remote: remote, key: key)
        let removal = try await SyncEngine.sync(library: deviceB, remote: remote, key: key)
        #expect(removal.deletedLocal == 1)
        #expect(read("Harbor Plan.md", in: deviceB) == nil)
    }
}

@Suite struct WebDAVServerIntegrationTests {
    /// A client pointed at a fresh local server.
    private func makeRig() throws -> (server: TestWebDAVServer, client: WebDAVClient) {
        let server = try TestWebDAVServer()
        let client = WebDAVClient(
            config: WebDAVClient.Config(
                baseURL: server.baseURL, username: server.username, password: server.password
            )
        )
        return (server, client)
    }

    @Test func clientOperationsAgainstRealServer() async throws {
        let (server, client) = try makeRig()
        defer { server.stop() }

        try await client.check()
        try await client.makeCollection("Skerry Backups")
        // Creating it again answers success, the idempotence the client relies on.
        try await client.makeCollection("Skerry Backups")

        let payload = Data("sealed backup bytes".utf8)
        try await client.upload(payload, to: "Skerry Backups/snap one.skerrybackup")
        let fetched = try await client.download("Skerry Backups/snap one.skerrybackup")
        #expect(fetched == payload)

        let entries = try await client.list("Skerry Backups")
        #expect(entries.contains { $0.name == "snap one.skerrybackup" && !$0.isCollection })

        try await client.delete("Skerry Backups/snap one.skerrybackup")
        await #expect(throws: WebDAVClient.WebDAVError.status(404)) {
            _ = try await client.download("Skerry Backups/snap one.skerrybackup")
        }
    }

    @Test func wrongPasswordIsRefused() async throws {
        let (server, _) = try makeRig()
        defer { server.stop() }
        let intruder = WebDAVClient(
            config: WebDAVClient.Config(
                baseURL: server.baseURL, username: server.username, password: "wrong"
            )
        )
        await #expect(throws: WebDAVClient.WebDAVError.status(401)) {
            try await intruder.check()
        }
    }

    @Test func putIntoMissingCollectionIsRefusedAndRemoteCreatesParents() async throws {
        let (server, client) = try makeRig()
        defer { server.stop() }
        // The raw client hits a strict server: no parent collection, no upload.
        await #expect(throws: WebDAVClient.WebDAVError.status(409)) {
            try await client.upload(Data("x".utf8), to: "missing/collection/file.bin")
        }
        // The sync remote creates every parent on the way in.
        let remote = WebDAVSyncRemote(
            config: WebDAVClient.Config(
                baseURL: server.baseURL, username: server.username, password: server.password
            )
        )
        try await remote.upload(Data("y".utf8), to: "deep/nested/path/file.bin")
        #expect(try await remote.download("deep/nested/path/file.bin") == Data("y".utf8))
        #expect(try await remote.download("deep/nested/path/absent.bin") == nil)
        try await remote.delete("deep/nested/path/file.bin")
        try await remote.delete("deep/nested/path/file.bin")
    }

    @Test func syncEngineConvergesOverWebDAV() async throws {
        let (server, _) = try makeRig()
        defer { server.stop() }
        let remote = WebDAVSyncRemote(
            config: WebDAVClient.Config(
                baseURL: server.baseURL, username: server.username, password: server.password
            )
        )
        try await SyncDrive.runTwoDeviceStory(over: remote)
    }

    @Test func unicodeAndSpacedNamesRoundTripOverWebDAV() async throws {
        let (server, _) = try makeRig()
        defer { server.stop() }
        let remote = WebDAVSyncRemote(
            config: WebDAVClient.Config(
                baseURL: server.baseURL, username: server.username, password: server.password
            )
        )
        let key = SymmetricKey(size: .bits256)
        let deviceA = try SyncDrive.makeLibrary()
        let deviceB = try SyncDrive.makeLibrary()
        try SyncDrive.write("fisk", to: "Færøerne notes 🐟.md", in: deviceA)
        try SyncDrive.write("nested", to: "Trip Ideas/São Miguel.md", in: deviceA)
        _ = try await SyncEngine.sync(library: deviceA, remote: remote, key: key)
        let result = try await SyncEngine.sync(library: deviceB, remote: remote, key: key)
        #expect(result.downloaded == 2)
        #expect(SyncDrive.read("Færøerne notes 🐟.md", in: deviceB) == "fisk")
        #expect(SyncDrive.read("Trip Ideas/São Miguel.md", in: deviceB) == "nested")
    }

    @Test func conditionalCreateIsExclusiveOverWebDAV() async throws {
        let (server, _) = try makeRig()
        defer { server.stop() }
        let remote = WebDAVSyncRemote(
            config: WebDAVClient.Config(
                baseURL: server.baseURL, username: server.username, password: server.password
            )
        )
        let first = try await remote.createExclusive(Data("mine".utf8), at: "Skerry Sync/lock")
        let second = try await remote.createExclusive(Data("theirs".utf8), at: "Skerry Sync/lock")
        #expect(first)
        #expect(!second)
        // The refused second create leaves the first writer's bytes untouched.
        #expect(try await remote.download("Skerry Sync/lock") == Data("mine".utf8))
    }
}

@Suite struct S3ServerIntegrationTests {
    /// A client pointed at a fresh local signature-verifying server.
    private func makeRig() throws -> (server: TestS3Server, client: S3Client) {
        let server = try TestS3Server()
        let client = S3Client(config: config(for: server))
        return (server, client)
    }

    /// Client configuration matching a server's expectations.
    private func config(for server: TestS3Server, secret: String? = nil) -> S3Client.Config {
        S3Client.Config(
            endpoint: server.endpoint, region: server.region, bucket: server.bucket,
            accessKeyID: server.accessKey, secretAccessKey: secret ?? server.secret
        )
    }

    @Test func clientOperationsPassSignatureVerification() async throws {
        let (server, client) = try makeRig()
        defer { server.stop() }

        try await client.check()
        let payload = Data("sealed snapshot".utf8)
        try await client.putObject(key: "skerry/2026-07-19.skerrybackup", data: payload)
        let fetched = try await client.getObject(key: "skerry/2026-07-19.skerrybackup")
        #expect(fetched == payload)

        try await client.putObject(key: "other/ignored.bin", data: Data("x".utf8))
        let listed = try await client.listObjects(prefix: "skerry/")
        #expect(listed == ["skerry/2026-07-19.skerrybackup"])

        try await client.deleteObject(key: "skerry/2026-07-19.skerrybackup")
        await #expect(throws: S3Client.S3Error.status(404)) {
            _ = try await client.getObject(key: "skerry/2026-07-19.skerrybackup")
        }
    }

    @Test func listObjectsFollowsContinuationTokensPastAPage() async throws {
        let (server, client) = try makeRig()
        defer { server.stop() }
        server.listPageSize = 2

        let keys = (0..<5).map { "skerry/2026-07-19T00_0\($0)_00.skerrybackup" }
        for key in keys {
            try await client.putObject(key: key, data: Data(key.utf8))
        }
        // Five keys over a two-key page means the client must follow two continuation tokens to
        // see them all; a single-page client would stop at the first two.
        let listed = try await client.listObjects(prefix: "skerry/")
        #expect(listed == keys.sorted())
    }

    @Test func wrongSecretFailsTheSignatureCheck() async throws {
        let (server, _) = try makeRig()
        defer { server.stop() }
        let intruder = S3Client(config: config(for: server, secret: "not-the-secret"))
        await #expect(throws: S3Client.S3Error.status(403)) {
            try await intruder.putObject(key: "skerry/x", data: Data("x".utf8))
        }
    }

    @Test func syncEngineConvergesOverS3() async throws {
        let (server, _) = try makeRig()
        defer { server.stop() }
        let remote = S3SyncRemote(config: config(for: server))
        try await SyncDrive.runTwoDeviceStory(over: remote)
    }

    @Test func syncObjectsLandUnderOpaqueKeys() async throws {
        let (server, _) = try makeRig()
        defer { server.stop() }
        let remote = S3SyncRemote(config: config(for: server))
        let key = SymmetricKey(size: .bits256)
        let library = try SyncDrive.makeLibrary()
        try SyncDrive.write("secret plans", to: "Secret Plans.md", in: library)
        _ = try await SyncEngine.sync(library: library, remote: remote, key: key)
        let keys = server.storedKeys()
        #expect(keys.contains("Skerry Sync/manifest.skmanifest"))
        #expect(!keys.contains { $0.contains("Secret") })
    }

    @Test func conditionalCreateIsExclusiveOverS3() async throws {
        let (server, _) = try makeRig()
        defer { server.stop() }
        let remote = S3SyncRemote(config: config(for: server))
        let first = try await remote.createExclusive(Data("mine".utf8), at: "Skerry Sync/lock")
        let second = try await remote.createExclusive(Data("theirs".utf8), at: "Skerry Sync/lock")
        #expect(first)
        #expect(!second)
        // The refused second create leaves the first writer's bytes untouched.
        #expect(try await remote.download("Skerry Sync/lock") == Data("mine".utf8))
    }
}
