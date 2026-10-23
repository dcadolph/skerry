import Foundation
import Testing

@testable import SkerryKit

@Suite struct MarkdownFootnotesTests {
    @Test func nextLabelCountsPastHighestNumber() {
        #expect(MarkdownFootnotes.nextLabel(in: "no footnotes") == "1")
        #expect(MarkdownFootnotes.nextLabel(in: "a[^1] b[^3]\n\n[^1]: one") == "4")
        #expect(MarkdownFootnotes.nextLabel(in: "named[^note] only") == "1")
    }

    @Test func insertEditAddsReferenceAndDefinition() {
        let (text, caret) = MarkdownFootnotes.insertEdit(text: "claim here", caret: 5)
        #expect(text == "claim[^1] here\n\n[^1]: ")
        #expect(caret == (text as NSString).length)
    }

    @Test func insertEditNumbersPastExisting() {
        let (text, _) = MarkdownFootnotes.insertEdit(text: "a[^1]\n\n[^1]: one\n", caret: 5)
        #expect(text.contains("[^2]"))
        #expect(text.hasSuffix("[^2]: "))
    }

    @Test func scannerEmitsFootnoteTokens() {
        let text = "claim[^1] more\n\n[^1]: the source\n"
        let tokens = MarkdownScanner.scan(text)
        let refs = tokens.filter { $0.kind == .footnoteReference }
        let defs = tokens.filter { $0.kind == .footnoteDefinition }
        #expect(refs.count == 1)
        #expect(defs.count == 1)
        #expect((text as NSString).substring(with: refs[0].range) == "[^1]")
        #expect((text as NSString).substring(with: defs[0].range) == "[^1]:")
    }

    @Test func htmlRendersFootnotes() {
        let html = MarkdownHTML.fragment("claim[^1]\n\n[^1]: the source")
        #expect(html.contains("<sup><a href=\"#fn-1\" id=\"fnref-1\">1</a></sup>"))
        #expect(html.contains("<li id=\"fn-1\">the source <a href=\"#fnref-1\">&#8617;</a></li>"))
        #expect(!html.contains("[^1]:"))
    }

    @Test func htmlLeavesUndefinedReferencesLiteral() {
        let html = MarkdownHTML.fragment("claim[^missing]")
        #expect(html.contains("[^missing]"))
        #expect(!html.contains("<sup>"))
    }

    @Test func htmlNumbersFootnotesByFirstUse() {
        let html = MarkdownHTML.fragment("b[^beta] a[^alpha]\n\n[^alpha]: A\n[^beta]: B")
        #expect(html.contains("id=\"fnref-beta\">1</a>"))
        #expect(html.contains("id=\"fnref-alpha\">2</a>"))
        let betaIndex = html.range(of: "<li id=\"fn-beta\">")!.lowerBound
        let alphaIndex = html.range(of: "<li id=\"fn-alpha\">")!.lowerBound
        #expect(betaIndex < alphaIndex)
    }
}
