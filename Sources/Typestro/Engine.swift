import AppKit
import TypestroCore

struct Suggestion {
    let kind: SuggestionKind
    let original: String
    /// What it could become, best first. Usually one.
    let options: [String]
    let reason: String
    var range: NSRange
    var choice = 0

    var replacement: String { options[choice] }
}

/// Reads what you write and underlines what could be better. It never changes your text on its own: a
/// suggestion is only applied when you accept it.
///
/// - Checks run when you pause, or soon after you finish a sentence, and only when the text has changed.
///   One request reads the text around the cursor and returns both kinds of underline: a wave under a
///   misspelled or wrong word, a dashed line under a sentence that could read better (Medium and Full).
///   Sentence suggestions only appear once you've moved on from that sentence.
/// - Hover over or click an underline for a card showing the change. Tab opens the nearest one from the
///   keyboard; Tab again accepts, Esc skips, ← → step through alternatives. ⌃⌥A accepts every suggestion
///   showing, ⌃⌥Z undoes the last accept (a whole batch at once).
/// - Accepting re-reads the field and skips anything whose text no longer matches exactly. While it edits,
///   your key presses are held and replayed afterwards.
@MainActor
final class Engine {
    private let settings: Settings
    private let tap: KeyTap
    private let overlay = Overlay()

    private(set) var suggestions: [Suggestion] = []
    private(set) var lastError: String?
    var onChange: (() -> Void)?

    /// The field the suggestions belong to.
    private var element: AXUIElement?
    /// The last snapshot of that field, for its position while scrolling settles.
    private var lastField: FocusedField?
    /// Where each suggestion's underline is on screen, by index. Empty when the app won't say.
    private var rects: [[NSRect]] = []

    private var pauseTimer: Timer?
    private var followTimer: Timer?
    private var followPending = false
    private var lastKeyTime = Date.distantPast
    private var lastChecked: String?
    private var checkTask: Task<Void, Never>?
    /// Edits run one after another, never two at once.
    private var editTask: Task<Void, Never>?
    private var undoStack: [(element: AXUIElement, edits: [PlannedEdit])] = []

    private var cardIndex: Int?
    private var cardFromKeyboard = false
    private var hoverWork: DispatchWorkItem?
    private var mouseMonitor: Any?
    private var scrollMonitor: Any?
    private var settle = ScrollSettle()
    private var settleTimer: Timer?

    private static let pauseDelay: TimeInterval = 1.2
    /// After . ! ? or Return: soon, but not so soon that "e.g." or a quick next word sets it off.
    private static let sentenceDelay: TimeInterval = 0.5
    private static let sentenceEnds: Set<Character> = [".", "!", "?", "\r", "\n"]

    init(settings: Settings, tap: KeyTap) {
        self.settings = settings
        self.tap = tap
    }

    var canUndo: Bool { !undoStack.isEmpty }

    private var isActive: Bool {
        settings.enabled && settings.suggestionsEnabled
            && !settings.isExcluded(NSWorkspace.shared.frontmostApplication?.bundleIdentifier)
    }

    // MARK: Keys

    /// Called for every key press before it reaches the app. Returns true to swallow the key.
    func handleKey(_ key: KeyTap.Key) -> Bool {
        guard isActive else {
            if !suggestions.isEmpty { clearSuggestions() }
            return false
        }
        lastKeyTime = Date()
        let controlOption = key.flags.contains(.maskControl) && key.flags.contains(.maskAlternate)
        if controlOption, key.keyCode == KeyCode.a {
            acceptAll()
            return true
        }
        if controlOption, key.keyCode == KeyCode.z {
            undoLast()
            return true
        }
        if let index = cardIndex, cardFromKeyboard, suggestions.indices.contains(index) {
            switch key.keyCode {
            case KeyCode.tab where key.isPlain: accept([index]); return true
            case KeyCode.escape: skip(index); return true
            case KeyCode.right where suggestions[index].options.count > 1: cycle(index, by: 1); return true
            case KeyCode.left where suggestions[index].options.count > 1: cycle(index, by: -1); return true
            default: break
            }
        } else if key.keyCode == KeyCode.tab, key.isPlain, !suggestions.isEmpty, showNearestCard() {
            return true
        }
        hideCard()
        scheduleFollow()
        guard !key.flags.contains(.maskCommand), !key.flags.contains(.maskControl) else { return false }
        let endsSentence = key.characters.last.map { Self.sentenceEnds.contains($0) } ?? false
        restartPauseTimer(endsSentence ? Self.sentenceDelay : Self.pauseDelay)
        return false
    }

    private func restartPauseTimer(_ delay: TimeInterval) {
        pauseTimer?.invalidate()
        pauseTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
    }

    // MARK: Checking

    private func check() {
        guard isActive, let field = FocusedField.current(), !settings.isExcluded(field.bundleID),
              field.selection.length == 0 else { return }
        let full = field.text as String
        guard TextTools.wordCount(full) >= 3, full != lastChecked, let client = makeClient() else { return }
        lastChecked = full

        let caret = min(field.selection.location, field.text.length)
        let window = TextTools.window(in: field.text, around: caret, radius: 3000)
        let slice = field.text.substring(with: window) as NSString
        let marked = slice.replacingCharacters(in: NSRange(location: caret - window.location, length: 0), with: Prompts.cursor)
        let system = Prompts.reviewSystem(intensity: settings.intensity, avoid: settings.dismissals,
                                          fixCapitals: SystemAutocorrect.capitalizationIsOff)
        let user = Prompts.reviewUser(app: field.appName, text: marked)
        let element = field.element

        checkTask?.cancel()
        checkTask = Task {
            do {
                let result = try await client.structured(
                    ReviewResult.self, system: system, user: user, schema: Prompts.reviewSchema, timeout: 25)
                guard !Task.isCancelled else { return }
                show(result.suggestions, element: element, near: caret)
                clearError()
            } catch {
                report(error)
            }
        }
    }

    /// Replaces the underlines with a fresh set from a check.
    private func show(_ items: [ReviewResult.Item], element: AXUIElement, near hint: Int) {
        guard isActive, let field = FocusedField.current(), CFEqual(field.element, element) else { return }
        let finished = TextTools.finishedEnd(in: field.text, caret: field.selection.location)
        var fresh: [Suggestion] = []
        for item in items {
            let kind = SuggestionKind(rawValue: item.kind) ?? .sentence
            guard kind == .word || settings.intensity != .light else { continue }
            let original = Prompts.stripMarks(item.original)
            var options: [String] = []
            for r in item.replacements where !r.isEmpty && r != original && !options.contains(r) { options.append(r) }
            options = Array(options.prefix(3))
            guard !original.isEmpty, !options.isEmpty,
                  !(kind == .word && settings.isIgnored(original)),
                  !settings.wasDismissed(original: original, replacement: options[0]),
                  let range = TextTools.locate(original, in: field.text, near: hint, within: nil),
                  // A sentence waits until you've moved on from it.
                  kind == .word || NSMaxRange(range) <= finished,
                  !fresh.contains(where: { NSIntersectionRange($0.range, range).length > 0 }) else { continue }
            fresh.append(Suggestion(kind: kind, original: original, options: options, reason: item.reason, range: range))
        }
        hideCard()
        self.element = element
        suggestions = fresh
        render(field)
    }

    // MARK: Drawing

    private func render(_ field: FocusedField) {
        lastField = field
        let frame = field.frame
        rects = suggestions.map { s in
            let lines = field.lineRects(for: s.range)
            // Some apps report nothing, or the whole box, for a range. Those go in the list instead.
            guard !lines.isEmpty, let frame, lines.allSatisfy({ frame.insetBy(dx: -6, dy: -6).contains($0) }) else { return [] }
            return lines
        }
        if settle.isSettling {
            overlay.hideUnderlines()
            overlay.hideList()
        } else {
            overlay.showUnderlines(zip(suggestions, rects).flatMap { s, lines in lines.map { ($0, s.kind) } })
            let unplaced = suggestions.indices.filter { rects[$0].isEmpty }
            if unplaced.isEmpty {
                overlay.hideList()
            } else {
                overlay.showList(unplaced.map { suggestions[$0] }, near: frame ?? field.caretRect,
                                 accept: { [weak self] i in self?.accept([unplaced[i]]) },
                                 skip: { [weak self] i in self?.skip(unplaced[i]) },
                                 acceptAll: { [weak self] in self?.acceptAll() })
            }
        }
        watch(!suggestions.isEmpty)
        onChange?()
    }

    /// Timers and monitors run only while there are underlines to keep in place.
    private func watch(_ on: Bool) {
        if on, followTimer == nil {
            // Keep underlines on their words while the text reflows.
            followTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.follow() }
            }
            mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDown]) { [weak self] event in
                MainActor.assumeIsolated { self?.mouse(clicked: event.type == .leftMouseDown) }
            }
            scrollMonitor = NSEvent.addGlobalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                MainActor.assumeIsolated { self?.scrolled(event) }
            }
        } else if !on, followTimer != nil {
            followTimer?.invalidate()
            followTimer = nil
            for monitor in [mouseMonitor, scrollMonitor].compactMap({ $0 }) { NSEvent.removeMonitor(monitor) }
            mouseMonitor = nil
            scrollMonitor = nil
            stopSettling()
        }
    }

    private func scheduleFollow() {
        guard !suggestions.isEmpty, !followPending else { return }
        followPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            self?.followPending = false
            self?.follow()
        }
    }

    /// Re-finds each suggestion's exact text after edits; drops the ones whose text is gone.
    private func follow() {
        guard !settle.isSettling else { return }
        guard let field = FocusedField.current(), let element, CFEqual(field.element, element) else {
            overlay.hideUnderlines()
            overlay.hideList()
            hideCard()
            return
        }
        let before = suggestions.count
        suggestions = suggestions.compactMap { s in
            guard let range = TextTools.locate(s.original, in: field.text, near: s.range.location, within: nil) else { return nil }
            var moved = s
            moved.range = range
            return moved
        }
        if suggestions.count != before { hideCard() }
        render(field)
    }

    // MARK: Scrolling

    /// Underlines can't keep up with another app's scrolling, so they hide and come back once it stops.
    private func scrolled(_ event: NSEvent) {
        guard event.scrollingDeltaX != 0 || event.scrollingDeltaY != 0 else { return }
        settle.scrolled()
        overlay.hideUnderlines()
        overlay.hideList()
        hideCard()
        guard settleTimer == nil else { return }
        settleTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkSettled() }
        }
    }

    private func checkSettled() {
        guard settle.check(frame: lastField?.frame) else { return }
        stopSettling()
        follow()
    }

    private func stopSettling() {
        settleTimer?.invalidate()
        settleTimer = nil
        settle = ScrollSettle()
    }

    // MARK: Card

    private func index(at point: NSPoint) -> Int? {
        rects.indices.first { i in rects[i].contains { $0.insetBy(dx: -1, dy: -3).contains(point) } }
    }

    private func mouse(clicked: Bool) {
        guard !settle.isSettling else { return }
        let point = NSEvent.mouseLocation
        hoverWork?.cancel()
        if let i = index(at: point) {
            guard cardIndex != i || cardFromKeyboard else { return }
            // A short dwell, so passing over a word on the way somewhere doesn't pop a card up.
            if clicked {
                showCard(i, fromKeyboard: false)
            } else {
                let work = DispatchWorkItem { [weak self] in
                    guard let self, index(at: NSEvent.mouseLocation) == i else { return }
                    showCard(i, fromKeyboard: false)
                }
                hoverWork = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
            }
        } else if cardIndex != nil, !cardFromKeyboard {
            // Time to reach the card. Over the card itself this monitor goes quiet, so it stays.
            let work = DispatchWorkItem { [weak self] in
                guard let self, !overlay.cardContains(NSEvent.mouseLocation),
                      index(at: NSEvent.mouseLocation) == nil else { return }
                hideCard()
            }
            hoverWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
        }
    }

    private func showNearestCard() -> Bool {
        guard let field = FocusedField.current(), let element, CFEqual(field.element, element) else { return false }
        let caret = field.selection.location
        guard let i = suggestions.indices.filter({ !rects[$0].isEmpty }).min(by: {
            abs(NSMaxRange(suggestions[$0].range) - caret) < abs(NSMaxRange(suggestions[$1].range) - caret)
        }) else { return false }
        showCard(i, fromKeyboard: true)
        return true
    }

    private func showCard(_ i: Int, fromKeyboard: Bool) {
        guard suggestions.indices.contains(i), let anchor = rects[i].first else { return }
        cardIndex = i
        cardFromKeyboard = fromKeyboard
        let s = suggestions[i]
        overlay.showCard(for: s, below: anchor, keyboard: fromKeyboard,
                         accept: { [weak self] in self?.accept([i]) },
                         skip: { [weak self] in self?.skip(i) },
                         cycle: { [weak self] step in self?.cycle(i, by: step) })
    }

    private func hideCard() {
        hoverWork?.cancel()
        guard cardIndex != nil else { return }
        cardIndex = nil
        overlay.hideCard()
    }

    private func cycle(_ i: Int, by step: Int) {
        guard suggestions.indices.contains(i) else { return }
        let count = suggestions[i].options.count
        suggestions[i].choice = (suggestions[i].choice + step + count) % count
        showCard(i, fromKeyboard: cardFromKeyboard)
    }

    private func skip(_ i: Int) {
        hideCard()
        guard suggestions.indices.contains(i) else { return }
        let s = suggestions.remove(at: i)
        if s.kind == .word, !s.original.contains(where: \.isWhitespace) { settings.ignore(s.original) }
        settings.recordDismissal(original: s.original, replacement: s.replacement)
        follow()
    }

    // MARK: Accepting

    func acceptAll() {
        accept(Array(suggestions.indices))
    }

    /// Applies the chosen suggestions as one step, from the end of the text backwards. Each is checked
    /// against a fresh read of the field first, and skipped if its text no longer matches exactly.
    private func accept(_ indices: [Int]) {
        hideCard()
        let wanted = indices.filter { suggestions.indices.contains($0) }.map { suggestions[$0] }
        // Bring positions up to date first. That can drop or reorder suggestions, so match them up by their text.
        follow()
        let picked: [Suggestion] = wanted.compactMap { w in
            guard var s = suggestions.filter({ $0.original == w.original && $0.options == w.options })
                .min(by: { abs($0.range.location - w.range.location) < abs($1.range.location - w.range.location) })
            else { return nil }
            s.choice = w.choice
            return s
        }
        guard !picked.isEmpty, let element else { return }
        suggestions.removeAll { s in picked.contains { $0.range == s.range && $0.original == s.original } }
        if let field = lastField { render(field) }
        let edits = picked.map { PlannedEdit(range: $0.range, original: $0.original, replacement: $0.replacement) }
        enqueueEdit { engine in
            let applied = await engine.run(edits, in: element, flash: true)
            if !applied.isEmpty {
                engine.undoStack.append((element, applied))
                if engine.undoStack.count > 10 { engine.undoStack.removeFirst() }
            }
            if applied.count < edits.count {
                NSLog("Typestro: %d of %d suggestions no longer matched the text and were skipped",
                      edits.count - applied.count, edits.count)
            }
            engine.lastChecked = nil
            engine.follow()
        }
    }

    /// Puts back everything the last accept changed.
    func undoLast() {
        guard let last = undoStack.popLast() else { return }
        hideCard()
        enqueueEdit { engine in
            _ = await engine.run(EditPlan.undo(of: last.edits), in: last.element, flash: false)
            engine.lastChecked = nil
            engine.follow()
        }
    }

    private func enqueueEdit(_ edit: @escaping @MainActor (Engine) async -> Void) {
        let previous = editTask
        editTask = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            await edit(self)
            onChange?()
        }
    }

    /// Makes `edits` in apply order with your keys held throughout. Returns the ones that were made.
    private func run(_ edits: [PlannedEdit], in element: AXUIElement, flash: Bool) async -> [PlannedEdit] {
        tap.hold()
        defer { tap.release() }
        var applied: [PlannedEdit] = []
        for edit in EditPlan.applyOrder(edits) {
            guard let field = FocusedField.current(), CFEqual(field.element, element) else { break }
            guard edit.matches(field.text), await field.replace(edit.range, with: edit.replacement, holding: tap) else { continue }
            applied.append(edit)
            if flash, let rect = field.screenRect(for: NSRange(location: edit.range.location,
                                                                length: (edit.replacement as NSString).length)) {
                overlay.flash(rect)
            }
        }
        return applied
    }

    /// Also forgets what was last checked, so the next pause reads the text afresh (after a level change, say).
    func clearSuggestions() {
        lastChecked = nil
        checkTask?.cancel()
        suggestions.removeAll()
        rects.removeAll()
        element = nil
        hideCard()
        overlay.hideUnderlines()
        overlay.hideList()
        watch(false)
        onChange?()
    }

    // MARK: Claude

    private func makeClient() -> ClaudeClient? {
        guard let key = settings.apiKey else {
            lastError = "Add a Claude API key to turn on suggestions"
            onChange?()
            return nil
        }
        return ClaudeClient(apiKey: key, model: settings.model)
    }

    private func clearError() {
        guard lastError != nil else { return }
        lastError = nil
        onChange?()
    }

    private func report(_ error: Error) {
        if error is CancellationError || (error as? URLError)?.code == .cancelled { return }
        lastError = (error as? ClaudeError)?.summary ?? error.localizedDescription
        NSLog("Typestro: %@", String(describing: error))
        onChange?()
    }
}
