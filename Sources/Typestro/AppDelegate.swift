import AppKit
import TypestroCore
import ServiceManagement

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let settings = Settings()
    private lazy var engine = Engine(settings: settings)
    private lazy var dictation = Dictation(settings: settings)
    private lazy var micButton = MicButton(settings: settings, dictation: dictation)
    private let telemetry = Telemetry()
    private let tap = KeyTap()
    private var statusItem: NSStatusItem!
    private var permissionTimer: Timer?
    /// The app you were in when the menu opened (the menu itself doesn't take focus).
    private var menuTargetApp: NSRunningApplication?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        engine.onChange = { [weak self] in self?.updateButton() }
        dictation.onChange = { [weak self] in self?.updateButton() }
        tap.handler = { [weak self] key in
            MainActor.assumeIsolated {
                guard let self else { return false }
                if self.dictation.handleKey(key) { return true }
                return self.engine.handleKey(key)
            }
        }
        tap.modifierHandler = { [weak self] keyCode, flags in
            MainActor.assumeIsolated { self?.dictation.modifiersChanged(keyCode: keyCode, flags: flags) }
        }
        micButton.update()
        installEditMenu()
        telemetry.onChange = { [weak self] in self?.updateButton() }
        telemetry.start()
        updateButton()
        if settings.handlesAutocorrect, settings.enabled { SystemAutocorrect.turnOff() }
        // The key tap waits for this, so it can't be in the way if macOS asks for your keychain password.
        settings.loadKeys { [weak self] in
            guard let self else { return }
            startWhenPermitted(prompt: true)
            updateButton()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                guard let self else { return }
                if settings.apiKey == nil { askForAPIKey() }
                offerAutocorrectTakeover()
            }
        }
    }

    /// A menu-bar-only app has no menu bar of its own, and without an Edit menu ⌘V, ⌘C and ⌘A do nothing
    /// in its text fields (like the API key prompts). This menu is never shown; it just carries the shortcuts.
    private func installEditMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        appItem.submenu = NSMenu()
        main.addItem(appItem)

        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let editItem = NSMenuItem()
        editItem.submenu = edit
        main.addItem(editItem)

        NSApp.mainMenu = main
    }

    func applicationWillTerminate(_ notification: Notification) {
        if settings.handlesAutocorrect { SystemAutocorrect.restore() }
    }

    // MARK: macOS autocorrect

    /// Asked once, and only if macOS autocorrect is actually on.
    private func offerAutocorrectTakeover() {
        guard !settings.askedAboutAutocorrect, SystemAutocorrect.anyOn else { return }
        settings.askedAboutAutocorrect = true
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Let Typestro handle autocorrect?"
        alert.informativeText = """
        macOS's own autocorrect, capitalization and predictive text change words before Typestro sees them, \
        and they don't read the sentence. Typestro can switch them off while it's running and put them back \
        exactly as they were when you pause or quit it. Apps that are already open may need to be reopened.
        """
        alert.addButton(withTitle: "Turn Them Off")
        alert.addButton(withTitle: "Keep macOS Autocorrect")
        if alert.runModal() == .alertFirstButtonReturn { setHandlesAutocorrect(true) }
    }

    private func setHandlesAutocorrect(_ on: Bool) {
        settings.handlesAutocorrect = on
        if on, settings.enabled {
            SystemAutocorrect.turnOff()
        } else {
            SystemAutocorrect.restore()
        }
    }

    // MARK: Permission

    private var isTrusted: Bool { AXIsProcessTrusted() }

    /// The key tap needs Accessibility permission; keep checking until it's granted.
    private func startWhenPermitted(prompt: Bool) {
        let options = ["AXTrustedCheckOptionPrompt": prompt] as CFDictionary
        if AXIsProcessTrustedWithOptions(options), tap.start() {
            permissionTimer?.invalidate()
            permissionTimer = nil
            updateButton()
            return
        }
        guard permissionTimer == nil else { return }
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.startWhenPermitted(prompt: false) }
        }
    }

    // MARK: Menu bar

    private func updateButton() {
        guard let button = statusItem?.button else { return }
        let ready = settings.enabled && tap.isRunning
        let symbol = dictation.isRecording ? "mic.fill" : (ready ? "sparkles" : "moon.zzz")
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Typestro")
        button.imagePosition = .imageLeading
        let count = engine.suggestions.count
        button.title = count > 0 ? " \(count)" : ""
        button.appearsDisabled = !ready
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menuTargetApp = NSWorkspace.shared.frontmostApplication
        menu.removeAllItems()

        if let update = telemetry.update {
            menu.addItem(item("Typestro \(update.version) Is Available. Download…", #selector(openUpdate)))
            menu.addItem(.separator())
        }
        menu.addItem(disabled(statusLine()))
        if let error = engine.lastError { menu.addItem(disabled(error)) }
        menu.addItem(.separator())

        menu.addItem(item(settings.enabled ? "Pause Typestro" : "Turn Typestro On", #selector(toggleEnabled)))

        let intensity = NSMenu()
        for level in Intensity.allCases {
            let i = item(level.title, #selector(setIntensity(_:)))
            i.representedObject = level.rawValue
            i.state = settings.intensity == level ? .on : .off
            intensity.addItem(i)
        }
        menu.addItem(submenu("Suggestions", intensity))

        let takeover = item("Let Typestro Handle Autocorrect", #selector(toggleAutocorrectTakeover))
        takeover.state = settings.handlesAutocorrect ? .on : .off
        takeover.toolTip = "Turns off macOS's own autocorrect, capitalization and predictive text while Typestro runs"
        menu.addItem(takeover)

        let fixes = NSMenu()
        if engine.recentFixes.isEmpty {
            fixes.addItem(disabled("No fixes yet"))
        } else {
            for (index, fix) in engine.recentFixes.enumerated() {
                let i = item("\(fix.original) → \(fix.replacement)", #selector(undoFix(_:)))
                i.tag = index
                i.toolTip = "Undo this fix and stop changing \"\(fix.original)\""
                fixes.addItem(i)
            }
            fixes.addItem(.separator())
            fixes.addItem(disabled("Click one to undo it. ⌃⌥Z undoes the latest."))
        }
        menu.addItem(submenu("Recent Fixes", fixes))

        if let app = menuTargetApp, let id = app.bundleIdentifier, id != Bundle.main.bundleIdentifier {
            let name = app.localizedName ?? id
            let off = settings.excluded.contains(id)
            menu.addItem(item(off ? "Turn On in \(name)" : "Turn Off in \(name)", #selector(toggleCurrentApp)))
        }

        menu.addItem(.separator())

        let models = NSMenu()
        for model in Settings.models {
            let i = item(model.title, #selector(setModel(_:)))
            i.representedObject = model.id
            i.state = settings.model == model.id ? .on : .off
            models.addItem(i)
        }
        menu.addItem(submenu("Claude Model", models))
        let noClaudeKey = settings.keysLoaded && settings.apiKey == nil
        menu.addItem(item(noClaudeKey ? "Add Claude API Key…" : "Change Claude API Key…", #selector(askForAPIKey)))

        menu.addItem(.separator())
        menu.addItem(submenu("Dictation", dictationMenu()))

        let login = item("Open at Login", #selector(toggleLogin))
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        menu.addItem(item("Forget Learned Preferences", #selector(forgetLearning)))
        let stats = item("Send Anonymous Usage Stats", #selector(toggleStats))
        stats.state = telemetry.isEnabled ? .on : .off
        stats.toolTip = "A daily ping with a random ID, the app and macOS versions, and your region. Never what you type or say."
        menu.addItem(stats)

        if !isTrusted {
            menu.addItem(.separator())
            menu.addItem(item("Grant Accessibility Permission…", #selector(openAccessibilitySettings)))
        }

        menu.addItem(.separator())
        menu.addItem(item("Send Feedback…", #selector(sendFeedback)))
        menu.addItem(item("Typestro Website", #selector(openWebsite)))
        menu.addItem(item("Buy Me a Coffee", #selector(openCoffee)))
        menu.addItem(disabled("Version \(AppInfo.version)"))
        menu.addItem(item("Quit Typestro", #selector(quit), key: "q"))
    }

    @objc private func toggleStats() {
        telemetry.isEnabled.toggle()
    }

    @objc private func sendFeedback() {
        NSWorkspace.shared.open(Links.feedbackMailto)
    }

    @objc private func openWebsite() {
        NSWorkspace.shared.open(Links.appPage)
    }

    @objc private func openCoffee() {
        NSWorkspace.shared.open(Links.coffee)
    }

    @objc private func openUpdate() {
        NSWorkspace.shared.open(telemetry.update?.downloadURL ?? Links.appPage)
    }

    private func dictationMenu() -> NSMenu {
        let menu = NSMenu()
        let key = settings.dictationKey
        let on = item("Hold \(key.title) to Dictate", #selector(toggleDictation))
        on.state = settings.dictationEnabled ? .on : .off
        menu.addItem(on)

        let keys = NSMenu()
        for option in Settings.DictationKey.allCases {
            let i = item(option.title, #selector(setDictationKey(_:)))
            i.representedObject = option.rawValue
            i.state = option == key ? .on : .off
            keys.addItem(i)
        }
        menu.addItem(submenu("Hotkey", keys))

        let button = item("Show Mic Button in Text Boxes", #selector(toggleMicButton))
        button.state = settings.showMicButton ? .on : .off
        menu.addItem(button)

        menu.addItem(.separator())
        let noOpenAIKey = settings.keysLoaded && settings.openAIKey == nil
        menu.addItem(item(noOpenAIKey ? "Add OpenAI API Key…" : "Change OpenAI API Key…", #selector(askForOpenAIKey)))
        if noOpenAIKey {
            menu.addItem(disabled("Dictation needs an OpenAI key"))
        }
        return menu
    }

    @objc private func toggleDictation() {
        settings.dictationEnabled.toggle()
        micButton.update()
    }

    @objc private func setDictationKey(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let key = Settings.DictationKey(rawValue: raw) else { return }
        settings.dictationKey = key
    }

    @objc private func toggleMicButton() {
        settings.showMicButton.toggle()
        micButton.update()
    }

    @objc private func askForOpenAIKey() {
        guard let key = promptForKey(
            title: "OpenAI API key",
            info: "Dictation sends your recording to OpenAI to turn it into text. Get a key at platform.openai.com. It's stored in your keychain.",
            placeholder: "sk-…") else { return }
        settings.setOpenAIKey(key) { [weak self] saved in
            if !saved { self?.showKeychainError() }
        }
    }

    private func promptForKey(title: String, info: String, placeholder: String) -> String? {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = info
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.placeholderString = placeholder
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let key = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return key.isEmpty ? nil : key
    }

    private func showKeychainError() {
        let failed = NSAlert()
        failed.messageText = "Couldn't save the key to your keychain."
        failed.runModal()
    }

    private func statusLine() -> String {
        if !settings.keysLoaded { return "Waiting for your keychain" }
        if !isTrusted { return "Needs Accessibility permission" }
        if !settings.enabled { return "Paused" }
        if settings.apiKey == nil { return "Fixing typos only (no API key)" }
        return "Watching as you type"
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.target = self
        return i
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        i.isEnabled = false
        return i
    }

    private func submenu(_ title: String, _ menu: NSMenu) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        i.submenu = menu
        return i
    }

    // MARK: Actions

    @objc private func toggleEnabled() {
        settings.enabled.toggle()
        if !settings.enabled { engine.clearSuggestions() }
        // While paused, macOS gets its own autocorrect back.
        if settings.handlesAutocorrect {
            if settings.enabled { SystemAutocorrect.turnOff() } else { SystemAutocorrect.restore() }
        }
        updateButton()
    }

    @objc private func toggleAutocorrectTakeover() {
        settings.askedAboutAutocorrect = true
        setHandlesAutocorrect(!settings.handlesAutocorrect)
    }

    @objc private func setIntensity(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let level = Intensity(rawValue: raw) else { return }
        settings.intensity = level
        if level == .light { engine.clearSuggestions() }
    }

    @objc private func setModel(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        settings.model = id
    }

    @objc private func undoFix(_ sender: NSMenuItem) {
        guard engine.recentFixes.indices.contains(sender.tag) else { return }
        engine.undo(engine.recentFixes[sender.tag])
    }

    @objc private func toggleCurrentApp() {
        guard let id = menuTargetApp?.bundleIdentifier else { return }
        settings.toggleExcluded(id)
        engine.clearSuggestions()
    }

    @objc private func askForAPIKey() {
        guard let key = promptForKey(
            title: "Claude API key",
            info: """
            Typestro sends the sentence you're typing to Claude, which fixes spelling and wrong words by context \
            and suggests improvements when you pause. Get a key at platform.claude.com. It's stored in your keychain.
            """,
            placeholder: "sk-ant-…") else { return }
        settings.setAPIKey(key) { [weak self] saved in
            if !saved { self?.showKeychainError() }
            self?.updateButton()
        }
    }

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            NSLog("Typestro: login item: %@", String(describing: error))
        }
    }

    @objc private func forgetLearning() {
        settings.forgetLearning()
    }

    @objc private func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
