import AppKit
import SwiftUI
import TypestroCore

/// Small windows drawn over other apps: underlines under suggestions, the flash on an accepted change,
/// the preview card, and the list used where an app won't say where its words are.
@MainActor
final class Overlay {
    private var underlines: [NSPanel] = []
    private var card: NSPanel?
    private var list: NSPanel?

    private static func panel(_ frame: NSRect) -> NSPanel {
        let p = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.level = .statusBar
        p.ignoresMouseEvents = true
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        return p
    }

    /// A soft highlight behind a word that was just fixed, fading out.
    func flash(_ rect: NSRect) {
        let p = Self.panel(rect.insetBy(dx: -3, dy: -1))
        let view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.28).cgColor
        view.layer?.cornerRadius = 4
        p.contentView = view
        p.orderFrontRegardless()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.7
                p.animator().alphaValue = 0
            }, completionHandler: {
                p.orderOut(nil)
            })
        }
    }

    func showUnderlines(_ marks: [(rect: NSRect, kind: SuggestionKind)]) {
        while underlines.count < marks.count {
            let p = Self.panel(.zero)
            p.contentView = UnderlineView()
            underlines.append(p)
        }
        for (i, p) in underlines.enumerated() {
            guard i < marks.count else { p.orderOut(nil); continue }
            let r = marks[i].rect
            (p.contentView as? UnderlineView)?.kind = marks[i].kind
            p.setFrame(NSRect(x: r.minX, y: r.minY - 4, width: max(r.width, 6), height: 5), display: true)
            p.orderFrontRegardless()
        }
    }

    func hideUnderlines() {
        underlines.forEach { $0.orderOut(nil) }
    }

    // MARK: Card and list

    /// Takes clicks without pulling focus away from the app you're typing in.
    private static func interactivePanel(_ frame: NSRect) -> NSPanel {
        let p = panel(frame)
        p.ignoresMouseEvents = false
        p.becomesKeyOnlyIfNeeded = true
        p.hasShadow = true
        return p
    }

    private static func place(_ size: NSSize, below rect: NSRect) -> NSRect {
        var origin = NSPoint(x: rect.minX, y: rect.minY - size.height - 8)
        if let screen = NSScreen.screens.first(where: { $0.frame.intersects(rect) }) ?? NSScreen.main {
            let visible = screen.visibleFrame
            if origin.y < visible.minY { origin.y = rect.maxY + 8 }
            origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - size.width - 8)
        }
        return NSRect(origin: origin, size: size)
    }

    func showCard(for suggestion: Suggestion, below rect: NSRect, keyboard: Bool,
                  accept: @escaping () -> Void, skip: @escaping () -> Void, cycle: @escaping (Int) -> Void) {
        hideCard()
        let host = ClickThroughHostingView(rootView: SuggestionCard(
            suggestion: suggestion, keyboard: keyboard, accept: accept, skip: skip, cycle: cycle))
        let size = host.fittingSize
        let p = Self.interactivePanel(Self.place(size, below: rect))
        host.frame = NSRect(origin: .zero, size: size)
        p.contentView = host
        p.orderFrontRegardless()
        card = p
    }

    func hideCard() {
        card?.orderOut(nil)
        card = nil
    }

    func cardContains(_ point: NSPoint) -> Bool {
        card.map { $0.isVisible && $0.frame.insetBy(dx: -4, dy: -4).contains(point) } ?? false
    }

    /// For apps that won't say where words are on screen: the suggestions as a small list by the text box.
    func showList(_ suggestions: [Suggestion], near rect: NSRect?,
                  accept: @escaping (Int) -> Void, skip: @escaping (Int) -> Void, acceptAll: @escaping () -> Void) {
        let host = ClickThroughHostingView(rootView: SuggestionList(
            suggestions: suggestions, accept: accept, skip: skip, acceptAll: acceptAll))
        let size = host.fittingSize
        let anchor = rect ?? NSRect(origin: NSEvent.mouseLocation, size: NSSize(width: 1, height: 1))
        let frame = Self.place(size, below: anchor)
        let p = list ?? Self.interactivePanel(frame)
        host.frame = NSRect(origin: .zero, size: size)
        p.contentView = host
        p.setFrame(frame, display: true)
        p.orderFrontRegardless()
        list = p
    }

    func hideList() {
        list?.orderOut(nil)
    }
}

/// The colour of Typestro's icon.
private let violet = NSColor(calibratedRed: 0.49, green: 0.42, blue: 1.00, alpha: 1)

/// Can be clicked without first bringing Typestro to the front.
private final class ClickThroughHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// A soft wave under a misspelled or wrong word; a dashed line under a sentence that could read better.
/// Both differ from the red dots of the app's own spellcheck.
private final class UnderlineView: NSView {
    var kind = SuggestionKind.word { didSet { if kind != oldValue { needsDisplay = true } } }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath()
        path.lineCapStyle = .round
        switch kind {
        case .word:
            let wavelength: CGFloat = 4, amplitude: CGFloat = 1.1, mid: CGFloat = 2.5
            path.move(to: NSPoint(x: 1, y: mid))
            var x: CGFloat = 1
            while x < bounds.width - 1 {
                path.line(to: NSPoint(x: x, y: mid + amplitude * sin(x / wavelength * 2 * .pi)))
                x += 0.5
            }
            path.lineWidth = 1.3
            violet.withAlphaComponent(0.9).setStroke()
        case .sentence:
            path.move(to: NSPoint(x: 1.5, y: 2.5))
            path.line(to: NSPoint(x: bounds.width - 1.5, y: 2.5))
            path.lineWidth = 1.5
            path.setLineDash([3, 3], count: 2, phase: 0)
            violet.withAlphaComponent(0.65).setStroke()
        }
        path.stroke()
    }
}

/// The change as it would read: removed words struck through, new words highlighted. Shown in the card's own
/// font rather than painted over the text, which would never quite line up.
private struct DiffText: View {
    let original: String
    let replacement: String

    var body: some View {
        var text = AttributedString()
        for segment in WordDiff.segments(from: original, to: replacement) {
            var piece = AttributedString(segment.text)
            switch segment.change {
            case .same:
                break
            case .removed:
                piece.strikethroughStyle = .single
                piece.foregroundColor = Color.primary.opacity(0.45)
            case .added:
                piece.backgroundColor = Color(nsColor: violet).opacity(0.22)
                piece.font = .system(size: 13, weight: .semibold)
            }
            text += piece
        }
        return Text(text).font(.system(size: 13))
    }
}

private struct SuggestionCard: View {
    let suggestion: Suggestion
    let keyboard: Bool
    let accept: () -> Void
    let skip: () -> Void
    let cycle: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Circle().fill(Color(nsColor: violet)).frame(width: 6, height: 6)
                Text(suggestion.reason)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                if suggestion.options.count > 1 {
                    Button { cycle(-1) } label: { Image(systemName: "chevron.left") }
                        .buttonStyle(.borderless)
                    Text("\(suggestion.choice + 1) of \(suggestion.options.count)")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Button { cycle(1) } label: { Image(systemName: "chevron.right") }
                        .buttonStyle(.borderless)
                }
            }
            DiffText(original: suggestion.original, replacement: suggestion.replacement)
                .lineLimit(8)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button("Accept", action: accept).controlSize(.small)
                Button("Skip", action: skip).controlSize(.small)
                Spacer(minLength: 8)
                if keyboard {
                    hint("tab", "accept")
                    hint("esc", "skip")
                } else {
                    hint("⌃⌥A", "accept all")
                }
            }
        }
        .padding(12)
        .frame(width: 320, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.primary.opacity(0.1)))
    }
}

private struct SuggestionList: View {
    let suggestions: [Suggestion]
    let accept: (Int) -> Void
    let skip: (Int) -> Void
    let acceptAll: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Typestro suggestions")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                if suggestions.count > 1 {
                    Button("Accept All", action: acceptAll).controlSize(.small)
                }
            }
            ForEach(Array(suggestions.prefix(6).enumerated()), id: \.offset) { i, s in
                VStack(alignment: .leading, spacing: 4) {
                    DiffText(original: s.original, replacement: s.replacement)
                        .lineLimit(4)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 8) {
                        Text(s.reason).font(.system(size: 11)).foregroundStyle(.secondary)
                        Spacer(minLength: 8)
                        Button("Accept") { accept(i) }.controlSize(.small)
                        Button("Skip") { skip(i) }.controlSize(.small)
                    }
                }
            }
        }
        .padding(12)
        .frame(width: 320, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.primary.opacity(0.1)))
    }
}

private func hint(_ key: String, _ action: String) -> some View {
    HStack(spacing: 4) {
        Text(key)
            .font(.system(size: 10, weight: .medium, design: .rounded))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 4))
        Text(action)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
    }
}
