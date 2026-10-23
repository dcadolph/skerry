import Foundation
import Testing

@testable import SkerryKit

@Suite struct SearchScopeTests {
    @Test func allScopeContainsEverything() {
        #expect(SearchScope.all.contains(path: "anything.md", tags: []))
        #expect(SearchScope.all.contains(path: "Work/deep/note.md", tags: ["x"]))
    }

    @Test func folderScopeMatchesDirectAndNestedChildren() {
        let scope = SearchScope.folder("Work")
        #expect(scope.contains(path: "Work/note.md", tags: []))
        #expect(scope.contains(path: "Work/Sub/note.md", tags: []))
    }

    @Test func folderScopeRejectsSiblingPrefixAndRoot() {
        let scope = SearchScope.folder("Work")
        // A sibling folder sharing the name prefix must not match.
        #expect(!scope.contains(path: "WorkStuff/note.md", tags: []))
        // A note at the library root is outside any folder.
        #expect(!scope.contains(path: "note.md", tags: []))
    }

    @Test func tagScopeMatchesExactAndDescendantTags() {
        let scope = SearchScope.tag("work")
        #expect(scope.contains(path: "note.md", tags: ["work"]))
        #expect(scope.contains(path: "note.md", tags: ["work/urgent"]))
        #expect(scope.contains(path: "note.md", tags: ["personal", "work/urgent/today"]))
    }

    @Test func tagScopeIgnoresCase() {
        let scope = SearchScope.tag("Work")
        #expect(scope.contains(path: "note.md", tags: ["WORK"]))
        #expect(scope.contains(path: "note.md", tags: ["work/URGENT"]))
    }

    @Test func tagScopeRejectsSiblingPrefixAndAbsence() {
        let scope = SearchScope.tag("work")
        // A tag that merely starts with the same letters is not a descendant.
        #expect(!scope.contains(path: "note.md", tags: ["workflow"]))
        #expect(!scope.contains(path: "note.md", tags: ["personal"]))
        #expect(!scope.contains(path: "note.md", tags: []))
    }
}
