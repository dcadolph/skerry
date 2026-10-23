import Foundation
import SkerryKit

#if canImport(AppKit)
    import AppKit
    /// Font type shared across platforms.
    typealias PlatformFont = NSFont
    /// Color type shared across platforms.
    typealias PlatformColor = NSColor
    /// Image type shared across platforms.
    typealias PlatformImage = NSImage
#else
    import UIKit
    /// Font type shared across platforms.
    typealias PlatformFont = UIFont
    /// Color type shared across platforms.
    typealias PlatformColor = UIColor
    /// Image type shared across platforms.
    typealias PlatformImage = UIImage
#endif

/// MarkdownTheme maps scanner tokens to TextKit attributes.
enum MarkdownTheme {
    #if os(iOS)
        /// Point size of body prose, a touch above the platform reading size.
        static let baseBodySize: CGFloat = 18
        /// Heading point sizes by level.
        static let baseHeadingSizes: [CGFloat] = [30, 24, 21, 18, 18, 18]
        /// Extra height between wrapped lines.
        static let lineSpacing: CGFloat = 5
        /// Air between paragraphs.
        static let paragraphSpacing: CGFloat = 8
        /// Tight air between consecutive list items, so a list reads as one block.
        static let listItemSpacing: CGFloat = 2
        /// Extra gap between a list marker and its text, for a cleaner bullet-to-word rhythm.
        static let bulletGap: CGFloat = 10
    #else
        /// Point size of body prose, a touch above the platform reading size.
        static let baseBodySize: CGFloat = 16
        /// Heading point sizes by level.
        static let baseHeadingSizes: [CGFloat] = [26, 21, 18, 16, 16, 16]
        /// Extra height between wrapped lines.
        static let lineSpacing: CGFloat = 3.5
        /// Air between paragraphs.
        static let paragraphSpacing: CGFloat = 6
        /// Tight air between consecutive list items, so a list reads as one block.
        static let listItemSpacing: CGFloat = 1.5
        /// Extra gap between a list marker and its text, for a cleaner bullet-to-word rhythm.
        static let bulletGap: CGFloat = 8
    #endif

    /// Multiplier the editor text-size setting applies to reading sizes. Set on the main actor.
    nonisolated(unsafe) static var sizeScale: CGFloat = 1
    /// Accent color chosen in Settings, overriding the system accent when set.
    nonisolated(unsafe) static var accentOverride: PlatformColor?
    /// Editor background from the active theme; nil follows the system.
    nonisolated(unsafe) static var backgroundOverride: PlatformColor?
    /// Body ink from the active theme; nil follows the system label color.
    nonisolated(unsafe) static var textOverride: PlatformColor?
    /// Code color from the active theme; nil keeps the default.
    nonisolated(unsafe) static var codeOverride: PlatformColor?

    /// Body prose size after the reading-size setting.
    static var bodySize: CGFloat { baseBodySize * sizeScale }
    /// Heading sizes after the reading-size setting.
    static var headingSizes: [CGFloat] { baseHeadingSizes.map { $0 * sizeScale } }

    /// Paragraph style shared by all prose: breathing room between lines and paragraphs.
    static var baseParagraphStyle: NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = lineSpacing
        style.paragraphSpacing = paragraphSpacing
        return style
    }

    /// Paragraph style for headings: extra space above so sections separate visually.
    static var headingParagraphStyle: NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = lineSpacing
        style.paragraphSpacing = paragraphSpacing
        style.paragraphSpacingBefore = paragraphSpacing * 1.5
        return style
    }

    /// Paragraph style for a list-item line: tight spacing plus a hanging indent so wrapped
    /// lines align under the item text instead of falling back under the bullet.
    static func listParagraphStyle(forLine line: String) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = lineSpacing
        style.paragraphSpacing = listItemSpacing
        style.headIndent = listContentIndent(forLine: line)
        return style
    }

    /// Matches a list line's prefix: leading indent, bullet or number, and any checkbox.
    private static let listPrefixPattern = try! NSRegularExpression(
        pattern: #"^[ \t]{0,8}(?:[-*+]|\d{1,4}\.)[ \t]+(?:\[[ xX]\][ \t]+)?"#
    )

    /// Horizontal offset where a list item's text begins, used as the hanging indent.
    private static func listContentIndent(forLine line: String) -> CGFloat {
        let ns = line as NSString
        guard let match = listPrefixPattern.firstMatch(
            in: line, range: NSRange(location: 0, length: ns.length)
        ) else { return 0 }
        let prefix = ns.substring(with: match.range)
        let base = (prefix as NSString).size(
            withAttributes: [.font: PlatformFont.systemFont(ofSize: bodySize)]
        ).width
        // Bullets and numbers gain the extra marker gap; task rows keep the box tight.
        return base + (prefix.contains("[") ? 0 : bulletGap)
    }

    /// Attributes applied to the whole document before token styling.
    static var baseAttributes: [NSAttributedString.Key: Any] {
        [
            .font: PlatformFont.systemFont(ofSize: bodySize),
            .foregroundColor: labelColor,
            .paragraphStyle: baseParagraphStyle,
        ]
    }

    /// Attributes for one token kind.
    static func attributes(for kind: MarkdownScanner.TokenKind) -> [NSAttributedString.Key: Any] {
        switch kind {
        case .heading(let level):
            let size = headingSizes[min(max(level, 1), 6) - 1]
            return [
                .font: PlatformFont.boldSystemFont(ofSize: size),
                .paragraphStyle: headingParagraphStyle,
            ]
        case .bold:
            return [.font: PlatformFont.boldSystemFont(ofSize: bodySize)]
        case .italic:
            return [.font: italicBodyFont]
        case .inlineCode, .fencedCode:
            return [
                .font: PlatformFont.monospacedSystemFont(
                    ofSize: bodySize - 1.5, weight: .regular
                ),
                .foregroundColor: codeColor,
            ]
        case .link:
            return [.foregroundColor: linkColor]
        case .wikiLink:
            return [
                .foregroundColor: accentColor,
                .font: PlatformFont.boldSystemFont(ofSize: bodySize),
            ]
        case .listMarker:
            return [
                .font: PlatformFont.boldSystemFont(ofSize: bodySize),
                .foregroundColor: accentColor,
            ]
        case .taskMarker(let checked):
            return [.foregroundColor: checked ? accentColor : secondaryColor]
        case .taskDone:
            return [
                .foregroundColor: secondaryColor,
                .strikethroughStyle: NSUnderlineStyle.single.rawValue,
            ]
        case .blockquote:
            return [.foregroundColor: secondaryColor, .font: italicBodyFont]
        case .tablePipe:
            return [.foregroundColor: secondaryColor]
        case .tableDelimiterRow:
            return [.foregroundColor: secondaryColor]
        case .tableHeader:
            return [.font: PlatformFont.boldSystemFont(ofSize: bodySize)]
        case .footnoteReference:
            return [
                .font: PlatformFont.systemFont(ofSize: bodySize * 0.75),
                .baselineOffset: bodySize * 0.25,
                .foregroundColor: accentColor,
            ]
        case .footnoteDefinition:
            return [
                .font: PlatformFont.boldSystemFont(ofSize: bodySize * 0.85),
                .foregroundColor: accentColor,
            ]
        case .tag:
            return [
                .foregroundColor: accentColor,
                .font: PlatformFont.systemFont(ofSize: bodySize * 0.9, weight: .medium),
            ]
        case .image:
            return [.foregroundColor: secondaryColor]
        case .highlightMark:
            return [.backgroundColor: highlightColor]
        case .codeKeyword:
            return [.foregroundColor: PlatformColor.systemPink]
        case .codeString:
            return [.foregroundColor: PlatformColor.systemOrange]
        case .codeComment:
            return [.foregroundColor: secondaryColor]
        case .codeNumber:
            return [.foregroundColor: PlatformColor.systemTeal]
        case .calloutHeader:
            return [
                .foregroundColor: accentColor,
                .font: PlatformFont.boldSystemFont(ofSize: bodySize),
            ]
        }
    }

    /// Height reserved beneath a line holding an image link, where the picture renders.
    static var inlineImageBand: CGFloat { 168 * sizeScale }

    /// URL scheme carrying wiki-link clicks from the text view to the app.
    static let wikiLinkScheme = "skerry-wiki"

    /// Attribute marking syntax characters the layout hides away from the caret line.
    static let concealKey = NSAttributedString.Key("skerryConceal")
    /// Attribute marking a list dash the layout draws as a bullet dot.
    static let bulletKey = NSAttributedString.Key("skerryBullet")
    /// Attribute marking a checkbox center the layout draws as an empty box.
    static let checkboxEmptyKey = NSAttributedString.Key("skerryCheckboxEmpty")
    /// Attribute marking a checkbox center the layout draws as a checked box.
    static let checkboxDoneKey = NSAttributedString.Key("skerryCheckboxDone")
    /// Attribute carrying a local image link the TextKit 2 editor renders in the text
    /// flow as an attachment, in place of the overlay band the legacy editor uses.
    static let imageLinkKey = NSAttributedString.Key("skerryImageLink")

    /// Applies base and token attributes to storage holding the given text.
    /// Non-Markdown formats get base styling only. With a focus range, everything outside
    /// it is dimmed, the paragraph-focus writing mode. A dirty range limits the work to
    /// the edited paragraphs and their neighbors, so typing never restyles the whole
    /// document; pass nil after loads, style changes, or edits that move fence state.
    static func highlight(
        _ storage: NSTextStorage, asMarkdown: Bool = true, focusRange: NSRange? = nil,
        dirty: NSRange? = nil, imagesInFlow: Bool = false
    ) {
        let full = NSRange(location: 0, length: storage.length)
        let text = storage.string as NSString
        let affected = dirty.map { MarkdownEditing.paragraphsAround($0, in: storage.string) }
            ?? full
        let isFull = affected == full
        storage.beginEditing()
        storage.setAttributes(baseAttributes, range: affected)
        defer {
            if let focusRange {
                dimOutsideFocus(focusRange, in: storage, within: affected)
            }
            storage.endEditing()
        }
        guard asMarkdown else { return }
        for token in MarkdownScanner.scan(storage.string) {
            guard token.range.location + token.range.length <= storage.length else { continue }
            let clipped = isFull ? token.range : NSIntersectionRange(token.range, affected)
            guard clipped.length > 0 else { continue }
            storage.addAttributes(attributes(for: token.kind), range: clipped)
            // Whole-token work runs only when the token sits inside the restyled range;
            // a token merely clipped by it keeps its earlier marks, which still stand.
            guard clipped == token.range else { continue }
            if token.kind == .wikiLink, let url = wikiURL(for: token.range, in: text) {
                storage.addAttribute(.link, value: url, range: token.range)
            }
            switch token.kind {
            case .listMarker, .taskMarker:
                let line = text.paragraphRange(for: token.range)
                let style = listParagraphStyle(forLine: text.substring(with: line))
                storage.addAttribute(.paragraphStyle, value: style, range: line)
            case .image:
                if let link = localImageLink(in: token.range, of: text) {
                    if imagesInFlow {
                        storage.addAttribute(imageLinkKey, value: link, range: token.range)
                    } else {
                        // The paragraph grows a band below it where the picture renders.
                        let line = text.paragraphRange(for: token.range)
                        let style = NSMutableParagraphStyle()
                        style.lineSpacing = lineSpacing
                        style.paragraphSpacing = paragraphSpacing + inlineImageBand
                        storage.addAttribute(.paragraphStyle, value: style, range: line)
                    }
                }
            default:
                break
            }
            markConcealment(for: token, in: storage, text: text)
        }
    }

    /// The local link inside an image token, nil for remote images, which render as
    /// their visible markdown rather than pictures.
    static func localImageLink(in range: NSRange, of text: NSString) -> String? {
        let span = text.substring(with: range)
        guard let match = MarkdownScanner.imagePattern.firstMatch(
            in: span, range: NSRange(location: 0, length: (span as NSString).length)
        ) else { return nil }
        let link = (span as NSString).substring(with: match.range(at: 1))
            .trimmingCharacters(in: .whitespaces)
        return link.contains("://") ? nil : link
    }

    /// Dims the restyled range's characters outside the focus range, leaving fonts and
    /// layout untouched so the text does not reflow as focus moves.
    private static func dimOutsideFocus(
        _ focus: NSRange, in storage: NSTextStorage, within affected: NSRange
    ) {
        let dim: [NSAttributedString.Key: Any] = [.foregroundColor: dimmedColor]
        let focusClamped = NSIntersectionRange(focus, affected)
        guard focusClamped.length > 0 else {
            if affected.length > 0 { storage.addAttributes(dim, range: affected) }
            return
        }
        if focusClamped.location > affected.location {
            storage.addAttributes(dim, range: NSRange(
                location: affected.location, length: focusClamped.location - affected.location
            ))
        }
        let focusEnd = focusClamped.location + focusClamped.length
        let affectedEnd = affected.location + affected.length
        if focusEnd < affectedEnd {
            storage.addAttributes(dim, range: NSRange(
                location: focusEnd, length: affectedEnd - focusEnd
            ))
        }
    }

    /// Tags the syntax delimiters of a token so layout can hide them off the caret line.
    private static func markConcealment(
        for token: MarkdownScanner.Token, in storage: NSTextStorage, text: NSString
    ) {
        let range = token.range
        func conceal(_ location: Int, _ length: Int) {
            guard length > 0, location >= 0, location + length <= storage.length else { return }
            storage.addAttribute(concealKey, value: true, range: NSRange(location: location, length: length))
        }
        switch token.kind {
        case .heading(let level):
            conceal(range.location, min(level + 1, range.length))
        case .bold:
            conceal(range.location, 2)
            conceal(range.location + range.length - 2, 2)
        case .italic, .inlineCode:
            conceal(range.location, 1)
            conceal(range.location + range.length - 1, 1)
        case .listMarker:
            let marker = text.substring(with: range).trimmingCharacters(in: .whitespaces)
            let afterMarker = range.location + range.length
            let peek = NSRange(location: afterMarker, length: min(4, text.length - afterMarker))
            let hasCheckbox = ["-", "*", "+"].contains(marker) && peek.length == 4
                && text.substring(with: peek).range(
                    of: #"^ \[[ xX]\]"#, options: .regularExpression
                ) != nil
            if hasCheckbox {
                // A bullet directly followed by a checkbox hides so only the box shows.
                conceal(range.location + range.length - 1, 1)
            } else {
                if ["-", "*", "+"].contains(marker) {
                    storage.addAttribute(
                        bulletKey, value: true,
                        range: NSRange(location: range.location + range.length - 1, length: 1)
                    )
                }
                // Widen the gap after the marker so words sit clearly apart from the bullet.
                if afterMarker < storage.length {
                    storage.addAttribute(
                        .kern, value: bulletGap,
                        range: NSRange(location: afterMarker, length: 1)
                    )
                }
            }
        case .taskMarker(let checked):
            conceal(range.location, 1)
            conceal(range.location + range.length - 1, 1)
            storage.addAttribute(
                checked ? checkboxDoneKey : checkboxEmptyKey, value: true,
                range: NSRange(location: range.location + 1, length: 1)
            )
        case .image:
            // The whole link conceals off the caret line; the picture stands in for it.
            conceal(range.location, range.length)
        case .highlightMark:
            conceal(range.location, 2)
            conceal(range.location + range.length - 2, 2)
        case .taskDone, .blockquote, .fencedCode, .link, .wikiLink,
            .tablePipe, .tableDelimiterRow, .tableHeader,
            .footnoteReference, .footnoteDefinition, .tag,
            .codeKeyword, .codeString, .codeComment, .codeNumber, .calloutHeader:
            break
        }
    }

    /// Builds the click-through URL for a wiki-link token range. The note lands in the
    /// host and any `#heading` in the fragment, both fully percent-encoded, so a target
    /// with spaces stays a valid URL and the heading rides along to the opened note.
    private static func wikiURL(for range: NSRange, in text: NSString) -> URL? {
        let inner = text.substring(with: range)
            .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        let target = WikiLink.split(inner)
        guard let note = target.note.addingPercentEncoding(withAllowedCharacters: .alphanumerics)
        else { return nil }
        var string = "\(wikiLinkScheme)://\(note)"
        if let heading = target.heading?.addingPercentEncoding(withAllowedCharacters: .alphanumerics) {
            string += "#\(heading)"
        }
        return URL(string: string)
    }

    /// The note a wiki-link URL points at, empty for a heading-only link within the same
    /// note, nil for a foreign URL.
    static func wikiTarget(from url: URL) -> String? {
        guard url.scheme == wikiLinkScheme else { return nil }
        return url.host()?.removingPercentEncoding ?? ""
    }

    /// The heading a wiki-link URL scrolls to, nil when it names none.
    static func wikiFragment(from url: URL) -> String? {
        guard url.scheme == wikiLinkScheme else { return nil }
        return url.fragment(percentEncoded: false)
    }

    /// Italic variant of the body font.
    private static var italicBodyFont: PlatformFont {
        #if canImport(AppKit)
            let base = NSFont.systemFont(ofSize: bodySize)
            return NSFontManager.shared.convert(base, toHaveTrait: .italicFontMask)
        #else
            return UIFont.italicSystemFont(ofSize: bodySize)
        #endif
    }

    /// Primary text color, themed when a palette overrides it.
    private static var labelColor: PlatformColor {
        if let textOverride { return textOverride }
        #if canImport(AppKit)
            return .labelColor
        #else
            return .label
        #endif
    }

    /// Dimmed color for blockquotes.
    private static var secondaryColor: PlatformColor {
        #if canImport(AppKit)
            .secondaryLabelColor
        #else
            .secondaryLabel
        #endif
    }

    /// Faint color for text outside the focused paragraph.
    private static var dimmedColor: PlatformColor {
        #if canImport(AppKit)
            .tertiaryLabelColor
        #else
            .tertiaryLabel
        #endif
    }

    /// Background wash for `==highlighted==` spans.
    private static var highlightColor: PlatformColor {
        PlatformColor.systemYellow.withAlphaComponent(0.35)
    }

    /// Color for code spans, themed when a palette overrides it.
    private static var codeColor: PlatformColor {
        codeOverride ?? .systemPurple
    }

    /// Color for links.
    private static var linkColor: PlatformColor {
        #if canImport(AppKit)
            .linkColor
        #else
            .link
        #endif
    }

    /// Accent color for list markers.
    private static var accentColor: PlatformColor {
        #if canImport(AppKit)
            .controlAccentColor
        #else
            .tintColor
        #endif
    }

    /// Tint for checkboxes and list markers, honoring a Settings accent override.
    static var markerAccent: PlatformColor { accentOverride ?? accentColor }

    /// A drawn checkbox for the editor: a rounded square that is either empty with a
    /// muted outline or filled with the accent and a white check, sized to the given text
    /// point size. Replaces the character-substituted box glyph so the checkbox looks the
    /// same in every font and reads as a real control rather than a tiny symbol.
    static func checkboxImage(checked: Bool, pointSize: CGFloat) -> PlatformImage {
        let side = (pointSize * 1.05).rounded()
        let inset = max(1.5, side * 0.09)
        let radius = side * 0.28
        let size = CGSize(width: side, height: side)
        let accent = markerAccent
        let outline = secondaryColor

        // Checkmark vertices in top-left coordinates, flipped per platform below.
        func check(_ flipped: Bool) -> [CGPoint] {
            let raw: [(CGFloat, CGFloat)] = [(0.27, 0.53), (0.43, 0.69), (0.73, 0.34)]
            return raw.map { CGPoint(x: $0.0 * side, y: (flipped ? 1 - $0.1 : $0.1) * side) }
        }
        let boxRect = CGRect(x: 0, y: 0, width: side, height: side).insetBy(dx: inset, dy: inset)

        #if canImport(AppKit)
            let image = NSImage(size: size)
            image.lockFocus()
            let box = NSBezierPath(roundedRect: boxRect, xRadius: radius, yRadius: radius)
            box.lineWidth = inset
            if checked {
                accent.setFill()
                box.fill()
                let mark = NSBezierPath()
                let points = check(true)
                mark.move(to: points[0])
                mark.line(to: points[1])
                mark.line(to: points[2])
                mark.lineWidth = max(1.5, side * 0.11)
                mark.lineCapStyle = .round
                mark.lineJoinStyle = .round
                PlatformColor.white.setStroke()
                mark.stroke()
            } else {
                outline.setStroke()
                box.stroke()
            }
            image.unlockFocus()
            return image
        #else
            let renderer = UIGraphicsImageRenderer(size: size)
            return renderer.image { _ in
                let box = UIBezierPath(roundedRect: boxRect, cornerRadius: radius)
                box.lineWidth = inset
                if checked {
                    accent.setFill()
                    box.fill()
                    let mark = UIBezierPath()
                    let points = check(false)
                    mark.move(to: points[0])
                    mark.addLine(to: points[1])
                    mark.addLine(to: points[2])
                    mark.lineWidth = max(1.5, side * 0.11)
                    mark.lineCapStyle = .round
                    mark.lineJoinStyle = .round
                    PlatformColor.white.setStroke()
                    mark.stroke()
                } else {
                    outline.setStroke()
                    box.stroke()
                }
            }
        #endif
    }
}
