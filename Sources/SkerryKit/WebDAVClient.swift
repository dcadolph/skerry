import Foundation

/// WebDAVClient talks to a WebDAV server so Skerry can back up straight to a NAS, iDrive,
/// Nextcloud, or any WebDAV host without a Files extension.
///
/// It carries only what a backup needs: create a collection, upload and download a file, list
/// a collection, and delete. Bodies are the already-sealed backup bytes, so the server never
/// sees anything but ciphertext.
public struct WebDAVClient: Sendable {
    /// Connection settings for a WebDAV collection.
    public struct Config: Sendable, Equatable {
        /// Base URL of the collection Skerry writes into, for example `https://host/dav/skerry/`.
        public var baseURL: URL
        /// Account user name.
        public var username: String
        /// Account password or app token.
        public var password: String

        /// Creates a configuration.
        public init(baseURL: URL, username: String, password: String) {
            self.baseURL = baseURL
            self.username = username
            self.password = password
        }
    }

    /// One entry returned by listing a collection.
    public struct Entry: Sendable, Equatable {
        /// Last path component of the entry.
        public var name: String
        /// Whether the entry is a collection rather than a file.
        public var isCollection: Bool

        /// Creates an entry.
        public init(name: String, isCollection: Bool) {
            self.name = name
            self.isCollection = isCollection
        }
    }

    /// Errors raised by WebDAV operations.
    public enum WebDAVError: Error, Equatable {
        /// The server returned a status outside the success range.
        case status(Int)
        /// The response was not HTTP.
        case invalidResponse
    }

    /// Connection settings.
    public let config: Config
    /// URL session used for requests.
    private let session: URLSession

    /// Creates a client over a configuration, defaulting to the shared session.
    public init(config: Config, session: URLSession = .shared) {
        self.config = config
        self.session = session
    }

    /// Verifies the server answers and the credentials work, by probing the base collection.
    public func check() async throws {
        _ = try await run(request("PROPFIND", url(""), headers: ["Depth": "0"]))
    }

    /// Creates a collection, treating an already-existing one as success.
    public func makeCollection(_ path: String) async throws {
        let (_, response) = try await session.data(for: request("MKCOL", url(path)))
        guard let http = response as? HTTPURLResponse else { throw WebDAVError.invalidResponse }
        // 201 created, 405 or 301 when it already exists.
        guard [201, 200, 301, 405].contains(http.statusCode) else {
            throw WebDAVError.status(http.statusCode)
        }
    }

    /// Uploads bytes to a path, replacing any existing file.
    public func upload(_ data: Data, to path: String) async throws {
        var req = request("PUT", url(path))
        req.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        let (_, response) = try await session.upload(for: req, from: data)
        try Self.expectSuccess(response)
    }

    /// Uploads bytes to a path only when the path is absent, using a conditional PUT. Returns
    /// true when this call created the file and false when it already existed. Not every WebDAV
    /// server honors If-None-Match, so a live check confirms it per server.
    public func createExclusive(_ data: Data, to path: String) async throws -> Bool {
        var req = request("PUT", url(path), headers: ["If-None-Match": "*"])
        req.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        let (_, response) = try await session.upload(for: req, from: data)
        guard let http = response as? HTTPURLResponse else { throw WebDAVError.invalidResponse }
        if http.statusCode == 412 { return false }
        try Self.expectSuccess(response)
        return true
    }

    /// Downloads the bytes at a path.
    public func download(_ path: String) async throws -> Data {
        try await run(request("GET", url(path)))
    }

    /// Deletes the file or collection at a path.
    public func delete(_ path: String) async throws {
        let (_, response) = try await session.data(for: request("DELETE", url(path)))
        try Self.expectSuccess(response)
    }

    /// Lists the immediate children of a collection.
    public func list(_ path: String) async throws -> [Entry] {
        let body = try await run(request("PROPFIND", url(path), headers: ["Depth": "1"]))
        return Self.parsePropfind(body)
    }

    /// Parses a WebDAV multistatus response into entries, tolerant of the namespace prefix a
    /// server uses because it matches on the local element name.
    public static func parsePropfind(_ data: Data) -> [Entry] {
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        let delegate = PropfindDelegate()
        parser.delegate = delegate
        parser.parse()
        return delegate.entries
    }

    /// Runs a request expecting a body, checking the status first.
    private func run(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        try Self.expectSuccess(response)
        return data
    }

    /// Builds a request with basic authentication and any extra headers.
    private func request(
        _ method: String, _ url: URL, headers: [String: String] = [:]
    ) -> URLRequest {
        var req = URLRequest(url: url)
        req.httpMethod = method
        let credentials = Data("\(config.username):\(config.password)".utf8).base64EncodedString()
        req.setValue("Basic \(credentials)", forHTTPHeaderField: "Authorization")
        for (field, value) in headers { req.setValue(value, forHTTPHeaderField: field) }
        return req
    }

    /// Resolves a relative path against the base collection, appending each segment on its own
    /// so a name with a slash or a space is encoded correctly.
    private func url(_ path: String) -> URL {
        var resolved = config.baseURL
        for segment in path.split(separator: "/") {
            resolved.appendPathComponent(String(segment))
        }
        return resolved
    }

    /// Throws unless the response is HTTP with a success or multistatus code.
    private static func expectSuccess(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { throw WebDAVError.invalidResponse }
        guard (200..<300).contains(http.statusCode) || http.statusCode == 207 else {
            throw WebDAVError.status(http.statusCode)
        }
    }
}

/// PropfindDelegate collects response entries from a multistatus document.
private final class PropfindDelegate: NSObject, XMLParserDelegate {
    /// Entries parsed so far.
    var entries: [WebDAVClient.Entry] = []
    /// Whether the parser is inside a response element.
    private var inResponse = false
    /// Whether the parser is inside the href of the current response.
    private var inHref = false
    /// Accumulated href text for the current response.
    private var href = ""
    /// Whether the current response describes a collection.
    private var isCollection = false

    func parser(
        _ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
        qualifiedName qName: String?, attributes: [String: String]
    ) {
        switch elementName {
        case "response": inResponse = true; href = ""; isCollection = false
        case "href" where inResponse: inHref = true
        case "collection" where inResponse: isCollection = true
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inHref { href += string }
    }

    func parser(
        _ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        switch elementName {
        case "href": inHref = false
        case "response":
            inResponse = false
            if let name = Self.name(fromHref: href) {
                entries.append(WebDAVClient.Entry(name: name, isCollection: isCollection))
            }
        default: break
        }
    }

    /// Extracts the decoded last path component from an href, ignoring bare collection roots.
    private static func name(fromHref rawHref: String) -> String? {
        let trimmed = rawHref.trimmingCharacters(in: .whitespacesAndNewlines)
        // URLComponents.path already percent-decodes, so decode the still-encoded path exactly
        // once. Decoding the decoded path again would corrupt a name that legitimately contains a
        // percent sequence, turning a file literally named "a%20b" into "a b".
        let encodedPath = URLComponents(string: trimmed)?.percentEncodedPath ?? trimmed
        let decoded = encodedPath.removingPercentEncoding ?? encodedPath
        let name = (decoded as NSString).lastPathComponent
        return name.isEmpty || name == "/" ? nil : name
    }
}
