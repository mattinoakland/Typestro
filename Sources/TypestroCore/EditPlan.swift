import Foundation

/// One change to make in a text field: `original` at `range` becomes `replacement`.
public struct PlannedEdit: Equatable, Sendable {
    public let range: NSRange
    public let original: String
    public let replacement: String

    public init(range: NSRange, original: String, replacement: String) {
        self.range = range
        self.original = original
        self.replacement = replacement
    }

    /// Only an exact match counts. If the text there has changed, the edit is skipped, never moved.
    public func matches(_ text: NSString) -> Bool {
        NSMaxRange(range) <= text.length && text.substring(with: range) == original
    }
}

/// Order and undo for a batch of edits, such as accepting every suggestion at once.
public enum EditPlan {
    /// Last in the text first, so making one edit never moves the ones still to come.
    public static func applyOrder(_ edits: [PlannedEdit]) -> [PlannedEdit] {
        edits.sorted { $0.range.location > $1.range.location }
    }

    /// The edits that put back everything in `applied` (in any order), as one step. Each replacement has been
    /// pushed along by the earlier edits before it in the text, so that's where it's looked for.
    public static func undo(of applied: [PlannedEdit]) -> [PlannedEdit] {
        let undone = applied.map { edit -> PlannedEdit in
            let shift = applied
                .filter { $0.range.location < edit.range.location }
                .reduce(0) { $0 + ($1.replacement as NSString).length - $1.range.length }
            let range = NSRange(location: edit.range.location + shift, length: (edit.replacement as NSString).length)
            return PlannedEdit(range: range, original: edit.replacement, replacement: edit.original)
        }
        return applyOrder(undone)
    }

    /// What `text` looks like after `edits`, applied in `applyOrder`. Skips any that don't match.
    public static func apply(_ edits: [PlannedEdit], to text: String) -> (text: String, applied: [PlannedEdit]) {
        var current = text as NSString
        var applied: [PlannedEdit] = []
        for edit in applyOrder(edits) where edit.matches(current) {
            current = current.replacingCharacters(in: edit.range, with: edit.replacement) as NSString
            applied.append(edit)
        }
        return (current as String, applied)
    }
}
