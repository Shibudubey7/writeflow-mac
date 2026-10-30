import AppKit
import Carbon.HIToolbox

/// While WriteFlow is on: notices when text is selected in another app, with the mouse (a drag, or a
/// double or triple click) or the keyboard (⇧ or ⌘⇧ with arrows, ⌘A), and reports where, for the W button. The text is nil
/// when the app does not report its selection (Chrome, many Electron apps); it is read on click then.
/// Anything else the user does next (a click, a key, scrolling, switching apps) dismisses it.
@MainActor
final class SelectionWatcher {
    var onSelection: (String?, NSPoint) -> Void = { _, _ in }
    var onDismiss: () -> Void = {}

    private var monitors: [Any] = []
    private var activationObserver: NSObjectProtocol?
    private var downLocation = NSPoint.zero
    /// Read on mouse down: the click count is not set on mouse-up events seen from other apps.
    private var downClickCount = 0
    private var downOnText = false
    private var pending: Task<Void, Never>?

    var isRunning: Bool { !monitors.isEmpty }

    /// Keys that extend a selection when ⇧ is held: arrows, Home, End, Page Up, Page Down.
    private static let selectionKeys: Set<Int> = [
        kVK_LeftArrow, kVK_RightArrow, kVK_UpArrow, kVK_DownArrow, kVK_Home, kVK_End, kVK_PageUp, kVK_PageDown,
    ]
    /// Focused elements where ⇧-arrow selects text, for apps that don't report the selection
    /// itself (Slack's message box reports as a scroll area). Lists and tables are left out, where
    /// ⇧-arrow selects files or rows.
    private static let keyboardTextRoles: Set<String> = [
        "AXTextArea", "AXTextField", "AXComboBox", "AXSearchField", "AXWebArea", "AXScrollArea", "AXStaticText", "AXGroup",
    ]

    func start() {
        guard monitors.isEmpty else { return }
        let mouseDown = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            let clicks = event.clickCount
            MainActor.assumeIsolated {
                self?.downLocation = NSEvent.mouseLocation
                self?.downClickCount = clicks
                self?.downOnText = SelectionReader.pointerIsTextCursor
                self?.dismiss()
            }
        }
        let mouseUp = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp) { [weak self] _ in
            MainActor.assumeIsolated { self?.mouseUp() }
        }
        let keyDown = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let keyCode = Int(event.keyCode)
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            MainActor.assumeIsolated { self?.keyDown(keyCode, flags) }
        }
        let other = NSEvent.addGlobalMonitorForEvents(matching: [.scrollWheel, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.dismiss() }
        }
        monitors = [mouseDown, mouseUp, keyDown, other].compactMap { $0 }
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] notification in
            let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated {
                SelectionReader.prepare(app)
                self?.dismiss()
            }
        }
        SelectionReader.prepare(NSWorkspace.shared.frontmostApplication)
    }

    func stop() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }
        activationObserver = nil
        dismiss()
    }

    private func mouseUp() {
        let location = NSEvent.mouseLocation
        let clickCount = downClickCount
        let startedOnText = downOnText
        let dragged = hypot(location.x - downLocation.x, location.y - downLocation.y) > 4
        guard dragged || clickCount >= 2 else { return }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
        pending?.cancel()
        pending = Task { [weak self] in
            // Give the app a moment to update its selection.
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard !Task.isCancelled else { return }
            let app = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "?"
            guard SelectionReader.isTrusted else {
                log.notice("selection in \(app, privacy: .public): no Accessibility access")
                return
            }
            let text = SelectionReader.selectedTextViaAccessibility()
            let role = SelectionReader.role(at: location)
            // A drag that starts on text and ends past the end of a line ends on an arrow cursor.
            let textCursor = SelectionReader.pointerIsTextCursor || startedOnText
            log.notice("selection in \(app, privacy: .public): role \(role ?? "none", privacy: .public), reported \(text?.count ?? 0, privacy: .public) characters, text cursor \(textCursor, privacy: .public), clicks \(clickCount, privacy: .public), dragged \(dragged, privacy: .public)")
            if text != nil || SelectionReader.isTextRole(role) || textCursor {
                self?.onSelection(text, location)
            }
        }
    }

    /// Any key hides the W button; a key that extends a selection shows it again once the user stops
    /// pressing keys for a moment (each new key restarts the wait).
    private func keyDown(_ keyCode: Int, _ flags: NSEvent.ModifierFlags) {
        dismiss()
        let extendsSelection = flags.contains(.shift) && Self.selectionKeys.contains(keyCode)
        let selectsAll = keyCode == kVK_ANSI_A && flags.subtracting([.capsLock, .numericPad, .function]) == .command
        guard extendsSelection || selectsAll else { return }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
        pending = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 450_000_000)
            guard !Task.isCancelled, SelectionReader.isTrusted else { return }
            let app = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "?"
            let text = SelectionReader.selectedTextViaAccessibility()
            let role = SelectionReader.focusedRole()
            let bounds = SelectionReader.selectionBounds()
            log.notice("keyboard selection in \(app, privacy: .public): focused \(role ?? "none", privacy: .public), reported \(text?.count ?? 0, privacy: .public) characters, bounds \(bounds != nil, privacy: .public)")
            // No focused element at all: an app that hides everything from Accessibility (Slack and
            // other Electron apps), where ⇧-arrow and ⌘A select text.
            guard text != nil || role.map(Self.keyboardTextRoles.contains) ?? true else { return }
            // Beside the end of the selection when the app says where it is, else at the pointer.
            let point = bounds.map { NSPoint(x: $0.maxX, y: $0.minY) } ?? NSEvent.mouseLocation
            self?.onSelection(text, point)
        }
    }

    private func dismiss() {
        pending?.cancel()
        pending = nil
        onDismiss()
    }
}
