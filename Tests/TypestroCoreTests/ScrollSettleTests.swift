import XCTest
@testable import TypestroCore

final class ScrollSettleTests: XCTestCase {
    private let start = Date(timeIntervalSinceReferenceDate: 0)
    private let box = CGRect(x: 10, y: 20, width: 300, height: 40)

    private func at(_ seconds: TimeInterval) -> Date {
        start.addingTimeInterval(seconds)
    }

    func testNothingHappensWithoutAScroll() {
        var settle = ScrollSettle()
        XCTAssertFalse(settle.isSettling)
        XCTAssertFalse(settle.check(frame: box, at: at(5)))
    }

    func testComesBackOnceTheBoxStopsMoving() {
        var settle = ScrollSettle()
        settle.scrolled(at: at(0))
        XCTAssertTrue(settle.isSettling)

        XCTAssertFalse(settle.check(frame: box, at: at(0.1)), "still inside the quiet period")
        XCTAssertFalse(settle.check(frame: box, at: at(0.2)), "first look at the box")
        XCTAssertFalse(settle.check(frame: box, at: at(0.3)), "hasn't stayed put long enough")
        XCTAssertTrue(settle.check(frame: box, at: at(0.4)))
        XCTAssertFalse(settle.isSettling)
    }

    func testAMovingBoxKeepsItHidden() {
        var settle = ScrollSettle()
        settle.scrolled(at: at(0))
        XCTAssertFalse(settle.check(frame: box, at: at(0.2)))
        XCTAssertFalse(settle.check(frame: box.offsetBy(dx: 0, dy: 30), at: at(0.3)))
        XCTAssertFalse(settle.check(frame: box.offsetBy(dx: 0, dy: 60), at: at(0.4)))
        XCTAssertFalse(settle.check(frame: box.offsetBy(dx: 0, dy: 60), at: at(0.5)), "the wait starts over")
        XCTAssertTrue(settle.check(frame: box.offsetBy(dx: 0, dy: 60), at: at(0.6)))
    }

    func testMoreScrollingStartsTheWaitOver() {
        var settle = ScrollSettle()
        settle.scrolled(at: at(0))
        XCTAssertFalse(settle.check(frame: box, at: at(0.2)))
        XCTAssertFalse(settle.check(frame: box, at: at(0.3)))
        settle.scrolled(at: at(0.35))
        XCTAssertFalse(settle.check(frame: box, at: at(0.4)))
        XCTAssertFalse(settle.check(frame: box, at: at(0.5)))
        XCTAssertFalse(settle.check(frame: box, at: at(0.6)))
        XCTAssertTrue(settle.check(frame: box, at: at(0.7)))
    }

    func testLongScrollDoesNotHitTheLimit() {
        var settle = ScrollSettle()
        for tick in 0..<50 {
            let now = at(Double(tick) * 0.1)
            settle.scrolled(at: now)
            XCTAssertFalse(settle.check(frame: box, at: now))
        }
        XCTAssertTrue(settle.isSettling)
    }

    func testABoxThatNeverStopsStillComesBack() {
        var settle = ScrollSettle()
        settle.scrolled(at: at(0))
        var tick = 2
        while !settle.check(frame: box.offsetBy(dx: 0, dy: CGFloat(tick)), at: at(Double(tick) * 0.1)) {
            tick += 1
            XCTAssertLessThan(tick, 30)
        }
        XCTAssertEqual(Double(tick) * 0.1, ScrollSettle.limit, accuracy: 0.001)
    }

    func testAMissingBoxFinishesToo() {
        var settle = ScrollSettle()
        settle.scrolled(at: at(0))
        XCTAssertFalse(settle.check(frame: nil, at: at(0.2)))
        XCTAssertFalse(settle.check(frame: nil, at: at(0.3)))
        XCTAssertTrue(settle.check(frame: nil, at: at(0.4)))
    }
}
