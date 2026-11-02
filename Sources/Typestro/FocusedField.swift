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
    /// changes late, so edits there select the text and type over it instead.
    var isWebContent: Bool {
        var current: AXUIElement? = element
        for _ in 0..<25 {
            guard let el = current else { return false }
            if Self.copyString(el, kAXRoleAttribute) == "AXWebArea" { return true }
            current = Self.copyElement(el, kAXParentAttribute)
        }
        return false
    }

    /// Replaces just `range` with `new` and puts the cursor back where it was. Nothing else is touched.
    /// From selecting the word until the cursor is back, your keys are held by `tap` and replayed afterwards,
    /// so they can never type over the selected word.
    @MainActor
    func replace(_ range: NSRange, with new: String, holding tap: KeyTap) async -> Bool {
        guard selection.length == 0, NSMaxRange(range) <= text.length else { return false }
        if !isWebContent, replaceDirectly(range, with: new) { return true }
        tap.hold()
        defer { tap.release() }
        return await replaceBySelecting(range, with: new, tap: tap)
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

    /// Web content: select only the word, wait for the app to show the selection, type over it, then move the
    /// cursor back. Never retypes what comes after it. The fix is called off, with the cursor put back, if you
    /// press a key before the word is selected or the app won't select it.
    @MainActor
    private func replaceBySelecting(_ range: NSRange, with new: String, tap: KeyTap) async -> Bool {
        let caret = selection
        // A key that reached the app just before the hold began has moved the cursor; this snapshot is stale.
        guard tap.heldCount == 0, currentSelection == caret, setSelection(range) else { return false }
        let selected = await waitFor({ tap.heldCount > 0 || currentSelection == range })
        guard selected, tap.heldCount == 0 else {
            await putBack(caret)
            if tap.heldCount == 0 { NSLog("Typestro: %@ wouldn't select the word, so it was left alone", appName) }
            return false
        }
        KeyTap.type(new)
        let typed = NSRange(location: range.location, length: (new as NSString).length)
        let landed = await waitFor({
            guard let value = Self.copyString(element, kAXValueAttribute) as NSString?, NSMaxRange(typed) <= value.length,
                  value.substring(with: typed) == new else { return false }
            return currentSelection == NSRange(location: NSMaxRange(typed), length: 0)
        }, timeout: 0.4)
        guard landed else {
            // Still selected means nothing was typed: put the cursor back so your keys can't land on the word.
            // Anything else (you clicked somewhere, say) is left as it is.
            if currentSelection == range { await putBack(caret) }
            return false
        }
        var back = caret
        if back.location >= NSMaxRange(range) { back.location += typed.length - range.length }
        if back != NSRange(location: NSMaxRange(typed), length: 0) { await putBack(back) }
        return true
    }

    @MainActor
    private func putBack(_ caret: NSRange) async {
        setSelection(caret)
        _ = await waitFor({ currentSelection == caret })
    }

    private var currentSelection: NSRange? { Self.copyRange(element, kAXSelectedTextRangeAttribute) }

    /// Checks every 10 ms without holding up the main thread, so the key tap keeps working.
    @MainActor
    private func waitFor(_ condition: () -> Bool, timeout: TimeInterval = 0.25) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
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
