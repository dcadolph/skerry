import Foundation

#if canImport(AppKit)
    import AppKit
#else
    import UIKit
#endif

/// ConcealingGlyphs hides Markdown syntax at the layout layer: delimiters tagged by the
/// theme render as nothing and list dashes render as bullet dots, except on the line the
/// caret occupies, which always shows raw source. The underlying text never changes.
final class ConcealingGlyphs: NSObject, NSLayoutManagerDelegate {
    /// Caret position; markers within one character of it render raw for editing.
    private var caretIndex = NSNotFound
    /// Line holding the caret, tracked so caret moves redraw only affected lines.
    private var caretLineRange = NSRange(location: NSNotFound, length: 0)

    /// Whether a marker run should render raw because the caret sits inside it.
    /// The trailing edge stays concealed so markers hide the instant they are typed.
    private func caretTouches(_ run: NSRange) -> Bool {
        guard caretIndex != NSNotFound else { return false }
        return caretIndex >= run.location - 1 && caretIndex < run.location + run.length
    }

    func layoutManager(
        _ layoutManager: NSLayoutManager,
        shouldGenerateGlyphs glyphs: UnsafePointer<CGGlyph>,
        properties: UnsafePointer<NSLayoutManager.GlyphProperty>,
        characterIndexes: UnsafePointer<Int>,
        font: PlatformFont,
        forGlyphRange glyphRange: NSRange
    ) -> Int {
        guard let storage = layoutManager.textStorage else { return 0 }
        let count = glyphRange.length
        var newGlyphs = Array(UnsafeBufferPointer(start: glyphs, count: count))
        var newProperties = Array(UnsafeBufferPointer(start: properties, count: count))
        var modified = false
        let ctFont = CTFontCreateWithFontDescriptor(
            font.fontDescriptor as CTFontDescriptor, font.pointSize, nil
        )
        for position in 0..<count {
            let charIndex = characterIndexes[position]
            guard charIndex < storage.length else { continue }
            var run = NSRange(location: 0, length: 0)
            if storage.attribute(MarkdownTheme.concealKey, at: charIndex, effectiveRange: &run)
                != nil {
                guard !caretTouches(run) else { continue }
                newProperties[position] = .null
                modified = true
            } else if storage.attribute(
                MarkdownTheme.bulletKey, at: charIndex, effectiveRange: &run
            ) != nil {
                guard !caretTouches(run) else { continue }
                if substitute(0x2022, at: position, font: ctFont, into: &newGlyphs) {
                    modified = true
                }
            } else if storage.attribute(
                MarkdownTheme.checkboxEmptyKey, at: charIndex, effectiveRange: &run
            ) != nil {
                guard !caretTouches(run) else { continue }
                if substitute(0x2610, at: position, font: ctFont, into: &newGlyphs) {
                    modified = true
                }
            } else if storage.attribute(
                MarkdownTheme.checkboxDoneKey, at: charIndex, effectiveRange: &run
            ) != nil {
                guard !caretTouches(run) else { continue }
                if substitute(0x2611, at: position, font: ctFont, into: &newGlyphs) {
                    modified = true
                }
            }
        }
        guard modified else { return 0 }
        newGlyphs.withUnsafeBufferPointer { glyphBuffer in
            newProperties.withUnsafeBufferPointer { propertyBuffer in
                layoutManager.setGlyphs(
                    glyphBuffer.baseAddress!, properties: propertyBuffer.baseAddress!,
                    characterIndexes: characterIndexes, font: font, forGlyphRange: glyphRange
                )
            }
        }
        return count
    }

    /// Swaps one glyph for the character's glyph in the given font; false if unavailable.
    private func substitute(
        _ codepoint: UniChar, at position: Int, font: CTFont, into glyphs: inout [CGGlyph]
    ) -> Bool {
        var character = codepoint
        var glyph: CGGlyph = 0
        guard CTFontGetGlyphsForCharacters(font, &character, &glyph, 1) else { return false }
        glyphs[position] = glyph
        return true
    }

    /// Moves the raw-source exemption to the new caret spot and redraws affected lines.
    func updateActiveLine(for selection: NSRange, in layoutManager: NSLayoutManager) {
        guard let storage = layoutManager.textStorage else { return }
        let text = storage.string as NSString
        let newCaret = min(selection.location, text.length)
        let newLine: NSRange
        if text.length == 0 {
            newLine = NSRange(location: 0, length: 0)
        } else {
            newLine = text.lineRange(
                for: NSRange(location: min(newCaret, text.length - 1), length: 0)
            )
        }
        guard newCaret != caretIndex else { return }
        let previousLine = caretLineRange
        caretIndex = newCaret
        caretLineRange = newLine
        for range in [previousLine, newLine] {
            guard range.location != NSNotFound, range.length > 0,
                range.location + range.length <= storage.length
            else { continue }
            layoutManager.invalidateGlyphs(
                forCharacterRange: range, changeInLength: 0, actualCharacterRange: nil
            )
            layoutManager.invalidateLayout(forCharacterRange: range, actualCharacterRange: nil)
        }
    }
}
