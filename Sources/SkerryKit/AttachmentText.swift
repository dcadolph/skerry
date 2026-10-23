import Foundation
import PDFKit

/// AttachmentText pulls searchable text out of attachments: PDF pages via PDFKit, images
/// via on-device Vision OCR, and plain text files directly. Nothing leaves the device.
public enum AttachmentText {
    /// Image extensions handed to OCR.
    public static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "heic", "webp"]
    /// Plain-text extensions read directly.
    public static let textExtensions: Set<String> = ["txt", "md", "markdown", "csv", "log", "json"]
    /// Most bytes read from a plain text attachment, keeping the index bounded.
    private static let textByteLimit = 200_000

    /// Extracts text from a file's bytes by extension; nil when the type carries no text
    /// or none was found.
    public static func extract(from data: Data, fileExtension: String) -> String? {
        let ext = fileExtension.lowercased()
        if ext == "pdf" {
            return pdfText(from: data)
        }
        if imageExtensions.contains(ext) {
            let recognized = (try? TextRecognizer.recognize(imageData: data))?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return recognized?.isEmpty == false ? recognized : nil
        }
        if textExtensions.contains(ext) {
            let capped = data.prefix(textByteLimit)
            let text = String(decoding: capped, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        }
        return nil
    }

    /// Joined text of every PDF page, nil for an unreadable or textless document.
    private static func pdfText(from data: Data) -> String? {
        guard let document = PDFDocument(data: data) else { return nil }
        var pages: [String] = []
        for pageIndex in 0..<document.pageCount {
            if let text = document.page(at: pageIndex)?.string {
                pages.append(text)
            }
        }
        let joined = pages.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return joined.isEmpty ? nil : joined
    }
}

/// AttachmentTextCache stores extracted attachment text keyed by file identity, so OCR and
/// PDF extraction run once per file rather than on every reload.
///
/// The cache lives in the library's `.skerry` folder and is rebuildable. Sealed `.skbox`
/// attachments are never extracted or cached, so the cache cannot become a plaintext copy
/// of an encrypted note's content.
public struct AttachmentTextCache {
    /// One cached extraction, valid while the file's size and mtime both match.
    private struct Entry: Codable {
        /// File size at extraction time.
        var size: Int
        /// File modification time at extraction time.
        var modified: TimeInterval
        /// Extracted text; empty when the file had none.
        var text: String
    }

    /// Cached entries keyed by asset file name.
    private var entries: [String: Entry]
    /// Where the cache persists.
    private let fileURL: URL

    /// Loads the cache from a library's cache folder, starting empty when absent.
    public init(libraryRoot: URL) {
        fileURL = libraryRoot
            .appendingPathComponent(".skerry", isDirectory: true)
            .appendingPathComponent("attachment-text.json")
        if let data = try? Data(contentsOf: fileURL),
            let decoded = try? JSONDecoder().decode([String: Entry].self, from: data) {
            entries = decoded
        } else {
            entries = [:]
        }
    }

    /// Text for an attachment, extracting and caching on a miss. Nil when the file has no
    /// text, cannot be read, or is a sealed `.skbox` attachment.
    public mutating func text(for url: URL) -> String? {
        guard url.pathExtension.lowercased() != "skbox" else { return nil }
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
            let size = attributes[.size] as? Int
        else { return nil }
        let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let key = url.lastPathComponent
        if let cached = entries[key], cached.size == size, cached.modified == modified {
            return cached.text.isEmpty ? nil : cached.text
        }
        guard let data = try? Data(contentsOf: url) else { return nil }
        let extracted = AttachmentText.extract(from: data, fileExtension: url.pathExtension) ?? ""
        entries[key] = Entry(size: size, modified: modified, text: extracted)
        return extracted.isEmpty ? nil : extracted
    }

    /// Persists the cache; failures are ignored since everything is re-extractable.
    public func save() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try? data.write(to: fileURL, options: .atomic)
    }
}
