/// Key presses held back while Typestro changes the text, so none can reach the app while a word is selected
/// (it would type over the word). They're given back in the order they came.
public struct KeyHold<Event> {
    private var events: [Event] = []
    public private(set) var isHolding = false

    public init() {}

    /// Keys that have arrived since `start`. Any at all before the word is selected means the fix is called off.
    public var count: Int { events.count }

    public mutating func start() {
        isHolding = true
    }

    /// True if the event was kept, which means it must not reach the app now.
    public mutating func offer(_ event: Event) -> Bool {
        guard isHolding else { return false }
        events.append(event)
        return true
    }

    /// Stops holding and hands back everything held, oldest first.
    public mutating func finish() -> [Event] {
        isHolding = false
        defer { events = [] }
        return events
    }
}
