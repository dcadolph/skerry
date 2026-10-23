import Foundation

/// HTMLToMarkdown converts clipped page HTML into readable Markdown: headings, emphasis,
/// links, images, lists, quotes, and code. A focused converter for what articles actually
/// use, not a browser engine; unknown tags vanish and their text survives.
public enum HTMLToMarkdown {
    /// Whether text smells like HTML markup worth converting.
    public static func looksLikeHTML(_ text: String) -> Bool {
        let lowered = text.lowercased()
        return lowered.contains("</") || lowered.contains("<html") || lowered.contains("<p>")
            || lowered.contains("<div") || lowered.contains("<br")
    }

    /// Converts an HTML string to Markdown.
    public static func convert(_ html: String) -> String {
        var text = html.replacingOccurrences(of: "\r\n", with: "\n")
        for tag in ["script", "style", "head", "nav", "footer", "iframe", "noscript", "svg", "form"] {
            text = replace(text, "(?is)<\(tag)[^>]*>.*?</\(tag)>", "")
        }
        text = replace(text, #"<!--[\s\S]*?-->"#, "")
        text = replace(text, #"(?i)<br\s*/?>"#, "\n")
        text = replace(text, #"(?i)<hr\s*/?>"#, "\n\n---\n\n")
        for level in 1...6 {
            let hashes = String(repeating: "#", count: level)
            text = replace(
                text, "(?is)<h\(level)[^>]*>(.*?)</h\(level)>", "\n\n\(hashes) $1\n\n"
            )
        }
        text = replace(text, #"(?is)<pre[^>]*>\s*(?:<code[^>]*>)?(.*?)(?:</code>)?\s*</pre>"#,
            "\n\n```\n$1\n```\n\n")
        text = replace(text, #"(?is)<(?:strong|b)\b[^>]*>(.*?)</(?:strong|b)>"#, "**$1**")
        text = replace(text, #"(?is)<(?:em|i)\b[^>]*>(.*?)</(?:em|i)>"#, "*$1*")
        text = replace(text, #"(?is)<mark[^>]*>(.*?)</mark>"#, "==$1==")
        text = replace(text, #"(?is)<code[^>]*>(.*?)</code>"#, "`$1`")
        text = replace(text, #"(?is)<img[^>]*?src="([^"]*)"[^>]*/?>"#, "![]($1)")
        text = replace(text, #"(?is)<a\b[^>]*?href="([^"]*)"[^>]*>(.*?)</a>"#, "[$2]($1)")
        text = replace(text, #"(?is)<blockquote[^>]*>\s*(.*?)\s*</blockquote>"#, "\n\n> $1\n\n")
        text = replace(text, #"(?is)<li[^>]*>(.*?)</li>"#, "\n- $1")
        text = replace(text, #"(?i)</(?:p|div|section|article|ul|ol|table|tr|main|header)>"#, "\n\n")
        text = replace(text, #"(?s)<[^>]+>"#, "")
        text = decodeEntities(text)
        text = replace(text, #"[ \t]+\n"#, "\n")
        text = replace(text, #"[ \t]{2,}"#, " ")
        text = replace(text, #"\n{3,}"#, "\n\n")
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The page title inside an HTML document, entities decoded and whitespace collapsed;
    /// nil when the document has none.
    public static func pageTitle(in html: String) -> String? {
        let pattern = try! NSRegularExpression(pattern: #"(?is)<title[^>]*>(.*?)</title>"#)
        let ns = html as NSString
        guard let match = pattern.firstMatch(
            in: html, range: NSRange(location: 0, length: ns.length)
        ) else { return nil }
        let raw = ns.substring(with: match.range(at: 1))
        let decoded = decodeEntities(raw)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !decoded.isEmpty else { return nil }
        return String(decoded.prefix(200))
    }

    /// Applies one regex replacement over a string.
    private static func replace(_ text: String, _ pattern: String, _ template: String) -> String {
        let regex = try! NSRegularExpression(pattern: pattern)
        let range = NSRange(location: 0, length: (text as NSString).length)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: template)
    }

    /// Named entities the converter understands.
    private static let namedEntities: [String: String] = [
        "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&apos;": "'",
        "&#39;": "'", "&nbsp;": " ", "&mdash;": "\u{2014}", "&ndash;": "\u{2013}",
        "&hellip;": "\u{2026}", "&rsquo;": "\u{2019}", "&lsquo;": "\u{2018}",
        "&rdquo;": "\u{201D}", "&ldquo;": "\u{201C}", "&copy;": "\u{00A9}",
    ]

    /// Matches numeric character references, decimal and hex.
    private static let numericEntityPattern = try! NSRegularExpression(
        pattern: #"&#(x?)([0-9a-fA-F]+);"#
    )

    /// Decodes the common named and numeric HTML entities.
    static func decodeEntities(_ input: String) -> String {
        var text = input
        for (entity, replacement) in namedEntities {
            text = text.replacingOccurrences(of: entity, with: replacement)
        }
        let ns = text as NSString
        var output = ""
        var cursor = 0
        let whole = NSRange(location: 0, length: ns.length)
        for match in numericEntityPattern.matches(in: text, range: whole) {
            output += ns.substring(
                with: NSRange(location: cursor, length: match.range.location - cursor)
            )
            let isHex = match.range(at: 1).length > 0
            let digits = ns.substring(with: match.range(at: 2))
            let value = UInt32(digits, radix: isHex ? 16 : 10)
            if let value, let scalar = Unicode.Scalar(value) {
                output.append(Character(scalar))
            } else {
                output += ns.substring(with: match.range)
            }
            cursor = match.range.location + match.range.length
        }
        output += ns.substring(from: cursor)
        return output
    }
}
