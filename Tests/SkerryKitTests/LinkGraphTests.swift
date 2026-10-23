import Foundation
import Testing

@testable import SkerryKit

@Suite struct LinkGraphTests {
    @Test func updateAndLookupRoundTrip() {
        var graph = LinkGraph()
        graph.update(path: "a.md", body: "see [[Harbor Plan]] and [[Boats]]")
        graph.update(path: "b.md", body: "also [[harbor plan]]")
        #expect(graph.sources(linkingTo: ["Harbor Plan"]) == ["a.md", "b.md"])
        #expect(graph.sources(linkingTo: ["Boats"]) == ["a.md"])
        #expect(graph.sources(linkingTo: ["Nothing"]).isEmpty)
    }

    @Test func editReplacesOutgoingLinks() {
        var graph = LinkGraph()
        graph.update(path: "a.md", body: "[[One]]")
        graph.update(path: "a.md", body: "[[Two]]")
        #expect(graph.sources(linkingTo: ["One"]).isEmpty)
        #expect(graph.sources(linkingTo: ["Two"]) == ["a.md"])
    }

    @Test func removeAndMoveKeepTheReverseIndexConsistent() {
        var graph = LinkGraph()
        graph.update(path: "a.md", body: "[[Target]]")
        graph.move(from: "a.md", to: "renamed.md")
        #expect(graph.sources(linkingTo: ["Target"]) == ["renamed.md"])
        graph.remove(path: "renamed.md")
        #expect(graph.sources(linkingTo: ["Target"]).isEmpty)
    }

    @Test func namesLookupIsCaseInsensitiveBothWays() {
        var graph = LinkGraph()
        graph.update(path: "a.md", body: "[[MiXeD Case]]")
        #expect(graph.sources(linkingTo: ["mixed case"]) == ["a.md"])
        #expect(graph.sources(linkingTo: ["MIXED CASE"]) == ["a.md"])
    }

    @Test func linksInsideCodeDoNotCount() {
        var graph = LinkGraph()
        graph.update(path: "a.md", body: "```\n[[Not A Link]]\n```\nreal [[Yes]]")
        #expect(graph.sources(linkingTo: ["Not A Link"]).isEmpty)
        #expect(graph.sources(linkingTo: ["Yes"]) == ["a.md"])
    }

    @Test func lookupByMultipleNamesUnions() {
        var graph = LinkGraph()
        graph.update(path: "byStem.md", body: "[[note-stem]]")
        graph.update(path: "byTitle.md", body: "[[The Title]]")
        let sources = graph.sources(linkingTo: ["note-stem", "The Title"])
        #expect(sources == ["byStem.md", "byTitle.md"])
    }
}
