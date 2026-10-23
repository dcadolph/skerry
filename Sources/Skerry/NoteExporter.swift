import Foundation
import SkerryKit
import SwiftUI
import UniformTypeIdentifiers

#if canImport(UIKit)
    import UIKit
#else
    import AppKit
#endif

#if canImport(UIKit)

    /// ShareSheet presents the system share sheet for an exported file on iOS.
    struct ShareSheet: UIViewControllerRepresentable {
        /// File to share.
        let url: URL

        func makeUIViewController(context: Context) -> UIActivityViewController {
            UIActivityViewController(activityItems: [url], applicationActivities: nil)
        }

        func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
    }

#endif

/// NoteExporter writes a note out in a chosen format and returns a file to share or save.
enum NoteExporter {
    /// A format a note can be exported to.
    enum Format: String, CaseIterable, Identifiable {
        case markdown, text, html, rtf, pdf, docx

        /// Stable identity for menus.
        var id: String { rawValue }
        /// Menu label.
        var label: String {
            switch self {
            case .markdown: return "Markdown"
            case .text: return "Plain Text"
            case .html: return "HTML"
            case .rtf: return "Rich Text"
            case .pdf: return "PDF"
            case .docx: return "Word (DOCX)"
            }
        }
        /// File extension for the exported file.
        var ext: String {
            switch self {
            case .markdown: return "md"
            case .text: return "txt"
            case .html: return "html"
            case .rtf: return "rtf"
            case .pdf: return "pdf"
            case .docx: return "docx"
            }
        }

        /// Formats offered on this platform; DOCX conversion exists only on macOS.
        static var exportable: [Format] {
            #if canImport(UIKit)
                allCases.filter { $0 != .docx }
            #else
                allCases
            #endif
        }
    }

    /// Writes the note in a format to a temporary file and returns its URL.
    @MainActor
    static func makeFile(for stored: StoredNote, format: Format) throws -> URL {
        let title = displayName(for: stored)
        let name = sanitize(title)
        // Exports go in a dedicated temp folder that is cleared each time, so a note's exported
        // plaintext, a decrypted note's included, does not pile up in the temporary directory.
        let exportsDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SkerryExports", isDirectory: true)
        try? FileManager.default.removeItem(at: exportsDir)
        try FileManager.default.createDirectory(at: exportsDir, withIntermediateDirectories: true)
        let url = exportsDir
            .appendingPathComponent(name)
            .appendingPathExtension(format.ext)
        switch format {
        case .markdown:
            try stored.note.body.write(to: url, atomically: true, encoding: .utf8)
        case .text:
            try plainText(from: stored.note.body).write(to: url, atomically: true, encoding: .utf8)
        case .html:
            try MarkdownHTML.document(title: title, markdown: stored.note.body)
                .write(to: url, atomically: true, encoding: .utf8)
        case .rtf:
            let html = MarkdownHTML.document(title: title, markdown: stored.note.body)
            try richText(html: html).write(to: url)
        case .pdf:
            let html = MarkdownHTML.document(title: title, markdown: stored.note.body)
            try renderPDF(html: html).write(to: url)
        case .docx:
            #if canImport(UIKit)
                throw CocoaError(.featureUnsupported)
            #else
                let html = MarkdownHTML.document(title: title, markdown: stored.note.body)
                try wordDocument(html: html).write(to: url)
            #endif
        }
        return url
    }

    /// How long a copy from an encrypted note stays on the clipboard.
    private static let sensitiveClipboardLifetime: TimeInterval = 60

    /// Copies the note to the clipboard as Markdown, HTML, or plain text. A copy from an
    /// encrypted note expires after a minute instead of lingering in clipboard history.
    @MainActor
    static func copy(_ stored: StoredNote, as format: Format) {
        let string: String
        switch format {
        case .html: string = MarkdownHTML.document(
            title: displayName(for: stored), markdown: stored.note.body
        )
        case .text: string = plainText(from: stored.note.body)
        default: string = stored.note.body
        }
        let sensitive = stored.note.metadata.encrypted || stored.note.metadata.locked
        #if canImport(UIKit)
            if sensitive {
                UIPasteboard.general.setItems(
                    [[UTType.utf8PlainText.identifier: string]],
                    options: [
                        .localOnly: true,
                        .expirationDate: Date().addingTimeInterval(sensitiveClipboardLifetime),
                    ]
                )
            } else {
                UIPasteboard.general.string = string
            }
        #else
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(string, forType: .string)
            if sensitive {
                let stamped = NSPasteboard.general.changeCount
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(sensitiveClipboardLifetime))
                    // Only clear when nothing else was copied since.
                    if NSPasteboard.general.changeCount == stamped {
                        NSPasteboard.general.clearContents()
                    }
                }
            }
        #endif
    }

    /// Display title for an exported file or job, with a file-name fallback.
    private static func displayName(for stored: StoredNote) -> String {
        stored.note.displayTitle
            ?? (stored.path.split(separator: "/").last.map(String.init) ?? "Note")
    }

    /// Renders HTML to Rich Text data through an attributed string.
    @MainActor
    private static func richText(html: String) throws -> Data {
        guard let data = html.data(using: .utf8) else { return Data() }
        let attributed = try NSAttributedString(
            data: data,
            options: [
                .documentType: NSAttributedString.DocumentType.html,
                .characterEncoding: String.Encoding.utf8.rawValue,
            ],
            documentAttributes: nil
        )
        return try attributed.data(
            from: NSRange(location: 0, length: attributed.length),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
        )
    }

    /// Strips Markdown syntax to leave readable plain text.
    private static func plainText(from markdown: String) -> String {
        var text = markdown
        for (pattern, template) in [
            (#"^#{1,6}\s+"#, ""), (#"^\s*[-*+]\s+(\[[ xX]\]\s+)?"#, ""),
            (#"^\s*\d+\.\s+"#, ""), (#"\*\*(.+?)\*\*"#, "$1"), (#"\*(.+?)\*"#, "$1"),
            (#"~~(.+?)~~"#, "$1"), (#"`([^`]+)`"#, "$1"), (#"\[\[([^\]]+)\]\]"#, "$1"),
            (#"\[([^\]]+)\]\([^)]+\)"#, "$1"),
        ] {
            let options: NSRegularExpression.Options =
                pattern.hasPrefix("^") ? [.anchorsMatchLines] : []
            let regex = try! NSRegularExpression(pattern: pattern, options: options)
            let range = NSRange(location: 0, length: (text as NSString).length)
            text = regex.stringByReplacingMatches(in: text, range: range, withTemplate: template)
        }
        return text
    }

    /// Sanitizes a title into a safe file name.
    private static func sanitize(_ title: String) -> String {
        let cleaned = title
            .components(separatedBy: CharacterSet(charactersIn: "/\\:?%*|\"<>"))
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty ? "Note" : String(cleaned.prefix(80))
    }

    #if !canImport(UIKit)
        /// Renders HTML to Word document bytes via the attributed string converter.
        @MainActor
        private static func wordDocument(html: String) throws -> Data {
            guard let data = html.data(using: .utf8) else { return Data() }
            let attributed = try NSAttributedString(
                data: data,
                options: [
                    .documentType: NSAttributedString.DocumentType.html,
                    .characterEncoding: String.Encoding.utf8.rawValue,
                ],
                documentAttributes: nil
            )
            return try attributed.data(
                from: NSRange(location: 0, length: attributed.length),
                documentAttributes: [
                    .documentType: NSAttributedString.DocumentType.officeOpenXML
                ]
            )
        }

        /// Prints the note rendered from HTML through the system print panel.
        @MainActor
        static func printNote(_ stored: StoredNote) {
            let html = MarkdownHTML.document(
                title: displayName(for: stored), markdown: stored.note.body
            )
            guard let data = html.data(using: .utf8),
                let attributed = try? NSAttributedString(
                    data: data,
                    options: [.documentType: NSAttributedString.DocumentType.html],
                    documentAttributes: nil
                )
            else { return }
            let width: CGFloat = 540
            let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: width, height: 100))
            textView.textStorage?.setAttributedString(attributed)
            textView.layoutManager?.ensureLayout(for: textView.textContainer!)
            let used = textView.layoutManager?.usedRect(for: textView.textContainer!).size
                ?? NSSize(width: width, height: 100)
            textView.frame = NSRect(x: 0, y: 0, width: width, height: used.height + 24)
            let operation = NSPrintOperation(view: textView)
            operation.printInfo.isVerticallyCentered = false
            operation.run()
        }

        /// Shows a save panel and copies the exported file to the chosen location.
        @MainActor
        static func saveOnMac(_ source: URL) {
            let panel = NSSavePanel()
            panel.nameFieldStringValue = source.lastPathComponent
            panel.canCreateDirectories = true
            guard panel.runModal() == .OK, let destination = panel.url else { return }
            try? FileManager.default.removeItem(at: destination)
            try? FileManager.default.copyItem(at: source, to: destination)
        }
    #endif

    #if canImport(UIKit)
        /// Renders HTML to PDF data using the print formatter, Letter size with margins.
        private static func renderPDF(html: String) throws -> Data {
            let formatter = UIMarkupTextPrintFormatter(markupText: html)
            let renderer = UIPrintPageRenderer()
            renderer.addPrintFormatter(formatter, startingAtPageAt: 0)
            let page = CGRect(x: 0, y: 0, width: 612, height: 792)
            renderer.setValue(page, forKey: "paperRect")
            renderer.setValue(page.insetBy(dx: 36, dy: 36), forKey: "printableRect")
            let data = NSMutableData()
            UIGraphicsBeginPDFContextToData(data, page, nil)
            for pageIndex in 0..<max(renderer.numberOfPages, 1) {
                UIGraphicsBeginPDFPage()
                renderer.drawPage(at: pageIndex, in: page)
            }
            UIGraphicsEndPDFContext()
            return data as Data
        }

        /// Presents the system print sheet for the note rendered from HTML.
        @MainActor
        static func printNote(_ stored: StoredNote) {
            let html = MarkdownHTML.document(
                title: displayName(for: stored), markdown: stored.note.body
            )
            let info = UIPrintInfo.printInfo()
            info.outputType = .general
            info.jobName = displayName(for: stored)
            let controller = UIPrintInteractionController.shared
            controller.printInfo = info
            controller.printFormatter = UIMarkupTextPrintFormatter(markupText: html)
            controller.present(animated: true, completionHandler: nil)
        }
    #else
        /// Renders HTML to PDF data via an off-screen text view.
        @MainActor
        private static func renderPDF(html: String) throws -> Data {
            guard let data = html.data(using: .utf8),
                let attributed = try? NSAttributedString(
                    data: data, options: [.documentType: NSAttributedString.DocumentType.html],
                    documentAttributes: nil
                )
            else { return Data() }
            let width: CGFloat = 540
            let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: width, height: 100))
            textView.textStorage?.setAttributedString(attributed)
            textView.layoutManager?.ensureLayout(for: textView.textContainer!)
            let used = textView.layoutManager?.usedRect(for: textView.textContainer!).size
                ?? NSSize(width: width, height: 100)
            textView.frame = NSRect(x: 0, y: 0, width: width, height: used.height + 24)
            return textView.dataWithPDF(inside: textView.bounds)
        }
    #endif
}
