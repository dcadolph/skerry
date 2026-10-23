import SkerryKit
import SwiftUI

/// CompletionContext is the tag or wiki-link token being typed at the caret.
struct CompletionContext: Equatable {
    /// What kind of completion applies.
    enum Kind: Equatable {
        /// Typing after `#`.
        case tag
        /// Typing inside an unclosed `[[`.
        case wikiLink
        /// Typing a heading after the `#` in an unclosed `[[Note#`; the associated value
        /// is the note whose headings to offer, empty for the note being edited.
        case wikiHeading(note: String)
    }
    /// Completion kind.
    var kind: Kind
    /// Characters typed so far, hash or brackets excluded.
    var prefix: String
    /// UTF-16 range of the prefix, the range a completion replaces.
    var range: NSRange
}

/// Finds the completion token at a caret: a `#tag` being typed, or the name inside an
/// unclosed `[[` on the same line. Nil when the caret is not in either.
func completionContext(text: NSString, caret: Int) -> CompletionContext? {
    guard caret > 0, caret <= text.length else { return nil }
    let lineStart = text.lineRange(for: NSRange(location: caret - 1, length: 0)).location

    // Wiki link: the nearest [[ before the caret on this line, with no closer between.
    var probe = caret - 2
    while probe >= lineStart {
        let char = text.character(at: probe)
        if char == 0x5D { break }
        if char == 0x5B, probe + 1 < text.length, text.character(at: probe + 1) == 0x5B {
            let prefixRange = NSRange(location: probe + 2, length: caret - probe - 2)
            let prefix = text.substring(with: prefixRange)
            if prefix.contains("[") { break }
            let hash = (prefix as NSString).range(of: "#")
            if hash.location != NSNotFound {
                // Past the `#`, the caret names a heading in the note before it.
                let note = (prefix as NSString).substring(to: hash.location)
                let headingStart = prefixRange.location + hash.location + 1
                return CompletionContext(
                    kind: .wikiHeading(note: note.trimmingCharacters(in: .whitespaces)),
                    prefix: (prefix as NSString).substring(from: hash.location + 1),
                    range: NSRange(location: headingStart, length: caret - headingStart)
                )
            }
            return CompletionContext(kind: .wikiLink, prefix: prefix, range: prefixRange)
        }
        probe -= 1
    }

    // Tag: word characters back to a hash that is not glued to a word or another hash.
    var start = caret
    while start > lineStart {
        let char = text.character(at: start - 1)
        guard isTagCharacter(char) else { break }
        start -= 1
    }
    if start > lineStart, text.character(at: start - 1) == 0x23 {
        let beforeHash = start - 2
        let clean = beforeHash < lineStart
            || (!isTagCharacter(text.character(at: beforeHash))
                && text.character(at: beforeHash) != 0x23)
        if clean {
            let prefixRange = NSRange(location: start, length: caret - start)
            return CompletionContext(
                kind: .tag, prefix: text.substring(with: prefixRange), range: prefixRange
            )
        }
    }
    return nil
}

/// Whether a UTF-16 unit can sit inside a tag name.
private func isTagCharacter(_ unit: unichar) -> Bool {
    guard let scalar = Unicode.Scalar(unit) else { return false }
    return CharacterSet.alphanumerics.contains(scalar)
        || scalar == "-" || scalar == "_" || scalar == "/"
}

/// The pasted string as a linkable web URL, nil when it is not a bare link.
func linkableURL(_ candidate: String) -> String? {
    let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
    let lowered = trimmed.lowercased()
    guard !trimmed.contains(" "), !trimmed.contains("\n"),
        lowered.hasPrefix("http://") || lowered.hasPrefix("https://"),
        URL(string: trimmed) != nil
    else { return nil }
    return trimmed
}

/// Ranks completion candidates for a prefix: prefix matches first, then substring
/// matches, case-insensitive, capped, with an exact match excluded so an accepted
/// completion does not immediately re-offer itself.
func completionMatches(_ candidates: [String], prefix: String) -> [String] {
    let query = prefix.lowercased()
    if query.isEmpty { return Array(candidates.prefix(8)) }
    var prefixed: [String] = []
    var contained: [String] = []
    for candidate in candidates {
        let lowered = candidate.lowercased()
        if lowered == query { continue }
        if lowered.hasPrefix(query) {
            prefixed.append(candidate)
        } else if lowered.contains(query) {
            contained.append(candidate)
        }
    }
    return Array((prefixed + contained).prefix(8))
}

#if canImport(AppKit)

    /// PastingTextView intercepts image pastes and inserts a Markdown link instead.
    final class PastingTextView: NSTextView {
        /// Saves pasted image data and returns the link path to insert, nil to decline.
        var onPasteImage: (Data, String) -> String? = { _, _ in nil }

        override func paste(_ sender: Any?) {
            let pasteboard = NSPasteboard.general
            // A URL pasted over selected text wraps it as a markdown link.
            if selectedRange().length > 0,
                let candidate = pasteboard.string(forType: .string),
                let url = linkableURL(candidate) {
                let selected = (string as NSString).substring(with: selectedRange())
                insertText("[\(selected)](\(url))", replacementRange: selectedRange())
                return
            }
            var payload: (Data, String)?
            if let png = pasteboard.data(forType: .png) {
                payload = (png, "png")
            } else if let tiff = pasteboard.data(forType: .tiff),
                let rep = NSBitmapImageRep(data: tiff),
                let png = rep.representation(using: .png, properties: [:]) {
                payload = (png, "png")
            }
            if let (data, ext) = payload, let link = onPasteImage(data, ext) {
                insertText("![](\(link))", replacementRange: selectedRange())
                return
            }
            super.paste(sender)
        }

        override func insertNewline(_ sender: Any?) {
            let action = MarkdownEditing.newlineAction(
                text: string, caret: selectedRange().location
            )
            switch action {
            case .insert(let snippet):
                insertText(snippet, replacementRange: selectedRange())
            case .replaceRange(let range, let replacement):
                if shouldChangeText(in: range, replacementString: replacement) {
                    textStorage?.replaceCharacters(in: range, with: replacement)
                    setSelectedRange(NSRange(location: range.location, length: 0))
                    didChangeText()
                }
            case .plain:
                super.insertNewline(sender)
            }
        }

        /// Inserts a fresh table skeleton on its own lines; a Format menu target.
        @objc func skerryInsertTable(_ sender: Any?) {
            insertText("\n" + MarkdownTables.skeleton() + "\n", replacementRange: selectedRange())
        }

        /// Lines up the columns of the table under the caret; a Format menu target.
        @objc func skerryFormatTable(_ sender: Any?) {
            guard let (range, replacement) = MarkdownTables.formatEdit(
                in: string, at: selectedRange().location
            ), shouldChangeText(in: range, replacementString: replacement) else { return }
            textStorage?.replaceCharacters(in: range, with: replacement)
            didChangeText()
        }

        /// Inserts a footnote reference at the caret and its definition stub at the end;
        /// a Format menu target.
        @objc func skerryInsertFootnote(_ sender: Any?) {
            let label = MarkdownFootnotes.nextLabel(in: string)
            insertText("[^\(label)]", replacementRange: selectedRange())
            let end = NSRange(location: (string as NSString).length, length: 0)
            let separator = string.hasSuffix("\n") ? "\n" : "\n\n"
            insertText(separator + "[^\(label)]: ", replacementRange: end)
        }

        /// Wraps the selection in highlight marks, or drops a pair at the caret;
        /// a Format menu target.
        @objc func skerryToggleHighlight(_ sender: Any?) {
            let range = selectedRange()
            let selected = (string as NSString).substring(with: range)
            insertText("==" + selected + "==", replacementRange: range)
            if selected.isEmpty {
                setSelectedRange(NSRange(location: range.location + 2, length: 0))
            }
        }

        /// Opens the incremental find bar; a Format menu target.
        @objc func skerryFind(_ sender: Any?) {
            let item = NSMenuItem()
            item.tag = NSTextFinder.Action.showFindInterface.rawValue
            performTextFinderAction(item)
        }

        /// Opens the find bar with the replace field; a Format menu target.
        @objc func skerryFindReplace(_ sender: Any?) {
            let item = NSMenuItem()
            item.tag = NSTextFinder.Action.showReplaceInterface.rawValue
            performTextFinderAction(item)
        }

        /// Replaces the whole typed token, hash or brackets excluded, when completing.
        override var rangeForUserCompletion: NSRange {
            if let context = completionContext(
                text: string as NSString, caret: selectedRange().location
            ) {
                return context.range
            }
            return super.rangeForUserCompletion
        }

        /// Closes a completed wiki link with `]]` on acceptance.
        override func insertCompletion(
            _ word: String, forPartialWordRange charRange: NSRange,
            movement: Int, isFinal flag: Bool
        ) {
            var completed = word
            if flag, movement != NSTextMovement.cancel.rawValue,
                let context = completionContext(
                    text: string as NSString, caret: selectedRange().location
                ), context.kind != .tag {
                let ns = string as NSString
                let after = charRange.location + charRange.length
                let alreadyClosed = after + 1 < ns.length
                    && ns.character(at: after) == 0x5D && ns.character(at: after + 1) == 0x5D
                if !alreadyClosed { completed += "]]" }
            }
            super.insertCompletion(
                completed, forPartialWordRange: charRange, movement: movement, isFinal: flag
            )
        }

        /// Folds or unfolds the section under the caret; a Format menu target.
        @objc func skerryToggleFold(_ sender: Any?) {
            (delegate as? MarkdownTextView.Coordinator)?.toggleFoldAtCaret(self)
        }
    }

    /// MarkdownTextView is an NSTextView-backed editor that live-highlights Markdown.
    struct MarkdownTextView: NSViewRepresentable {
        /// Markdown source being edited.
        @Binding var text: String
        /// Called with the note name and any heading when a wiki link is clicked.
        var onWikiLink: (String, String?) -> Void = { _, _ in }
        /// Saves pasted image data and returns the link path to insert, nil to decline.
        var onPasteImage: (Data, String) -> String? = { _, _ in nil }
        /// Whether Markdown token styling applies; plain formats get base styling only.
        var highlightsMarkdown = true
        /// Present on iOS only; unused on macOS where the format keyboard does not apply.
        var onShowFormatHelp: () -> Void = {}
        /// Changes when an appearance or size choice changes, cueing a re-highlight.
        var styleToken: Int = 0
        /// Light or dark override for the editor, nil to follow the device.
        var colorSchemeHint: ColorScheme?
        /// Whether typewriter scrolling keeps the caret line vertically centered.
        var typewriter = false
        /// Whether paragraph focus dims everything but the paragraph being edited.
        var paragraphFocus = false
        /// Tag names offered while typing `#`.
        var tagCompletions: () -> [String] = { [] }
        /// Note titles offered while typing `[[`.
        var titleCompletions: () -> [String] = { [] }
        /// Headings offered while typing `[[Note#`, keyed by the named note.
        var headingCompletions: (String) -> [String] = { _ in [] }
        /// Decoded image for an inline image link, nil to show a placeholder.
        var inlineImageProvider: (String) -> PlatformImage? = { _ in nil }
        /// Whether the TextKit 2 engine backs the view, the opt-in beta editor.
        var usesTextKit2 = false
        /// Heading to scroll to once the note loads, from a wiki `#heading` link.
        var scrollToHeading: String?
        /// Called after the editor has scrolled to a pending heading, so the model clears it.
        var onHeadingResolved: () -> Void = {}

        func makeCoordinator() -> Coordinator {
            Coordinator(self)
        }

        func makeNSView(context: Context) -> NSScrollView {
            let textView = PastingTextView(usingTextLayoutManager: usesTextKit2)
            if usesTextKit2 {
                textView.textContentStorage?.delegate = context.coordinator.concealer2
                context.coordinator.concealer2.conceals = highlightsMarkdown
            } else {
                textView.layoutManager?.delegate = context.coordinator.concealer
            }
            textView.autoresizingMask = [.width]
            textView.isVerticallyResizable = true
            textView.isHorizontallyResizable = false
            textView.textContainer?.widthTracksTextView = true
            let scroll = NSScrollView()
            scroll.hasVerticalScroller = true
            scroll.documentView = textView
            textView.onPasteImage = onPasteImage
            textView.delegate = context.coordinator
            textView.allowsUndo = true
            textView.isRichText = false
            textView.usesFindBar = true
            textView.isIncrementalSearchingEnabled = true
            textView.isAutomaticQuoteSubstitutionEnabled = false
            textView.isAutomaticDashSubstitutionEnabled = false
            textView.textContainerInset = NSSize(width: 12, height: 12)
            textView.typingAttributes = MarkdownTheme.baseAttributes
            textView.string = text
            if let storage = textView.textStorage {
                MarkdownTheme.highlight(
                    storage, asMarkdown: highlightsMarkdown, imagesInFlow: usesTextKit2
                )
            }
            let click = NSClickGestureRecognizer(
                target: context.coordinator, action: #selector(Coordinator.handleClick(_:))
            )
            click.delaysPrimaryMouseButtonEvents = false
            textView.addGestureRecognizer(click)
            DispatchQueue.main.async {
                textView.window?.makeFirstResponder(textView)
            }
            return scroll
        }

        func updateNSView(_ scroll: NSScrollView, context: Context) {
            context.coordinator.parent = self
            guard let textView = scroll.documentView as? PastingTextView else { return }
            textView.onPasteImage = onPasteImage
            let wantName: NSAppearance.Name? = colorSchemeHint == .dark ? .darkAqua
                : colorSchemeHint == .light ? .aqua : nil
            if scroll.appearance?.name != wantName {
                scroll.appearance = wantName.flatMap(NSAppearance.init(named:))
            }
            if context.coordinator.lastStyleToken != styleToken {
                context.coordinator.lastStyleToken = styleToken
                textView.backgroundColor = MarkdownTheme.backgroundOverride
                    ?? NSColor.textBackgroundColor
                textView.typingAttributes = MarkdownTheme.baseAttributes
                context.coordinator.refreshHighlight(textView)
            }
            let textChanged = textView.string != text
            if textChanged {
                textView.string = text
                context.coordinator.imageOverlay.clearCache()
                context.coordinator.concealer2.clearImages()
                context.coordinator.concealer2.resetFolds()
                context.coordinator.foldedIDs = []
                context.coordinator.refreshHighlight(textView)
            }
            if let heading = scrollToHeading {
                let coordinator = context.coordinator
                let resolved = onHeadingResolved
                // Layout settles before the scroll, then the model drops the pending heading.
                DispatchQueue.main.async {
                    coordinator.scroll(to: heading, in: textView)
                    resolved()
                }
            } else if textChanged {
                textView.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
            }
            guard textChanged else { return }
            DispatchQueue.main.async {
                textView.window?.makeFirstResponder(textView)
            }
        }

        /// Coordinator forwards edits to the binding and re-applies highlighting.
        @MainActor
        final class Coordinator: NSObject, NSTextViewDelegate {
            /// Owning representable, refreshed on every update pass.
            var parent: MarkdownTextView
            /// Glyph-level syntax concealment shared with the TextKit 1 layout manager.
            let concealer = ConcealingGlyphs()
            /// Paragraph-level syntax concealment for the TextKit 2 content storage.
            let concealer2 = ConcealingParagraphs()
            /// Last applied style token, so a style change forces one re-highlight.
            var lastStyleToken = -1
            /// Paragraph the focus dim last applied to, so caret moves inside it are free.
            private var lastFocusParagraph = NSRange(location: NSNotFound, length: 0)
            /// Pictures rendered beneath their image links, the TextKit 1 path only.
            let imageOverlay = InlineImageOverlay()
            /// Titles of headings folded away in the TextKit 2 editor, per open note.
            var foldedIDs: Set<String> = []
            /// Whether the next text change carries a recorded edit range.
            private var pendingEditRecorded = false
            /// The recorded edit's post-change range; nil forces a full restyle.
            private var pendingEditRange: NSRange?

            /// Creates a coordinator for one representable.
            init(_ parent: MarkdownTextView) {
                self.parent = parent
            }

            /// Remembers what one keystroke touches, so the change handler restyles just
            /// those paragraphs instead of the whole document.
            func recordEdit(replacing affected: NSRange, with replacement: String, in text: String) {
                pendingEditRecorded = true
                pendingEditRange = MarkdownEditing.editRequiresFullRestyle(
                    replacing: affected, with: replacement, in: text
                )
                    ? nil
                    : NSRange(
                        location: affected.location, length: (replacement as NSString).length
                    )
            }

            /// The dirty range for the change being handled, full when none was recorded.
            func consumeEdit() -> NSRange? {
                defer {
                    pendingEditRecorded = false
                    pendingEditRange = nil
                }
                return pendingEditRecorded ? pendingEditRange : nil
            }

            /// Re-applies highlighting, dimming outside the caret's paragraph when
            /// paragraph focus is on, then refreshes images and folds. A dirty range
            /// keeps the restyle local to the edit.
            func refreshHighlight(_ textView: NSTextView, dirty: NSRange? = nil) {
                guard let storage = textView.textStorage else { return }
                let focus = focusParagraph(of: textView)
                lastFocusParagraph = focus ?? NSRange(location: NSNotFound, length: 0)
                concealer2.conceals = parent.highlightsMarkdown
                concealer2.imageProvider = parent.inlineImageProvider
                concealer2.maxImageWidth = max(
                    textView.bounds.width - textView.textContainerInset.width * 2 - 12, 200
                )
                MarkdownTheme.highlight(
                    storage, asMarkdown: parent.highlightsMarkdown, focusRange: focus,
                    dirty: dirty, imagesInFlow: parent.usesTextKit2
                )
                if parent.usesTextKit2 {
                    concealer2.updateFolds(
                        MarkdownFolding.foldedBodies(
                            in: textView.string, foldedIDs: foldedIDs
                        ),
                        in: storage
                    )
                } else if parent.highlightsMarkdown {
                    imageOverlay.update(in: textView, provider: parent.inlineImageProvider)
                }
            }

            /// Folds or unfolds the section under the caret, TextKit 2 editor only. A
            /// caret inside the newly hidden body hops to the heading so typing never
            /// lands somewhere invisible.
            func toggleFoldAtCaret(_ textView: NSTextView) {
                guard parent.usesTextKit2, let storage = textView.textStorage else { return }
                let caret = textView.selectedRange().location
                guard let section = MarkdownFolding.section(
                    atCaret: caret, in: textView.string
                ) else { return }
                if foldedIDs.contains(section.foldID) {
                    foldedIDs.remove(section.foldID)
                } else {
                    foldedIDs.insert(section.foldID)
                    if NSLocationInRange(caret, section.body) {
                        let headingEnd = section.headingLine.location
                            + max(section.headingLine.length - 1, 0)
                        textView.setSelectedRange(NSRange(location: headingEnd, length: 0))
                    }
                }
                concealer2.updateFolds(
                    MarkdownFolding.foldedBodies(
                        in: textView.string, foldedIDs: foldedIDs
                    ),
                    in: storage
                )
            }

            /// Scrolls the named heading into view and places the caret at its start, the
            /// landing for a wiki `#heading` link. A missing heading leaves the caret be.
            func scroll(to headingName: String, in textView: NSTextView) {
                guard let heading = MarkdownFolding.heading(
                    named: headingName, in: textView.string
                ) else { return }
                textView.setSelectedRange(NSRange(location: heading.line.location, length: 0))
                textView.scrollRangeToVisible(heading.line)
            }

            /// The caret's paragraph range when paragraph focus is on, else nil.
            private func focusParagraph(of textView: NSTextView) -> NSRange? {
                guard parent.paragraphFocus else { return nil }
                let ns = textView.string as NSString
                let caret = min(textView.selectedRange().location, ns.length)
                return ns.paragraphRange(for: NSRange(location: caret, length: 0))
            }

            /// Scrolls so the caret line sits vertically centered, the typewriter behavior.
            func centerCaret(_ textView: NSTextView) {
                guard parent.typewriter else { return }
                guard let rect = caretLineRect(in: textView),
                    let scroll = textView.enclosingScrollView
                else { return }
                let clip = scroll.contentView
                let target = rect.midY + textView.textContainerInset.height
                    - clip.bounds.height / 2
                let maxY = max(textView.frame.height - clip.bounds.height, 0)
                let clamped = min(max(target, 0), maxY)
                clip.setBoundsOrigin(NSPoint(x: clip.bounds.origin.x, y: clamped))
                scroll.reflectScrolledClipView(clip)
            }

            /// The caret's line rectangle in container coordinates, from whichever
            /// layout engine backs the view.
            private func caretLineRect(in textView: NSTextView) -> NSRect? {
                if parent.usesTextKit2 {
                    guard let layoutManager = textView.textLayoutManager,
                        let contentManager = layoutManager.textContentManager
                    else { return nil }
                    layoutManager.ensureLayout(for: layoutManager.documentRange)
                    let caret = textView.selectedRange().location
                    guard let location = contentManager.location(
                        contentManager.documentRange.location, offsetBy: caret
                    ) else { return nil }
                    var frame: CGRect?
                    layoutManager.enumerateTextSegments(
                        in: NSTextRange(location: location),
                        type: .selection, options: .rangeNotRequired
                    ) { _, segmentFrame, _, _ in
                        frame = segmentFrame
                        return false
                    }
                    return frame
                }
                guard let layoutManager = textView.layoutManager,
                    let container = textView.textContainer
                else { return nil }
                layoutManager.ensureLayout(for: container)
                let caret = textView.selectedRange().location
                if layoutManager.numberOfGlyphs == 0 {
                    return nil
                } else if caret >= (textView.string as NSString).length,
                    !layoutManager.extraLineFragmentRect.isEmpty {
                    return layoutManager.extraLineFragmentRect
                }
                let glyph = layoutManager.glyphIndexForCharacter(
                    at: min(caret, (textView.string as NSString).length - 1)
                )
                return layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            }

            func textDidChange(_ notification: Notification) {
                guard let textView = notification.object as? NSTextView else { return }
                parent.text = textView.string
                refreshHighlight(textView, dirty: consumeEdit())
                textView.typingAttributes = MarkdownTheme.baseAttributes
                centerCaret(textView)
                offerCompletions(textView)
            }

            /// Guards against completion recursion while the popup inserts text.
            private var completing = false

            /// Pops the native completion list while a tag or wiki-link token is typed.
            private func offerCompletions(_ textView: NSTextView) {
                guard !completing else { return }
                guard let context = completionContext(
                    text: textView.string as NSString, caret: textView.selectedRange().location
                ), !context.prefix.isEmpty else { return }
                let source: [String]
                switch context.kind {
                case .tag: source = parent.tagCompletions()
                case .wikiLink: source = parent.titleCompletions()
                case .wikiHeading(let note): source = parent.headingCompletions(note)
                }
                guard !completionMatches(source, prefix: context.prefix).isEmpty else { return }
                completing = true
                textView.complete(nil)
                completing = false
            }

            /// Serves tag names after `#` and note titles inside `[[`.
            func textView(
                _ textView: NSTextView, completions words: [String],
                forPartialWordRange charRange: NSRange,
                indexOfSelectedItem index: UnsafeMutablePointer<Int>?
            ) -> [String] {
                guard let context = completionContext(
                    text: textView.string as NSString, caret: textView.selectedRange().location
                ) else { return words }
                let source: [String]
                switch context.kind {
                case .tag: source = parent.tagCompletions()
                case .wikiLink: source = parent.titleCompletions()
                case .wikiHeading(let note): source = parent.headingCompletions(note)
                }
                let matches = completionMatches(source, prefix: context.prefix)
                return matches.isEmpty ? words : matches
            }

            func textViewDidChangeSelection(_ notification: Notification) {
                guard let textView = notification.object as? NSTextView else { return }
                if parent.usesTextKit2 {
                    if let storage = textView.textStorage {
                        concealer2.updateCaretParagraph(
                            for: textView.selectedRange(), in: storage
                        )
                    }
                } else if let layoutManager = textView.layoutManager {
                    concealer.updateActiveLine(for: textView.selectedRange(), in: layoutManager)
                }
                if parent.paragraphFocus {
                    let ns = textView.string as NSString
                    let caret = min(textView.selectedRange().location, ns.length)
                    let paragraph = ns.paragraphRange(for: NSRange(location: caret, length: 0))
                    if paragraph != lastFocusParagraph {
                        refreshHighlight(textView)
                    }
                }
                centerCaret(textView)
            }

            /// Closing partner for each character that wraps the selection when typed over it.
            static let pairClose: [String: String] = ["*": "*", "_": "_", "`": "`", "[": "]"]

            /// Wraps a non-empty selection when a pairing character is typed, so hitting `*`
            /// with text selected emphasizes it rather than replacing it. Every accepted
            /// change records its range so the restyle stays local to the edit.
            func textView(
                _ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange,
                replacementString: String?
            ) -> Bool {
                if let open = replacementString, affectedCharRange.length > 0,
                    let close = Self.pairClose[open] {
                    let selected = (textView.string as NSString)
                        .substring(with: affectedCharRange)
                    textView.insertText(
                        open + selected + close, replacementRange: affectedCharRange
                    )
                    textView.setSelectedRange(
                        NSRange(
                            location: affectedCharRange.location + (open as NSString).length,
                            length: (selected as NSString).length
                        )
                    )
                    return false
                }
                recordEdit(
                    replacing: affectedCharRange, with: replacementString ?? "",
                    in: textView.string
                )
                return true
            }

            /// Maps Tab and Shift-Tab to cell hops inside a table, line indentation outside.
            func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
                switch commandSelector {
                case #selector(NSResponder.insertTab(_:)):
                    if applyTableTab(textView, backward: false) { return true }
                    return shiftLine(textView, outdent: false)
                case #selector(NSResponder.insertBacktab(_:)):
                    if applyTableTab(textView, backward: true) { return true }
                    return shiftLine(textView, outdent: true)
                default:
                    return false
                }
            }

            /// Hops the caret to the next or previous table cell, growing a fresh row when
            /// tabbing past the last cell. False when the caret is not inside a table.
            private func applyTableTab(_ textView: NSTextView, backward: Bool) -> Bool {
                guard let result = MarkdownTables.tabEdit(
                    in: textView.string, at: textView.selectedRange().location, backward: backward
                ) else { return false }
                if let (range, replacement) = result.edit {
                    guard textView.shouldChangeText(in: range, replacementString: replacement)
                    else { return true }
                    textView.textStorage?.replaceCharacters(in: range, with: replacement)
                    textView.didChangeText()
                }
                textView.setSelectedRange(NSRange(location: result.caret, length: 0))
                return true
            }

            /// Indents the caret's line by two spaces, or removes up to two, keeping the caret.
            private func shiftLine(_ textView: NSTextView, outdent: Bool) -> Bool {
                let ns = textView.string as NSString
                let caret = textView.selectedRange()
                let lineStart = ns.lineRange(for: NSRange(location: caret.location, length: 0)).location
                if outdent {
                    var remove = 0
                    while remove < 2, lineStart + remove < ns.length,
                        ns.character(at: lineStart + remove) == 32 {
                        remove += 1
                    }
                    guard remove > 0 else { return true }
                    textView.insertText("", replacementRange: NSRange(location: lineStart, length: remove))
                    textView.setSelectedRange(
                        NSRange(location: max(lineStart, caret.location - remove), length: 0)
                    )
                } else {
                    textView.insertText("  ", replacementRange: NSRange(location: lineStart, length: 0))
                    textView.setSelectedRange(NSRange(location: caret.location + 2, length: 0))
                }
                return true
            }

            @objc func handleClick(_ gesture: NSClickGestureRecognizer) {
                guard let textView = gesture.view as? NSTextView else { return }
                // Insertion indexing works under both layout engines, unlike glyph APIs.
                let index = textView.characterIndexForInsertion(
                    at: gesture.location(in: textView)
                )
                guard let (range, replacement) = MarkdownEditing.taskToggleEdit(
                    text: textView.string, at: index
                ), textView.shouldChangeText(in: range, replacementString: replacement) else {
                    return
                }
                // The storage edit runs through didChangeText, whose handler restyles
                // the toggled line and pushes the text to the binding.
                textView.textStorage?.replaceCharacters(in: range, with: replacement)
                textView.didChangeText()
            }

            func textView(
                _ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int
            ) -> Bool {
                guard let url = link as? URL,
                    let target = MarkdownTheme.wikiTarget(from: url)
                else { return false }
                parent.onWikiLink(target, MarkdownTheme.wikiFragment(from: url))
                return true
            }
        }
    }

#else

    /// PastingTextView intercepts image pastes and inserts a Markdown link instead.
    final class PastingTextView: UITextView {
        /// Saves pasted image data and returns the link path to insert, nil to decline.
        var onPasteImage: (Data, String) -> String? = { _, _ in nil }

        override func paste(_ sender: Any?) {
            // A URL pasted over selected text wraps it as a markdown link.
            if selectedRange.length > 0, let candidate = UIPasteboard.general.string,
                let url = linkableURL(candidate), let range = selectedTextRange,
                let selected = text(in: range) {
                replace(range, withText: "[\(selected)](\(url))")
                return
            }
            if let image = UIPasteboard.general.image, let png = image.pngData(),
                let link = onPasteImage(png, "png") {
                insertText("![](\(link))")
                return
            }
            super.paste(sender)
        }
    }

    /// MarkdownTextView is a UITextView-backed editor that live-highlights Markdown.
    struct MarkdownTextView: UIViewRepresentable {
        /// Markdown source being edited.
        @Binding var text: String
        /// Called with the note name and any heading when a wiki link is tapped.
        var onWikiLink: (String, String?) -> Void = { _, _ in }
        /// Saves pasted image data and returns the link path to insert, nil to decline.
        var onPasteImage: (Data, String) -> String? = { _, _ in nil }
        /// Whether Markdown token styling applies; plain formats get base styling only.
        var highlightsMarkdown = true
        /// Asks the host to present the formatting guide.
        var onShowFormatHelp: () -> Void = {}
        /// Changes when an appearance or size choice changes, cueing a re-highlight.
        var styleToken: Int = 0
        /// Light or dark override for the editor, nil to follow the device.
        var colorSchemeHint: ColorScheme?
        /// Whether typewriter scrolling keeps the caret line vertically centered.
        var typewriter = false
        /// Whether paragraph focus dims everything but the paragraph being edited.
        var paragraphFocus = false
        /// Tag names offered while typing `#`.
        var tagCompletions: () -> [String] = { [] }
        /// Note titles offered while typing `[[`.
        var titleCompletions: () -> [String] = { [] }
        /// Headings offered while typing `[[Note#`, keyed by the named note.
        var headingCompletions: (String) -> [String] = { _ in [] }
        /// Decoded image for an inline image link, nil to show a placeholder.
        var inlineImageProvider: (String) -> PlatformImage? = { _ in nil }
        /// Whether the TextKit 2 engine backs the view, the opt-in beta editor.
        var usesTextKit2 = false
        /// Heading to scroll to once the note loads, from a wiki `#heading` link.
        var scrollToHeading: String?
        /// Called after the editor has scrolled to a pending heading, so the model clears it.
        var onHeadingResolved: () -> Void = {}

        func makeCoordinator() -> Coordinator {
            Coordinator(self)
        }

        func makeUIView(context: Context) -> UITextView {
            let textView = PastingTextView(usingTextLayoutManager: usesTextKit2)
            if usesTextKit2 {
                let contentStorage = textView.textLayoutManager?.textContentManager
                    as? NSTextContentStorage
                contentStorage?.delegate = context.coordinator.concealer2
                context.coordinator.concealer2.conceals = highlightsMarkdown
            } else {
                textView.layoutManager.delegate = context.coordinator.concealer
            }
            textView.onPasteImage = onPasteImage
            textView.delegate = context.coordinator
            textView.isFindInteractionEnabled = true
            textView.backgroundColor = .clear
            textView.textContainerInset = UIEdgeInsets(top: 20, left: 20, bottom: 24, right: 20)
            textView.typingAttributes = MarkdownTheme.baseAttributes
            textView.text = text
            MarkdownTheme.highlight(
                textView.textStorage, asMarkdown: highlightsMarkdown,
                imagesInFlow: usesTextKit2
            )
            let tap = UITapGestureRecognizer(
                target: context.coordinator, action: #selector(Coordinator.handleTap(_:))
            )
            tap.cancelsTouchesInView = false
            tap.delegate = context.coordinator
            textView.addGestureRecognizer(tap)
            context.coordinator.textView = textView
            let bar = context.coordinator.makeAccessoryBar()
            context.coordinator.standardAccessory = bar
            textView.inputAccessoryView = bar
            DispatchQueue.main.async {
                textView.becomeFirstResponder()
            }
            return textView
        }

        func updateUIView(_ textView: UITextView, context: Context) {
            context.coordinator.parent = self
            (textView as? PastingTextView)?.onPasteImage = onPasteImage
            let wantStyle: UIUserInterfaceStyle = colorSchemeHint == .dark ? .dark
                : colorSchemeHint == .light ? .light : .unspecified
            if textView.overrideUserInterfaceStyle != wantStyle {
                textView.overrideUserInterfaceStyle = wantStyle
            }
            if context.coordinator.lastStyleToken != styleToken {
                context.coordinator.lastStyleToken = styleToken
                textView.backgroundColor = MarkdownTheme.backgroundOverride ?? .clear
                textView.typingAttributes = MarkdownTheme.baseAttributes
                context.coordinator.refreshHighlight(textView)
            }
            let textChanged = textView.text != text
            if textChanged {
                textView.text = text
                context.coordinator.imageOverlay.clearCache()
                context.coordinator.concealer2.clearImages()
                context.coordinator.concealer2.resetFolds()
                context.coordinator.foldedIDs = []
                context.coordinator.refreshHighlight(textView)
            }
            if let heading = scrollToHeading {
                let coordinator = context.coordinator
                let resolved = onHeadingResolved
                // Layout settles before the scroll, then the model drops the pending heading.
                DispatchQueue.main.async {
                    coordinator.scroll(to: heading, in: textView)
                    resolved()
                }
            } else if textChanged {
                textView.selectedRange = NSRange(location: (text as NSString).length, length: 0)
            }
            guard textChanged else { return }
            DispatchQueue.main.async {
                textView.becomeFirstResponder()
            }
        }

        /// Coordinator forwards edits to the binding and re-applies highlighting.
        @MainActor
        final class Coordinator: NSObject, UITextViewDelegate, UIGestureRecognizerDelegate {
            /// Owning representable, refreshed on every update pass.
            var parent: MarkdownTextView
            /// Glyph-level syntax concealment shared with the TextKit 1 layout manager.
            let concealer = ConcealingGlyphs()
            /// Paragraph-level syntax concealment for the TextKit 2 content storage.
            let concealer2 = ConcealingParagraphs()
            /// Last applied style token, so a style change forces one re-highlight.
            var lastStyleToken = -1
            /// The edited text view, used by the keyboard accessory bar.
            weak var textView: UITextView?
            /// Paragraph the focus dim last applied to, so caret moves inside it are free.
            private var lastFocusParagraph = NSRange(location: NSNotFound, length: 0)
            /// The formatting bar restored when no completion is being typed.
            var standardAccessory: MarkdownAccessoryBar?
            /// Suggestions currently showing, so the bar only rebuilds on change.
            private var shownSuggestions: [String] = []
            /// Pictures rendered beneath their image links, the TextKit 1 path only.
            let imageOverlay = InlineImageOverlay()
            /// Titles of headings folded away in the TextKit 2 editor, per open note.
            var foldedIDs: Set<String> = []
            /// Whether the next text change carries a recorded edit range.
            private var pendingEditRecorded = false
            /// The recorded edit's post-change range; nil forces a full restyle.
            private var pendingEditRange: NSRange?

            /// Remembers what one keystroke touches, so the change handler restyles just
            /// those paragraphs instead of the whole document.
            func recordEdit(replacing affected: NSRange, with replacement: String, in text: String) {
                pendingEditRecorded = true
                pendingEditRange = MarkdownEditing.editRequiresFullRestyle(
                    replacing: affected, with: replacement, in: text
                )
                    ? nil
                    : NSRange(
                        location: affected.location, length: (replacement as NSString).length
                    )
            }

            /// The dirty range for the change being handled, full when none was recorded.
            func consumeEdit() -> NSRange? {
                defer {
                    pendingEditRecorded = false
                    pendingEditRange = nil
                }
                return pendingEditRecorded ? pendingEditRange : nil
            }

            /// Folds or unfolds the section under the caret, TextKit 2 editor only. A
            /// caret inside the newly hidden body hops to the heading so typing never
            /// lands somewhere invisible.
            func toggleFoldAtCaret() {
                guard parent.usesTextKit2, let textView else { return }
                let caret = textView.selectedRange.location
                guard let section = MarkdownFolding.section(
                    atCaret: caret, in: textView.text
                ) else { return }
                if foldedIDs.contains(section.foldID) {
                    foldedIDs.remove(section.foldID)
                } else {
                    foldedIDs.insert(section.foldID)
                    if NSLocationInRange(caret, section.body) {
                        let headingEnd = section.headingLine.location
                            + max(section.headingLine.length - 1, 0)
                        textView.selectedRange = NSRange(location: headingEnd, length: 0)
                    }
                }
                concealer2.updateFolds(
                    MarkdownFolding.foldedBodies(
                        in: textView.text, foldedIDs: foldedIDs
                    ),
                    in: textView.textStorage
                )
            }

            /// Scrolls the named heading into view and places the caret at its start, the
            /// landing for a wiki `#heading` link. A missing heading leaves the caret be.
            func scroll(to headingName: String, in textView: UITextView) {
                guard let heading = MarkdownFolding.heading(
                    named: headingName, in: textView.text
                ) else { return }
                textView.selectedRange = NSRange(location: heading.line.location, length: 0)
                textView.scrollRangeToVisible(heading.line)
            }

            /// Swaps the accessory bar to completions while a tag or wiki link is typed.
            func refreshSuggestions(_ textView: UITextView) {
                guard let context = completionContext(
                    text: textView.text as NSString, caret: textView.selectedRange.location
                ) else {
                    restoreStandardAccessory(textView)
                    return
                }
                let source: [String]
                switch context.kind {
                case .tag: source = parent.tagCompletions()
                case .wikiLink: source = parent.titleCompletions()
                case .wikiHeading(let note): source = parent.headingCompletions(note)
                }
                let matches = completionMatches(source, prefix: context.prefix)
                guard !matches.isEmpty else {
                    restoreStandardAccessory(textView)
                    return
                }
                guard matches != shownSuggestions else { return }
                shownSuggestions = matches
                textView.inputAccessoryView = TagSuggestionBar(
                    width: UIScreen.main.bounds.width, suggestions: matches
                ) { [weak self] picked in
                    self?.acceptSuggestion(picked)
                }
                textView.reloadInputViews()
            }

            /// Puts the formatting bar back.
            private func restoreStandardAccessory(_ textView: UITextView) {
                guard !shownSuggestions.isEmpty else { return }
                shownSuggestions = []
                textView.inputAccessoryView = standardAccessory
                textView.reloadInputViews()
            }

            /// Replaces the typed token with a picked completion, closing a wiki link.
            private func acceptSuggestion(_ suggestion: String) {
                guard let textView,
                    let context = completionContext(
                        text: textView.text as NSString, caret: textView.selectedRange.location
                    ),
                    let start = textView.position(
                        from: textView.beginningOfDocument, offset: context.range.location
                    ),
                    let end = textView.position(from: start, offset: context.range.length),
                    let range = textView.textRange(from: start, to: end)
                else { return }
                let ns = textView.text as NSString
                let after = context.range.location + context.range.length
                let isWiki = context.kind != .tag
                let alreadyClosed = isWiki && after + 1 < ns.length
                    && ns.character(at: after) == 0x5D && ns.character(at: after + 1) == 0x5D
                let closing = isWiki && !alreadyClosed ? "]]" : ""
                textView.replace(range, withText: suggestion + closing)
                syncEdit()
                restoreStandardAccessory(textView)
            }

            /// Re-applies highlighting, dimming outside the caret's paragraph when
            /// paragraph focus is on, then refreshes images and folds. A dirty range
            /// keeps the restyle local to the edit.
            func refreshHighlight(_ textView: UITextView, dirty: NSRange? = nil) {
                let focus = focusParagraph(of: textView)
                lastFocusParagraph = focus ?? NSRange(location: NSNotFound, length: 0)
                concealer2.conceals = parent.highlightsMarkdown
                concealer2.imageProvider = parent.inlineImageProvider
                concealer2.maxImageWidth = max(
                    textView.bounds.width - textView.textContainerInset.left
                        - textView.textContainerInset.right - 12,
                    200
                )
                MarkdownTheme.highlight(
                    textView.textStorage, asMarkdown: parent.highlightsMarkdown,
                    focusRange: focus, dirty: dirty, imagesInFlow: parent.usesTextKit2
                )
                if parent.usesTextKit2 {
                    concealer2.updateFolds(
                        MarkdownFolding.foldedBodies(
                            in: textView.text, foldedIDs: foldedIDs
                        ),
                        in: textView.textStorage
                    )
                } else if parent.highlightsMarkdown {
                    imageOverlay.update(in: textView, provider: parent.inlineImageProvider)
                }
            }

            /// The caret's paragraph range when paragraph focus is on, else nil.
            private func focusParagraph(of textView: UITextView) -> NSRange? {
                guard parent.paragraphFocus else { return nil }
                let ns = textView.text as NSString
                let caret = min(textView.selectedRange.location, ns.length)
                return ns.paragraphRange(for: NSRange(location: caret, length: 0))
            }

            /// Scrolls so the caret line sits vertically centered, the typewriter behavior.
            func centerCaret(_ textView: UITextView) {
                guard parent.typewriter, let selection = textView.selectedTextRange else { return }
                let caret = textView.caretRect(for: selection.end)
                guard caret.origin.y.isFinite, caret.height > 0 else { return }
                let insets = textView.adjustedContentInset
                let visible = textView.bounds.height - insets.top - insets.bottom
                guard visible > 0 else { return }
                let target = caret.midY - insets.top - visible / 2
                let minOffset = -insets.top
                let maxOffset = max(
                    textView.contentSize.height - textView.bounds.height + insets.bottom, minOffset
                )
                let clamped = min(max(target, minOffset), maxOffset)
                textView.setContentOffset(CGPoint(x: 0, y: clamped), animated: false)
            }

            /// Lets the checkbox tap coexist with the text view's own gestures, so double-tap
            /// to select a word, the caret loupe, and long-press selection keep working.
            func gestureRecognizer(
                _ gestureRecognizer: UIGestureRecognizer,
                shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
            ) -> Bool {
                true
            }

            /// Creates a coordinator for one representable.
            init(_ parent: MarkdownTextView) {
                self.parent = parent
            }

            /// Builds the formatting bar shown above the keyboard.
            func makeAccessoryBar() -> MarkdownAccessoryBar {
                let shortcuts: [MarkdownAccessoryBar.Shortcut] = [
                    .init(symbol: "checklist") { [weak self] in self?.prefixLine("- [ ] ") },
                    .init(symbol: "list.bullet") { [weak self] in self?.prefixLine("- ") },
                    .init(symbol: "list.number") { [weak self] in self?.prefixLine("1. ") },
                    .init(symbol: "number") { [weak self] in self?.prefixLine("# ") },
                    .init(symbol: "rectangle.compress.vertical") {
                        [weak self] in self?.toggleFoldAtCaret()
                    },
                    .init(symbol: "bold") { [weak self] in self?.wrapSelection("**") },
                    .init(symbol: "italic") { [weak self] in self?.wrapSelection("*") },
                    .init(symbol: "chevron.left.forwardslash.chevron.right") {
                        [weak self] in self?.wrapSelection("`")
                    },
                    .init(symbol: "link") { [weak self] in self?.wrapSelection("[", close: "]()") },
                    .init(symbol: "highlighter") { [weak self] in self?.wrapSelection("==") },
                    .init(symbol: "quote.opening") { [weak self] in self?.prefixLine("> ") },
                    .init(symbol: "tablecells") { [weak self] in self?.insertTable() },
                    .init(symbol: "textformat.superscript") { [weak self] in self?.insertFootnote() },
                    .init(symbol: "magnifyingglass") { [weak self] in
                        self?.textView?.findInteraction?.presentFindNavigator(showingReplace: false)
                    },
                ]
                return MarkdownAccessoryBar(
                    width: UIScreen.main.bounds.width,
                    shortcuts: shortcuts,
                    onToggleKeyboard: { [weak self] in self?.toggleFormatKeyboard() },
                    onShowHelp: { [weak self] in self?.parent.onShowFormatHelp() }
                )
            }

            /// Inserts a Markdown prefix at the start of the caret's line.
            private func prefixLine(_ prefix: String) {
                guard let textView, let selection = textView.selectedTextRange else { return }
                let caret = textView.offset(from: textView.beginningOfDocument, to: selection.start)
                let lineStart = (textView.text as NSString)
                    .lineRange(for: NSRange(location: caret, length: 0)).location
                guard let position = textView.position(
                    from: textView.beginningOfDocument, offset: lineStart
                ), let range = textView.textRange(from: position, to: position) else { return }
                textView.replace(range, withText: prefix)
                syncEdit()
            }

            /// Wraps the selection in a marker, or drops an empty pair with the caret inside.
            private func wrapSelection(_ open: String, close: String? = nil) {
                guard let textView, let selection = textView.selectedTextRange else { return }
                let closing = close ?? open
                let selected = textView.text(in: selection) ?? ""
                textView.replace(selection, withText: open + selected + closing)
                if selected.isEmpty, let caret = textView.position(
                    from: selection.start, offset: open.count
                ) {
                    textView.selectedTextRange = textView.textRange(from: caret, to: caret)
                }
                syncEdit()
            }

            /// Pushes an editor edit back to the binding and refreshes highlighting.
            private func syncEdit() {
                guard let textView else { return }
                parent.text = textView.text
                refreshHighlight(textView)
            }

            /// Inserts raw text at the caret, then optionally moves the caret back.
            private func insertBlock(_ text: String, caretBackBy: Int = 0) {
                guard let textView else { return }
                textView.insertText(text)
                if caretBackBy > 0, let selection = textView.selectedTextRange,
                    let caret = textView.position(from: selection.start, offset: -caretBackBy) {
                    textView.selectedTextRange = textView.textRange(from: caret, to: caret)
                }
                syncEdit()
            }

            /// Inserts a horizontal rule on its own line.
            private func insertHorizontalRule() { insertBlock("\n---\n") }

            /// Inserts a fenced code block with the caret on the empty middle line.
            private func insertCodeBlock() { insertBlock("```\n\n```\n", caretBackBy: 5) }

            /// Inserts a fresh Markdown table skeleton.
            private func insertTable() {
                insertBlock("\n" + MarkdownTables.skeleton() + "\n")
            }

            /// Inserts a footnote reference at the caret and its definition stub at the end.
            private func insertFootnote() {
                guard let textView else { return }
                let caret = textView.offset(
                    from: textView.beginningOfDocument,
                    to: textView.selectedTextRange?.start ?? textView.endOfDocument
                )
                let (updated, newCaret) = MarkdownFootnotes.insertEdit(
                    text: textView.text, caret: caret
                )
                textView.text = updated
                if let position = textView.position(
                    from: textView.beginningOfDocument, offset: newCaret
                ) {
                    textView.selectedTextRange = textView.textRange(from: position, to: position)
                }
                syncEdit()
            }

            /// Inserts today's date in an abbreviated form.
            private func insertDate() {
                insertBlock(Date().formatted(date: .abbreviated, time: .omitted))
            }

            /// Inserts the current time.
            private func insertTime() {
                insertBlock(Date().formatted(date: .omitted, time: .shortened))
            }

            /// Indents the caret's line by two spaces.
            private func indentLine() { prefixLine("  ") }

            /// Removes up to two leading spaces from the caret's line.
            private func outdentLine() {
                guard let textView, let selection = textView.selectedTextRange else { return }
                let caret = textView.offset(from: textView.beginningOfDocument, to: selection.start)
                let ns = textView.text as NSString
                let lineStart = ns.lineRange(for: NSRange(location: caret, length: 0)).location
                var remove = 0
                while remove < 2, lineStart + remove < ns.length,
                    ns.character(at: lineStart + remove) == 32 {
                    remove += 1
                }
                guard remove > 0, let start = textView.position(
                    from: textView.beginningOfDocument, offset: lineStart
                ), let end = textView.position(from: start, offset: remove),
                    let range = textView.textRange(from: start, to: end) else { return }
                textView.replace(range, withText: "")
                syncEdit()
            }

            /// Applies smart list continuation for a return pressed on the format keyboard.
            private func performReturn() {
                guard let textView else { return }
                let caret = textView.offset(
                    from: textView.beginningOfDocument,
                    to: textView.selectedTextRange?.start ?? textView.beginningOfDocument
                )
                switch MarkdownEditing.newlineAction(text: textView.text, caret: caret) {
                case .insert(let snippet): textView.insertText(snippet)
                case .replaceRange(let range, let replacement):
                    if let start = textView.position(
                        from: textView.beginningOfDocument, offset: range.location
                    ), let end = textView.position(from: start, offset: range.length),
                        let textRange = textView.textRange(from: start, to: end) {
                        textView.replace(textRange, withText: replacement)
                    }
                case .plain: textView.insertText("\n")
                }
                syncEdit()
            }

            /// Flips between the formatting keyboard and the system keyboard.
            private func toggleFormatKeyboard() {
                guard let textView else { return }
                textView.inputView = textView.inputView == nil ? makeFormatKeyboard() : nil
                textView.reloadInputViews()
            }

            /// Builds the alternative formatting keyboard grid.
            private func makeFormatKeyboard() -> FormatKeyboard {
                typealias Key = FormatKeyboard.Key
                let rows: [[Key]] = [
                    [
                        Key(title: "H1") { [weak self] in self?.prefixLine("# ") },
                        Key(title: "H2") { [weak self] in self?.prefixLine("## ") },
                        Key(title: "H3") { [weak self] in self?.prefixLine("### ") },
                        Key(symbol: "quote.opening") { [weak self] in self?.prefixLine("> ") },
                        Key(symbol: "curlybraces") { [weak self] in self?.wrapSelection("`") },
                    ],
                    [
                        Key(title: "B") { [weak self] in self?.wrapSelection("**") },
                        Key(title: "I") { [weak self] in self?.wrapSelection("*") },
                        Key(symbol: "strikethrough") { [weak self] in self?.wrapSelection("~~") },
                        Key(symbol: "link") { [weak self] in self?.wrapSelection("[", close: "]()") },
                        Key(symbol: "highlighter") { [weak self] in self?.wrapSelection("==") },
                    ],
                    [
                        Key(symbol: "list.bullet") { [weak self] in self?.prefixLine("- ") },
                        Key(symbol: "list.number") { [weak self] in self?.prefixLine("1. ") },
                        Key(symbol: "checklist") { [weak self] in self?.prefixLine("- [ ] ") },
                        Key(symbol: "increase.indent") { [weak self] in self?.indentLine() },
                        Key(symbol: "decrease.indent") { [weak self] in self?.outdentLine() },
                    ],
                    [
                        Key(symbol: "minus") { [weak self] in self?.insertHorizontalRule() },
                        Key(symbol: "curlybraces.square") { [weak self] in self?.insertCodeBlock() },
                        Key(symbol: "tablecells") { [weak self] in self?.insertTable() },
                        Key(symbol: "calendar") { [weak self] in self?.insertDate() },
                        Key(symbol: "clock") { [weak self] in self?.insertTime() },
                    ],
                    [
                        Key(symbol: "arrow.uturn.backward", prominent: true) {
                            [weak self] in self?.textView?.undoManager?.undo()
                        },
                        Key(symbol: "arrow.uturn.forward", prominent: true) {
                            [weak self] in self?.textView?.undoManager?.redo()
                        },
                        Key(symbol: "delete.left", prominent: true) {
                            [weak self] in self?.textView?.deleteBackward()
                        },
                        Key(symbol: "return", prominent: true) { [weak self] in self?.performReturn() },
                        Key(title: "ABC", prominent: true) { [weak self] in
                            self?.toggleFormatKeyboard()
                        },
                    ],
                ]
                return FormatKeyboard(width: UIScreen.main.bounds.width, rows: rows)
            }

            func textViewDidChange(_ textView: UITextView) {
                parent.text = textView.text
                refreshHighlight(textView, dirty: consumeEdit())
                textView.typingAttributes = MarkdownTheme.baseAttributes
                centerCaret(textView)
                refreshSuggestions(textView)
            }

            func textViewDidChangeSelection(_ textView: UITextView) {
                if parent.usesTextKit2 {
                    concealer2.updateCaretParagraph(
                        for: textView.selectedRange, in: textView.textStorage
                    )
                } else {
                    concealer.updateActiveLine(
                        for: textView.selectedRange, in: textView.layoutManager
                    )
                }
                if parent.paragraphFocus {
                    let ns = textView.text as NSString
                    let caret = min(textView.selectedRange.location, ns.length)
                    let paragraph = ns.paragraphRange(for: NSRange(location: caret, length: 0))
                    if paragraph != lastFocusParagraph {
                        refreshHighlight(textView)
                    }
                }
                centerCaret(textView)
            }

            @objc func handleTap(_ gesture: UITapGestureRecognizer) {
                guard let textView = gesture.view as? UITextView else { return }
                // Text-input geometry works under both layout engines, unlike glyph APIs.
                let position = textView.closestPosition(to: gesture.location(in: textView))
                    ?? textView.beginningOfDocument
                let index = textView.offset(from: textView.beginningOfDocument, to: position)
                guard let (range, replacement) = MarkdownEditing.taskToggleEdit(
                    text: textView.text, at: index
                ), let start = textView.position(
                    from: textView.beginningOfDocument, offset: range.location
                ), let end = textView.position(from: start, offset: range.length),
                    let textRange = textView.textRange(from: start, to: end)
                else { return }
                textView.replace(textRange, withText: replacement)
                parent.text = textView.text
                MarkdownTheme.highlight(
                    textView.textStorage, asMarkdown: parent.highlightsMarkdown,
                    imagesInFlow: parent.usesTextKit2
                )
            }

            func textView(
                _ textView: UITextView, shouldChangeTextIn range: NSRange,
                replacementText replacement: String
            ) -> Bool {
                if replacement == "\t", range.length == 0,
                    let result = MarkdownTables.tabEdit(
                        in: textView.text, at: range.location, backward: false
                    ) {
                    if let (editRange, editText) = result.edit,
                        let start = textView.position(
                            from: textView.beginningOfDocument, offset: editRange.location
                        ), let end = textView.position(from: start, offset: editRange.length),
                        let textRange = textView.textRange(from: start, to: end) {
                        textView.replace(textRange, withText: editText)
                    }
                    if let position = textView.position(
                        from: textView.beginningOfDocument, offset: result.caret
                    ) {
                        textView.selectedTextRange = textView.textRange(
                            from: position, to: position
                        )
                    }
                    syncEdit()
                    return false
                }
                guard replacement == "\n", range.length == 0 else {
                    recordEdit(replacing: range, with: replacement, in: textView.text)
                    return true
                }
                let action = MarkdownEditing.newlineAction(
                    text: textView.text, caret: range.location
                )
                switch action {
                case .insert(let snippet):
                    textView.insertText(snippet)
                    return false
                case .replaceRange(let clearRange, let clearText):
                    if let start = textView.position(
                        from: textView.beginningOfDocument, offset: clearRange.location
                    ), let end = textView.position(from: start, offset: clearRange.length),
                        let textRange = textView.textRange(from: start, to: end) {
                        textView.replace(textRange, withText: clearText)
                    }
                    return false
                case .plain:
                    recordEdit(replacing: range, with: replacement, in: textView.text)
                    return true
                }
            }

            func textView(
                _ textView: UITextView, shouldInteractWith url: URL, in characterRange: NSRange,
                interaction: UITextItemInteraction
            ) -> Bool {
                guard let target = MarkdownTheme.wikiTarget(from: url) else { return true }
                parent.onWikiLink(target, MarkdownTheme.wikiFragment(from: url))
                return false
            }
        }
    }

#endif
