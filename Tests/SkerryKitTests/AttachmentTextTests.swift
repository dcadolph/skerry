import CoreGraphics
import CoreText
import Foundation
import Testing

@testable import SkerryKit

@Suite struct AttachmentTextTests {
    /// Draws one line of text into a fresh PDF and returns its bytes.
    private func makePDF(text: String) -> Data {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 400, height: 200)
        let consumer = CGDataConsumer(data: data as CFMutableData)!
        let context = CGContext(consumer: consumer, mediaBox: &box, nil)!
        context.beginPDFPage(nil)
        let attributed = NSAttributedString(
            string: text,
            attributes: [.font: CTFontCreateWithName("Helvetica" as CFString, 18, nil)]
        )
        let line = CTLineCreateWithAttributedString(attributed)
        context.textPosition = CGPoint(x: 20, y: 100)
        CTLineDraw(line, context)
        context.endPDFPage()
        context.closePDF()
        return data as Data
    }

    @Test func pdfTextExtracts() {
        let pdf = makePDF(text: "quarterly harbor report")
        let text = AttachmentText.extract(from: pdf, fileExtension: "pdf")
        #expect(text?.contains("harbor") == true)
    }

    @Test func plainTextExtractsAndUnknownTypesDoNot() {
        let text = AttachmentText.extract(from: Data("boat manifest".utf8), fileExtension: "txt")
        #expect(text == "boat manifest")
        #expect(AttachmentText.extract(from: Data([0, 1, 2]), fileExtension: "zip") == nil)
    }

    @Test func cacheExtractsOnceAndInvalidatesOnChange() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("skerry-cache-\(UUID().uuidString)")
        let assets = root.appendingPathComponent("assets")
        try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
        let file = assets.appendingPathComponent("note.txt")
        try Data("first content".utf8).write(to: file)

        var cache = AttachmentTextCache(libraryRoot: root)
        #expect(cache.text(for: file) == "first content")
        cache.save()

        // A reloaded cache serves the stored text for an unchanged file.
        var reloaded = AttachmentTextCache(libraryRoot: root)
        #expect(reloaded.text(for: file) == "first content")

        // A rewrite with a different size re-extracts.
        try Data("second content longer".utf8).write(to: file)
        #expect(reloaded.text(for: file) == "second content longer")
    }

    @Test func cacheSkipsSealedAttachments() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("skerry-cache-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let sealed = root.appendingPathComponent("photo.png.skbox")
        try Data("ciphertext".utf8).write(to: sealed)
        var cache = AttachmentTextCache(libraryRoot: root)
        #expect(cache.text(for: sealed) == nil)
    }

    @Test func indexSearchesExtras() throws {
        let index = try NoteIndex(databasePath: ":memory:")
        var note = Note()
        note.metadata.title = "Receipts"
        note.body = "see attachment"
        try index.upsert(
            StoredNote(path: "receipts.md", note: note), extras: "ferry ticket 42 dollars"
        )
        let hits = try index.search("ferry ticket")
        #expect(hits.map(\.path) == ["receipts.md"])
    }
}
