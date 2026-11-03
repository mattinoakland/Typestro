import AppKit
import CoreGraphics
import TypestroCore

enum KeyCode {
    static let tab: Int64 = 48
    static let escape: Int64 = 53
    static let z: Int64 = 6
    static let a: Int64 = 0
    static let left: Int64 = 123
    static let right: Int64 = 124
}

/// Sees every key press system-wide before the app in front gets it, and can swallow one
/// (Tab and Esc, only while a suggestion card is showing). Needs Accessibility permission.
final class KeyTap {
    struct Key {
        let keyCode: Int64
        let characters: String
        let flags: CGEventFlags

        var isPlain: Bool {
            flags.intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift]).isEmpty
        }
    }

    /// Marks keystrokes Typestro posts itself so the tap lets them through untouched.
    static let marker: Int64 = 0x4D52_474E

    /// Return true to swallow the key.
    var handler: ((Key) -> Bool)?
    /// A modifier key (Shift, Option, Command, Control) went down or up. These always pass through.
    var modifierHandler: ((Int64, CGEventFlags) -> Void)?

    private var tap: CFMachPort?
    /// Keys pressed while Typestro is changing the text, sent on once it's done.
    private var held = KeyHold<CGEvent>()
    private var holdDepth = 0
    private var holdGeneration = 0

    var isRunning: Bool { tap != nil }

    /// Holds back key presses until the matching `release`, so they can't land in the middle of an edit (on a
    /// selected word, say). Holds nest: accepting several suggestions holds for the whole batch, and each word's
    /// edit inside it holds too. Lets go by itself three seconds after the last `hold`, in case an edit never
    /// finishes; one word's edit waits about one second at most, so this only ever catches a bug.
    func hold() {
        holdDepth += 1
        if holdDepth == 1 { held.start() }
        holdGeneration += 1
        let generation = holdGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self, holdGeneration == generation, held.isHolding else { return }
            holdDepth = 1
            release()
        }
    }

    /// Once the outermost hold ends, sends the held keys on, in order. They pass through the tap again, so
    /// they're handled like any other key.
    func release() {
        guard holdDepth > 0 else { return }
        holdDepth -= 1
        guard holdDepth == 0 else { return }
        for event in held.finish() { event.post(tap: .cgSessionEventTap) }
    }

    func start() -> Bool {
        if tap != nil { return true }
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            let me = Unmanaged<KeyTap>.fromOpaque(refcon!).takeUnretainedValue()
            return me.handle(type, event)
        }
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(1 << CGEventType.keyDown.rawValue) | CGEventMask(1 << CGEventType.keyUp.rawValue)
                | CGEventMask(1 << CGEventType.flagsChanged.rawValue),
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return false }
        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        guard event.getIntegerValueField(.eventSourceUserData) != Self.marker else {
            return Unmanaged.passUnretained(event)
        }
        // Releases are held too, so the app never sees a key let go before it was pressed.
        if type == .keyDown || type == .keyUp, held.isHolding {
            // A key that can't be kept is dropped: letting it through could type over the selected word.
            if let copy = event.copy() { _ = held.offer(copy) }
            return nil
        }
        if type == .flagsChanged {
            modifierHandler?(event.getIntegerValueField(.keyboardEventKeycode), event.flags)
            return Unmanaged.passUnretained(event)
        }
        guard type == .keyDown else { return Unmanaged.passUnretained(event) }
        let key = Key(
            keyCode: event.getIntegerValueField(.keyboardEventKeycode),
            characters: NSEvent(cgEvent: event)?.characters ?? "",
            flags: event.flags
        )
        if handler?(key) == true { return nil }
        return Unmanaged.passUnretained(event)
    }

    /// Types text one character at a time, whatever the keyboard layout. Line breaks are typed as
    /// Shift-Return, which adds a line in chat apps (Slack, Claude, Messages) instead of sending.
    static func type(_ text: String) {
        let source = CGEventSource(stateID: .privateState)
        for character in text {
            if character.isNewline {
                for down in [true, false] {
                    if let event = CGEvent(keyboardEventSource: source, virtualKey: 36, keyDown: down) { post(event, flags: .maskShift) }
                }
                continue
            }
            var units = Array(String(character).utf16)
            for down in [true, false] {
                guard let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down) else { continue }
                event.keyboardSetUnicodeString(stringLength: units.count, unicodeString: &units)
                post(event)
            }
        }
    }

    /// Posts a keystroke marked as Typestro's own, with only the given modifiers (so a held Shift can't leak in).
    private static func post(_ event: CGEvent, flags: CGEventFlags = []) {
        event.flags = flags
        event.setIntegerValueField(.eventSourceUserData, value: marker)
        event.post(tap: .cgSessionEventTap)
    }
}
