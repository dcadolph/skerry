import Foundation
import Testing

@testable import SkerryKit

@Suite struct VersionStoreTests {
    /// A store over a fresh temporary library root.
    private func makeStore(
        limit: Int = 50, coalesce: TimeInterval = 600
    ) throws -> (VersionStore, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("skerry-versions-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return (VersionStore(libraryRoot: root, limit: limit, coalesceInterval: coalesce), root)
    }

    @Test func recordAndReadBackVersions() throws {
        let (store, _) = try makeStore()
        let early = Date(timeIntervalSince1970: 1_000_000)
        try store.record(path: "a.md", text: "one", at: early, coalescing: false)
        try store.record(path: "a.md", text: "two", at: early.addingTimeInterval(1000))
        let versions = store.versions(for: "a.md")
        #expect(versions.count == 2)
        #expect(try store.text(of: versions[0]) == "two")
        #expect(try store.text(of: versions[1]) == "one")
    }

    @Test func identicalTextRecordsNothing() throws {
        let (store, _) = try makeStore()
        try store.record(path: "a.md", text: "same")
        try store.record(path: "a.md", text: "same")
        #expect(store.versions(for: "a.md").count == 1)
    }

    @Test func rapidSavesCoalesceIntoOneVersion() throws {
        let (store, _) = try makeStore(coalesce: 600)
        let start = Date(timeIntervalSince1970: 2_000_000)
        try store.record(path: "a.md", text: "draft one", at: start)
        try store.record(path: "a.md", text: "draft two", at: start.addingTimeInterval(30))
        let versions = store.versions(for: "a.md")
        #expect(versions.count == 1)
        #expect(try store.text(of: versions[0]) == "draft two")
    }

    @Test func savesPastTheWindowKeepBothVersions() throws {
        let (store, _) = try makeStore(coalesce: 600)
        let start = Date(timeIntervalSince1970: 3_000_000)
        try store.record(path: "a.md", text: "morning", at: start)
        try store.record(path: "a.md", text: "evening", at: start.addingTimeInterval(3600))
        #expect(store.versions(for: "a.md").count == 2)
    }

    @Test func oldestVersionsPruneBeyondLimit() throws {
        let (store, _) = try makeStore(limit: 3)
        let start = Date(timeIntervalSince1970: 4_000_000)
        for step in 0..<5 {
            try store.record(
                path: "a.md", text: "v\(step)",
                at: start.addingTimeInterval(Double(step) * 1000), coalescing: false
            )
        }
        let versions = store.versions(for: "a.md")
        #expect(versions.count == 3)
        #expect(try store.text(of: versions[0]) == "v4")
        #expect(try store.text(of: versions[2]) == "v2")
    }

    @Test func moveCarriesHistoryToTheNewPath() throws {
        let (store, _) = try makeStore()
        try store.record(path: "old.md", text: "content")
        store.move(from: "old.md", to: "new.md")
        #expect(store.versions(for: "old.md").isEmpty)
        #expect(store.versions(for: "new.md").count == 1)
    }

    @Test func removeAllDropsEveryVersion() throws {
        let (store, _) = try makeStore()
        try store.record(path: "a.md", text: "content")
        store.removeAll(for: "a.md")
        #expect(store.versions(for: "a.md").isEmpty)
    }

    @Test func pathsDoNotCollide() throws {
        let (store, _) = try makeStore()
        try store.record(path: "a.md", text: "for a")
        try store.record(path: "b.md", text: "for b")
        #expect(try store.text(of: store.versions(for: "a.md")[0]) == "for a")
        #expect(try store.text(of: store.versions(for: "b.md")[0]) == "for b")
    }
}
