import Foundation

/// TextMerge three-way merges note text at line level, so edits from two devices both
/// survive when they touch different lines and only genuinely overlapping edits count as
/// conflicts.
///
/// The merge is symmetric: both devices compute the same result regardless of which side
/// they call "mine", which is what lets two peers converge without coordination. When any
/// hunks truly overlap, the merge reports a conflict and the caller falls back to keeping
/// both versions whole.
public enum TextMerge {
    /// Outcome of a merge attempt.
    public struct Outcome: Equatable, Sendable {
        /// The merged text; meaningful only when conflicts is zero.
        public let merged: String
        /// How many overlapping edits could not be reconciled.
        public let conflicts: Int
    }

    /// Most lines a side may have before the merge punts to a conflict, keeping the
    /// quadratic line-matching bounded.
    private static let lineLimit = 4000

    /// One edit against the base: a base line range and its replacement lines.
    private struct Hunk {
        /// First base line the hunk replaces.
        var start: Int
        /// How many base lines it replaces; zero for a pure insertion.
        var length: Int
        /// Lines that take the range's place.
        var replacement: [String]
    }

    /// Merges two descendants of a common base.
    public static func merge(base: String, mine: String, theirs: String) -> Outcome {
        if mine == theirs { return Outcome(merged: mine, conflicts: 0) }
        if base == mine { return Outcome(merged: theirs, conflicts: 0) }
        if base == theirs { return Outcome(merged: mine, conflicts: 0) }

        let baseLines = base.components(separatedBy: "\n")
        let mineLines = mine.components(separatedBy: "\n")
        let theirLines = theirs.components(separatedBy: "\n")
        guard baseLines.count <= lineLimit, mineLines.count <= lineLimit,
            theirLines.count <= lineLimit
        else { return Outcome(merged: mine, conflicts: 1) }

        let mineHunks = hunks(base: baseLines, updated: mineLines)
        let theirHunks = hunks(base: baseLines, updated: theirLines)

        // Combine both hunk lists in base order, applying the symmetric rules.
        var combined: [Hunk] = []
        var i = 0
        var j = 0
        while i < mineHunks.count || j < theirHunks.count {
            if i < mineHunks.count, j < theirHunks.count {
                let a = mineHunks[i]
                let b = theirHunks[j]
                let overlap = a.start < b.start + b.length && b.start < a.start + a.length
                let samePlace = a.start == b.start && a.length == b.length
                if samePlace, a.replacement == b.replacement {
                    // Both sides made the identical edit.
                    combined.append(a)
                    i += 1
                    j += 1
                    continue
                }
                if a.length == 0, b.length == 0, a.start == b.start {
                    // Two insertions at the same point keep both, in an order that does
                    // not depend on which side is "mine" so peers converge.
                    let joinedA = a.replacement.joined(separator: "\n")
                    let joinedB = b.replacement.joined(separator: "\n")
                    let ordered = joinedA <= joinedB
                        ? a.replacement + b.replacement
                        : b.replacement + a.replacement
                    combined.append(Hunk(start: a.start, length: 0, replacement: ordered))
                    i += 1
                    j += 1
                    continue
                }
                if overlap || samePlace || a.start == b.start {
                    // The same base region changed differently on each side, or an
                    // insertion collides with an edit at the same point; either way the
                    // apply order would depend on which side merges, so it conflicts.
                    return Outcome(merged: mine, conflicts: 1)
                }
                if a.start < b.start {
                    combined.append(a)
                    i += 1
                } else {
                    combined.append(b)
                    j += 1
                }
            } else if i < mineHunks.count {
                combined.append(mineHunks[i])
                i += 1
            } else {
                combined.append(theirHunks[j])
                j += 1
            }
        }

        // Apply the combined edits over the base.
        var result: [String] = []
        var cursor = 0
        for hunk in combined {
            if hunk.start > cursor {
                result.append(contentsOf: baseLines[cursor..<hunk.start])
            }
            result.append(contentsOf: hunk.replacement)
            cursor = hunk.start + hunk.length
        }
        if cursor < baseLines.count {
            result.append(contentsOf: baseLines[cursor...])
        }
        return Outcome(merged: result.joined(separator: "\n"), conflicts: 0)
    }

    /// Edit hunks turning base into updated, from a longest-common-subsequence match.
    private static func hunks(base: [String], updated: [String]) -> [Hunk] {
        let matches = lcsMatches(base, updated)
        var result: [Hunk] = []
        var basePos = 0
        var updatedPos = 0
        for (baseIndex, updatedIndex) in matches + [(base.count, updated.count)] {
            let removed = baseIndex - basePos
            let added = Array(updated[updatedPos..<updatedIndex])
            if removed > 0 || !added.isEmpty {
                result.append(Hunk(start: basePos, length: removed, replacement: added))
            }
            basePos = baseIndex + 1
            updatedPos = updatedIndex + 1
        }
        return result
    }

    /// Index pairs of matched lines in a longest common subsequence of the two sides.
    private static func lcsMatches(_ a: [String], _ b: [String]) -> [(Int, Int)] {
        let n = a.count
        let m = b.count
        guard n > 0, m > 0 else { return [] }
        // Classic DP table of LCS lengths, one row at a time to bound memory.
        var table = [[Int32]](repeating: [Int32](repeating: 0, count: m + 1), count: n + 1)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                if a[i] == b[j] {
                    table[i][j] = table[i + 1][j + 1] + 1
                } else {
                    table[i][j] = max(table[i + 1][j], table[i][j + 1])
                }
            }
        }
        var matches: [(Int, Int)] = []
        var i = 0
        var j = 0
        while i < n, j < m {
            if a[i] == b[j] {
                matches.append((i, j))
                i += 1
                j += 1
            } else if table[i + 1][j] >= table[i][j + 1] {
                i += 1
            } else {
                j += 1
            }
        }
        return matches
    }
}
