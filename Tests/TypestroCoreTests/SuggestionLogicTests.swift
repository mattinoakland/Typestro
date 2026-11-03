import XCTest
@testable import TypestroCore

final class SuggestionLogicTests: XCTestCase {
    // MARK: Diff

    func testDiffOfASingleWord() {
        XCTAssertEqual(WordDiff.segments(from: "teh", to: "the"),
                       [.init("teh", .removed), .init("the", .added)])
    }

    func testDiffKeepsSharedWords() {
        XCTAssertEqual(WordDiff.segments(from: "I think the the timeline is", to: "I think the timeline is"),
                       [.init("I think the ", .same), .init("the ", .removed), .init("timeline is", .same)])
    }

    func testDiffJoinsBackUp() {
        let original = "we should of went there"
        let replacement = "we should have gone there"
        let segments = WordDiff.segments(from: original, to: replacement)
        XCTAssertEqual(segments.filter { $0.change != .added }.map(\.text).joined(), original)
        XCTAssertEqual(segments.filter { $0.change != .removed }.map(\.text).joined(), replacement)
        XCTAssertTrue(segments.contains(.init("we should ", .same)))
    }

    // MARK: Accept all and undo

    private let text = "I'll be their in ten minuets, and then we can by lunch."

    private func edit(_ original: String, _ replacement: String) -> PlannedEdit {
        let range = (text as NSString).range(of: original)
        return PlannedEdit(range: range, original: original, replacement: replacement)
    }

    func testAcceptAllAppliesFromTheEnd() {
        let edits = [edit("their", "there"), edit("minuets", "minutes"), edit("by", "buy")]
        XCTAssertEqual(EditPlan.applyOrder(edits).map(\.original), ["by", "minuets", "their"])
        let result = EditPlan.apply(edits, to: text)
        XCTAssertEqual(result.text, "I'll be there in ten minutes, and then we can buy lunch.")
        XCTAssertEqual(result.applied.count, 3)
    }

    func testOneUndoPutsTheWholeBatchBack() {
        let edits = [edit("their", "there"), edit("ten minuets", "ten minutes"), edit("by", "buy")]
        let done = EditPlan.apply(edits, to: text)
        let undone = EditPlan.apply(EditPlan.undo(of: done.applied), to: done.text)
        XCTAssertEqual(undone.applied.count, 3)
        XCTAssertEqual(undone.text, text)
    }

    func testUndoFindsWordsMovedByLongerReplacements() {
        let edits = [edit("I'll", "I will"), edit("by", "buy")]
        let done = EditPlan.apply(edits, to: text)
        XCTAssertEqual(done.text, "I will be their in ten minuets, and then we can buy lunch.")
        let undo = EditPlan.undo(of: done.applied)
        XCTAssertEqual(undo.first?.original, "buy")
        XCTAssertEqual(undo.first?.range.location, (done.text as NSString).range(of: "buy").location)
        XCTAssertEqual(EditPlan.apply(undo, to: done.text).text, text)
    }

    func testChangedTextIsSkippedNotGuessed() {
        let stale = PlannedEdit(range: NSRange(location: 8, length: 5), original: "their", replacement: "there")
        let changed = "I'll be thier in ten minuets"
        XCTAssertFalse(stale.matches(changed as NSString))
        let result = EditPlan.apply([stale], to: changed)
        XCTAssertEqual(result.text, changed)
        XCTAssertTrue(result.applied.isEmpty)
    }

    func testAnEditPastTheEndIsSkipped() {
        let edit = PlannedEdit(range: NSRange(location: 40, length: 3), original: "abc", replacement: "x")
        XCTAssertFalse(edit.matches("short" as NSString))
    }

    // MARK: Finished sentences

    func testFinishedEnd() {
        func finished(_ s: String) -> String {
            let text = s as NSString
            return text.substring(to: TextTools.finishedEnd(in: text, caret: text.length))
        }
        XCTAssertEqual(finished("Still typing this"), "")
        XCTAssertEqual(finished("Just ended."), "", "a period alone isn't moving on yet")
        XCTAssertEqual(finished("Done here. Now"), "Done here.")
        XCTAssertEqual(finished("One. Two! Three"), "One. Two!")
        XCTAssertEqual(finished("He said \"hi.\" Then"), "He said \"hi.\"")
        XCTAssertEqual(finished("First line\nsecond"), "First line\n")
        XCTAssertEqual(finished("Pi is 3.14 and"), "")
    }
}
