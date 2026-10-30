import AVFoundation
import AppKit
import SwiftUI
import TypestroCore

/// Hold a key (or click the mic), talk, let go. OpenAI transcribes the audio, Claude tidies it to fit
/// the text box, and it's typed at the cursor. With no text box focused, the result goes to the clipboard.
@MainActor
final class Dictation: NSObject {
    private enum State {
        case idle
        case recording(started: Date, byHotkey: Bool)
        case writing
    }

    private let settings: Settings
    private let pill = DictationPill()
    private var state = State.idle
    private var recorder: AVAudioRecorder?
    private var meterTimer: Timer?
    var onChange: (() -> Void)?

    private let file = FileManager.default.temporaryDirectory.appendingPathComponent("typestro-dictation.m4a")
    /// Shorter than this, a hotkey press was a tap or the start of an Option-shortcut, not dictation.
    private static let minimumHold: TimeInterval = 0.3

    init(settings: Settings) {
        self.settings = settings
    }

    var isRecording: Bool {
        if case .recording = state { return true }
        return false
    }

    // MARK: Triggers

    /// Hold-to-talk on the chosen right-hand modifier.
    func modifiersChanged(keyCode: Int64, flags: CGEventFlags) {
        let key = settings.dictationKey
        guard settings.enabled, settings.dictationEnabled, keyCode == key.keyCode else { return }
        if flags.contains(key.flag) {
            if case .idle = state { start(byHotkey: true) }
        } else if case .recording(let started, true) = state {
            if Date().timeIntervalSince(started) < Self.minimumHold { cancel() } else { finish() }
        }
    }

    /// Any other key while recording. Esc cancels (and is swallowed). A key pressed early in a hotkey
    /// hold means it was a shortcut like Option-E, so the recording is dropped and the key goes through.
    func handleKey(_ key: KeyTap.Key) -> Bool {
        guard case .recording(let started, let byHotkey) = state else { return false }
        if key.keyCode == KeyCode.escape {
            cancel()
            return true
        }
        if byHotkey, Date().timeIntervalSince(started) < 1 { cancel() }
        return false
    }

    /// The mic button: click to start, click again to finish.
    func toggle() {
        switch state {
        case .idle: start(byHotkey: false)
        case .recording: finish()
        case .writing: break
        }
    }

    // MARK: Recording

    private func start(byHotkey: Bool) {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            break
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { _ in }
            return
        default:
            pill.show(.message("Allow Typestro under Privacy & Security → Microphone"), near: anchor())
            pill.hide(after: 3)
            return
        }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        ]
        guard let recorder = try? AVAudioRecorder(url: file, settings: settings) else { return }
        recorder.isMeteringEnabled = true
        guard recorder.record(forDuration: 300) else { return }
        self.recorder = recorder
        state = .recording(started: Date(), byHotkey: byHotkey)
        onChange?()

        // Show the pill after a beat, so a quick tap of the key doesn't flash it.
        let anchorRect = anchor()
        DispatchQueue.main.asyncAfter(deadline: .now() + (byHotkey ? 0.2 : 0)) { [weak self] in
            guard let self, self.isRecording else { return }
            self.pill.show(.listening, near: anchorRect)
        }
        meterTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let recorder = self?.recorder else { return }
                recorder.updateMeters()
                // Decibels (-160…0) to a 0…1 level that moves with normal speech.
                let level = pow(10, recorder.averagePower(forChannel: 0) / 20)
                self?.pill.level = min(1, Double(level) * 3)
            }
        }
    }

    private func stopRecording() {
        meterTimer?.invalidate()
        meterTimer = nil
        recorder?.stop()
        recorder = nil
    }

    func cancel() {
        stopRecording()
        try? FileManager.default.removeItem(at: file)
        state = .idle
        pill.hide()
        onChange?()
    }

    private func finish() {
        stopRecording()
        state = .writing
        pill.show(.writing, near: anchor())
        onChange?()

        let field = FocusedField.current()
        let caret = field?.selection.location ?? 0
        let before = field.map { $0.text.substring(to: caret) } ?? ""
        let after = field.map { $0.text.substring(from: min(NSMaxRange($0.selection), $0.text.length)) } ?? ""
        let app = field?.appName ?? NSWorkspace.shared.frontmostApplication?.localizedName ?? "an app"
        let element = field?.element

        Task {
            defer {
                try? FileManager.default.removeItem(at: file)
                state = .idle
                onChange?()
            }
            guard let key = settings.openAIKey else {
                pill.show(.message("Add an OpenAI API key in the Typestro menu"), near: anchor())
                pill.hide(after: 3)
                return
            }
            do {
                let transcript = try await Transcriber(apiKey: key)
                    .transcribe(file, prompt: String(before.suffix(600)))
                guard !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    pill.hide()
                    return
                }
                let text = await tidy(transcript, app: app, before: String(before.suffix(800)), after: String(after.prefix(200)))
                deliver(text, to: element, before: before, after: after)
            } catch {
                let message = (error as? TranscriptionError)?.summary ?? (error as? ClaudeError)?.summary ?? error.localizedDescription
                NSLog("Typestro dictation: %@", String(describing: error))
                pill.show(.message(message), near: anchor())
                pill.hide(after: 3)
            }
        }
    }

    /// Claude's cleanup. Without a Claude key, or if it fails, the transcript goes in as it came.
    private func tidy(_ transcript: String, app: String, before: String, after: String) async -> String {
        guard let key = settings.apiKey else { return transcript }
        let client = ClaudeClient(apiKey: key, model: settings.model)
        let result = try? await client.structured(
            DictationResult.self, system: Prompts.dictationSystem,
            user: Prompts.dictationUser(app: app, before: before, after: after, transcript: transcript),
            schema: Prompts.dictationSchema, timeout: 20)
        return result?.text ?? transcript
    }

    private func deliver(_ text: String, to element: AXUIElement?, before: String, after: String) {
        guard !text.isEmpty else {
            pill.hide()
            return
        }
        // Into the same text box, if it still has focus; otherwise onto the clipboard.
        guard let field = FocusedField.current(), let element, CFEqual(field.element, element) else {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            pill.show(.message("Copied. Paste it with ⌘V"), near: anchor())
            pill.hide(after: 2.5)
            return
        }
        var insert = text
        if let last = before.last, !last.isWhitespace, let first = insert.first, !first.isPunctuation { insert = " " + insert }
        if let next = after.first, next.isLetter || next.isNumber { insert += " " }
        pill.hide()
        field.insert(insert)
    }

    /// Where to show the pill: by the cursor, else the text box, else the mouse.
    private func anchor() -> NSRect {
        if let field = FocusedField.current(), let rect = field.caretRect { return rect }
        let mouse = NSEvent.mouseLocation
        return NSRect(x: mouse.x, y: mouse.y, width: 1, height: 1)
    }
}

// MARK: - Pill

/// The small floating "Listening…" / "Writing…" indicator by the cursor.
@MainActor
final class DictationPill: ObservableObject {
    enum Mode: Equatable {
        case listening
        case writing
        case message(String)
    }

    @Published var mode = Mode.listening
    @Published var level = 0.0
    private var panel: NSPanel?
    private var hideWork: DispatchWorkItem?

    func show(_ mode: Mode, near rect: NSRect) {
        hideWork?.cancel()
        self.mode = mode
        level = 0
        let panel = self.panel ?? makePanel()
        self.panel = panel
        let size = (panel.contentView as? NSHostingView<PillView>)?.fittingSize ?? NSSize(width: 140, height: 30)
        var origin = NSPoint(x: rect.minX, y: rect.minY - size.height - 6)
        if let screen = NSScreen.screens.first(where: { $0.frame.intersects(rect) }) ?? NSScreen.main {
            let visible = screen.visibleFrame
            if origin.y < visible.minY { origin.y = rect.maxY + 6 }
            origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - size.width - 8)
        }
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        panel.orderFrontRegardless()
    }

    func hide(after delay: TimeInterval = 0) {
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.panel?.orderOut(nil) }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func makePanel() -> NSPanel {
        let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = .statusBar
        p.ignoresMouseEvents = true
        p.hidesOnDeactivate = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        let host = NSHostingView(rootView: PillView(pill: self))
        host.sizingOptions = [.intrinsicContentSize]
        p.contentView = host
        return p
    }
}

private struct PillView: View {
    @ObservedObject var pill: DictationPill

    var body: some View {
        HStack(spacing: 8) {
            switch pill.mode {
            case .listening:
                Circle().fill(Color.red).frame(width: 8, height: 8)
                Meter(level: pill.level)
                Text("Listening").foregroundStyle(.secondary)
            case .writing:
                ProgressView().controlSize(.small)
                Text("Writing").foregroundStyle(.secondary)
            case .message(let text):
                Image(systemName: "mic.slash").foregroundStyle(.secondary)
                Text(text)
            }
        }
        .font(.system(size: 12, weight: .medium))
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.1)))
        .fixedSize()
    }
}

/// Five bars that move with your voice.
private struct Meter: View {
    let level: Double
    private let weights = [0.5, 0.8, 1.0, 0.8, 0.5]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(weights.indices, id: \.self) { i in
                Capsule()
                    .fill(Color.primary.opacity(0.7))
                    .frame(width: 3, height: 4 + 12 * level * weights[i])
            }
        }
        .frame(height: 16)
        .animation(.easeOut(duration: 0.08), value: level)
    }
}

// MARK: - Mic button

/// An optional mic button inside the right edge of whichever text box has focus.
/// It takes clicks without pulling focus away from the app you're typing in.
@MainActor
final class MicButton {
    private let settings: Settings
    private let dictation: Dictation
    private var panel: NSPanel?
    private var timer: Timer?

    init(settings: Settings, dictation: Dictation) {
        self.settings = settings
        self.dictation = dictation
    }

    /// Starts or stops following the focused text box, to match the setting.
    func update() {
        if settings.showMicButton, timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.follow() }
            }
            follow()
        } else if !settings.showMicButton {
            timer?.invalidate()
            timer = nil
            panel?.orderOut(nil)
        }
    }

    private func follow() {
        guard settings.enabled, settings.dictationEnabled,
              let field = FocusedField.current(), !settings.isExcluded(field.bundleID),
              let frame = field.frame, frame.width > 60 else {
            panel?.orderOut(nil)
            return
        }
        let size: CGFloat = 24
        // Bottom-right corner of big boxes, centered on the right of single-line ones.
        let y = frame.height < 44 ? frame.midY - size / 2 : frame.minY + 6
        let rect = NSRect(x: frame.maxX - size - 6, y: y, width: size, height: size)
        let panel = self.panel ?? makePanel()
        self.panel = panel
        (panel.contentView as? MicButtonView)?.recording = dictation.isRecording
        panel.setFrame(rect, display: true)
        panel.orderFrontRegardless()
    }

    private func makePanel() -> NSPanel {
        let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.level = .statusBar
        p.hidesOnDeactivate = false
        p.becomesKeyOnlyIfNeeded = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        let view = MicButtonView()
        view.onClick = { [weak self] in self?.dictation.toggle() }
        p.contentView = view
        return p
    }
}

private final class MicButtonView: NSView {
    var onClick: (() -> Void)?
    var recording = false { didSet { if recording != oldValue { needsDisplay = true } } }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        onClick?()
    }

    override func draw(_ dirtyRect: NSRect) {
        let circle = NSBezierPath(ovalIn: bounds.insetBy(dx: 1, dy: 1))
        (recording ? NSColor.systemRed : NSColor.windowBackgroundColor.withAlphaComponent(0.9)).setFill()
        circle.fill()
        NSColor.separatorColor.setStroke()
        circle.stroke()
        let config = NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
        guard let symbol = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: "Dictate")?
            .withSymbolConfiguration(config) else { return }
        let tinted = NSImage(size: symbol.size, flipped: false) { rect in
            symbol.draw(in: rect)
            (self.recording ? NSColor.white : NSColor.secondaryLabelColor).set()
            rect.fill(using: .sourceAtop)
            return true
        }
        let origin = NSPoint(x: bounds.midX - symbol.size.width / 2, y: bounds.midY - symbol.size.height / 2)
        tinted.draw(at: origin, from: .zero, operation: .sourceOver, fraction: 1)
    }
}
