import XCTest
@testable import TypestroCore

/// Stands in for the keychain. With `hold` set, calls wait the way they do behind a password prompt.
private final class FakeKeychain: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String]
    private var callThreads: [Bool] = []
    let hold = DispatchSemaphore(value: 0)
    var holds = false
    var saves = true

    init(_ values: [String: String] = [:]) {
        self.values = values
    }

    private func enter() {
        lock.lock()
        callThreads.append(Thread.isMainThread)
        lock.unlock()
        if holds { hold.wait() }
    }

    var calls: Int {
        lock.lock()
        defer { lock.unlock() }
        return callThreads.count
    }

    var calledOnMain: Bool {
        lock.lock()
        defer { lock.unlock() }
        return callThreads.contains(true)
    }

    func read(_ account: String) -> String? {
        enter()
        lock.lock()
        defer { lock.unlock() }
        return values[account]
    }

    func write(_ value: String, _ account: String) -> Bool {
        enter()
        lock.lock()
        defer { lock.unlock() }
        if saves { values[account] = value }
        return saves
    }
}

final class KeyStoreTests: XCTestCase {
    private func store(_ fake: FakeKeychain) -> KeyStore {
        KeyStore(read: { fake.read($0) }, write: { fake.write($0, $1) })
    }

    func testLoadsEachKeyOnceOffTheMainThread() {
        let fake = FakeKeychain(["a": "one"])
        let keys = store(fake)
        let done = expectation(description: "loaded")
        keys.load(["a", "b"]) {
            XCTAssertTrue(Thread.isMainThread)
            done.fulfill()
        }
        wait(for: [done], timeout: 2)

        XCTAssertTrue(keys.isLoaded)
        XCTAssertEqual(keys.key("a"), "one")
        XCTAssertNil(keys.key("b"))
        _ = keys.key("a")
        _ = keys.key("b")
        XCTAssertEqual(fake.calls, 2, "reading a key afterwards must not touch the keychain")
        XCTAssertFalse(fake.calledOnMain)
    }

    func testAPromptDoesNotHoldUpTheMainThread() {
        let fake = FakeKeychain(["a": "one"])
        fake.holds = true
        let keys = store(fake)
        let done = expectation(description: "loaded")
        keys.load(["a"]) { done.fulfill() }

        // The keychain is stuck, as it is while a prompt is up. These return straight away.
        XCTAssertFalse(keys.isLoaded)
        XCTAssertNil(keys.key("a"))

        fake.hold.signal()
        wait(for: [done], timeout: 2)
        XCTAssertEqual(keys.key("a"), "one")
    }

    func testCompletionWaitsForTheLastKey() {
        let fake = FakeKeychain(["a": "one", "b": "two"])
        fake.holds = true
        let keys = store(fake)
        let done = expectation(description: "loaded")
        done.isInverted = true
        keys.load(["a", "b"]) { done.fulfill() }

        fake.hold.signal()
        wait(for: [done], timeout: 0.2)
        XCTAssertFalse(keys.isLoaded, "the key tap has to stay off until every prompt is answered")

        let finished = expectation(description: "finished")
        keys.load([]) { finished.fulfill() }
        fake.hold.signal()
        wait(for: [finished], timeout: 2)
        XCTAssertTrue(keys.isLoaded)
    }

    func testSavingUpdatesMemoryOffTheMainThread() {
        let fake = FakeKeychain()
        let keys = store(fake)
        let done = expectation(description: "saved")
        keys.save("new", "a") { saved in
            XCTAssertTrue(saved)
            XCTAssertTrue(Thread.isMainThread)
            done.fulfill()
        }
        wait(for: [done], timeout: 2)

        XCTAssertEqual(keys.key("a"), "new")
        XCTAssertFalse(fake.calledOnMain)
    }

    func testFailedSaveKeepsTheOldKey() {
        let fake = FakeKeychain(["a": "old"])
        let keys = store(fake)
        let loaded = expectation(description: "loaded")
        keys.load(["a"]) { loaded.fulfill() }
        wait(for: [loaded], timeout: 2)

        fake.saves = false
        let done = expectation(description: "saved")
        keys.save("new", "a") { saved in
            XCTAssertFalse(saved)
            done.fulfill()
        }
        wait(for: [done], timeout: 2)
        XCTAssertEqual(keys.key("a"), "old")
    }
}
