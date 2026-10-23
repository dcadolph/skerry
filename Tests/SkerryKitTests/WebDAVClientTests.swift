import Foundation
import Testing

@testable import SkerryKit

@Suite struct WebDAVClientTests {
    @Test func parsesEntriesAndCollectionFlag() {
        let xml = """
        <?xml version="1.0" encoding="utf-8"?>
        <D:multistatus xmlns:D="DAV:">
          <D:response>
            <D:href>/dav/skerry/Skerry%20Encrypted%20Backups/</D:href>
            <D:propstat><D:prop><D:resourcetype><D:collection/></D:resourcetype></D:prop>
            <D:status>HTTP/1.1 200 OK</D:status></D:propstat>
          </D:response>
          <D:response>
            <D:href>/dav/skerry/Skerry%20Encrypted%20Backups/2026-07-14T12_00_00.000Z.skerrybackup</D:href>
            <D:propstat><D:prop><D:resourcetype/></D:prop>
            <D:status>HTTP/1.1 200 OK</D:status></D:propstat>
          </D:response>
        </D:multistatus>
        """
        let entries = WebDAVClient.parsePropfind(Data(xml.utf8))
        #expect(entries.count == 2)
        #expect(entries[0] == WebDAVClient.Entry(name: "Skerry Encrypted Backups", isCollection: true))
        #expect(
            entries[1] == WebDAVClient.Entry(
                name: "2026-07-14T12_00_00.000Z.skerrybackup", isCollection: false
            )
        )
    }

    @Test func toleratesLowercaseNamespacePrefix() {
        let xml = """
        <?xml version="1.0"?>
        <d:multistatus xmlns:d="DAV:">
          <d:response><d:href>/x/note.skerrybackup</d:href>
          <d:propstat><d:prop><d:resourcetype/></d:prop></d:propstat></d:response>
        </d:multistatus>
        """
        let entries = WebDAVClient.parsePropfind(Data(xml.utf8))
        #expect(entries == [WebDAVClient.Entry(name: "note.skerrybackup", isCollection: false)])
    }
}
