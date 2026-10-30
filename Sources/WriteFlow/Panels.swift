import AppKit

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

/// The small W button that appears next to a selection.
@MainActor
final class BubbleController {
    private var panel: FloatingPanel?
    private var action: () -> Void = {}

    func show(at mouse: NSPoint, action: @escaping () -> Void) {
        self.action = action
        let panel = self.panel ?? makePanel()
        self.panel = panel
        panel.place(topLeft: NSPoint(x: mouse.x + 8, y: mouse.y - 8))
        panel.alphaValue = 1
        panel.orderFrontRegardless()
    }

    func hide() {
        panel?.orderOut(nil)
    }

    private func makePanel() -> FloatingPanel {
        let panel = FloatingPanel(size: NSSize(width: 28, height: 28), acceptsKey: false)
        let button = BubbleView(frame: NSRect(x: 0, y: 0, width: 28, height: 28))
        button.onClick = { [weak self] in
            self?.hide()
            self?.action()
        }
        panel.contentView = button
        return panel
    }
}

private final class BubbleView: NSView {
    var onClick: () -> Void = {}

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let box = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 7, yRadius: 7)
        NSColor.writeFlowAccent.setFill()
        box.fill()
        let title = NSAttributedString(string: "W", attributes: [
            .font: NSFont.systemFont(ofSize: 14, weight: .heavy),
            .foregroundColor: NSColor.white,
        ])
        let size = title.size()
        title.draw(at: NSPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2))
    }

    override func mouseDown(with event: NSEvent) { onClick() }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}

extension NSColor {
    /// #4f46e5, the extension's indigo.
    static let writeFlowAccent = NSColor(srgbRed: 0x4F / 255, green: 0x46 / 255, blue: 0xE5 / 255, alpha: 1)
}
