import Foundation

/// SearchScope limits which notes a search or a sidebar container considers: the whole
/// library, a folder subtree, or a tag and its descendants. It holds the pure containment
/// rules so the same folder and tag matching is shared and unit-tested rather than duplicated
/// across the view layer.
public enum SearchScope: Equatable, Sendable {
    /// The whole library, with no container narrowing.
    case all
    /// A folder subtree, identified by its library-relative path. Subfolders are included.
    case folder(String)
    /// A tag and its descendant tags, so `work` also matches `work/urgent`.
    case tag(String)

    /// Whether a note falls inside this scope. The path is library-relative and the tags are
    /// the note's effective tags, front matter plus inline. Tag matching ignores case. The
    /// trailing separator on folder and tag prefixes keeps a sibling like `WorkStuff` from
    /// matching the `Work` scope.
    public func contains(path: String, tags: [String]) -> Bool {
        switch self {
        case .all:
            return true
        case .folder(let folder):
            return path.hasPrefix(folder + "/")
        case .tag(let tag):
            let target = tag.lowercased()
            return tags.contains { candidate in
                let lowered = candidate.lowercased()
                return lowered == target || lowered.hasPrefix(target + "/")
            }
        }
    }
}
