import CryptoKit
import Foundation
import Testing

@testable import SkerryKit

@Suite struct ImporterTests {
    /// A tiny ENEX document with one note carrying a tag, dates, ENML content, and one
    /// image resource referenced by hash.
    private func makeENEX(imageData: Data) -> Data {
        let base64 = imageData.base64EncodedString()
        let hash = Insecure.MD5.hash(data: imageData)
            .map { String(format: "%02x", $0) }
            .joined()
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <en-export export-date="20240101T120000Z" application="Evernote">
        <note>
        <title>Ferry Timetable</title>
        <content><![CDATA[<?xml version="1.0"?><en-note><div>Check the <b>morning</b> ferry.</div><div><en-media hash="\(hash)" type="image/png"/></div></en-note>]]></content>
        <created>20240101T090000Z</created>
        <updated>20240102T100000Z</updated>
        <tag>travel</tag>
        <tag>scotland</tag>
        <resource>
        <data encoding="base64">\(base64)</data>
        <mime>image/png</mime>
        <resource-attributes><file-name>timetable.png</file-name></resource-attributes>
        </resource>
        </note>
        </en-export>
        """
        return Data(xml.utf8)
    }

    @Test func enexNoteConvertsWithTagsDatesAndAttachment() {
        let image = Data([0x89, 0x50, 0x4E, 0x47, 1, 2, 3, 4])
        let results = NoteImporter.importENEX(makeENEX(imageData: image))
        #expect(results.count == 1)
        let item = results[0]
        #expect(item.imported.name == "Ferry Timetable")
        #expect(item.imported.note.metadata.title == "Ferry Timetable")
        #expect(item.imported.note.metadata.tags.contains("travel"))
        #expect(item.imported.note.metadata.tags.contains("scotland"))
        #expect(item.imported.note.metadata.created != nil)
        #expect(item.imported.note.metadata.updated != nil)
        #expect(item.imported.note.body.contains("Check the **morning** ferry."))

        #expect(item.attachments.count == 1)
        let attachment = item.attachments[0]
        #expect(attachment.preferredName == "timetable.png")
        #expect(attachment.data == image)
        // The body references the resource through its hash placeholder as an image.
        #expect(item.imported.note.body.contains("![](skerry-enex://\(attachment.hash))"))
    }

    @Test func enexWithoutResourcesStillImports() {
        let xml = """
        <en-export><note><title>Plain</title>
        <content><![CDATA[<en-note><div>Just words.</div></en-note>]]></content>
        </note></en-export>
        """
        let results = NoteImporter.importENEX(Data(xml.utf8))
        #expect(results.count == 1)
        #expect(results[0].imported.note.body == "Just words.")
        #expect(results[0].attachments.isEmpty)
    }

    @Test func dayOneEntriesImportWithDatesAndTags() {
        let json = """
        {"metadata":{"version":"1.0"},"entries":[
          {"text":"# Harbor morning\\n\\nCold and clear.","creationDate":"2024-03-01T08:00:00Z",
           "modifiedDate":"2024-03-01T09:30:00Z","tags":["weather","harbor"]},
          {"text":"Second entry with no title line.","creationDate":"2024-03-02T08:00:00Z"}
        ]}
        """
        let entries = NoteImporter.importDayOne(Data(json.utf8))
        #expect(entries.count == 2)
        #expect(entries[0].name == "Harbor morning")
        #expect(entries[0].note.metadata.tags == ["weather", "harbor"])
        #expect(entries[0].note.metadata.created != nil)
        #expect(entries[0].note.metadata.updated != nil)
        // A headingless entry names itself by its date, journal style.
        #expect(entries[1].name == "Journal 2024-03-02")
    }

    @Test func dayOneDetectionIsConservative() {
        #expect(NoteImporter.looksLikeDayOne(Data(#"{"entries":[{"text":"x"}]}"#.utf8)))
        #expect(!NoteImporter.looksLikeDayOne(Data(#"{"notes":[]}"#.utf8)))
        #expect(!NoteImporter.looksLikeDayOne(Data("not json".utf8)))
        #expect(!NoteImporter.looksLikeDayOne(Data(#"{"entries":"nope"}"#.utf8)))
    }

    @Test func emptyDayOneEntriesAreSkipped() {
        let json = #"{"entries":[{"text":"  \n "},{"text":"real"}]}"#
        let entries = NoteImporter.importDayOne(Data(json.utf8))
        #expect(entries.count == 1)
        #expect(entries[0].note.body == "real")
    }
}
