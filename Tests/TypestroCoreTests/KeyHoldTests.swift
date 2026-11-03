import XCTest
@testable import TypestroCore

final class KeyHoldTests: XCTestCase {
    func testKeysPassWhenNothingIsHeld() {
        var hold = KeyHold<String>()
        XCTAssertFalse(hold.offer("a"))
        XCTAssertEqual(hold.count, 0)
    }

    func testKeysDuringAnEditComeBackInOrder() {
        var hold = KeyHold<String>()
        hold.start()
        for key in ["h-down", "h-up", "e-down", "l-down", "e-up", "l-up"] {
            XCTAssertTrue(hold.offer(key), "\(key) must not reach the app while the word is selected")
        }
        XCTAssertEqual(hold.count, 6)
        XCTAssertEqual(hold.finish(), ["h-down", "h-up", "e-down", "l-down", "e-up", "l-up"])
    }

    func testFinishingLetsKeysThroughAgain() {
        var hold = KeyHold<String>()
        hold.start()
        _ = hold.offer("a")
        _ = hold.finish()
        XCTAssertFalse(hold.isHolding)
        XCTAssertFalse(hold.offer("b"))
        XCTAssertEqual(hold.finish(), [], "nothing is replayed twice")
    }

    func testCountsWhatIsHeld() {
        var hold = KeyHold<String>()
        hold.start()
        XCTAssertEqual(hold.count, 0)
        _ = hold.offer("x")
        XCTAssertEqual(hold.count, 1)
    }
}
