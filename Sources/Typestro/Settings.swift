import CoreGraphics
import Foundation
import TypestroCore

@MainActor
final class Settings {
    private let defaults = UserDefaults.standard

    static let models: [(id: String, title: String)] = [
        ("claude-opus-5-5", "Claude Opus 5.5 (smartest)"),
        ("claude-sonnet-5-5", "Claude Sonnet 5.5"),
        ("claude-haiku-5-5", "Claude Haiku 5.5 (fastest)"),
    ]

    /// Places where rewriting what you type does more harm than good: terminals, code editors, password managers.
    static let defaultExcluded: Set<String> = [
        "com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.Warp-Stable", "com.mitchellh.ghostty",
        "com.apple.dt.Xcode", "com.microsoft.VSCode", "com.todesktop.230313mzl4w4u92", "com.sublimetext.4",
        "com.1password.1password", "com.apple.keychainaccess", "com.apple.Passwords",
    ]

    var enabled: Bool {
        get { defaults.object(forKey: "enabled") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "enabled") }
    }

    var intensity: Intensity {
        get { Intensity(rawValue: defaults.string(forKey: "intensity") ?? "") ?? .medium }
        set { defaults.set(newValue.rawValue, forKey: "intensity") }
    }

    var model: String {
        get { defaults.string(forKey: "model") ?? "claude-haiku-5-5" }
        set { defaults.set(newValue, forKey: "model") }
    }

    /// Whether Typestro switches off macOS's own autocorrect while it runs.
    var handlesAutocorrect: Bool {
        get { defaults.bool(forKey: "handlesAutocorrect") }
        set { defaults.set(newValue, forKey: "handlesAutocorrect") }
    }

    var askedAboutAutocorrect: Bool {
        get { defaults.bool(forKey: "askedAboutAutocorrect") }
        set { defaults.set(newValue, forKey: "askedAboutAutocorrect") }
    }

    // MARK: Dictation

    /// The modifier key you hold to dictate. Right-hand ones, so the left ones stay free for shortcuts.
    enum DictationKey: String, CaseIterable {
        case rightOption, rightCommand, rightControl

        var keyCode: Int64 {
            switch self {
            case .rightOption: 61
            case .rightCommand: 54
            case .rightControl: 62
            }
        }

        var flag: CGEventFlags {
            switch self {
            case .rightOption: .maskAlternate
            case .rightCommand: .maskCommand
            case .rightControl: .maskControl
            }
        }

        var title: String {
            switch self {
            case .rightOption: "Right Option"
            case .rightCommand: "Right Command"
            case .rightControl: "Right Control"
            }
        }
    }

    var dictationEnabled: Bool {
        get { defaults.object(forKey: "dictationEnabled") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "dictationEnabled") }
    }

    var dictationKey: DictationKey {
        get { DictationKey(rawValue: defaults.string(forKey: "dictationKey") ?? "") ?? .rightOption }
        set { defaults.set(newValue.rawValue, forKey: "dictationKey") }
    }

    var showMicButton: Bool {
        get { defaults.bool(forKey: "showMicButton") }
        set { defaults.set(newValue, forKey: "showMicButton") }
    }

    var openAIKey: String? {
        keys.key(Keychain.openAI) ?? ProcessInfo.processInfo.environment["OPENAI_API_KEY"]
    }

    func setOpenAIKey(_ key: String, completion: @escaping @MainActor @Sendable (Bool) -> Void) {
        keys.save(key, Keychain.openAI, completion: completion)
    }

    // MARK: Apps

    var excluded: Set<String> {
        get { Set(defaults.stringArray(forKey: "excluded") ?? Array(Self.defaultExcluded)) }
        set { defaults.set(newValue.sorted(), forKey: "excluded") }
    }

    func isExcluded(_ bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        return bundleID == Bundle.main.bundleIdentifier || excluded.contains(bundleID)
    }

    func toggleExcluded(_ bundleID: String) {
        var set = excluded
        if set.contains(bundleID) { set.remove(bundleID) } else { set.insert(bundleID) }
        excluded = set
    }

    // MARK: What Typestro has learned

    /// Words you undid a fix for. Typestro leaves them alone from then on.
    private var ignoredWords: Set<String> {
        get { Set(defaults.stringArray(forKey: "ignoredWords") ?? []) }
        set { defaults.set(newValue.sorted(), forKey: "ignoredWords") }
    }

    func isIgnored(_ word: String) -> Bool { ignoredWords.contains(word.lowercased()) }

    func ignore(_ word: String) { ignoredWords.insert(word.lowercased()) }

    /// Suggestions you dismissed, most recent first. Sent to Claude so it learns what you don't want.
    var dismissals: [String] { defaults.stringArray(forKey: "dismissals") ?? [] }

    private static func dismissalKey(_ original: String, _ replacement: String) -> String {
        "\"\(original)\" → \"\(replacement)\""
    }

    func recordDismissal(original: String, replacement: String) {
        let key = Self.dismissalKey(original, replacement)
        let list = [key] + dismissals.filter { $0 != key }
        defaults.set(Array(list.prefix(25)), forKey: "dismissals")
    }

    func wasDismissed(original: String, replacement: String) -> Bool {
        dismissals.contains(Self.dismissalKey(original, replacement))
    }

    func forgetLearning() {
        defaults.removeObject(forKey: "ignoredWords")
        defaults.removeObject(forKey: "dismissals")
    }

    // MARK: API key

    /// The keychain can stop and show a password prompt, so it's never touched on this (the main) thread.
    private let keys = KeyStore()

    var keysLoaded: Bool { keys.isLoaded }

    /// Reads both keys once, in the background. They're empty until `completion` runs.
    func loadKeys(completion: @escaping @MainActor @Sendable () -> Void) {
        keys.load([Keychain.anthropic, Keychain.openAI], completion: completion)
    }

    var apiKey: String? {
        keys.key(Keychain.anthropic) ?? ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"]
    }

    func setAPIKey(_ key: String, completion: @escaping @MainActor @Sendable (Bool) -> Void) {
        keys.save(key, Keychain.anthropic, completion: completion)
    }
}
