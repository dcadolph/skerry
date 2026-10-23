import Foundation
import Testing

@testable import SkerryKit

@Suite struct TextMergeTests {
    @Test func disjointEditsBothApply() {
        let base = "# Title\n\nfirst paragraph\n\nsecond paragraph\n"
        let mine = "# Title\n\nfirst paragraph edited\n\nsecond paragraph\n"
        let theirs = "# Title\n\nfirst paragraph\n\nsecond paragraph edited\n"
        let outcome = TextMerge.merge(base: base, mine: mine, theirs: theirs)
        #expect(outcome.conflicts == 0)
        #expect(outcome.merged == "# Title\n\nfirst paragraph edited\n\nsecond paragraph edited\n")
    }

    @Test func mergeIsSymmetric() {
        let base = "alpha\nbeta\ngamma\ndelta\n"
        let mine = "alpha changed\nbeta\ngamma\ndelta\n"
        let theirs = "alpha\nbeta\ngamma\ndelta changed\n"
        let forward = TextMerge.merge(base: base, mine: mine, theirs: theirs)
        let reversed = TextMerge.merge(base: base, mine: theirs, theirs: mine)
        #expect(forward.conflicts == 0)
        #expect(forward.merged == reversed.merged)
    }

    @Test func sameLineEditedDifferentlyConflicts() {
        let base = "shared line\n"
        let outcome = TextMerge.merge(
            base: base, mine: "my version\n", theirs: "their version\n"
        )
        #expect(outcome.conflicts == 1)
    }

    @Test func identicalEditsOnBothSidesMergeOnce() {
        let base = "one\ntwo\nthree\n"
        let both = "one\ntwo changed\nthree\n"
        let outcome = TextMerge.merge(base: base, mine: both, theirs: both)
        #expect(outcome.conflicts == 0)
        #expect(outcome.merged == both)
    }

    @Test func appendsAtTheEndKeepBothSymmetrically() {
        let base = "log\n"
        let mine = "log\nmine added this\n"
        let theirs = "log\ntheirs added this\n"
        let forward = TextMerge.merge(base: base, mine: mine, theirs: theirs)
        let reversed = TextMerge.merge(base: base, mine: theirs, theirs: mine)
        #expect(forward.conflicts == 0)
        #expect(forward.merged == reversed.merged)
        #expect(forward.merged.contains("mine added this"))
        #expect(forward.merged.contains("theirs added this"))
    }

    @Test func oneSideUnchangedTakesTheOther() {
        let base = "text\n"
        let theirs = "text rewritten\n"
        let outcome = TextMerge.merge(base: base, mine: base, theirs: theirs)
        #expect(outcome.conflicts == 0)
        #expect(outcome.merged == theirs)
    }

    @Test func deletionAndDistantEditBothApply() {
        let base = "keep\nremove me\nkeep too\nedit me\n"
        let mine = "keep\nkeep too\nedit me\n"
        let theirs = "keep\nremove me\nkeep too\nedited\n"
        let outcome = TextMerge.merge(base: base, mine: mine, theirs: theirs)
        #expect(outcome.conflicts == 0)
        #expect(outcome.merged == "keep\nkeep too\nedited\n")
    }

    @Test func insertionAgainstOverlappingEditConflicts() {
        let base = "a\nb\nc\n"
        let mine = "a\ninserted\nb\nc\n"
        let theirs = "a\nb changed\nc\n"
        let outcome = TextMerge.merge(base: base, mine: mine, theirs: theirs)
        #expect(outcome.conflicts == 1)
    }

    @Test func convergenceAfterOneSideMerges() {
        // Device A merges first and uploads; device B then merges its own version
        // against A's merge result and must land on the same text.
        let base = "top\nmiddle\nbottom\n"
        let deviceA = "top A\nmiddle\nbottom\n"
        let deviceB = "top\nmiddle\nbottom B\n"
        let firstMerge = TextMerge.merge(base: base, mine: deviceA, theirs: deviceB)
        #expect(firstMerge.conflicts == 0)
        let second = TextMerge.merge(base: base, mine: deviceB, theirs: firstMerge.merged)
        #expect(second.conflicts == 0)
        #expect(second.merged == firstMerge.merged)
    }

    @Test func oversizedInputsPuntToConflict() {
        let big = Array(repeating: "line", count: 5000).joined(separator: "\n")
        let outcome = TextMerge.merge(base: big, mine: big + "\nx", theirs: big + "\ny")
        #expect(outcome.conflicts == 1)
    }
}
