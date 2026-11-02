import XCTest
@testable import TypestroCore

final class FixPolicyTests: XCTestCase {
    func testNarrowsToTheWordThatChanges() {
        XCTAssertEqual(TextTools.narrowChange("could of", "could have"),
                       TextTools.Change(offset: 6, original: "of", replacement: "have"))
        XCTAssertEqual(TextTools.narrowChange("form now on", "from now on"),
                       TextTools.Change(offset: 0, original: "form", replacement: "from"))
        XCTAssertEqual(TextTools.narrowChange("I'll be their in", "I'll be there in"),
                       TextTools.Change(offset: 8, original: "their", replacement: "there"))
        XCTAssertEqual(TextTools.narrowChange("sirkumstanses", "circumstances"),
                       TextTools.Change(offset: 0, original: "sirkumstanses", replacement: "circumstances"))
    }

    func testSharedLettersInsideAWordAreNotSplit() {
        // "rekamend" and "recommend" share "re" and "end", but the whole word is what gets replaced.
        let change = TextTools.narrowChange("rekamend", "recommend")
        XCTAssertEqual(change.original, "rekamend")
        XCTAssertEqual(change.offset, 0)
    }

    func testOnlySingleWordsAreSilent() {
        XCTAssertTrue(TextTools.narrowChange("could of", "could have").isWordLevel)
        XCTAssertTrue(TextTools.narrowChange("alot", "a lot").isWordLevel)
        XCTAssertTrue(TextTools.narrowChange("its", "it's").isWordLevel)
        XCTAssertFalse(TextTools.narrowChange("me and him went", "he and I went").isWordLevel, "two words change")
        XCTAssertFalse(TextTools.narrowChange("going to the", "going the").isWordLevel, "a word removed")
        XCTAssertFalse(TextTools.narrowChange("the", "the very best of the").isWordLevel, "a phrase added")
        XCTAssertFalse(TextTools.narrowChange("same", "same").isWordLevel)
    }

    func testFinishedEnd() {
        func finished(_ s: String) -> String {
            let text = s as NSString
            return text.substring(to: TextTools.finishedEnd(in: text, caret: text.length))
        }
        XCTAssertEqual(finished("Still typing this"), "")
        XCTAssertEqual(finished("Just ended."), "", "a period alone isn't moving on yet")
        XCTAssertEqual(finished("Done here. Now"), "Done here.")
        XCTAssertEqual(finished("Done here. "), "Done here.")
        XCTAssertEqual(finished("One. Two! Three"), "One. Two!")
        XCTAssertEqual(finished("He said \"hi.\" Then"), "He said \"hi.\"")
        XCTAssertEqual(finished("First line\nsecond"), "First line\n", "a new line or paragraph counts")
        XCTAssertEqual(finished("Pi is 3.14 and"), "", "a decimal point isn't a sentence end")
    }
}
