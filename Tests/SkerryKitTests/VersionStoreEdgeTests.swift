import CryptoKit
import Foundation
import Testing

@testable import SkerryKit

@Suite struct VersionStoreEdgeTests {
    /// A store over a fresh temporary library root.
    private func makeStore(
        limit: Int = 50, coalesce: TimeInterval = 600
    ) throws -> VersionStore {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("skerry-versions-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return VersionStore(libraryRoot: root, limit: limit, coalesceInterval: coalesce)
    }

    @Test func sameTimestampGetsACollisionSuffixAndStillParses() throws {
        let store = try makeStore()
        let moment = Date(timeIntervalSince1970: 5_000_000)
        try store.record(path: "a.md", text: "one", at: moment, coalescing: false)
        try store.record(path: "a.md", text: "two", at: moment, coalescing: false)
        let versions = store.versions(for: "a.md")
        #expect(versions.count == 2)
        #expect(Set(versions.map(\.name)).count == 2)
        #expect(versions.allSatisfy { $0.date == moment })
        let texts = Set(try versions.map { try store.text(of: $0) })
        #expect(texts == ["one", "two"])
    }

    @Test func sealedEnvelopeTextRoundTripsVerbatim() throws {
        let store = try makeStore()
        let key = SymmetricKey(size: .bits256)
        var note = Note()
        note.metadata.id = UUID()
        note.metadata.title = "hidden"
        note.body = "hidden body"
        let envelope = try EncryptedNote.seal(note, key: key)
        let fileText = FrontMatter.serializeNote(envelope)

        try store.record(path: "sealed.md", text: fileText)
        let stored = try store.text(of: store.versions(for: "sealed.md")[0])
        #expect(stored == fileText)
        // The stored version stays ciphertext and still unseals to the original.
        #expect(!stored.contains("hidden body"))
        let reopened = try EncryptedNote.unseal(FrontMatter.parseNote(stored), key: key)
        #expect(reopened.body == "hidden body")
    }

    @Test func limitOfOneKeepsOnlyTheNewest() throws {
        let store = try makeStore(limit: 1)
        let start = Date(timeIntervalSince1970: 6_000_000)
        try store.record(path: "a.md", text: "first", at: start, coalescing: false)
        try store.record(
            path: "a.md", text: "second", at: start.addingTimeInterval(1000), coalescing: false
        )
        let versions = store.versions(for: "a.md")
        #expect(versions.count == 1)
        #expect(try store.text(of: versions[0]) == "second")
    }

    @Test func moveIntoExistingHistoryMergesBothSets() throws {
        let store = try makeStore()
        let start = Date(timeIntervalSince1970: 7_000_000)
        try store.record(path: "old.md", text: "from old", at: start, coalescing: false)
        try store.record(
            path: "new.md", text: "from new", at: start.addingTimeInterval(1000), coalescing: false
        )
        store.move(from: "old.md", to: "new.md")
        let versions = store.versions(for: "new.md")
        #expect(versions.count == 2)
        #expect(store.versions(for: "old.md").isEmpty)
    }

    @Test func emptyTextIsARecordableState() throws {
        let store = try makeStore()
        let start = Date(timeIntervalSince1970: 8_000_000)
        try store.record(path: "a.md", text: "words", at: start, coalescing: false)
        try store.record(path: "a.md", text: "", at: start.addingTimeInterval(1000), coalescing: false)
        let versions = store.versions(for: "a.md")
        #expect(versions.count == 2)
        #expect(try store.text(of: versions[0]) == "")
    }

    @Test func recordingIntoAMissingCacheFolderCreatesIt() throws {
        // The .skerry cache may have been deleted between saves; recording recreates it.
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("skerry-versions-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = VersionStore(libraryRoot: root)
        try store.record(path: "a.md", text: "content")
        try FileManager.default.removeItem(at: root.appendingPathComponent(".skerry"))
        try store.record(path: "a.md", text: "after wipe")
        #expect(store.versions(for: "a.md").count == 1)
        #expect(try store.text(of: store.versions(for: "a.md")[0]) == "after wipe")
    }
}
