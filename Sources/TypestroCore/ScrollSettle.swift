import CoreGraphics
import Foundation

/// Decides when something pinned to a text box in another app can come back after a scroll.
/// A window can't track another app's page in step with it, so it hides and waits for the box to stop moving.
public struct ScrollSettle {
    /// How long the scrolling has to have stopped before the box is worth looking at.
    public static let quiet: TimeInterval = 0.15
    /// How long the box has to stay put. Browsers report a new position a moment after they draw it.
    public static let steady: TimeInterval = 0.15
    /// Come back anyway after this long, for pages where something keeps moving the box.
    public static let limit: TimeInterval = 1.5

    private var lastScroll: Date?
    private var lastFrame: CGRect?
    private var steadySince: Date?

    public init() {}

    public var isSettling: Bool { lastScroll != nil }

    public mutating func scrolled(at now: Date = Date()) {
        lastScroll = now
        lastFrame = nil
        steadySince = nil
    }

    /// Give it the box's current frame, nil if it's gone. Returns true once it's time to come back.
    public mutating func check(frame: CGRect?, at now: Date = Date()) -> Bool {
        guard let lastScroll else { return false }
        let sinceScroll = now.timeIntervalSince(lastScroll)
        guard sinceScroll >= Self.quiet else { return false }

        if let steadySince, frame == lastFrame {
            guard now.timeIntervalSince(steadySince) >= Self.steady else {
                return finishIfOverLimit(sinceScroll)
            }
            finish()
            return true
        }
        lastFrame = frame
        steadySince = now
        return finishIfOverLimit(sinceScroll)
    }

    private mutating func finishIfOverLimit(_ sinceScroll: TimeInterval) -> Bool {
        guard sinceScroll >= Self.limit else { return false }
        finish()
        return true
    }

    private mutating func finish() {
        lastScroll = nil
        lastFrame = nil
        steadySince = nil
    }
}
