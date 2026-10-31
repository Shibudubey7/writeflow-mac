import AppKit
import WriteFlowCore

/// A borderless panel that floats over every app without taking focus from it, so the selection and
/// the frontmost app stay as they were.
final class FloatingPanel: NSPanel {
    var onCancel: () -> Void = {}
    private let acceptsKey: Bool

    init(size: NSSize, acceptsKey: Bool) {
        self.acceptsKey = acceptsKey
        super.init(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        isFloatingPanel = true
        level = .popUpMenu
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
    }

    override var canBecomeKey: Bool { acceptsKey }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) { onCancel() }

    /// Places the panel's top-left corner at `point`, kept inside the screen under it.
    func place(topLeft point: NSPoint) {
        var frame = NSRect(x: point.x, y: point.y - self.frame.height, width: self.frame.width, height: self.frame.height)
        let screen = NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) } ?? NSScreen.main
        if let visible = screen?.visibleFrame {
            frame.origin.x = min(max(frame.minX, visible.minX + 8), visible.maxX - frame.width - 8)
            frame.origin.y = min(max(frame.minY, visible.minY + 8), visible.maxY - frame.height - 8)
        }
        setFrame(frame, display: true)
    }

    /// New size, keeping the top edge where it is (cards grow downwards as results arrive), then
    /// moved up if the bottom would go under the Dock or off the screen.
    func resize(to size: NSSize) {
        guard size.width > 0, size.height > 0 else { return }
        let top = frame.maxY
        setFrame(NSRect(x: frame.minX, y: top - size.height, width: size.width, height: size.height), display: true)
        place(topLeft: NSPoint(x: frame.minX, y: frame.maxY))
    }
}

/// What the W button shows beside the W.
enum BubbleScore: Equatable {
    case none
    /// Asked for, not answered yet.
    case pending
    case value(Score)
}

/// The small W button that appears next to a selection, with the writing score beside it.
@MainActor
final class BubbleController {
    private static let size: CGFloat = 28
    private static let badgeWidth: CGFloat = 32

    private var panel: FloatingPanel?
    private var view: BubbleView?
    private var action: () -> Void = {}

    func show(at mouse: NSPoint, action: @escaping () -> Void) {
        self.action = action
        let panel = self.panel ?? makePanel()
        self.panel = panel
        view?.score = .none
        panel.setContentSize(NSSize(width: Self.size, height: Self.size))
        panel.place(topLeft: NSPoint(x: mouse.x + 8, y: mouse.y - 8))
        panel.alphaValue = 1
        panel.orderFrontRegardless()
    }

    /// Widens the button for the score (or back to just the W), keeping it on screen.
    func setScore(_ score: BubbleScore) {
        guard let panel, let view, panel.isVisible else { return }
        view.score = score
        let width = Self.size + (score == .none ? 0 : Self.badgeWidth)
        panel.setFrame(NSRect(x: panel.frame.minX, y: panel.frame.minY, width: width, height: Self.size), display: true)
        panel.place(topLeft: NSPoint(x: panel.frame.minX, y: panel.frame.maxY))
        view.needsDisplay = true
    }

    func hide() {
        panel?.orderOut(nil)
    }

    private func makePanel() -> FloatingPanel {
        let panel = FloatingPanel(size: NSSize(width: Self.size, height: Self.size), acceptsKey: false)
        let button = BubbleView(frame: NSRect(x: 0, y: 0, width: Self.size, height: Self.size))
        button.autoresizingMask = [.width, .height]
        button.onClick = { [weak self] in
            self?.hide()
            self?.action()
        }
        panel.contentView = button
        view = button
        return panel
    }
}

final class BubbleView: NSView {
    var onClick: () -> Void = {}
    var score: BubbleScore = .none {
        didSet { toolTip = Self.toolTip(for: score) }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 7, yRadius: 7).addClip()
        NSColor.writeFlowAccent.setFill()
        bounds.fill()

        let markWidth = bounds.height
        if score != .none {
            let badge = NSRect(x: markWidth, y: 0, width: bounds.width - markWidth, height: bounds.height)
            let (fill, ink, label) = Self.badgeStyle(for: score)
            fill.setFill()
            badge.fill()
            Self.drawCentered(label, in: badge, font: .systemFont(ofSize: 12, weight: .bold), color: ink)
        }
        NSGraphicsContext.restoreGraphicsState()

        Self.drawCentered(
            "W", in: NSRect(x: 0, y: 0, width: markWidth, height: bounds.height),
            font: .systemFont(ofSize: 14, weight: .heavy), color: .white
        )
    }

    /// Red below 65, yellow 65-84, green 85 and up.
    private static func badgeStyle(for score: BubbleScore) -> (NSColor, NSColor, String) {
        guard case .value(let result) = score else {
            return (NSColor.white.withAlphaComponent(0.18), NSColor.white.withAlphaComponent(0.8), "…")
        }
        let value = result.score
        switch ScoreBand(score: value) {
        case .low: return (NSColor(srgbRed: 0xDC / 255, green: 0x26 / 255, blue: 0x26 / 255, alpha: 1), .white, "\(value)")
        case .fair: return (NSColor(srgbRed: 0xEA / 255, green: 0xB3 / 255, blue: 0x08 / 255, alpha: 1), NSColor(srgbRed: 0x1C / 255, green: 0x1C / 255, blue: 0x22 / 255, alpha: 1), "\(value)")
        case .good: return (NSColor(srgbRed: 0x16 / 255, green: 0xA3 / 255, blue: 0x4A / 255, alpha: 1), .white, "\(value)")
        }
    }

    private static func toolTip(for score: BubbleScore) -> String {
        if case .value(let result) = score {
            let breakdown = result.breakdown
            let summary = breakdown.isEmpty ? "Score \(result.score)/100" : "Score \(result.score)/100 (\(breakdown))"
            return "\(summary). Click to rewrite with WriteFlow"
        }
        return "Rewrite with WriteFlow"
    }

    private static func drawCentered(_ text: String, in rect: NSRect, font: NSFont, color: NSColor) {
        let title = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color])
        let size = title.size()
        title.draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2))
    }

    override func mouseDown(with event: NSEvent) { onClick() }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}

extension NSColor {
    /// #4f46e5, the extension's indigo.
    static let writeFlowAccent = NSColor(srgbRed: 0x4F / 255, green: 0x46 / 255, blue: 0xE5 / 255, alpha: 1)
}
