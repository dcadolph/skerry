import Foundation

/// CodeHighlighter finds keywords, strings, comments, and numbers inside fenced code so
/// the editor can color them. Line-based and deliberately lightweight: enough to make
/// code readable, not a compiler.
public enum CodeHighlighter {
    /// Kind of a colored span.
    public enum Kind: Equatable, Sendable {
        case keyword, string, comment, number
    }

    /// One colored span within a line.
    public struct Span: Equatable, Sendable {
        /// What the span is.
        public let kind: Kind
        /// UTF-16 range within the line.
        public let range: NSRange

        /// Creates a span.
        public init(kind: Kind, range: NSRange) {
            self.kind = kind
            self.range = range
        }
    }

    /// Keyword sets by lowercased language name or alias.
    private static let keywordTable: [String: Set<String>] = {
        let swiftWords: Set<String> = [
            "func", "let", "var", "if", "else", "guard", "return", "struct", "class", "enum",
            "case", "switch", "for", "while", "in", "import", "extension", "protocol", "init",
            "self", "nil", "true", "false", "try", "catch", "throw", "throws", "async", "await",
            "public", "private", "internal", "static", "some", "defer", "do", "break",
            "continue", "where", "as", "is", "any", "mutating", "override", "final",
        ]
        let goWords: Set<String> = [
            "func", "var", "const", "if", "else", "return", "struct", "type", "interface",
            "switch", "case", "for", "range", "import", "package", "defer", "go", "chan",
            "map", "nil", "true", "false", "select", "break", "continue", "fallthrough",
            "goto", "string", "int", "int64", "bool", "byte", "error", "make", "new", "len",
        ]
        let pythonWords: Set<String> = [
            "def", "class", "if", "elif", "else", "return", "import", "from", "as", "for",
            "while", "in", "try", "except", "finally", "with", "lambda", "pass", "break",
            "continue", "raise", "yield", "async", "await", "None", "True", "False", "not",
            "and", "or", "is", "global", "del", "print",
        ]
        let scriptWords: Set<String> = [
            "function", "const", "let", "var", "if", "else", "return", "class", "extends",
            "switch", "case", "for", "while", "of", "in", "import", "export", "from",
            "default", "try", "catch", "finally", "throw", "new", "this", "null",
            "undefined", "true", "false", "async", "await", "typeof", "instanceof",
            "break", "continue", "yield", "interface", "type",
        ]
        let rustWords: Set<String> = [
            "fn", "let", "mut", "if", "else", "return", "struct", "enum", "impl", "trait",
            "match", "for", "while", "in", "use", "mod", "pub", "self", "Self", "true",
            "false", "async", "await", "loop", "break", "continue", "where", "as", "dyn",
            "ref", "crate", "move",
        ]
        let rubyWords: Set<String> = [
            "def", "end", "class", "module", "if", "elsif", "else", "unless", "return",
            "case", "when", "for", "while", "do", "require", "begin", "rescue", "ensure",
            "raise", "yield", "nil", "true", "false", "self", "not", "and", "or", "puts",
        ]
        let shellWords: Set<String> = [
            "if", "then", "else", "elif", "fi", "for", "while", "do", "done", "case",
            "esac", "function", "return", "local", "export", "echo", "exit", "in", "set",
        ]
        var table: [String: Set<String>] = [:]
        table["swift"] = swiftWords
        for name in ["go", "golang"] { table[name] = goWords }
        for name in ["python", "py"] { table[name] = pythonWords }
        for name in ["javascript", "js", "typescript", "ts", "jsx", "tsx", "json"] {
            table[name] = scriptWords
        }
        for name in ["rust", "rs"] { table[name] = rustWords }
        for name in ["ruby", "rb"] { table[name] = rubyWords }
        for name in ["bash", "sh", "shell", "zsh"] { table[name] = shellWords }
        return table
    }()

    /// Languages whose line comments start with a hash rather than a double slash.
    private static let hashCommentLanguages: Set<String> = [
        "python", "py", "bash", "sh", "shell", "zsh", "ruby", "rb", "yaml", "yml", "toml",
    ]

    /// Matches double-quoted, single-quoted, and backtick strings with escapes.
    private static let stringPattern = try! NSRegularExpression(
        pattern: #""(?:[^"\\\n]|\\.)*"|'(?:[^'\\\n]|\\.)*'|`[^`\n]*`"#
    )
    /// Matches integer and decimal literals.
    private static let numberPattern = try! NSRegularExpression(
        pattern: #"(?<![\w.])\d+(?:\.\d+)?\b"#
    )
    /// Matches identifier words.
    private static let wordPattern = try! NSRegularExpression(
        pattern: #"[A-Za-z_][A-Za-z0-9_]*"#
    )

    /// Spans to color in one line of code for a language. Unknown languages still get
    /// strings, numbers, and slash comments.
    public static func spans(line: String, language rawLanguage: String) -> [Span] {
        let language = rawLanguage.lowercased()
        let ns = line as NSString
        let whole = NSRange(location: 0, length: ns.length)
        var spans: [Span] = []

        var strings: [NSRange] = []
        for match in stringPattern.matches(in: line, range: whole) {
            strings.append(match.range)
        }

        // The first comment marker outside a string claims the rest of the line.
        let marker = hashCommentLanguages.contains(language) ? "#" : "//"
        var commentStart = NSNotFound
        var searchFrom = 0
        while searchFrom < ns.length {
            let found = ns.range(
                of: marker, range: NSRange(location: searchFrom, length: ns.length - searchFrom)
            )
            guard found.location != NSNotFound else { break }
            let insideString = strings.contains {
                NSIntersectionRange($0, found).length > 0
            }
            if insideString {
                searchFrom = found.location + found.length
            } else {
                commentStart = found.location
                break
            }
        }
        if commentStart != NSNotFound {
            spans.append(Span(
                kind: .comment,
                range: NSRange(location: commentStart, length: ns.length - commentStart)
            ))
            strings.removeAll { $0.location >= commentStart }
        }

        for range in strings {
            spans.append(Span(kind: .string, range: range))
        }

        var claimed = spans.map(\.range)
        func free(_ range: NSRange) -> Bool {
            !claimed.contains { NSIntersectionRange($0, range).length > 0 }
        }

        for match in numberPattern.matches(in: line, range: whole) where free(match.range) {
            spans.append(Span(kind: .number, range: match.range))
            claimed.append(match.range)
        }

        if let keywords = keywordTable[language] {
            for match in wordPattern.matches(in: line, range: whole) where free(match.range) {
                let word = ns.substring(with: match.range)
                if keywords.contains(word) {
                    spans.append(Span(kind: .keyword, range: match.range))
                    claimed.append(match.range)
                }
            }
        }

        return spans.sorted { $0.range.location < $1.range.location }
    }
}
