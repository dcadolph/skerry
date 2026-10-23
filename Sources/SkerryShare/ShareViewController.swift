import Foundation
import UniformTypeIdentifiers

#if canImport(UIKit)
    import UIKit
    /// Platform view controller the share extension principal subclasses.
    typealias PlatformShareController = UIViewController
#else
    import AppKit
    /// Platform view controller the share extension principal subclasses.
    typealias PlatformShareController = NSViewController
#endif

/// ShareViewController receives shared text, links, and images, parks them in the app
/// group inbox, and finishes immediately; the note appears next time Skerry runs.
final class ShareViewController: PlatformShareController {
    #if canImport(AppKit)
        override func loadView() {
            view = NSView()
        }
    #endif

    override func viewDidLoad() {
        super.viewDidLoad()
        let context = extensionContext
        Task {
            await Self.collect(from: context)
            context?.completeRequest(returningItems: nil)
        }
    }

    /// Pulls text, the URL, and images out of the shared items into one inbox capture.
    static func collect(from context: NSExtensionContext?) async {
        var capture = SharedCapture(title: "", text: "", url: "", images: [], createdAt: Date())
        for item in context?.inputItems.compactMap({ $0 as? NSExtensionItem }) ?? [] {
            if capture.title.isEmpty {
                capture.title = item.attributedTitle?.string ?? ""
            }
            for provider in item.attachments ?? [] {
                let loaded = await load(provider)
                if let url = loaded.url, capture.url.isEmpty { capture.url = url }
                if let text = loaded.text {
                    capture.text += capture.text.isEmpty ? text : "\n\n" + text
                }
                if let image = loaded.image { capture.images.append(image) }
            }
            if capture.text.isEmpty {
                capture.text = item.attributedContentText?.string ?? ""
            }
        }
        guard !capture.text.isEmpty || !capture.url.isEmpty || !capture.images.isEmpty else {
            return
        }
        ShareInbox.deposit(capture)
    }

    /// Loads one attachment as a link, text, or image bytes.
    private static func load(
        _ provider: NSItemProvider
    ) async -> (url: String?, text: String?, image: Data?) {
        if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
            let item = try? await provider.loadItem(forTypeIdentifier: UTType.url.identifier)
            if let url = item as? URL {
                if url.isFileURL {
                    if let data = try? Data(contentsOf: url) { return (nil, nil, data) }
                } else {
                    return (url.absoluteString, nil, nil)
                }
            }
        }
        if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
            let item = try? await provider.loadItem(forTypeIdentifier: UTType.image.identifier)
            if let url = item as? URL, let data = try? Data(contentsOf: url) {
                return (nil, nil, data)
            }
            if let data = item as? Data { return (nil, nil, data) }
            #if canImport(UIKit)
                if let image = item as? UIImage, let data = image.pngData() {
                    return (nil, nil, data)
                }
            #else
                if let image = item as? NSImage, let tiff = image.tiffRepresentation,
                    let rep = NSBitmapImageRep(data: tiff),
                    let data = rep.representation(using: .png, properties: [:]) {
                    return (nil, nil, data)
                }
            #endif
        }
        if provider.hasItemConformingToTypeIdentifier(UTType.html.identifier) {
            // Raw page HTML travels as-is; the app converts it to Markdown on import.
            let item = try? await provider.loadItem(forTypeIdentifier: UTType.html.identifier)
            if let html = item as? String { return (nil, html, nil) }
            if let data = item as? Data {
                return (nil, String(decoding: data, as: UTF8.self), nil)
            }
        }
        if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
            let item = try? await provider.loadItem(forTypeIdentifier: UTType.plainText.identifier)
            if let text = item as? String { return (nil, text, nil) }
            if let attributed = item as? NSAttributedString { return (nil, attributed.string, nil) }
        }
        return (nil, nil, nil)
    }
}
