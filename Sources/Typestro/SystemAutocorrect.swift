import Foundation

/// macOS's own typing helpers (autocorrect, auto-capitalization, inline predictions), which change
/// words before Typestro sees them, and its red spelling underlines, which would sit on top of Typestro's
/// own. Switched off while Typestro runs, and put back exactly as they were when it stops. Apps already
/// open may keep the old behavior until reopened. Chrome and Electron apps have their own spell-check
/// setting and ignore all of these.
///
/// The spelling-underline keys were checked in a test process: with `NSAllowContinuousSpellChecking`
/// off, a text view can't turn continuous spell-checking on; `WebContinuousSpellCheckingEnabled` is where
/// older WebKit views (Mail's compose window) start out.
@MainActor
enum SystemAutocorrect {
    private static let keys = [
        "NSAutomaticSpellingCorrectionEnabled",
        "WebAutomaticSpellingCorrectionEnabled",
        "NSAutomaticCapitalizationEnabled",
        "NSAutomaticInlinePredictionEnabled",
        // Red spelling underlines: Cocoa text views (Notes, TextEdit, Messages), then WebKit.
        "NSAllowContinuousSpellChecking",
        "WebContinuousSpellCheckingEnabled",
    ]
    private static let capitalizationKey = "NSAutomaticCapitalizationEnabled"
    /// The user's own values, saved before Typestro first changes them. Survives a crash.
    private static let savedKey = "savedSystemAutocorrect"
    private static let unset = "unset"

    private static func read(_ key: String) -> Bool? {
        CFPreferencesCopyValue(key as CFString, kCFPreferencesAnyApplication,
                               kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? Bool
    }

    private static func write(_ key: String, _ value: Bool?) {
        CFPreferencesSetValue(key as CFString, value.map { $0 as CFBoolean }, kCFPreferencesAnyApplication,
                              kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
    }

    private static func sync() {
        CFPreferencesSynchronize(kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
    }

    /// Unset counts as on, which is the macOS default.
    static var anyOn: Bool { keys.contains { read($0) ?? true } }

    /// When the Mac isn't capitalizing, Claude does it.
    static var capitalizationIsOff: Bool { read(capitalizationKey) == false }

    static func turnOff() {
        let defaults = UserDefaults.standard
        // Saved once. A copy saved by an older version lacks newer keys, so those get their originals added
        // now, before they're changed, instead of being reset to the default on restore.
        var saved = defaults.dictionary(forKey: savedKey) ?? [:]
        for key in keys where saved[key] == nil { saved[key] = read(key).map { $0 as Any } ?? unset }
        defaults.set(saved, forKey: savedKey)
        for key in keys { write(key, false) }
        sync()
    }

    static func restore() {
        let defaults = UserDefaults.standard
        guard let saved = defaults.dictionary(forKey: savedKey) else { return }
        for key in keys { write(key, saved[key] as? Bool) }
        sync()
        defaults.removeObject(forKey: savedKey)
    }
}
