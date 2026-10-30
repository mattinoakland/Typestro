import Foundation

/// Text helpers. Everything works in UTF-16 offsets (NSString / NSRange),
/// because that is what the macOS Accessibility API uses for text ranges.
public enum TextTools {
    private static let letters = CharacterSet.letters
    private static let apostrophes = CharacterSet(charactersIn: "'’")
    private static let allowedBefore = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "([{\"“‘'—–"))
    private static let allowedAfter = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ".,!?;:)]}\"”’'…—–"))
    private static let sentenceEnds = CharacterSet(charactersIn: ".!?\n\r")

    static func scalar(_ c: unichar) -> Unicode.Scalar? { Unicode.Scalar(c) }

    static func isLetter(_ c: unichar) -> Bool {
        guard let s = scalar(c) else { return false }
        return letters.contains(s)
    }

    static func isWordUnit(_ c: unichar) -> Bool {
        guard let s = scalar(c) else { return false }
        return letters.contains(s) || apostrophes.contains(s)
    }

    static func isIn(_ set: CharacterSet, _ c: unichar) -> Bool {
        guard let s = scalar(c) else { return false }
        return set.contains(s)
    }

    /// The word that ends just before `caret`, skipping the space or punctuation the user just typed.
    /// Returns nil when the caret is in the middle of a word.
    public static func lastCompletedWord(in text: NSString, caret: Int) -> NSRange? {
        var end = min(max(caret, 0), text.length)
        var skipped = 0
        while end > 0, !isWordUnit(text.character(at: end - 1)) {
            end -= 1
            skipped += 1
            if skipped > 3 { return nil }
        }
        guard skipped > 0 else { return nil }
        var start = end
        while start > 0, isWordUnit(text.character(at: start - 1)) { start -= 1 }
        // Drop apostrophes at the edges, e.g. 'quoted' words.
        while start < end, !isLetter(text.character(at: start)) { start += 1 }
        while end > start, !isLetter(text.character(at: end - 1)) { end -= 1 }
        guard end > start else { return nil }
        return NSRange(location: start, length: end - start)
    }

    /// Where the word the caret is in the middle of starts (the caret itself when it's not in a word).
    public static func startOfWordInProgress(in text: NSString, caret: Int) -> Int {
        var start = min(max(caret, 0), text.length)
        while start > 0, isWordUnit(text.character(at: start - 1)) { start -= 1 }
        return start
    }

    /// Whether a word is ordinary prose worth spell-checking. Skips acronyms, camelCase and brand
    /// spellings (iPhone), single letters, and anything glued to digits, @handles, paths or URLs.
    public static func shouldConsider(_ range: NSRange, in text: NSString) -> Bool {
        guard range.length >= 2, range.length <= 40 else { return false }
        if range.location > 0, !isIn(allowedBefore, text.character(at: range.location - 1)) { return false }
        let after = NSMaxRange(range)
        if after < text.length, !isIn(allowedAfter, text.character(at: after)) { return false }
        let word = text.substring(with: range)
        if word == word.uppercased() { return false }
        if word.dropFirst().contains(where: { $0.isUppercase }) { return false }
        return true
    }

    /// The sentence the caret is in (or just finished), from its start up to the caret.
    public static func sentenceRange(in text: NSString, endingAt caret: Int) -> NSRange {
        let end = min(max(caret, 0), text.length)
        var i = end
        // Step back over the terminator and spaces just typed.
        while i > 0, isIn(sentenceEnds, text.character(at: i - 1)) || isIn(.whitespaces, text.character(at: i - 1)) { i -= 1 }
        while i > 0, !isIn(sentenceEnds, text.character(at: i - 1)) { i -= 1 }
        while i < end, isIn(.whitespacesAndNewlines, text.character(at: i)) { i += 1 }
        return NSRange(location: i, length: end - i)
    }

    /// A range of about `radius` characters either side of `location`, for long documents.
    public static func window(in text: NSString, around location: Int, radius: Int) -> NSRange {
        let lo = max(0, location - radius)
        let hi = min(text.length, location + radius)
        return NSRange(location: lo, length: hi - lo)
    }

    public static func wordCount(_ s: String) -> Int {
        s.split(whereSeparator: { $0.isWhitespace }).count
    }

    /// Finds `needle` as whole words in `text`, choosing the occurrence nearest `near`.
    /// When `within` is given, only occurrences fully inside it count.
    public static func locate(_ needle: String, in text: NSString, near: Int, within: NSRange?) -> NSRange? {
        let n = needle as NSString
        guard n.length > 0 else { return nil }
        let startsWithLetter = isWordUnit(n.character(at: 0))
        let endsWithLetter = isWordUnit(n.character(at: n.length - 1))
        let bounds = within.map { NSIntersectionRange($0, NSRange(location: 0, length: text.length)) }
            ?? NSRange(location: 0, length: text.length)
        var search = bounds
        var best: NSRange?
        while search.length >= n.length {
            let r = text.range(of: needle, options: [], range: search)
            if r.location == NSNotFound { break }
            let okBefore = !startsWithLetter || r.location == 0 || !isWordUnit(text.character(at: r.location - 1))
            let okAfter = !endsWithLetter || NSMaxRange(r) >= text.length || !isWordUnit(text.character(at: NSMaxRange(r)))
            if okBefore && okAfter {
                if best == nil || abs(r.location - near) < abs(best!.location - near) { best = r }
            }
            let next = r.location + 1
            search = NSRange(location: next, length: NSMaxRange(bounds) - next)
        }
        return best
    }

    /// Gives `replacement` the capitalization style of `original` (ALL CAPS, or a leading capital).
    public static func matchCase(of original: String, to replacement: String) -> String {
        guard let first = original.first, let repFirst = replacement.first else { return replacement }
        if original.count > 1, original == original.uppercased(), original != original.lowercased() {
            return replacement.uppercased()
        }
        if first.isUppercase, repFirst.isLowercase {
            return repFirst.uppercased() + replacement.dropFirst()
        }
        return replacement
    }

    /// Edit distance that counts a swap of two neighbouring letters as one edit ("teh" → "the").
    public static func editDistance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var d = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in 0...a.count { d[i][0] = i }
        for j in 0...b.count { d[0][j] = j }
        for i in 1...a.count {
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                d[i][j] = min(d[i - 1][j] + 1, d[i][j - 1] + 1, d[i - 1][j - 1] + cost)
                if i > 1, j > 1, a[i - 1] == b[j - 2], a[i - 2] == b[j - 1] {
                    d[i][j] = min(d[i][j], d[i - 2][j - 2] + 1)
                }
            }
        }
        return d[a.count][b.count]
    }
}
