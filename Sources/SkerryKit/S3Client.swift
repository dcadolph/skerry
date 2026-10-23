import CryptoKit
import Foundation

/// S3Client backs Skerry up to any S3-compatible object store: Backblaze B2, Wasabi, iDrive
/// e2, or AWS itself. It speaks the S3 REST API with AWS Signature Version 4 and path-style
/// URLs, which every S3-compatible service accepts. Bodies are already-sealed backup bytes, so
/// the bucket only ever holds ciphertext.
public struct S3Client: Sendable {
    /// Connection settings for an S3-compatible bucket.
    public struct Config: Sendable, Equatable {
        /// Service endpoint, for example `https://s3.us-west-002.backblazeb2.com`.
        public var endpoint: URL
        /// Region label the service expects, for example `us-west-002`.
        public var region: String
        /// Bucket name.
        public var bucket: String
        /// Access key id.
        public var accessKeyID: String
        /// Secret access key.
        public var secretAccessKey: String

        /// Creates a configuration.
        public init(
            endpoint: URL, region: String, bucket: String,
            accessKeyID: String, secretAccessKey: String
        ) {
            self.endpoint = endpoint
            self.region = region
            self.bucket = bucket
            self.accessKeyID = accessKeyID
            self.secretAccessKey = secretAccessKey
        }
    }

    /// Errors raised by S3 operations.
    public enum S3Error: Error, Equatable {
        /// The server returned a status outside the success range.
        case status(Int)
        /// The response was not HTTP.
        case invalidResponse
    }

    /// SHA-256 of an empty body, used for requests without a payload.
    static let emptyPayloadHash =
        "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"

    /// Connection settings.
    public let config: Config
    /// URL session used for requests.
    private let session: URLSession

    /// Creates a client over a configuration, defaulting to the shared session.
    public init(config: Config, session: URLSession = .shared) {
        self.config = config
        self.session = session
    }

    /// Verifies the credentials and bucket by listing with an empty prefix.
    public func check() async throws {
        _ = try await listObjects(prefix: "")
    }

    /// Uploads bytes to an object key, replacing any existing object.
    public func putObject(key: String, data: Data) async throws {
        let request = signedRequest(
            method: "PUT", key: key, payload: data, payloadHash: Self.hexSHA256(data)
        )
        let (_, response) = try await session.upload(for: request, from: data)
        try Self.expectSuccess(response)
    }

    /// Uploads bytes to an object key only when the key is absent, using a conditional write.
    /// Returns true when this call created the object and false when it already existed. Not
    /// every S3-compatible service honors If-None-Match, so a live check confirms it per provider.
    public func putObjectExclusive(key: String, data: Data) async throws -> Bool {
        let request = signedRequest(
            method: "PUT", key: key, payload: data, payloadHash: Self.hexSHA256(data),
            extraHeaders: ["If-None-Match": "*"]
        )
        let (_, response) = try await session.upload(for: request, from: data)
        guard let http = response as? HTTPURLResponse else { throw S3Error.invalidResponse }
        if http.statusCode == 412 { return false }
        try Self.expectSuccess(response)
        return true
    }

    /// Downloads the bytes of an object key.
    public func getObject(key: String) async throws -> Data {
        let request = signedRequest(method: "GET", key: key)
        let (data, response) = try await session.data(for: request)
        try Self.expectSuccess(response)
        return data
    }

    /// Deletes an object key.
    public func deleteObject(key: String) async throws {
        let request = signedRequest(method: "DELETE", key: key)
        let (_, response) = try await session.data(for: request)
        try Self.expectSuccess(response)
    }

    /// Lists object keys under a prefix, following continuation tokens so the result is complete
    /// past the 1000-key limit S3 places on a single response. A truncated page with no next token
    /// ends the loop rather than repeating forever.
    public func listObjects(prefix: String) async throws -> [String] {
        var keys: [String] = []
        var continuationToken: String?
        repeat {
            var query = [
                URLQueryItem(name: "list-type", value: "2"),
                URLQueryItem(name: "prefix", value: prefix),
            ]
            if let token = continuationToken {
                query.append(URLQueryItem(name: "continuation-token", value: token))
            }
            let request = signedRequest(method: "GET", key: "", query: query, isBucketLevel: true)
            let (data, response) = try await session.data(for: request)
            try Self.expectSuccess(response)
            let page = Self.parseList(data)
            keys.append(contentsOf: page.keys)
            continuationToken = page.isTruncated ? page.nextToken : nil
        } while continuationToken != nil
        return keys
    }

    /// Builds a signed request for an object key or a bucket-level query.
    private func signedRequest(
        method: String, key: String, query: [URLQueryItem] = [],
        payload: Data? = nil, payloadHash: String? = nil, isBucketLevel: Bool = false,
        extraHeaders: [String: String] = [:]
    ) -> URLRequest {
        var components = URLComponents(url: config.endpoint, resolvingAgainstBaseURL: false)!
        var path = "/" + config.bucket
        if !isBucketLevel, !key.isEmpty { path += "/" + key }
        components.percentEncodedPath = Self.uriEncodePath(path)
        if !query.isEmpty { components.queryItems = query }
        let url = components.url!
        let hash = payloadHash ?? Self.emptyPayloadHash
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = payload
        for (field, value) in Self.signingHeaders(
            method: method, url: url, extraHeaders: extraHeaders, payloadHash: hash,
            accessKey: config.accessKeyID, secret: config.secretAccessKey,
            region: config.region, date: Date()
        ) {
            request.setValue(value, forHTTPHeaderField: field)
        }
        return request
    }

    /// Computes the headers that authorize a request under AWS Signature Version 4.
    ///
    /// Exposed within the module so it can be checked against AWS's published example. Callers
    /// set every returned header on the request.
    static func signingHeaders(
        method: String, url: URL, extraHeaders: [String: String] = [:], payloadHash: String,
        accessKey: String, secret: String, region: String, date: Date
    ) -> [String: String] {
        let amzDate = format(date, "yyyyMMdd'T'HHmmss'Z'")
        let dateStamp = format(date, "yyyyMMdd")
        var host = url.host() ?? ""
        if let port = url.port { host += ":\(port)" }

        var headers = extraHeaders.reduce(into: [String: String]()) { $0[$1.key.lowercased()] = $1.value }
        headers["host"] = host
        headers["x-amz-date"] = amzDate
        headers["x-amz-content-sha256"] = payloadHash

        let sortedNames = headers.keys.sorted()
        let canonicalHeaders = sortedNames
            .map { "\($0):\(headers[$0]!.trimmingCharacters(in: .whitespaces))\n" }
            .joined()
        let signedHeaders = sortedNames.joined(separator: ";")

        let rawPath = url.path(percentEncoded: false)
        let canonicalURI = rawPath.isEmpty ? "/" : uriEncodePath(rawPath)
        let canonicalQuery = canonicalQueryString(url)
        let canonicalRequest = [
            method, canonicalURI, canonicalQuery, canonicalHeaders, signedHeaders, payloadHash,
        ].joined(separator: "\n")

        let scope = "\(dateStamp)/\(region)/s3/aws4_request"
        let stringToSign = [
            "AWS4-HMAC-SHA256", amzDate, scope, hexSHA256(Data(canonicalRequest.utf8)),
        ].joined(separator: "\n")

        let signingKey = deriveSigningKey(secret: secret, dateStamp: dateStamp, region: region)
        let signature = hmac(signingKey, Data(stringToSign.utf8))
            .map { String(format: "%02x", $0) }.joined()

        let authorization = "AWS4-HMAC-SHA256 "
            + "Credential=\(accessKey)/\(scope), "
            + "SignedHeaders=\(signedHeaders), Signature=\(signature)"

        var result = extraHeaders
        result["Authorization"] = authorization
        result["x-amz-date"] = amzDate
        result["x-amz-content-sha256"] = payloadHash
        return result
    }

    /// Derives the SigV4 signing key through the dated HMAC chain.
    private static func deriveSigningKey(secret: String, dateStamp: String, region: String) -> Data {
        let kDate = hmac(Data("AWS4\(secret)".utf8), Data(dateStamp.utf8))
        let kRegion = hmac(kDate, Data(region.utf8))
        let kService = hmac(kRegion, Data("s3".utf8))
        return hmac(kService, Data("aws4_request".utf8))
    }

    /// Canonical, sorted, encoded query string for signing.
    private static func canonicalQueryString(_ url: URL) -> String {
        guard let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else {
            return ""
        }
        var pairs: [(name: String, value: String)] = []
        for item in items {
            pairs.append((uriEncode(item.name), uriEncode(item.value ?? "")))
        }
        pairs.sort { lhs, rhs in
            lhs.name == rhs.name ? lhs.value < rhs.value : lhs.name < rhs.name
        }
        var encoded: [String] = []
        for pair in pairs {
            encoded.append(pair.name + "=" + pair.value)
        }
        return encoded.joined(separator: "&")
    }

    /// URI-encodes a path, keeping the slashes between segments.
    static func uriEncodePath(_ path: String) -> String {
        path.split(separator: "/", omittingEmptySubsequences: false)
            .map(uriEncode).joined(separator: "/")
    }

    /// URI-encodes a string per RFC 3986, the way SigV4 requires.
    static func uriEncode(_ string: some StringProtocol) -> String {
        let unreserved = Set(
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~".utf8
        )
        var result = ""
        for byte in string.utf8 {
            if unreserved.contains(byte) {
                result.append(Character(UnicodeScalar(byte)))
            } else {
                result += String(format: "%%%02X", byte)
            }
        }
        return result
    }

    /// HMAC-SHA256 of data under a key.
    private static func hmac(_ key: Data, _ data: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: data, using: SymmetricKey(data: key)))
    }

    /// Lowercase hex SHA-256 of data.
    static func hexSHA256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Formats a date in UTC with a fixed pattern for signing.
    private static func format(_ date: Date, _ pattern: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = pattern
        return formatter.string(from: date)
    }

    /// A parsed page of a ListBucketResult: its keys and whether more pages follow.
    struct ListResult {
        /// Object keys in this page.
        var keys: [String]
        /// Whether the bucket holds more keys beyond this page.
        var isTruncated: Bool
        /// Token that fetches the next page, present only when truncated.
        var nextToken: String?
    }

    /// Extracts object keys from a ListBucketResult document.
    static func parseKeys(_ data: Data) -> [String] {
        parseList(data).keys
    }

    /// Parses a ListBucketResult into its keys and pagination state.
    static func parseList(_ data: Data) -> ListResult {
        let parser = XMLParser(data: data)
        let delegate = ListResultDelegate()
        parser.delegate = delegate
        parser.parse()
        return ListResult(
            keys: delegate.keys, isTruncated: delegate.isTruncated, nextToken: delegate.nextToken
        )
    }

    /// Throws unless the response is HTTP with a success code.
    private static func expectSuccess(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { throw S3Error.invalidResponse }
        guard (200..<300).contains(http.statusCode) else { throw S3Error.status(http.statusCode) }
    }
}

/// ListResultDelegate collects the object keys and pagination markers from a ListBucketResult.
private final class ListResultDelegate: NSObject, XMLParserDelegate {
    /// Keys parsed so far.
    var keys: [String] = []
    /// Whether the listing was truncated to a single page.
    var isTruncated = false
    /// Continuation token for the next page, when the listing is truncated.
    var nextToken: String?
    /// Text accumulated for the current leaf element.
    private var current = ""

    func parser(
        _ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
        qualifiedName qName: String?, attributes: [String: String]
    ) {
        current = ""
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        current += string
    }

    func parser(
        _ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
        switch elementName {
        case "Key" where !trimmed.isEmpty: keys.append(trimmed)
        case "IsTruncated": isTruncated = trimmed == "true"
        case "NextContinuationToken" where !trimmed.isEmpty: nextToken = trimmed
        default: break
        }
    }
}
