import Foundation

/// The change a suggestion makes, word by word, for the preview card: removed words struck through,
/// new words highlighted, the rest as it was.
public enum WordDiff {
    public enum Change: Equatable, Sendable {
        case same, removed, added
    }

    public struct Segment: Equatable, Sendable {
        public let text: String
        public let change: Change

        public init(_ text: String, _ change: Change) {
            self.text = text
            self.change = change
        }
    }

    /// Words and the spaces between them, so the pieces join back up exactly.
    static func tokens(_ s: String) -> [String] {
        var out: [String] = []
        var current = ""
        for c in s {
            if let last = current.last, last.isWhitespace != c.isWhitespace {
                out.append(current)
                current = ""
            }
            current.append(c)
        }
        if !current.isEmpty { out.append(current) }
        return out
    }

    public static func segments(from original: String, to replacement: String) -> [Segment] {
        let a = tokens(original), b = tokens(replacement)
        // Longest common subsequence of tokens; small inputs, so the plain table is fine.
        var lcs = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in stride(from: a.count - 1, through: 0, by: -1) {
            for j in stride(from: b.count - 1, through: 0, by: -1) {
                lcs[i][j] = a[i] == b[j] ? lcs[i + 1][j + 1] + 1 : max(lcs[i + 1][j], lcs[i][j + 1])
            }
        }
        var raw: [Segment] = []
        var i = 0, j = 0
        while i < a.count || j < b.count {
            if i < a.count, j < b.count, a[i] == b[j] {
                raw.append(Segment(a[i], .same)); i += 1; j += 1
            } else if i < a.count, j == b.count || lcs[i + 1][j] >= lcs[i][j + 1] {
                // Struck-through words read before the ones replacing them.
                raw.append(Segment(a[i], .removed)); i += 1
            } else {
                raw.append(Segment(b[j], .added)); j += 1
            }
        }
        // Runs of the same kind join up, so a change shows as one piece.
        var merged: [Segment] = []
        for seg in raw {
            if let last = merged.last, last.change == seg.change {
                merged[merged.count - 1] = Segment(last.text + seg.text, seg.change)
            } else {
                merged.append(seg)
            }
        }
        return merged
    }
}
