import Foundation

/// FrontMatter parses and serializes the note metadata block defined in FORMAT.md.
///
/// The format is a deliberate YAML subset: lowercase scalar keys, inline string lists, and
/// double quotes only when a value needs them. Unknown keys round-trip untouched.
public enum FrontMatter {
    /// Delimiter line that opens and closes a front matter block.
    static let delimiter = "---"

    /// Parses a full note file into metadata and body.
    ///
    /// A file with no front matter block yields empty metadata and the whole text as body.
    public static func parseNote(_ text: String) -> Note {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.first.map(String.init) == delimiter else {
            return Note(metadata: Note.Metadata(), body: text)
        }
        guard let end = lines.dropFirst().firstIndex(where: { String($0) == delimiter }) else {
            return Note(metadata: Note.Metadata(), body: text)
        }
        let blockLines = lines[1..<end].map(String.init)
        guard looksLikeFrontMatter(blockLines) else {
            return Note(metadata: Note.Metadata(), body: text)
        }
        let metadata = parseMetadata(blockLines)
        var body = lines[(end + 1)...].joined(separator: "\n")
        if body.hasPrefix("\n") { body.removeFirst() }
        return Note(metadata: metadata, body: body)
    }

    /// Reports whether delimited lines are front matter rather than body text that merely opens
    /// with a rule. Every non-empty line must be a `key: value` pair and there must be at least
    /// one, so a note whose first line is `---` keeps its content instead of losing it.
    static func looksLikeFrontMatter(_ lines: [String]) -> Bool {
        var sawKey = false
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            guard let colon = trimmed.firstIndex(of: ":"), colon != trimmed.startIndex else {
                return false
            }
            sawKey = true
        }
        return sawKey
    }

    /// Serializes a note back to file text, emitting front matter only when it has content.
    public static func serializeNote(_ note: Note) -> String {
        let block = serializeMetadata(note.metadata)
        guard !block.isEmpty else { return note.body }
        return "\(delimiter)\n\(block)\(delimiter)\n\n\(note.body)"
    }

    /// Parses front matter lines (without delimiters) into metadata.
    static func parseMetadata(_ lines: [String]) -> Note.Metadata {
        var metadata = Note.Metadata()
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, let colon = trimmed.firstIndex(of: ":") else { continue }
            let key = String(trimmed[..<colon]).trimmingCharacters(in: .whitespaces)
            let rawValue = String(trimmed[trimmed.index(after: colon)...])
                .trimmingCharacters(in: .whitespaces)
            switch key {
            case "id": metadata.id = UUID(uuidString: unquote(rawValue))
            case "title": metadata.title = unquote(rawValue)
            case "tags": metadata.tags = parseList(rawValue)
            case "starred": metadata.starred = rawValue == "true"
            case "pinned": metadata.pinned = rawValue == "true"
            case "archived": metadata.archived = rawValue == "true"
            case "locked": metadata.locked = rawValue == "true"
            case "encrypted": metadata.encrypted = rawValue == "true"
            case "created": metadata.created = parseDate(unquote(rawValue))
            case "updated": metadata.updated = parseDate(unquote(rawValue))
            default: metadata.unknown.append((key: key, rawValue: rawValue))
            }
        }
        return metadata
    }

    /// Serializes metadata to front matter lines; returns empty when nothing is set.
    static func serializeMetadata(_ metadata: Note.Metadata) -> String {
        var lines: [String] = []
        if let id = metadata.id { lines.append("id: \(id.uuidString)") }
        if let title = metadata.title { lines.append("title: \(quoteIfNeeded(title))") }
        if !metadata.tags.isEmpty {
            let items = metadata.tags.map(quoteIfNeeded).joined(separator: ", ")
            lines.append("tags: [\(items)]")
        }
        if metadata.starred { lines.append("starred: true") }
        if metadata.pinned { lines.append("pinned: true") }
        if metadata.archived { lines.append("archived: true") }
        if metadata.locked { lines.append("locked: true") }
        if metadata.encrypted { lines.append("encrypted: true") }
        if let created = metadata.created { lines.append("created: \(formatDate(created))") }
        if let updated = metadata.updated { lines.append("updated: \(formatDate(updated))") }
        for entry in metadata.unknown { lines.append("\(entry.key): \(entry.rawValue)") }
        guard !lines.isEmpty else { return "" }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Parses an inline list value like `[a, "b c", d]` into its items.
    ///
    /// Commas inside double quotes do not split, so a tag such as `"a, b"` survives the round
    /// trip instead of splitting into two, matching how `quoteIfNeeded` protects such values.
    static func parseList(_ rawValue: String) -> [String] {
        var inner = rawValue.trimmingCharacters(in: .whitespaces)
        if inner.hasPrefix("[") { inner.removeFirst() }
        if inner.hasSuffix("]") { inner.removeLast() }
        var items: [String] = []
        var current = ""
        var inQuotes = false
        var escaped = false
        for char in inner {
            if escaped {
                current.append(char)
                escaped = false
            } else if char == "\\" {
                current.append(char)
                escaped = true
            } else if char == "\"" {
                inQuotes.toggle()
                current.append(char)
            } else if char == ",", !inQuotes {
                items.append(current)
                current = ""
            } else {
                current.append(char)
            }
        }
        items.append(current)
        return items
            .map { unquote($0.trimmingCharacters(in: .whitespaces)) }
            .filter { !$0.isEmpty }
    }

    /// Removes one layer of double quotes and unescapes embedded quotes.
    static func unquote(_ value: String) -> String {
        guard value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") else { return value }
        return String(value.dropFirst().dropLast()).replacingOccurrences(of: "\\\"", with: "\"")
    }

    /// Double-quotes a value when the format requires it, escaping embedded quotes.
    static func quoteIfNeeded(_ value: String) -> String {
        let needsQuotes = value.contains("#") || value.contains(":") || value.contains(",")
            || value.contains("\"") || value != value.trimmingCharacters(in: .whitespaces)
            || value.isEmpty
        guard needsQuotes else { return value }
        return "\"\(value.replacingOccurrences(of: "\"", with: "\\\""))\""
    }

    /// Parses an ISO 8601 UTC timestamp, with and without fractional seconds.
    static func parseDate(_ value: String) -> Date? {
        if let date = try? Date(value, strategy: .iso8601) { return date }
        let fractional = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
        return try? Date(value, strategy: fractional)
    }

    /// Formats a date as an ISO 8601 UTC timestamp with second precision.
    static func formatDate(_ date: Date) -> String {
        date.formatted(.iso8601)
    }
}
