import XCTest
@testable import TypestroCore

final class TextToolsTests: XCTestCase {
    private func word(_ s: String, caret: Int? = nil) -> String? {
        let text = s as NSString
        guard let r = TextTools.lastCompletedWord(in: text, caret: caret ?? text.length) else { return nil }
        return text.substring(with: r)
    }

    func testLastCompletedWord() {
        XCTAssertEqual(word("under these sirkumstanses "), "sirkumstanses")
        XCTAssertEqual(word("it's done."), "done")
        XCTAssertEqual(word("they're "), "they're")
        XCTAssertEqual(word("'quoted' "), "quoted")
        XCTAssertNil(word("mid wor"), "caret inside a word")
        XCTAssertEqual(word("first second", caret: 6), "first")
    }

    func testShouldConsider() {
        func check(_ s: String) -> Bool {
            let text = s as NSString
            guard let r = TextTools.lastCompletedWord(in: text, caret: text.length) else { return false }
            return TextTools.shouldConsider(r, in: text)
        }
        XCTAssertTrue(check("I rekamend "))
        XCTAssertTrue(check("Rekamend "))
        XCTAssertFalse(check("call NASA "))
        XCTAssertFalse(check("my iPhone "))
        XCTAssertFalse(check("ping @mattm "))
        XCTAssertFalse(check("see abc1 "))
        XCTAssertFalse(check("go to example.com "))
        XCTAssertFalse(check("a "))
    }

    func testSentenceRange() {
        let text = "First one. Second sentence here." as NSString
        let r = TextTools.sentenceRange(in: text, endingAt: text.length)
        XCTAssertEqual(text.substring(with: r), "Second sentence here.")
        let partial = "Done. Now typing" as NSString
        XCTAssertEqual(partial.substring(with: TextTools.sentenceRange(in: partial, endingAt: partial.length)), "Now typing")
    }

    func testLocateWholeWordsNearest() {
        let text = "their house and their car, theirs too" as NSString
        XCTAssertEqual(TextTools.locate("their", in: text, near: 18, within: nil)?.location, 16)
        XCTAssertEqual(TextTools.locate("their", in: text, near: 0, within: nil)?.location, 0)
        XCTAssertNil(TextTools.locate("hous", in: text, near: 0, within: nil))
        XCTAssertNil(TextTools.locate("their", in: text, near: 0, within: NSRange(location: 22, length: 15)), "theirs is not their")
    }

    func testMatchCase() {
        XCTAssertEqual(TextTools.matchCase(of: "Rekamend", to: "recommend"), "Recommend")
        XCTAssertEqual(TextTools.matchCase(of: "TEH", to: "the"), "THE")
        XCTAssertEqual(TextTools.matchCase(of: "teh", to: "the"), "the")
    }

    func testEditDistance() {
        XCTAssertEqual(TextTools.editDistance("teh", "the"), 1)
        XCTAssertEqual(TextTools.editDistance("recieve", "receive"), 1)
        XCTAssertGreaterThan(TextTools.editDistance("sirkumstanses", "circumstances"), 1)
    }

    func testSchemasAreValidJSON() throws {
        XCTAssertNoThrow(try JSONSerialization.data(withJSONObject: Prompts.spellingSchema))
        XCTAssertNoThrow(try JSONSerialization.data(withJSONObject: Prompts.suggestionSchema))
    }
}
