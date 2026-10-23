import Foundation
import Testing

@testable import SkerryKit

@Suite struct S3ClientTests {
    @Test func signatureMatchesAWSPublishedExample() {
        // From AWS's documented S3 GET Object SigV4 example, whose signature is published.
        let headers = S3Client.signingHeaders(
            method: "GET",
            url: URL(string: "https://examplebucket.s3.amazonaws.com/test.txt")!,
            extraHeaders: ["range": "bytes=0-9"],
            payloadHash: S3Client.emptyPayloadHash,
            accessKey: "AKIAIOSFODNN7EXAMPLE",
            secret: "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
            region: "us-east-1",
            date: Date(timeIntervalSince1970: 1_369_353_600)
        )
        #expect(headers["x-amz-date"] == "20130524T000000Z")
        #expect(
            headers["Authorization"]?.contains(
                "Signature=f0e8bdb87c964420e857bd35b5d6ed310bd44f0170aba48dd91039c6036bdb41"
            ) == true
        )
    }

    @Test func parsesListBucketKeys() {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <ListBucketResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
          <Name>bucket</Name><Prefix>skerry/</Prefix>
          <Contents><Key>skerry/2026-07-14T12_00_00.000Z.skerrybackup</Key>
            <Size>1024</Size></Contents>
          <Contents><Key>skerry/2026-07-14T13_00_00.000Z.skerrybackup</Key>
            <Size>2048</Size></Contents>
        </ListBucketResult>
        """
        let keys = S3Client.parseKeys(Data(xml.utf8))
        #expect(keys == [
            "skerry/2026-07-14T12_00_00.000Z.skerrybackup",
            "skerry/2026-07-14T13_00_00.000Z.skerrybackup",
        ])
    }

    @Test func parsesTruncationMarkers() {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <ListBucketResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
          <Contents><Key>a</Key></Contents>
          <Contents><Key>b</Key></Contents>
          <IsTruncated>true</IsTruncated>
          <NextContinuationToken>tok-123</NextContinuationToken>
        </ListBucketResult>
        """
        let result = S3Client.parseList(Data(xml.utf8))
        #expect(result.keys == ["a", "b"])
        #expect(result.isTruncated)
        #expect(result.nextToken == "tok-123")
    }

    @Test func uriEncodeFollowsRFC3986() {
        #expect(S3Client.uriEncode("a b/c") == "a%20b%2Fc")
        #expect(S3Client.uriEncodePath("/bucket/a b") == "/bucket/a%20b")
        #expect(S3Client.uriEncode("keep-._~") == "keep-._~")
    }
}
