import Foundation

#if canImport(AppKit)
    import AppKit
#else
    import UIKit
#endif

/// ConcealingParagraphs is the TextKit 2 presentation layer: it hides Markdown syntax,
/// swaps list dashes and checkbox centers one-for-one to bullet and box characters,
/// renders local images in the text flow as attachments, and collapses folded sections,
/// all without ever touching the stored text. Character counts always match storage, so
/// caret math stays exact and copying yields raw Markdown. The paragraph holding the
/// caret renders raw for editing.
final class ConcealingParagraphs: NSObject, NSTextContentStorageDelegate {
    /// Whether Markdown concealment applies; plain formats render as stored.
    var conceals = true
    /// Decoded image for a local image link, supplied by the editor's model.
    var imageProvider: ((String) -> PlatformImage?)?
    /// Widest an in-flow image may render, tracking the text view's layout width.
    var maxImageWidth: CGFloat = 520
    /// Body ranges hidden by folded headings.
    private(set) var foldedBodies: [NSRange] = []
    /// Paragraph holding the caret, which always shows raw source.
    private var caretParagraph = NSRange(location: NSNotFound, length: 0)
    /// Decoded images by link, so files decode once per note.
    private var imageCache: [String: PlatformImage] = [:]

    /// Near-invisible font that collapses a concealed run's width to a hairline.
    private static var hiddenFont: PlatformFont { .systemFont(ofSize: 0.1) }

    /// Attributes that make a run take almost no space.
    private static var hiddenAttributes: [NSAttributedString.Key: Any] {
        [.font: hiddenFont, .foregroundColor: PlatformColor.clear]
    }

    /// Drops decoded images, on note switches.
    func clearImages() {
        imageCache.removeAll()
    }

    func textContentStorage(
        _ textContentStorage: NSTextContentStorage, textParagraphWith range: NSRange
    ) -> NSTextParagraph? {
        guard conceals, let storage = textContentStorage.textStorage,
            range.length > 0, range.location + range.length <= storage.length
        else { return nil }

        if NSIntersectionRange(range, caretParagraph).length != 0 || caretSitsIn(range) {
            // The caret line stays raw so its syntax is editable, except for the leading
            // list marker, which keeps rendering as a bullet or checkbox so a list reads
            // clean the instant it is typed.
            return markerOnlyParagraph(for: range, in: storage)
        }

        if foldedBodies.contains(where: { NSLocationInRange(range.location, $0) }) {
            return collapsedParagraph(for: range, in: storage)
        }

        var needsWork = false
        storage.enumerateAttributes(in: range, options: []) { attributes, _, stop in
            if attributes[MarkdownTheme.concealKey] != nil
                || attributes[MarkdownTheme.bulletKey] != nil
                || attributes[MarkdownTheme.checkboxEmptyKey] != nil
                || attributes[MarkdownTheme.checkboxDoneKey] != nil
                || attributes[MarkdownTheme.imageLinkKey] != nil {
                needsWork = true
                stop.pointee = true
            }
        }
        guard needsWork else { return nil }

        let copy = NSMutableAttributedString(
            attributedString: storage.attributedSubstring(from: range)
        )
        let full = NSRange(location: 0, length: copy.length)
        copy.enumerateAttributes(in: full, options: []) { attributes, run, _ in
            if let link = attributes[MarkdownTheme.imageLinkKey] as? String {
                placeImage(link, over: run, in: copy, attributes: attributes)
            } else if attributes[MarkdownTheme.concealKey] != nil {
                copy.addAttributes(Self.hiddenAttributes, range: run)
            } else if attributes[MarkdownTheme.bulletKey] != nil {
                replace(run, in: copy, with: "\u{2022}")
            } else if attributes[MarkdownTheme.checkboxEmptyKey] != nil {
                placeCheckbox(checked: false, over: run, in: copy, attributes: attributes)
            } else if attributes[MarkdownTheme.checkboxDoneKey] != nil {
                placeCheckbox(checked: true, over: run, in: copy, attributes: attributes)
            }
        }
        return NSTextParagraph(attributedString: copy)
    }

    /// Matches the leading marker of a task line through its checkbox and trailing spaces.
    private static let taskMarkerPrefix = try! NSRegularExpression(
        pattern: #"^\s{0,8}[-*+] \[[ xX]\] +"#
    )
    /// Matches the leading marker of a bullet or ordered line through its trailing spaces.
    private static let listMarkerPrefix = try! NSRegularExpression(
        pattern: #"^\s{0,8}(?:[-*+]|\d{1,9}\.) +"#
    )

    /// The UTF-16 length of a line's leading list marker, or nil when the line opens no
    /// list. Task markers win over plain bullets so a checkbox includes its brackets.
    private func leadingMarkerLength(of line: String) -> Int? {
        let whole = NSRange(location: 0, length: (line as NSString).length)
        if let match = Self.taskMarkerPrefix.firstMatch(in: line, range: whole) {
            return match.range.length
        }
        if let match = Self.listMarkerPrefix.firstMatch(in: line, range: whole) {
            return match.range.length
        }
        return nil
    }

    /// Builds the caret line with only its leading list marker concealed: the bullet or
    /// checkbox renders while the rest of the line stays raw source. Returns nil when the
    /// line opens no list, so a plain caret line falls back to fully raw rendering.
    private func markerOnlyParagraph(
        for range: NSRange, in storage: NSTextStorage
    ) -> NSTextParagraph? {
        let line = storage.attributedSubstring(from: range).string
        guard let prefix = leadingMarkerLength(of: line) else { return nil }
        let copy = NSMutableAttributedString(
            attributedString: storage.attributedSubstring(from: range)
        )
        let markerRange = NSRange(location: 0, length: min(prefix, copy.length))
        copy.enumerateAttributes(in: markerRange, options: []) { attributes, run, _ in
            if attributes[MarkdownTheme.concealKey] != nil {
                copy.addAttributes(Self.hiddenAttributes, range: run)
            } else if attributes[MarkdownTheme.bulletKey] != nil {
                replace(run, in: copy, with: "\u{2022}")
            } else if attributes[MarkdownTheme.checkboxEmptyKey] != nil {
                placeCheckbox(checked: false, over: run, in: copy, attributes: attributes)
            } else if attributes[MarkdownTheme.checkboxDoneKey] != nil {
                placeCheckbox(checked: true, over: run, in: copy, attributes: attributes)
            }
        }
        return NSTextParagraph(attributedString: copy)
    }

    /// Renders an image link's first character as the picture itself and hides the
    /// rest of the link, so the image lives in the text flow at its natural size.
    private func placeImage(
        _ link: String, over run: NSRange, in copy: NSMutableAttributedString,
        attributes: [NSAttributedString.Key: Any]
    ) {
        guard run.length >= 1 else { return }
        let attachment = NSTextAttachment()
        let image: PlatformImage?
        if let cached = imageCache[link] {
            image = cached
        } else if let loaded = imageProvider?(link) {
            imageCache[link] = loaded
            image = loaded
        } else {
            image = nil
        }
        if let image, image.size.width > 0, image.size.height > 0 {
            attachment.image = image
            attachment.bounds = CGRect(origin: .zero, size: fitted(image.size))
        } else {
            // Missing file or locked vault: a quiet placeholder holds the space.
            #if canImport(AppKit)
                attachment.image = NSImage(
                    systemSymbolName: "lock.doc", accessibilityDescription: "Locked image"
                )
            #else
                attachment.image = UIImage(systemName: "lock.doc")
            #endif
            attachment.bounds = CGRect(x: 0, y: 0, width: 44, height: 56)
        }
        let placed = NSMutableAttributedString(attachment: attachment)
        if let paragraphStyle = attributes[.paragraphStyle] {
            placed.addAttribute(
                .paragraphStyle, value: paragraphStyle,
                range: NSRange(location: 0, length: placed.length)
            )
        }
        copy.replaceCharacters(in: NSRange(location: run.location, length: 1), with: placed)
        if run.length > 1 {
            copy.addAttributes(
                Self.hiddenAttributes,
                range: NSRange(location: run.location + 1, length: run.length - 1)
            )
        }
    }

    /// Draws a real checkbox in place of the box's center character, sized and vertically
    /// centered on the surrounding text. Only the single center character carries the
    /// attachment, so storage offsets stay identical to the raw source.
    private func placeCheckbox(
        checked: Bool, over run: NSRange, in copy: NSMutableAttributedString,
        attributes: [NSAttributedString.Key: Any]
    ) {
        guard run.length >= 1 else { return }
        let font = (attributes[.font] as? PlatformFont)
            ?? .systemFont(ofSize: MarkdownTheme.bodySize)
        let image = MarkdownTheme.checkboxImage(checked: checked, pointSize: font.pointSize)
        let side = image.size.width
        let attachment = NSTextAttachment()
        attachment.image = image
        let baseline = ((font.capHeight - side) / 2).rounded()
        attachment.bounds = CGRect(x: 0, y: baseline, width: side, height: side)
        let placed = NSMutableAttributedString(attachment: attachment)
        if let paragraphStyle = attributes[.paragraphStyle] {
            placed.addAttribute(
                .paragraphStyle, value: paragraphStyle,
                range: NSRange(location: 0, length: placed.length)
            )
        }
        copy.replaceCharacters(in: NSRange(location: run.location, length: 1), with: placed)
        if run.length > 1 {
            copy.addAttributes(
                Self.hiddenAttributes,
                range: NSRange(location: run.location + 1, length: run.length - 1)
            )
        }
    }

    /// The display size for an image: natural size, shrunk to the layout width and a
    /// height cap with aspect preserved, never upscaled.
    private func fitted(_ size: CGSize) -> CGSize {
        let maxHeight: CGFloat = 440
        let scale = min(maxImageWidth / size.width, maxHeight / size.height, 1)
        return CGSize(width: size.width * scale, height: size.height * scale)
    }

    /// A folded line: present but nearly heightless, so a folded section reads as gone
    /// while offsets and copying stay exact.
    private func collapsedParagraph(
        for range: NSRange, in storage: NSTextStorage
    ) -> NSTextParagraph {
        let copy = NSMutableAttributedString(
            attributedString: storage.attributedSubstring(from: range)
        )
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 0
        style.paragraphSpacing = 0
        style.maximumLineHeight = 0.5
        copy.setAttributes(
            [
                .font: Self.hiddenFont,
                .foregroundColor: PlatformColor.clear,
                .paragraphStyle: style,
            ],
            range: NSRange(location: 0, length: copy.length)
        )
        return NSTextParagraph(attributedString: copy)
    }

    /// Swaps a run's characters for a marker of the same length, keeping attributes, so
    /// presentation offsets stay identical to storage offsets.
    private func replace(_ run: NSRange, in copy: NSMutableAttributedString, with marker: String) {
        let repeated = String(repeating: marker, count: run.length)
        guard (repeated as NSString).length == run.length else { return }
        let attributes = copy.attributes(at: run.location, effectiveRange: nil)
        copy.replaceCharacters(
            in: run, with: NSAttributedString(string: repeated, attributes: attributes)
        )
    }

    /// Whether the caret paragraph starts inside the range, covering the empty last line.
    private func caretSitsIn(_ range: NSRange) -> Bool {
        caretParagraph.location != NSNotFound
            && caretParagraph.location >= range.location
            && caretParagraph.location < range.location + range.length
    }

    /// Moves the raw-source exemption to the caret's paragraph and asks the storage to
    /// re-present the lines that changed. Attribute-only edits, so undo stays untouched.
    func updateCaretParagraph(for selection: NSRange, in storage: NSTextStorage) {
        let text = storage.string as NSString
        let caret = min(selection.location, text.length)
        let paragraph = text.paragraphRange(for: NSRange(location: caret, length: 0))
        guard paragraph != caretParagraph else { return }
        let previous = caretParagraph
        caretParagraph = paragraph
        for range in [previous, paragraph] {
            repaint(range, in: storage)
        }
    }

    /// Replaces the folded regions, asking the storage to re-present every line whose
    /// fold state changed. Attribute-only edits, so undo stays untouched.
    func updateFolds(_ bodies: [NSRange], in storage: NSTextStorage) {
        guard bodies != foldedBodies else { return }
        let stale = foldedBodies
        foldedBodies = bodies
        for range in stale + bodies {
            repaint(range, in: storage)
        }
    }

    /// Forgets fold state without touching storage, for note switches.
    func resetFolds() {
        foldedBodies = []
    }

    /// Asks the storage to re-present a range after a presentation-only state change.
    private func repaint(_ range: NSRange, in storage: NSTextStorage) {
        guard range.location != NSNotFound, range.length > 0,
            range.location + range.length <= storage.length
        else { return }
        storage.edited(.editedAttributes, range: range, changeInLength: 0)
    }
}
