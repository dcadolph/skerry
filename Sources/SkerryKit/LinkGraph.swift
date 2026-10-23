import Foundation

/// LinkGraph tracks which notes wiki-link to which names, so backlinks are a dictionary
/// lookup instead of a scan of every note body on every render.
///
/// Names are the text inside `[[...]]`, lowercased; a note is found by its file stem or
/// its title, so callers ask for sources linking to either.
public struct LinkGraph: Sendable {
    /// Outgoing lowercased link names per source path.
    private var outgoing: [String: Set<String>] = [:]
    /// Source paths per lowercased target name, the reverse index.
    private var incoming: [String: Set<String>] = [:]

    /// Creates an empty graph.
    public init() {}

    /// Records a note's outgoing links from its body, replacing what was known.
    public mutating func update(path: String, body: String) {
        setOutgoing(path: path, names: Self.wikiNames(in: body))
    }

    /// Forgets a note entirely.
    public mutating func remove(path: String) {
        setOutgoing(path: path, names: [])
    }

    /// Moves a note, carrying its outgoing links to the new path.
    public mutating func move(from oldPath: String, to newPath: String) {
        let names = outgoing[oldPath] ?? []
        setOutgoing(path: oldPath, names: [])
        setOutgoing(path: newPath, names: names)
    }

    /// Paths of notes linking to any of the given names, case-insensitive.
    public func sources(linkingTo names: [String]) -> Set<String> {
        var result: Set<String> = []
        for name in names {
            result.formUnion(incoming[name.lowercased()] ?? [])
        }
        return result
    }

    /// Replaces a path's outgoing set, keeping the reverse index consistent.
    private mutating func setOutgoing(path: String, names: Set<String>) {
        let previous = outgoing[path] ?? []
        for stale in previous.subtracting(names) {
            incoming[stale]?.remove(path)
            if incoming[stale]?.isEmpty == true { incoming[stale] = nil }
        }
        for fresh in names.subtracting(previous) {
            incoming[fresh, default: []].insert(path)
        }
        outgoing[path] = names.isEmpty ? nil : names
    }

    /// Lowercased wiki-link names in a body, code excluded the same way styling is.
    public static func wikiNames(in body: String) -> Set<String> {
        var names: Set<String> = []
        let ns = body as NSString
        for token in MarkdownScanner.scan(body) where token.kind == .wikiLink {
            let inner = ns.substring(with: token.range)
                .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
                .trimmingCharacters(in: .whitespaces)
            // A `[[Note#Heading]]` link still points at Note, so key the graph on the note part
            // only; keeping the fragment would make backlinks to the note silently miss.
            let note = WikiLink.split(inner).note
            if !note.isEmpty { names.insert(note.lowercased()) }
        }
        return names
    }
}
