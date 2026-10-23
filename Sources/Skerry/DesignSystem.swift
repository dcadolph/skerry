import SkerryKit
import SwiftUI

/// Style is the shared visual vocabulary for Skerry's chrome: one spacing grid, one set of
/// radii, and a few semantic colors, so every view reads as part of the same app rather than
/// a pile of one-off numbers. The editor keeps its own [MarkdownTheme]; this governs lists,
/// cards, chips, and the sidebar.
enum Style {
    /// Spacing steps on a four-point grid, from hairline gaps to section breaks.
    enum Space {
        /// Two points, for glyph-to-text gaps.
        static let xxs: CGFloat = 2
        /// Four points.
        static let xs: CGFloat = 4
        /// Eight points, the default gap between stacked elements.
        static let s: CGFloat = 8
        /// Twelve points, the default block padding.
        static let m: CGFloat = 12
        /// Sixteen points.
        static let l: CGFloat = 16
        /// Twenty-four points, for section separation.
        static let xl: CGFloat = 24
    }

    /// Corner radii, kept few so shapes rhyme across the app.
    enum Radius {
        /// Chips and small pills.
        static let chip: CGFloat = 6
        /// List rows and inline surfaces.
        static let row: CGFloat = 10
        /// Cards and larger panels.
        static let card: CGFloat = 14
    }

    /// Hairline color for separators and card borders, faint in both appearances.
    static let hairline = Color.primary.opacity(0.08)
    /// Resting fill for a card, a barely-there lift off the background.
    static let cardFill = Color.primary.opacity(0.04)
    /// Fill for a selected row or card, tinted by the app accent.
    static let selectionFill = Color.accentColor.opacity(0.16)
    /// Background wash behind a tag chip.
    static let chipFill = Color.accentColor.opacity(0.14)
}

/// ListDensity sets how much air the note rows carry, so the same list can be a tight scan
/// or a roomy read. This is the kind of control Bear does not offer, and it is one setting.
enum ListDensity: String, CaseIterable, Identifiable, Sendable {
    /// A tight, single-line-preview scan that fits the most notes on screen.
    case compact
    /// The balanced default: a two-line preview with comfortable spacing.
    case comfortable
    /// A roomy read with a three-line preview and generous spacing.
    case spacious

    /// Stable identity for pickers.
    var id: String { rawValue }

    /// Menu and picker label.
    var label: String {
        switch self {
        case .compact: return "Compact"
        case .comfortable: return "Comfortable"
        case .spacious: return "Spacious"
        }
    }

    /// SF Symbol standing in for the density in a menu.
    var symbol: String {
        switch self {
        case .compact: return "rectangle.compress.vertical"
        case .comfortable: return "rectangle.grid.1x2"
        case .spacious: return "rectangle.expand.vertical"
        }
    }

    /// Vertical padding above and below a row's content.
    var rowPadding: CGFloat {
        switch self {
        case .compact: return Style.Space.xs
        case .comfortable: return Style.Space.s - 1
        case .spacious: return Style.Space.m - 1
        }
    }

    /// Spacing between the title, preview, and meta lines of a row.
    var rowSpacing: CGFloat {
        switch self {
        case .compact: return Style.Space.xxs
        case .comfortable: return Style.Space.xs
        case .spacious: return Style.Space.s - 2
        }
    }

    /// How many preview lines a row shows, zero when the density hides the preview.
    var previewLineLimit: Int {
        switch self {
        case .compact: return 1
        case .comfortable: return 2
        case .spacious: return 3
        }
    }
}

/// SearchMatch builds display text that emphasizes where a query landed, shared by the note
/// rows and cards so a result always shows its match the same way.
enum SearchMatch {
    /// An attributed rendering of a hit's snippet with the matched terms weighted and tinted.
    /// Falls back to plain text when the hit carries no highlight ranges.
    static func snippet(_ hit: NoteIndex.Hit) -> AttributedString {
        let source = hit.snippet as NSString
        guard source.length > 0 else { return AttributedString() }
        let full = NSRange(location: 0, length: source.length)
        var result = AttributedString()
        var cursor = 0
        for range in hit.highlights.sorted(by: { $0.location < $1.location }) {
            let clamped = NSIntersectionRange(range, full)
            guard clamped.length > 0, clamped.location >= cursor else { continue }
            if clamped.location > cursor {
                result += AttributedString(
                    source.substring(with: NSRange(location: cursor, length: clamped.location - cursor))
                )
            }
            var matched = AttributedString(source.substring(with: clamped))
            matched.foregroundColor = .accentColor
            matched.inlinePresentationIntent = .stronglyEmphasized
            result += matched
            cursor = clamped.location + clamped.length
        }
        if cursor < source.length {
            result += AttributedString(
                source.substring(with: NSRange(location: cursor, length: source.length - cursor))
            )
        }
        return result
    }
}

/// TagPalette gives every tag a stable color, so a tag reads the same in the sidebar, the
/// note rows, and the editor's tag bar. The slot comes from [TagColor] in the kit, which
/// hashes the name the same way on every device; this is only the list of colors.
enum TagPalette {
    /// Eight hues chosen to stay legible on both light and dark backgrounds.
    static let colors: [Color] = [
        Color(hex: 0x2AA198), Color(hex: 0x4C86C6), Color(hex: 0x6C5CE7),
        Color(hex: 0xB1589E), Color(hex: 0xE07A5F), Color(hex: 0xD9A441),
        Color(hex: 0x5FA85B), Color(hex: 0xC65D5D),
    ]

    /// The color a tag wears, derived from its name.
    static func color(for tag: String) -> Color {
        colors[TagColor.paletteIndex(for: tag, count: colors.count)]
    }
}

/// TagChip is the one true tag pill: a small capsule tinted with the tag's own color, used
/// in rows, cards, and the tag bar, so tags look the same everywhere they appear.
struct TagChip: View {
    /// Tag text without the leading hash.
    let tag: String
    /// Whether to lead with a colored dot, for denser contexts like the tag bar.
    var showsDot = false

    var body: some View {
        let color = TagPalette.color(for: tag)
        HStack(spacing: Style.Space.xs) {
            if showsDot {
                Circle().fill(color).frame(width: 6, height: 6)
            }
            Text(tag)
                .font(.caption2)
                .lineLimit(1)
        }
        .padding(.horizontal, Style.Space.s - 2)
        .padding(.vertical, Style.Space.xxs - 0.5)
        .background(color.opacity(0.16), in: Capsule())
        .foregroundStyle(color)
    }
}

/// TagDot is a small color swatch standing in for a tag in tight rows like the sidebar.
struct TagDot: View {
    /// Tag whose color the dot shows.
    let tag: String

    var body: some View {
        Circle()
            .fill(TagPalette.color(for: tag))
            .frame(width: 8, height: 8)
    }
}
