import CryptoKit
import Foundation

/// NoteImporter converts notes exported from other apps into Skerry notes.
///
/// Bear, Obsidian, Apple Notes, and plain Markdown all keep a note as Markdown text, sometimes
/// with inline `#tags` and sometimes with a front matter block. This lifts inline tags into
/// metadata so they become first class, derives a title from the first heading, and falls back to
/// the file's own dates for timestamps the source did not record.
public enum NoteImporter {
    /// A converted note together with the file-name stem it should be written under.
    public struct Imported: Equatable, Sendable {
        /// File-name stem without extension, already sanitized for the filesystem.
        public var name: String
        /// The converted note.
        public var note: Note

        /// Creates an imported result from a name stem and a note.
        public init(name: String, note: Note) {
            self.name = name
            self.note = note
        }
    }

    /// File extensions an import reads as Markdown or plain text.
    public static let markdownExtensions: Set<String> = ["md", "markdown", "mdown", "txt", "text"]

    /// Converts Markdown text from another app into a Skerry note. The file name seeds the title
    /// when the body has no heading; the dates seed metadata the source did not carry.
    public static func importMarkdown(
        _ text: String, fileName: String, created: Date? = nil, modified: Date? = nil
    ) -> Imported {
        var note = FrontMatter.parseNote(text)
        note.metadata.tags = mergeTags(note.metadata.tags, with: inlineTags(in: note.body))
        if note.metadata.id == nil { note.metadata.id = UUID() }
        if note.metadata.created == nil { note.metadata.created = created ?? modified }
        if note.metadata.updated == nil { note.metadata.updated = modified ?? created }
        return Imported(name: titleStem(for: note, fileName: fileName), note: note)
    }

    /// Extracts inline tags: a hash that opens a word, meaning it sits at the start or after
    /// whitespace and is followed by a letter, then word characters, slashes, or hyphens. A `# `
    /// heading is never a tag because a heading puts a space after the hash.
    static func inlineTags(in body: String) -> [String] {
        let pattern = "(?:^|\\s)#([A-Za-z][A-Za-z0-9_/-]*)"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        var tags: [String] = []
        var seen: Set<String> = []
        for match in regex.matches(in: body, range: NSRange(body.startIndex..., in: body)) {
            guard let range = Range(match.range(at: 1), in: body) else { continue }
            let tag = String(body[range])
            if seen.insert(tag.lowercased()).inserted { tags.append(tag) }
        }
        return tags
    }

    /// Merges two tag lists, dropping case-insensitive duplicates and keeping first-seen casing.
    static func mergeTags(_ first: [String], with second: [String]) -> [String] {
        var result: [String] = []
        var seen: Set<String> = []
        for tag in first + second where !tag.isEmpty {
            if seen.insert(tag.lowercased()).inserted { result.append(tag) }
        }
        return result
    }

    /// One attachment bundled with an imported note.
    public struct ImportedAttachment: Equatable, Sendable {
        /// File name to save the attachment under.
        public var preferredName: String
        /// Attachment bytes.
        public var data: Data
        /// Hex MD5 the source body references this attachment by; the caller replaces
        /// `skerry-enex://<hash>` placeholders with the saved asset's link.
        public var hash: String

        /// Creates an attachment record.
        public init(preferredName: String, data: Data, hash: String) {
            self.preferredName = preferredName
            self.data = data
            self.hash = hash
        }
    }

    /// A converted note together with attachments its source bundled.
    public struct ImportedWithAttachments: Equatable, Sendable {
        /// The converted note.
        public var imported: Imported
        /// Bundled attachments.
        public var attachments: [ImportedAttachment]

        /// Creates a result.
        public init(imported: Imported, attachments: [ImportedAttachment]) {
            self.imported = imported
            self.attachments = attachments
        }
    }

    /// Parses an Evernote ENEX export: each note's ENML converts to Markdown, tags carry
    /// over, dates carry over, and resources come along as attachments referenced by
    /// `skerry-enex://<md5>` placeholders for the caller to resolve after saving them.
    public static func importENEX(_ data: Data) -> [ImportedWithAttachments] {
        let parser = XMLParser(data: data)
        let delegate = ENEXDelegate()
        parser.delegate = delegate
        parser.parse()
        return delegate.finished.map { raw in
            var content = raw.content
            // en-media tags become placeholders before the HTML conversion, images as
            // image links so they render inline after the caller resolves them.
            let mediaPattern = try! NSRegularExpression(
                pattern: #"<en-media[^>]*?hash="([0-9a-fA-F]+)"[^>]*?/?>(?:</en-media>)?"#,
                options: [.caseInsensitive]
            )
            let ns = content as NSString
            var rebuilt = ""
            var cursor = 0
            for match in mediaPattern.matches(
                in: content, range: NSRange(location: 0, length: ns.length)
            ) {
                rebuilt += ns.substring(
                    with: NSRange(location: cursor, length: match.range.location - cursor)
                )
                let hash = ns.substring(with: match.range(at: 1)).lowercased()
                let resource = raw.resources.first { $0.hash == hash }
                let isImage = resource?.mime.hasPrefix("image/") ?? false
                let name = resource?.preferredName ?? "attachment"
                rebuilt += isImage
                    ? "![](skerry-enex://\(hash))"
                    : "[\(name)](skerry-enex://\(hash))"
                cursor = match.range.location + match.range.length
            }
            rebuilt += ns.substring(from: cursor)
            var markdown = HTMLToMarkdown.convert(rebuilt)
            if markdown.isEmpty { markdown = raw.title }

            var note = Note()
            note.metadata.id = UUID()
            note.metadata.title = raw.title.isEmpty ? nil : raw.title
            note.metadata.tags = mergeTags(raw.tags, with: inlineTags(in: markdown))
            note.metadata.created = raw.created
            note.metadata.updated = raw.updated ?? raw.created
            note.body = markdown
            let imported = Imported(
                name: titleStem(for: note, fileName: raw.title.isEmpty ? "Evernote Note" : raw.title),
                note: note
            )
            let attachments = raw.resources.map {
                ImportedAttachment(preferredName: $0.preferredName, data: $0.data, hash: $0.hash)
            }
            return ImportedWithAttachments(imported: imported, attachments: attachments)
        }
    }

    /// Whether JSON bytes look like a Day One export.
    public static func looksLikeDayOne(_ data: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return false }
        return object["entries"] is [[String: Any]]
    }

    /// Parses a Day One `Journal.json` export. Entry text is already Markdown; titles come
    /// from the first line, tags and dates carry over. Photo references stay as Day One
    /// wrote them, since the bare JSON does not include the image files.
    public static func importDayOne(_ data: Data) -> [Imported] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let entries = object["entries"] as? [[String: Any]]
        else { return [] }
        return entries.compactMap { entry in
            guard let text = entry["text"] as? String,
                !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { return nil }
            var note = FrontMatter.parseNote(text)
            note.metadata.id = UUID()
            note.metadata.tags = mergeTags(
                (entry["tags"] as? [String]) ?? [], with: inlineTags(in: note.body)
            )
            note.metadata.created = (entry["creationDate"] as? String).flatMap(parseISO)
            note.metadata.updated = (entry["modifiedDate"] as? String).flatMap(parseISO)
                ?? note.metadata.created
            let fallbackName = note.metadata.created.map {
                "Journal " + $0.formatted(.iso8601.year().month().day().dateSeparator(.dash))
            } ?? "Day One Entry"
            return Imported(name: titleStem(for: note, fileName: fallbackName), note: note)
        }
    }

    /// Parses an ISO 8601 timestamp.
    private static func parseISO(_ value: String) -> Date? {
        try? Date(value, strategy: .iso8601)
    }

    /// The file-name stem for an imported note: its display title when it has one, otherwise the
    /// original file name, sanitized and length-capped so it is safe on disk.
    static func titleStem(for note: Note, fileName: String) -> String {
        let base = note.displayTitle ?? (fileName as NSString).deletingPathExtension
        let cleaned = base
            .components(separatedBy: CharacterSet(charactersIn: "/\\:"))
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let capped = String(cleaned.prefix(80)).trimmingCharacters(in: .whitespaces)
        return capped.isEmpty ? "Imported Note" : capped
    }
}

/// ENEXDelegate walks an Evernote export document collecting notes and their resources.
private final class ENEXDelegate: NSObject, XMLParserDelegate {
    /// One raw resource before conversion.
    struct RawResource {
        /// Decoded attachment bytes.
        var data: Data
        /// MIME type.
        var mime: String
        /// File name from the resource attributes, or a mime-derived fallback.
        var preferredName: String
        /// Hex MD5 of the bytes, the handle ENML bodies reference.
        var hash: String
    }

    /// One raw note before conversion.
    struct RawNote {
        var title = ""
        var content = ""
        var tags: [String] = []
        var created: Date?
        var updated: Date?
        var resources: [RawResource] = []
    }

    /// Completed notes in document order.
    var finished: [RawNote] = []

    /// Note under construction.
    private var current: RawNote?
    /// Element text accumulator.
    private var buffer = ""
    /// Whether the parser is inside a resource.
    private var inResource = false
    /// Base64 accumulator for the current resource data.
    private var resourceData = ""
    /// MIME of the current resource.
    private var resourceMime = ""
    /// File name of the current resource.
    private var resourceFileName = ""

    /// Evernote's timestamp shape, basic ISO in UTC.
    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return formatter
    }()

    func parser(
        _ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
        qualifiedName qName: String?, attributes: [String: String]
    ) {
        buffer = ""
        switch elementName {
        case "note":
            current = RawNote()
        case "resource":
            inResource = true
            resourceData = ""
            resourceMime = ""
            resourceFileName = ""
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        buffer += string
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        buffer += String(decoding: CDATABlock, as: UTF8.self)
    }

    func parser(
        _ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        let text = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        switch elementName {
        case "title":
            current?.title = text
        case "content":
            current?.content = buffer
        case "tag":
            if !text.isEmpty { current?.tags.append(text) }
        case "created":
            current?.created = Self.dateFormatter.date(from: text)
        case "updated":
            current?.updated = Self.dateFormatter.date(from: text)
        case "data" where inResource:
            resourceData = buffer
        case "mime" where inResource:
            resourceMime = text
        case "file-name" where inResource:
            resourceFileName = text
        case "resource":
            inResource = false
            let compact = resourceData
                .components(separatedBy: .whitespacesAndNewlines)
                .joined()
            if let decoded = Data(base64Encoded: compact), !decoded.isEmpty {
                let hash = Insecure.MD5.hash(data: decoded)
                    .map { String(format: "%02x", $0) }
                    .joined()
                let fallback = "attachment." + (resourceMime.split(separator: "/").last
                    .map(String.init) ?? "bin")
                current?.resources.append(
                    RawResource(
                        data: decoded,
                        mime: resourceMime,
                        preferredName: resourceFileName.isEmpty ? fallback : resourceFileName,
                        hash: hash
                    )
                )
            }
        case "note":
            if let current { finished.append(current) }
            current = nil
        default:
            break
        }
        buffer = ""
    }
}
