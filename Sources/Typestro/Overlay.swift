import AppKit
import SwiftUI

/// Small click-through windows drawn over other apps: the flash on a fixed word,
/// dotted underlines under suggestions, and the suggestion card.
@MainActor
final class Overlay {
    private var underlines: [NSPanel] = []
    private var card: NSPanel?

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

    func showUnderlines(_ rects: [NSRect]) {
        while underlines.count < rects.count {
            let p = Self.panel(.zero)
            p.contentView = UnderlineView()
            underlines.append(p)
        }
        for (i, p) in underlines.enumerated() {
            guard i < rects.count else { p.orderOut(nil); continue }
            let r = rects[i]
            p.setFrame(NSRect(x: r.minX, y: r.minY - 3, width: max(r.width, 6), height: 4), display: true)
            p.orderFrontRegardless()
        }
    }

    func hideUnderlines() {
        underlines.forEach { $0.orderOut(nil) }
    }

    func showCard(for suggestion: Suggestion, below rect: NSRect) {
        hideCard()
        let host = NSHostingView(rootView: SuggestionCard(
            reason: suggestion.reason, original: suggestion.original, replacement: suggestion.replacement))
        let size = host.fittingSize
        var origin = NSPoint(x: rect.minX, y: rect.minY - size.height - 8)
        if let screen = NSScreen.screens.first(where: { $0.frame.intersects(rect) }) ?? NSScreen.main {
            let visible = screen.visibleFrame
            if origin.y < visible.minY { origin.y = rect.maxY + 8 }
            origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - size.width - 8)
        }
        let p = Self.panel(NSRect(origin: origin, size: size))
        host.frame = NSRect(origin: .zero, size: size)
        p.contentView = host
        p.hasShadow = true
        p.orderFrontRegardless()
        card = p
    }

    func hideCard() {
        card?.orderOut(nil)
        card = nil
    }
}

private final class UnderlineView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath()
        path.move(to: NSPoint(x: 1.5, y: 2))
        path.line(to: NSPoint(x: bounds.width - 1.5, y: 2))
        path.lineWidth = 2
        path.lineCapStyle = .round
        path.setLineDash([0.01, 4], count: 2, phase: 0)
        NSColor.systemIndigo.withAlphaComponent(0.85).setStroke()
        path.stroke()
    }
}

private struct SuggestionCard: View {
    let reason: String
    let original: String
    let replacement: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(reason)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(original)
                .font(.system(size: 13))
                .strikethrough()
                .foregroundStyle(.secondary)
                .lineLimit(3)
            Text(replacement)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(5)
            HStack(spacing: 12) {
                hint("tab", "accept")
                hint("esc", "dismiss")
            }
            .padding(.top, 2)
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(12)
        .frame(width: 300, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.primary.opacity(0.1)))
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
}
