import AppKit
import TypestroCore

struct Fix {
    let original: String
    let replacement: String
    let location: Int
    let element: AXUIElement
}

struct Suggestion {
    let original: String
    let replacement: String
    let reason: String
    /// From the pause review (replaced on each new review), as opposed to an unsure spelling fix.
    let fromReview: Bool
    var range: NSRange
}

/// Decides what to fix and suggest, and when.
///
/// - Silent fixes: every time you finish a word, Claude reads the sentence you're in (and the one
///   before, for context) and fixes words that are misspelled or clearly not the word you meant.
///   One check runs at a time; if you typed more meanwhile, the next one starts with the newer text.
///   Fixes Claude is certain of are applied in place; unsure ones are underlined.
/// - Suggestions: when you pause, Claude reads the whole field and may underline a few spots.
///   Tab shows the closest one, Tab again accepts, Esc dismisses.
@MainActor
final class Engine {
    private let settings: Settings
    private let overlay = Overlay()

    private(set) var recentFixes: [Fix] = []
    private(set) var suggestions: [Suggestion] = []
    private(set) var lastError: String?
    var onChange: (() -> Void)?

    private var suggestionElement: AXUIElement?
    private var cardIndex: Int?
    private var pauseTimer: Timer?
    private var followTimer: Timer?
    private var followPending = false
    private var lastReviewedText: String?
    private var reviewTask: Task<Void, Never>?
    private var lastKeyTime = Date.distantPast
    private var checkPauseTimer: Timer?
    private var lastChecked: String?
    private var checkInFlight = false
    /// A check asked for while another was running; true if it should include the word at the cursor.
    private var queuedCheck: Bool?

    private static let boundaries: Set<Character> = [" ", ",", ".", "!", "?", ";", ":", ")", "\"", "”", "\r", "\n"]
    private static let checkPauseDelay: TimeInterval = 0.7
    private static let pauseDelay: TimeInterval = 1.5

    init(settings: Settings) {
        self.settings = settings
    }

    // MARK: Keys

    /// Called for every key press before it reaches the app. Returns true to swallow the key.
    func handleKey(_ key: KeyTap.Key) -> Bool {
        guard settings.enabled, !settings.isExcluded(NSWorkspace.shared.frontmostApplication?.bundleIdentifier) else {
            if !suggestions.isEmpty { clearSuggestions() }
            return false
        }
        lastKeyTime = Date()
        if let index = cardIndex {
            if key.keyCode == KeyCode.tab, key.isPlain { accept(index); return true }
            if key.keyCode == KeyCode.escape { dismiss(index); return true }
            hideCard()
        } else if key.keyCode == KeyCode.tab, key.isPlain, !suggestions.isEmpty, showCard() {
            return true
        }
        if key.keyCode == KeyCode.z, key.flags.contains(.maskControl), key.flags.contains(.maskAlternate) {
            undoLastFix()
            return true
        }
        scheduleFollow()
        guard !key.flags.contains(.maskCommand), !key.flags.contains(.maskControl) else { return false }
        restartPauseTimer()
        if let c = key.characters.last, Self.boundaries.contains(c) {
            // Let the keystroke land in the app before reading the field.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                self?.requestCheck(includingWordAtCursor: false)
            }
        }
        return false
    }

    // MARK: Silent fixes

    /// Runs `edit` once there's a short gap in typing, so a keystroke already on its way to the app
    /// can't land in the middle of the edit. Gives up after about three seconds of nonstop typing.
    private func whenTypingPauses(_ edit: @escaping () -> Void, attempts: Int = 60) {
        if Date().timeIntervalSince(lastKeyTime) >= 0.08 {
            edit()
        } else if attempts > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                self?.whenTypingPauses(edit, attempts: attempts - 1)
            }
        }
    }

    /// Asks Claude to check what you just typed: the sentence you're in and the one before it.
    /// After a finished word the word you're starting is left out; after a pause it's included,
    /// so the end of a message with no period still gets checked.
    private func requestCheck(includingWordAtCursor: Bool) {
        if checkInFlight {
            queuedCheck = (queuedCheck ?? false) || includingWordAtCursor
            return
        }
        guard settings.enabled, let field = FocusedField.current(), field.selection.length == 0,
              !settings.isExcluded(field.bundleID) else { return }
        let caret = field.selection.location
        let end = includingWordAtCursor ? caret : TextTools.startOfWordInProgress(in: field.text, caret: caret)
        let current = TextTools.sentenceRange(in: field.text, endingAt: end)
        let previous = TextTools.sentenceRange(in: field.text, endingAt: current.location)
        let focus = NSRange(location: previous.location, length: end - previous.location)
        let text = field.text.substring(with: focus)
        guard TextTools.wordCount(text) >= 2, text != lastChecked, let client = makeClient() else { return }
        lastChecked = text

        let earlierStart = max(0, focus.location - 600)
        let earlier = field.text.substring(with: NSRange(location: earlierStart, length: focus.location - earlierStart))
        let system = Prompts.spellingSystem(fixCapitals: SystemAutocorrect.capitalizationIsOff)
        let user = Prompts.spellingUser(app: field.appName, earlier: earlier, focus: text)
        let element = field.element
        checkInFlight = true
        Task {
            defer {
                checkInFlight = false
                if let next = queuedCheck {
                    queuedCheck = nil
                    requestCheck(includingWordAtCursor: next)
                }
            }
            do {
                let result = try await client.structured(
                    SpellingResult.self, system: system, user: user,
                    schema: Prompts.spellingSchema, timeout: 12)
                var unsure: [(String, String, String)] = []
                for c in result.corrections {
                    let original = Prompts.stripMarks(c.original)
                    guard !original.isEmpty, original != c.replacement, !settings.isIgnored(original) else { continue }
                    if c.certain {
                        whenTypingPauses { [weak self] in
                            self?.apply(original: original, replacement: c.replacement, in: element, near: focus.location)
                        }
                    } else {
                        unsure.append((original, c.replacement, "Did you mean this?"))
                    }
                }
                if !unsure.isEmpty { addSuggestions(unsure, fromReview: false, element: element, near: focus.location) }
                clearError()
            } catch {
                report(error)
            }
        }
    }

    /// Fixes `original` behind the cursor, near where it was seen, and flashes the fixed word.
    /// A word you've since kept typing into no longer matches as a whole word, so it's left alone.
    @discardableResult
    private func apply(original: String, replacement: String, in element: AXUIElement, near hint: Int) -> Bool {
        guard let field = FocusedField.current(), CFEqual(field.element, element) else { return false }
        let caret = field.selection.location
        let lo = max(0, hint - 40)
        guard caret > lo,
              let range = TextTools.locate(original, in: field.text, near: hint,
                                           within: NSRange(location: lo, length: caret - lo)) else { return false }
        let fixed = TextTools.matchCase(of: original, to: replacement)
        guard field.replace(range, with: fixed) else { return false }
        if let rect = field.screenRect(for: NSRange(location: range.location, length: (fixed as NSString).length)) {
            overlay.flash(rect)
        }
        recentFixes.insert(Fix(original: original, replacement: fixed, location: range.location, element: element), at: 0)
        if recentFixes.count > 15 { recentFixes.removeLast() }
        onChange?()
        return true
    }

    func undoLastFix() {
        if let fix = recentFixes.first { undo(fix) }
    }

    /// Puts back what was typed, and stops fixing that word from now on.
    func undo(_ fix: Fix) {
        recentFixes.removeAll { $0.location == fix.location && $0.replacement == fix.replacement }
        settings.ignore(fix.original)
        defer { onChange?() }
        guard let field = FocusedField.current(), CFEqual(field.element, fix.element),
              let range = TextTools.locate(fix.replacement, in: field.text, near: fix.location, within: nil) else { return }
        _ = field.replace(range, with: fix.original)
    }

    // MARK: Suggestions

    private func restartPauseTimer() {
        checkPauseTimer?.invalidate()
        checkPauseTimer = Timer.scheduledTimer(withTimeInterval: Self.checkPauseDelay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.requestCheck(includingWordAtCursor: true) }
        }
        pauseTimer?.invalidate()
        guard settings.intensity != .light else { return }
        pauseTimer = Timer.scheduledTimer(withTimeInterval: Self.pauseDelay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.review() }
        }
    }

    private func review() {
        guard settings.enabled, settings.intensity != .light,
              let field = FocusedField.current(), !settings.isExcluded(field.bundleID) else { return }
        let full = field.text as String
        guard TextTools.wordCount(full) >= 8, full != lastReviewedText, let client = makeClient() else { return }
        lastReviewedText = full

        let caret = min(field.selection.location, field.text.length)
        let window = TextTools.window(in: field.text, around: caret, radius: 3000)
        let slice = field.text.substring(with: window) as NSString
        let marked = slice.replacingCharacters(in: NSRange(location: caret - window.location, length: 0), with: Prompts.cursor)
        let system = Prompts.suggestionSystem(intensity: settings.intensity, avoid: settings.dismissals)
        let user = Prompts.suggestionUser(app: field.appName, text: marked)
        let element = field.element

        reviewTask?.cancel()
        reviewTask = Task {
            do {
                let result = try await client.structured(
                    SuggestionResult.self, system: system, user: user,
                    schema: Prompts.suggestionSchema, timeout: 25)
                guard !Task.isCancelled else { return }
                let items = result.suggestions
                    .filter { !$0.original.contains(Prompts.flagOpen) && $0.original != $0.replacement }
                    .filter { !settings.wasDismissed(original: $0.original, replacement: $0.replacement) }
                    .map { ($0.original, $0.replacement, $0.reason) }
                addSuggestions(items, fromReview: true, element: element, near: caret)
                clearError()
            } catch {
                report(error)
            }
        }
    }

    private func addSuggestions(_ items: [(String, String, String)], fromReview: Bool, element: AXUIElement, near hint: Int) {
        guard let field = FocusedField.current(), CFEqual(field.element, element) else { return }
        if let current = suggestionElement, !CFEqual(current, element) { suggestions.removeAll() }
        if fromReview { suggestions.removeAll { $0.fromReview } }
        hideCard()
        suggestionElement = element
        for (original, replacement, reason) in items {
            guard let range = TextTools.locate(original, in: field.text, near: hint, within: nil),
                  !suggestions.contains(where: { NSIntersectionRange($0.range, range).length > 0 }) else { continue }
            suggestions.append(Suggestion(original: original, replacement: replacement, reason: reason,
                                          fromReview: fromReview, range: range))
        }
        render(field)
    }

    private func render(_ field: FocusedField) {
        overlay.showUnderlines(suggestions.flatMap { field.lineRects(for: $0.range) })
        if suggestions.isEmpty {
            followTimer?.invalidate()
            followTimer = nil
        } else if followTimer == nil {
            // Keep underlines on their words while the text scrolls or reflows.
            followTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.follow() }
            }
        }
        onChange?()
    }

    private func scheduleFollow() {
        guard !suggestions.isEmpty, !followPending else { return }
        followPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            self?.followPending = false
            self?.follow()
        }
    }

    /// Re-finds each suggestion's text after edits; drops the ones whose text is gone.
    private func follow() {
        guard let field = FocusedField.current(), let element = suggestionElement, CFEqual(field.element, element) else {
            overlay.hideUnderlines()
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

    private func showCard() -> Bool {
        guard let field = FocusedField.current(), let element = suggestionElement, CFEqual(field.element, element) else { return false }
        let caret = field.selection.location
        guard let index = suggestions.indices.min(by: {
            abs(NSMaxRange(suggestions[$0].range) - caret) < abs(NSMaxRange(suggestions[$1].range) - caret)
        }), let rect = field.screenRect(for: suggestions[index].range) else { return false }
        cardIndex = index
        overlay.showCard(for: suggestions[index], below: rect)
        return true
    }

    private func hideCard() {
        cardIndex = nil
        overlay.hideCard()
    }

    private func accept(_ index: Int) {
        hideCard()
        guard suggestions.indices.contains(index), let field = FocusedField.current() else { return }
        let s = suggestions.remove(at: index)
        if let range = TextTools.locate(s.original, in: field.text, near: s.range.location, within: nil),
           field.replace(range, with: s.replacement),
           let rect = field.screenRect(for: NSRange(location: range.location, length: (s.replacement as NSString).length)) {
            overlay.flash(rect)
        }
        follow()
    }

    private func dismiss(_ index: Int) {
        hideCard()
        guard suggestions.indices.contains(index) else { return }
        let s = suggestions.remove(at: index)
        if s.fromReview {
            settings.recordDismissal(original: s.original, replacement: s.replacement)
        } else {
            settings.ignore(s.original)
        }
        follow()
    }

    func clearSuggestions() {
        suggestions.removeAll()
        suggestionElement = nil
        hideCard()
        overlay.hideUnderlines()
        followTimer?.invalidate()
        followTimer = nil
        onChange?()
    }

    // MARK: Claude

    private func makeClient() -> ClaudeClient? {
        guard let key = settings.apiKey else {
            lastError = "Add a Claude API key to turn on AI fixes"
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
