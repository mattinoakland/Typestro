import AppKit
import ApplicationServices

/// A snapshot of the text field that has keyboard focus, in whatever app is in front,
/// read and edited through the Accessibility API.
struct FocusedField {
    let element: AXUIElement
    let bundleID: String?
    let appName: String
    let text: NSString
    let selection: NSRange

    private static let systemWide: AXUIElement = {
        let s = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(s, 0.25)
        return s
    }()

    /// Apps whose accessibility tree we've asked to switch on (Chrome and Electron apps only build it on request).
    private static var primed = Set<pid_t>()

    static func current() -> FocusedField? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        if !primed.contains(app.processIdentifier) {
            primed.insert(app.processIdentifier)
            let appElement = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetAttributeValue(appElement, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        }
        guard let element = copyElement(systemWide, kAXFocusedUIElementAttribute) else { return nil }
        AXUIElementSetMessagingTimeout(element, 0.25)

        // Never look inside password fields.
        if copyString(element, kAXSubroleAttribute) == kAXSecureTextFieldSubrole { return nil }

        guard let value = copyString(element, kAXValueAttribute),
              let selection = copyRange(element, kAXSelectedTextRangeAttribute) else { return nil }

        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)
        let owner = NSRunningApplication(processIdentifier: pid) ?? app
        return FocusedField(
            element: element,
            bundleID: owner.bundleIdentifier,
            appName: owner.localizedName ?? "an app",
            text: value as NSString,
            selection: selection
        )
    }

    /// Where a range of text is on screen, in AppKit coordinates (origin bottom-left).
    func screenRect(for range: NSRange) -> NSRect? {
        var cf = CFRange(location: range.location, length: range.length)
        guard let param = AXValueCreate(.cfRange, &cf) else { return nil }
        var out: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element, kAXBoundsForRangeParameterizedAttribute as CFString, param, &out) == .success,
              let out, CFGetTypeID(out) == AXValueGetTypeID() else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(out as! AXValue, .cgRect, &rect), rect.width > 0, rect.height > 0 else { return nil }
        // Accessibility uses a top-left origin measured from the primary screen.
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return NSRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    /// The text box itself on screen, in AppKit coordinates.
    var frame: NSRect? {
        guard let p = Self.copy(element, kAXPositionAttribute), CFGetTypeID(p) == AXValueGetTypeID(),
              let s = Self.copy(element, kAXSizeAttribute), CFGetTypeID(s) == AXValueGetTypeID() else { return nil }
        var origin = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(p as! AXValue, .cgPoint, &origin), AXValueGetValue(s as! AXValue, .cgSize, &size) else { return nil }
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return NSRect(x: origin.x, y: primaryHeight - origin.y - size.height, width: size.width, height: size.height)
    }

    /// Roughly where the cursor is: the character just before it, or the box when that isn't available.
    var caretRect: NSRect? {
        let caret = selection.location
        if caret > 0, let r = screenRect(for: NSRange(location: caret - 1, length: 1)) {
            return NSRect(x: r.maxX, y: r.minY, width: 1, height: r.height)
        }
        return frame
    }

    /// Inserts text at the cursor, replacing any selection.
    func insert(_ string: String) {
        if !isWebContent {
            let expected = text.replacingCharacters(in: selection, with: string)
            if AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, string as CFString) == .success,
               Self.copyString(element, kAXValueAttribute) == expected {
                setSelection(NSRange(location: selection.location + (string as NSString).length, length: 0))
                return
            }
        }
        KeyTap.type(string)
    }

    /// One rect per line a range covers. A phrase that wraps would otherwise get a single box
    /// spanning the full width of both lines.
    func lineRects(for range: NSRange) -> [NSRect] {
        guard let whole = screenRect(for: range) else { return [] }
        var words: [NSRect] = []
        text.enumerateSubstrings(in: range, options: .byWords) { _, wordRange, _, _ in
            if let r = screenRect(for: wordRange) { words.append(r) }
        }
        guard let first = words.first, whole.height > first.height * 1.5 else { return [whole] }
        var lines: [NSRect] = []
        for word in words {
            if let i = lines.indices.last, abs(lines[i].midY - word.midY) < first.height / 2 {
                lines[i] = lines[i].union(word)
            } else {
                lines.append(word)
            }
        }
        return lines
    }

    @discardableResult
    func setSelection(_ range: NSRange) -> Bool {
        var cf = CFRange(location: range.location, length: range.length)
        guard let value = AXValueCreate(.cfRange, &cf) else { return false }
        return AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, value) == .success
    }

    /// True for text inside web content: browsers and Electron apps (Claude, Slack, Discord).
    /// Those report accessibility edits as done without doing them, and apply selection
    /// changes late, so edits there are typed as keystrokes instead.
    var isWebContent: Bool {
        var current: AXUIElement? = element
        for _ in 0..<25 {
            guard let el = current else { return false }
            if Self.copyString(el, kAXRoleAttribute) == "AXWebArea" { return true }
            current = Self.copyElement(el, kAXParentAttribute)
        }
        return false
    }

    /// Replaces `range` with `new`.
    ///
    /// This runs on the main thread, which is also where the key tap lives, so keys the user
    /// presses meanwhile wait in the tap and land after the edit.
    func replace(_ range: NSRange, with new: String) -> Bool {
        if !isWebContent, replaceDirectly(range, with: new) { return true }
        return replaceByTyping(range, with: new)
    }

    /// Native text views: set the text through accessibility, check it took, put the cursor back.
    private func replaceDirectly(_ range: NSRange, with new: String) -> Bool {
        let caret = selection
        guard setSelection(range) else { return false }
        guard AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, new as CFString) == .success,
              Self.copyString(element, kAXValueAttribute) == text.replacingCharacters(in: range, with: new) else {
            setSelection(caret)
            return false
        }
        var c = caret
        if c.location >= NSMaxRange(range) { c.location += (new as NSString).length - range.length }
        setSelection(c)
        return true
    }

    /// Web content. Near the cursor: backspace to the start of the word and retype it plus whatever
    /// followed, the way text expanders do, so nothing is ever left selected. Further back (accepting
    /// a suggestion while you're idle): select it, wait for the app to show the selection, type over it.
    private func replaceByTyping(_ range: NSRange, with new: String) -> Bool {
        let caret = selection.location
        guard selection.length == 0 else { return false }
        if range.location < caret, NSMaxRange(range) <= caret, caret - range.location <= 150 {
            let tail = text.substring(with: NSRange(location: NSMaxRange(range), length: caret - NSMaxRange(range)))
            // Retyping a Return could send a chat message.
            guard !tail.contains(where: \.isNewline) else { return false }
            let erase = text.substring(with: NSRange(location: range.location, length: caret - range.location)).count
            KeyTap.backspace(erase)
            KeyTap.type(new + tail)
            return true
        }
        guard setSelection(range), waitFor({ Self.copyRange(element, kAXSelectedTextRangeAttribute) == range }) else {
            return false
        }
        KeyTap.type(new)
        return true
    }

    private func waitFor(_ condition: () -> Bool, timeout: TimeInterval = 0.25) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            usleep(10_000)
        }
        return condition()
    }

    // MARK: Attribute helpers

    private static func copy(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    private static func copyElement(_ element: AXUIElement, _ name: String) -> AXUIElement? {
        guard let v = copy(element, name), CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return (v as! AXUIElement)
    }

    private static func copyString(_ element: AXUIElement, _ name: String) -> String? {
        copy(element, name) as? String
    }

    private static func copyRange(_ element: AXUIElement, _ name: String) -> NSRange? {
        guard let v = copy(element, name), CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        var cf = CFRange()
        guard AXValueGetValue(v as! AXValue, .cfRange, &cf) else { return nil }
        return NSRange(location: cf.location, length: cf.length)
    }
}
