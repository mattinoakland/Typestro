import AppKit
import CoreGraphics

enum KeyCode {
    static let tab: Int64 = 48
    static let escape: Int64 = 53
    static let z: Int64 = 6
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

    var isRunning: Bool { tap != nil }

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
            eventsOfInterest: CGEventMask(1 << CGEventType.keyDown.rawValue) | CGEventMask(1 << CGEventType.flagsChanged.rawValue),
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

    /// Presses Backspace `count` times.
    static func backspace(_ count: Int) {
        let source = CGEventSource(stateID: .privateState)
        for _ in 0..<count {
            for down in [true, false] {
                if let event = CGEvent(keyboardEventSource: source, virtualKey: 51, keyDown: down) { post(event) }
            }
        }
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
