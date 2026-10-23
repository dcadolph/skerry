import Foundation
import Testing

@testable import SkerryKit

@Suite struct InlineTagTests {
    /// Covered text of every tag token in a text.
    private func tagSpans(_ text: String) -> [String] {
        let ns = text as NSString
        return MarkdownScanner.scan(text)
            .filter { $0.kind == .tag }
            .map { ns.substring(with: $0.range) }
    }

    @Test func plainAndNestedTagsTokenize() {
        #expect(tagSpans("work on #skerry today\n") == ["#skerry"])
        #expect(tagSpans("#work/clients/acme is nested\n") == ["#work/clients/acme"])
        #expect(tagSpans("#one and #two-three\n") == ["#one", "#two-three"])
    }

    @Test func headingsAndBareHashesAreNotTags() {
        #expect(tagSpans("# Heading\n").isEmpty)
        #expect(tagSpans("just a # alone\n").isEmpty)
        #expect(tagSpans("a##b and ## rules\n").isEmpty)
        #expect(tagSpans("mid#word does not tag\n").isEmpty)
    }

    @Test func punctuationEndsATag() {
        #expect(tagSpans("ship #skerry.\n") == ["#skerry"])
        #expect(tagSpans("(#skerry)\n") == ["#skerry"])
        #expect(tagSpans("#skerry, #boat!\n") == ["#skerry", "#boat"])
    }

    @Test func trailingSeparatorsStayOutOfTheTag() {
        #expect(tagSpans("#work/ and on\n") == ["#work"])
        #expect(tagSpans("#a-b- c\n") == ["#a-b"])
    }

    @Test func codeNeverTags() {
        #expect(tagSpans("`#not-a-tag` in code\n").isEmpty)
        #expect(tagSpans("```\n#also-not\n```\n").isEmpty)
    }

    @Test func inlineTagsDedupeCaseInsensitively() {
        let tags = MarkdownScanner.inlineTags(in: "#Work then #work then #WORK and #other")
        #expect(tags == ["Work", "other"])
    }

    @Test func unicodeTagsWork() {
        #expect(tagSpans("about #færøerne trip\n") == ["#færøerne"])
        #expect(MarkdownScanner.inlineTags(in: "#日記 today") == ["日記"])
    }

    @Test func tagsInsideTablesCount() {
        let tags = MarkdownScanner.inlineTags(in: "| #project | note |\n| --- | --- |")
        #expect(tags == ["project"])
    }
}
