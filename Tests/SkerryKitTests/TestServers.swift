import CryptoKit
import Foundation

@testable import SkerryKit

/// TestHTTPRequest is one parsed request the test server hands to a route handler.
struct TestHTTPRequest: Sendable {
    /// HTTP method, uppercased.
    var method: String
    /// Percent-decoded path, without the query.
    var path: String
    /// Path exactly as it appeared on the request line, without the query.
    var rawPath: String
    /// Raw query string without the leading `?`, empty when absent.
    var rawQuery: String
    /// Headers with lowercased names.
    var headers: [String: String]
    /// Request body.
    var body: Data

    /// Decoded query pairs in arrival order.
    var queryItems: [(name: String, value: String)] {
        guard !rawQuery.isEmpty else { return [] }
        return rawQuery.split(separator: "&").map { pair in
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let name = String(parts[0]).removingPercentEncoding ?? String(parts[0])
            let value = parts.count > 1
                ? (String(parts[1]).removingPercentEncoding ?? String(parts[1]))
                : ""
            return (name, value)
        }
    }
}

/// TestHTTPResponse is what a route handler returns.
struct TestHTTPResponse: Sendable {
    /// HTTP status code.
    var status: Int
    /// Extra headers; Content-Length and Connection are added automatically.
    var headers: [String: String] = [:]
    /// Response body.
    var body: Data = Data()

    /// A bare status response.
    static func code(_ status: Int) -> TestHTTPResponse {
        TestHTTPResponse(status: status)
    }
}

/// TestHTTPServer is a minimal blocking HTTP/1.1 server on a loopback socket, so the
/// network clients are exercised through real request parsing, sockets, and URLSession.
final class TestHTTPServer: @unchecked Sendable {
    /// Listening socket.
    private let listenFD: Int32
    /// Bound ephemeral port.
    let port: UInt16
    /// Route handler for every request.
    private let handler: @Sendable (TestHTTPRequest) -> TestHTTPResponse

    /// Starts a server on 127.0.0.1 with an ephemeral port.
    init(handler: @escaping @Sendable (TestHTTPRequest) -> TestHTTPResponse) throws {
        self.handler = handler
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        precondition(fd >= 0, "socket failed")
        listenFD = fd
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                bind(fd, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        precondition(bound == 0, "bind failed")
        var boundAddr = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        withUnsafeMutablePointer(to: &boundAddr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                _ = getsockname(fd, sockaddrPointer, &length)
            }
        }
        port = UInt16(bigEndian: boundAddr.sin_port)
        precondition(listen(fd, 32) == 0, "listen failed")
        let route = handler
        Thread.detachNewThread {
            while true {
                let client = accept(fd, nil, nil)
                guard client >= 0 else { break }
                Self.serve(client: client, handler: route)
                close(client)
            }
        }
    }

    /// Stops accepting connections.
    func stop() {
        close(listenFD)
    }

    /// Reads one request off a connection, routes it, and writes the response.
    private static func serve(
        client: Int32, handler: (TestHTTPRequest) -> TestHTTPResponse
    ) {
        guard let request = readRequest(client: client) else { return }
        let response = handler(request)
        var head = "HTTP/1.1 \(response.status) \(reason(for: response.status))\r\n"
        head += "Content-Length: \(response.body.count)\r\n"
        head += "Connection: close\r\n"
        for (name, value) in response.headers {
            head += "\(name): \(value)\r\n"
        }
        head += "\r\n"
        var out = Data(head.utf8)
        out.append(response.body)
        out.withUnsafeBytes { buffer in
            var sent = 0
            while sent < buffer.count {
                let wrote = write(client, buffer.baseAddress! + sent, buffer.count - sent)
                guard wrote > 0 else { break }
                sent += wrote
            }
        }
    }

    /// Reads and parses one HTTP request, nil on a malformed or closed connection.
    private static func readRequest(client: Int32) -> TestHTTPRequest? {
        var data = Data()
        var chunk = [UInt8](repeating: 0, count: 65536)
        var headerEnd: Range<Data.Index>?
        while headerEnd == nil {
            let count = read(client, &chunk, chunk.count)
            guard count > 0 else { return nil }
            data.append(contentsOf: chunk[0..<count])
            headerEnd = data.range(of: Data("\r\n\r\n".utf8))
        }
        guard let headerEnd else { return nil }
        let headerData = data[data.startIndex..<headerEnd.lowerBound]
        let headerText = String(decoding: headerData, as: UTF8.self)
        var lines = headerText.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { return nil }
        let requestLine = lines.removeFirst().split(separator: " ")
        guard requestLine.count >= 2 else { return nil }
        let method = String(requestLine[0]).uppercased()
        let target = String(requestLine[1])
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = String(line[..<colon]).lowercased()
            let value = String(line[line.index(after: colon)...])
                .trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }
        let contentLength = Int(headers["content-length"] ?? "0") ?? 0
        var body = Data(data[headerEnd.upperBound...])
        while body.count < contentLength {
            let count = read(client, &chunk, chunk.count)
            guard count > 0 else { break }
            body.append(contentsOf: chunk[0..<count])
        }
        let question = target.firstIndex(of: "?")
        let rawPath = question.map { String(target[..<$0]) } ?? target
        let rawQuery = question.map { String(target[target.index(after: $0)...]) } ?? ""
        return TestHTTPRequest(
            method: method,
            path: rawPath.removingPercentEncoding ?? rawPath,
            rawPath: rawPath,
            rawQuery: rawQuery,
            headers: headers,
            body: body
        )
    }

    /// Reason phrase for a status line.
    private static func reason(for status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 201: return "Created"
        case 204: return "No Content"
        case 207: return "Multi-Status"
        case 401: return "Unauthorized"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 409: return "Conflict"
        default: return "Status"
        }
    }
}

/// TestWebDAVServer serves a strict WebDAV subset over a temporary folder with Basic
/// authentication, so the WebDAV client and sync remote face real server semantics:
/// PUT into a missing collection is refused rather than silently created.
final class TestWebDAVServer: @unchecked Sendable {
    /// Underlying HTTP server.
    private let http: TestHTTPServer
    /// Folder that backs the DAV tree.
    let root: URL
    /// Expected account.
    let username = "captain"
    /// Expected password.
    let password = "seabird"

    /// Base collection URL clients should use.
    var baseURL: URL { URL(string: "http://127.0.0.1:\(http.port)/dav/")! }

    /// Starts the server over a fresh temporary folder.
    init() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("skerry-dav-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        root = folder
        let expected = "Basic " + Data("captain:seabird".utf8).base64EncodedString()
        http = try TestHTTPServer { [folder] request in
            guard request.headers["authorization"] == expected else { return .code(401) }
            return Self.route(request, root: folder)
        }
    }

    /// Stops the server.
    func stop() {
        http.stop()
    }

    /// Routes one request against the folder tree.
    private static func route(_ request: TestHTTPRequest, root: URL) -> TestHTTPResponse {
        guard request.path == "/dav" || request.path.hasPrefix("/dav/") else { return .code(404) }
        let relative = String(request.path.dropFirst("/dav".count))
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let target = relative.isEmpty
            ? root
            : relative.split(separator: "/").reduce(root) {
                $0.appendingPathComponent(String($1))
            }
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: target.path, isDirectory: &isDirectory)

        switch request.method {
        case "PROPFIND":
            guard exists else { return .code(404) }
            let depth = request.headers["depth"] ?? "1"
            var entries: [(href: String, isCollection: Bool)] = [
                (hrefFor(relative: relative, isCollection: isDirectory.boolValue), isDirectory.boolValue)
            ]
            if depth != "0", isDirectory.boolValue {
                let children = (try? FileManager.default.contentsOfDirectory(
                    at: target, includingPropertiesForKeys: [.isDirectoryKey]
                )) ?? []
                for child in children {
                    let childIsDir = (try? child.resourceValues(forKeys: [.isDirectoryKey]))?
                        .isDirectory ?? false
                    let childRelative = relative.isEmpty
                        ? child.lastPathComponent
                        : relative + "/" + child.lastPathComponent
                    entries.append((hrefFor(relative: childRelative, isCollection: childIsDir), childIsDir))
                }
            }
            let responses = entries.map { entry -> String in
                let resourceType = entry.isCollection
                    ? "<d:resourcetype><d:collection/></d:resourcetype>"
                    : "<d:resourcetype/>"
                return "<d:response><d:href>\(entry.href)</d:href>"
                    + "<d:propstat><d:prop>\(resourceType)</d:prop>"
                    + "<d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>"
            }
            let xml = "<?xml version=\"1.0\" encoding=\"utf-8\"?>"
                + "<d:multistatus xmlns:d=\"DAV:\">" + responses.joined() + "</d:multistatus>"
            return TestHTTPResponse(
                status: 207,
                headers: ["Content-Type": "application/xml; charset=utf-8"],
                body: Data(xml.utf8)
            )

        case "MKCOL":
            if exists { return .code(405) }
            let parent = target.deletingLastPathComponent()
            guard FileManager.default.fileExists(atPath: parent.path) else { return .code(409) }
            try? FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
            return .code(201)

        case "PUT":
            let parent = target.deletingLastPathComponent()
            var parentIsDirectory: ObjCBool = false
            guard FileManager.default.fileExists(
                atPath: parent.path, isDirectory: &parentIsDirectory
            ), parentIsDirectory.boolValue else { return .code(409) }
            if request.headers["if-none-match"] == "*", exists { return .code(412) }
            let created = !exists
            do {
                try request.body.write(to: target)
            } catch {
                return .code(409)
            }
            return .code(created ? 201 : 204)

        case "GET":
            guard exists, !isDirectory.boolValue, let data = try? Data(contentsOf: target) else {
                return .code(404)
            }
            return TestHTTPResponse(status: 200, body: data)

        case "DELETE":
            guard exists else { return .code(404) }
            try? FileManager.default.removeItem(at: target)
            return .code(204)

        default:
            return .code(405)
        }
    }

    /// Percent-encoded href for an entry, with the trailing slash collections carry.
    private static func hrefFor(relative: String, isCollection: Bool) -> String {
        let encoded = relative.split(separator: "/")
            .map {
                String($0).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)
                    ?? String($0)
            }
            .joined(separator: "/")
        let base = encoded.isEmpty ? "/dav" : "/dav/" + encoded
        return isCollection ? base + "/" : base
    }
}

/// TestS3Server serves the S3 subset the client uses and cryptographically verifies the
/// AWS Signature Version 4 on every request, so a signing bug fails loudly in tests.
final class TestS3Server: @unchecked Sendable {
    /// Object storage keyed by object key.
    private var objects: [String: Data] = [:]
    /// Guards the object map across connections.
    private let lock = NSLock()
    /// Underlying HTTP server.
    private var http: TestHTTPServer!
    /// Expected access key id.
    let accessKey = "AKIDTESTKEY"
    /// Expected secret access key.
    let secret = "puffin-secret-key"
    /// Region requests must be signed for.
    let region = "us-west-002"
    /// Bucket name requests must target.
    let bucket = "skerry-test"
    /// Maximum keys returned per list page. A small value forces the client to follow continuation
    /// tokens; the default returns everything in one page, matching real S3's 1000-key ceiling
    /// loosely enough for tests. Tests set this before issuing requests.
    var listPageSize = Int.max

    /// Endpoint URL for the client configuration.
    var endpoint: URL { URL(string: "http://127.0.0.1:\(http.port)")! }

    /// Starts the server.
    init() throws {
        http = try TestHTTPServer { [weak self] request in
            self?.route(request) ?? .code(500)
        }
    }

    /// Stops the server.
    func stop() {
        http.stop()
    }

    /// Keys currently stored, for assertions.
    func storedKeys() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return objects.keys.sorted()
    }

    /// Routes one request after verifying its signature.
    private func route(_ request: TestHTTPRequest) -> TestHTTPResponse {
        guard verifySignature(request) else { return .code(403) }
        let prefix = "/" + bucket
        guard request.path == prefix || request.path.hasPrefix(prefix + "/") else {
            return .code(404)
        }
        let key = String(request.path.dropFirst(prefix.count))
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))

        if request.method == "GET", key.isEmpty {
            let queryPrefix = request.queryItems.first { $0.name == "prefix" }?.value ?? ""
            let token = request.queryItems.first { $0.name == "continuation-token" }?.value
            lock.lock()
            let pageSize = listPageSize
            var keys = objects.keys.filter { $0.hasPrefix(queryPrefix) }.sorted()
            lock.unlock()
            if let token { keys = keys.filter { $0 > token } }
            let page = Array(keys.prefix(pageSize))
            let truncated = page.count < keys.count
            let contents = page
                .map { "<Contents><Key>\(escapeXML($0))</Key></Contents>" }
                .joined()
            var xml = "<?xml version=\"1.0\" encoding=\"UTF-8\"?><ListBucketResult>"
            xml += contents + "<IsTruncated>\(truncated)</IsTruncated>"
            if truncated, let last = page.last {
                xml += "<NextContinuationToken>\(escapeXML(last))</NextContinuationToken>"
            }
            xml += "</ListBucketResult>"
            return TestHTTPResponse(
                status: 200,
                headers: ["Content-Type": "application/xml"],
                body: Data(xml.utf8)
            )
        }

        switch request.method {
        case "PUT":
            lock.lock()
            if request.headers["if-none-match"] == "*", objects[key] != nil {
                lock.unlock()
                return .code(412)
            }
            objects[key] = request.body
            lock.unlock()
            return .code(200)
        case "GET":
            lock.lock()
            let data = objects[key]
            lock.unlock()
            guard let data else { return .code(404) }
            return TestHTTPResponse(status: 200, body: data)
        case "DELETE":
            lock.lock()
            objects[key] = nil
            lock.unlock()
            return .code(204)
        default:
            return .code(405)
        }
    }

    /// Recomputes the SigV4 signature from the received request and compares it to the
    /// Authorization header, the same math AWS runs.
    private func verifySignature(_ request: TestHTTPRequest) -> Bool {
        guard let authorization = request.headers["authorization"],
            authorization.hasPrefix("AWS4-HMAC-SHA256 ")
        else { return false }
        var credential = ""
        var signedHeaders = ""
        var signature = ""
        for part in authorization.dropFirst("AWS4-HMAC-SHA256 ".count)
            .components(separatedBy: ", ") {
            if part.hasPrefix("Credential=") { credential = String(part.dropFirst(11)) }
            if part.hasPrefix("SignedHeaders=") { signedHeaders = String(part.dropFirst(14)) }
            if part.hasPrefix("Signature=") { signature = String(part.dropFirst(10)) }
        }
        let credentialParts = credential.split(separator: "/").map(String.init)
        guard credentialParts.count == 5,
            credentialParts[0] == accessKey,
            credentialParts[2] == region,
            credentialParts[3] == "s3",
            credentialParts[4] == "aws4_request",
            let amzDate = request.headers["x-amz-date"],
            let payloadHash = request.headers["x-amz-content-sha256"]
        else { return false }
        let dateStamp = credentialParts[1]

        // The declared payload hash must also match the actual body.
        guard payloadHash == S3Client.hexSHA256(request.body) else { return false }

        var canonicalHeaders = ""
        for name in signedHeaders.split(separator: ";") {
            let value = request.headers[String(name)] ?? ""
            canonicalHeaders += String(name) + ":" + value + "\n"
        }
        var encodedQuery: [(name: String, value: String)] = []
        for item in request.queryItems {
            encodedQuery.append(
                (name: S3Client.uriEncode(item.name), value: S3Client.uriEncode(item.value))
            )
        }
        encodedQuery.sort { lhs, rhs in
            lhs.name == rhs.name ? lhs.value < rhs.value : lhs.name < rhs.name
        }
        let canonicalQuery = encodedQuery
            .map { pair in pair.name + "=" + pair.value }
            .joined(separator: "&")
        let canonicalRequest = [
            request.method, request.rawPath, canonicalQuery,
            canonicalHeaders, signedHeaders, payloadHash,
        ].joined(separator: "\n")

        let scope = "\(dateStamp)/\(region)/s3/aws4_request"
        let stringToSign = [
            "AWS4-HMAC-SHA256", amzDate, scope,
            S3Client.hexSHA256(Data(canonicalRequest.utf8)),
        ].joined(separator: "\n")

        let kDate = hmac(Data("AWS4\(secret)".utf8), Data(dateStamp.utf8))
        let kRegion = hmac(kDate, Data(region.utf8))
        let kService = hmac(kRegion, Data("s3".utf8))
        let kSigning = hmac(kService, Data("aws4_request".utf8))
        let expected = hmac(kSigning, Data(stringToSign.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return expected == signature
    }

    /// HMAC-SHA256 of data under a key.
    private func hmac(_ key: Data, _ data: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: data, using: SymmetricKey(data: key)))
    }

    /// Escapes XML-significant characters in a key.
    private func escapeXML(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}
