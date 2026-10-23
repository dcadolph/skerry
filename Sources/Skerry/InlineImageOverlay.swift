import Foundation
import SkerryKit

#if canImport(AppKit)
    import AppKit
    /// Image view type hosting one inline picture.
    private typealias PlatformImageHost = NSImageView
#else
    import UIKit
    /// Image view type hosting one inline picture.
    private typealias PlatformImageHost = UIImageView
#endif

/// InlineImageOverlay renders image attachments inside the editor: each `![alt](path)`
/// line reserves a band below it (see MarkdownTheme) and this overlay positions a decoded
/// picture there, tracking layout as the text changes. The text itself never changes.
@MainActor
final class InlineImageOverlay {
    /// Hosted image views keyed by link plus character position.
    private var hosts: [String: PlatformImageHost] = [:]
    /// Decoded images by link, so files decode once per note.
    private var cache: [String: PlatformImage] = [:]

    /// Drops decoded images, on note switches.
    func clearCache() {
        cache.removeAll()
    }

    #if canImport(AppKit)
        /// Repositions pictures beneath every image link in the text view.
        func update(in textView: NSTextView, provider: (String) -> PlatformImage?) {
            guard let layoutManager = textView.layoutManager,
                let container = textView.textContainer
            else { return }
            layoutManager.ensureLayout(for: container)
            let inset = CGPoint(
                x: textView.textContainerInset.width, y: textView.textContainerInset.height
            )
            apply(
                text: textView.string,
                provider: provider,
                container: textView,
                lineBottom: { characterIndex in
                    let glyph = layoutManager.glyphIndexForCharacter(at: characterIndex)
                    let rect = layoutManager.lineFragmentUsedRect(
                        forGlyphAt: glyph, effectiveRange: nil
                    )
                    return CGRect(
                        x: rect.minX + inset.x, y: rect.maxY + inset.y,
                        width: max(textView.bounds.width - inset.x * 2, 50), height: 0
                    )
                }
            )
        }

    #else
        /// Repositions pictures beneath every image link in the text view.
        func update(in textView: UITextView, provider: (String) -> PlatformImage?) {
            textView.layoutManager.ensureLayout(for: textView.textContainer)
            let inset = CGPoint(
                x: textView.textContainerInset.left, y: textView.textContainerInset.top
            )
            apply(
                text: textView.text,
                provider: provider,
                container: textView,
                lineBottom: { characterIndex in
                    let glyph = textView.layoutManager.glyphIndexForCharacter(at: characterIndex)
                    let rect = textView.layoutManager.lineFragmentUsedRect(
                        forGlyphAt: glyph, effectiveRange: nil
                    )
                    return CGRect(
                        x: rect.minX + inset.x, y: rect.maxY + inset.y,
                        width: max(textView.bounds.width - inset.x * 2, 50), height: 0
                    )
                }
            )
        }

    #endif

    /// Shared placement: finds image tokens, resolves pictures, and diffs the hosted
    /// views against what the text needs now.
    private func apply(
        text: String, provider: (String) -> PlatformImage?,
        container: PlatformView, lineBottom: (Int) -> CGRect
    ) {
        let ns = text as NSString
        var wanted: Set<String> = []
        var horizontalCursor: [Int: CGFloat] = [:]

        for token in MarkdownScanner.scan(text) where token.kind == .image {
            guard token.range.location < ns.length else { continue }
            let span = ns.substring(with: token.range)
            guard let match = MarkdownScanner.imagePattern.firstMatch(
                in: span, range: NSRange(location: 0, length: (span as NSString).length)
            ) else { continue }
            let link = (span as NSString).substring(with: match.range(at: 1))
                .trimmingCharacters(in: .whitespaces)
            guard !link.contains("://") else { continue }
            let key = "\(token.range.location)|\(link)"
            wanted.insert(key)

            let image: PlatformImage?
            if let cached = cache[link] {
                image = cached
            } else if let loaded = provider(link) {
                cache[link] = loaded
                image = loaded
            } else {
                image = nil
            }

            let band = lineBottom(token.range.location)
            let maxHeight = MarkdownTheme.inlineImageBand - 12
            let size = fittedSize(of: image, maxWidth: band.width, maxHeight: maxHeight)
            let startX = band.minX + (horizontalCursor[token.range.location] ?? 0)
            horizontalCursor[token.range.location] = (horizontalCursor[token.range.location] ?? 0)
                + size.width + 8
            let frame = CGRect(
                x: startX, y: band.minY + 6, width: size.width, height: size.height
            )

            let host: PlatformImageHost
            if let existing = hosts[key] {
                host = existing
            } else {
                host = PlatformImageHost(frame: frame)
                #if canImport(AppKit)
                    host.imageScaling = .scaleProportionallyUpOrDown
                    host.wantsLayer = true
                    host.layer?.cornerRadius = 8
                    host.layer?.masksToBounds = true
                #else
                    host.contentMode = .scaleAspectFill
                    host.layer.cornerRadius = 8
                    host.layer.masksToBounds = true
                    host.isUserInteractionEnabled = false
                #endif
                container.addSubview(host)
                hosts[key] = host
            }
            host.frame = frame
            if let image {
                host.image = image
                #if canImport(AppKit)
                    host.layer?.backgroundColor = nil
                #else
                    host.backgroundColor = .clear
                #endif
            } else {
                // Missing file or locked vault: a quiet placeholder holds the space.
                host.image = lockPlaceholder
                #if canImport(AppKit)
                    host.layer?.backgroundColor =
                        NSColor.quaternaryLabelColor.withAlphaComponent(0.15).cgColor
                #else
                    host.backgroundColor = UIColor.quaternaryLabel.withAlphaComponent(0.15)
                #endif
            }
        }

        for (key, host) in hosts where !wanted.contains(key) {
            host.removeFromSuperview()
            hosts[key] = nil
        }
    }

    /// Size fitting an image inside the band, preserving aspect; placeholders get a box.
    private func fittedSize(
        of image: PlatformImage?, maxWidth: CGFloat, maxHeight: CGFloat
    ) -> CGSize {
        guard let image, image.size.width > 0, image.size.height > 0 else {
            return CGSize(width: min(120, maxWidth), height: maxHeight)
        }
        let scale = min(maxWidth / image.size.width, maxHeight / image.size.height, 1)
        return CGSize(
            width: max(image.size.width * scale, 24),
            height: max(image.size.height * scale, 24)
        )
    }

    /// System image used when the picture cannot be shown.
    private var lockPlaceholder: PlatformImage? {
        #if canImport(AppKit)
            NSImage(systemSymbolName: "lock.doc", accessibilityDescription: "Locked image")
        #else
            UIImage(systemName: "lock.doc")
        #endif
    }
}

#if canImport(AppKit)
    /// View type both platforms hang image hosts off.
    typealias PlatformView = NSView
#else
    /// View type both platforms hang image hosts off.
    typealias PlatformView = UIView
#endif
