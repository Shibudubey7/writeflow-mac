import AppKit
import Carbon.HIToolbox
import Combine
import WriteFlowCore

/// The W in the menu bar, the shortcut and the W button on selection.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let settings = SettingsStore()
    private let client = APIClient()
    private lazy var card = CardController(settings: settings, client: client)
    private lazy var settingsWindow = SettingsWindowController(settings: settings, client: client)
    private let bubble = BubbleController()
    private let watcher = SelectionWatcher()
    private var statusItem: NSStatusItem!
    private var hotKey: HotKey?
    private var keyMonitor: Any?
    private var lastShortcut = Date.distantPast
    /// Bumped on every new selection and dismissal, so a late score never lands on the wrong one.
    private var selectionID = 0
    /// The current selection's text once known (read for the score), so clicking W needn't copy again.
    private var bubbleText: String?
    private var cancellables: Set<AnyCancellable> = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        settings.$shortcut
            .removeDuplicates()
            .sink { [weak self] shortcut in self?.register(shortcut) }
            .store(in: &cancellables)
        log.notice("started, Accessibility \(SelectionReader.isTrusted ? "allowed" : "not allowed", privacy: .public)")

        watcher.onSelection = { [weak self] text, location in
            self?.selectionMade(text, at: location)
        }
        watcher.onDismiss = { [weak self] in
            guard let self else { return }
            self.selectionID += 1
            self.bubbleText = nil
            self.bubble.hide()
        }

        settings.$enabled
            .removeDuplicates()
            .sink { [weak self] enabled in self?.apply(enabled: enabled) }
            .store(in: &cancellables)

        if settings.takeFirstLaunch() || !SelectionReader.isTrusted {
            if !SelectionReader.isTrusted { SelectionReader.requestAccess() }
            settingsWindow.show()
        }
    }

    /// Two ways to catch the shortcut: the registered hot key, and (with Accessibility access)
    /// watching key presses, for when macOS doesn't deliver the hot key. Whichever comes first wins.
    private func register(_ shortcut: Shortcut) {
        hotKey = nil // unregisters the previous one first
        hotKey = HotKey(keyCode: shortcut.keyCode, modifiers: shortcut.modifiers, id: 1) { [weak self] in
            self?.shortcutPressed(via: "hot key")
        }
        log.notice("shortcut \(shortcut.display, privacy: .public) registered: \(self.hotKey != nil, privacy: .public)")

        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard !SelectionReader.isSynthetic(event) else { return }
            let matches = Int(event.keyCode) == shortcut.keyCode && Self.carbonModifiers(event.modifierFlags) == shortcut.modifiers
            guard matches else { return }
            MainActor.assumeIsolated { self?.shortcutPressed(via: "key monitor") }
        }
    }

    private func shortcutPressed(via source: String) {
        guard Date().timeIntervalSince(lastShortcut) > 0.5 else { return }
        lastShortcut = Date()
        log.notice("shortcut pressed (\(source, privacy: .public))")
        rewriteSelection()
    }

    private static func carbonModifiers(_ flags: NSEvent.ModifierFlags) -> Int {
        var modifiers = 0
        if flags.contains(.command) { modifiers |= Shortcut.command }
        if flags.contains(.shift) { modifiers |= Shortcut.shift }
        if flags.contains(.option) { modifiers |= Shortcut.option }
        if flags.contains(.control) { modifiers |= Shortcut.control }
        return modifiers
    }

    /// The on/off switch, shown in the menu bar icon: filled W when on, outlined and dimmed when off.
    private func apply(enabled: Bool) {
        statusItem.button?.image = StatusIcon.image(on: enabled)
        statusItem.button?.appearsDisabled = !enabled
        statusItem.button?.toolTip = enabled
            ? "WriteFlow is on: select text to see the W button"
            : "WriteFlow is off: \(settings.shortcut.display) still works"
        if enabled { watcher.start() } else { watcher.stop() }
    }

    /// Shows the W button, then asks for the writing score. Apps that don't report their selection
    /// (Slack, Chrome) get it read with ⌘C first, the clipboard put back right after.
    private func selectionMade(_ text: String?, at location: NSPoint) {
        guard !card.isOpen else { return }
        selectionID += 1
        let id = selectionID
        bubbleText = text
        bubble.show(at: location) { [weak self] in
            guard let self else { return }
            if let text = self.bubbleText { self.card.show(text: text, at: location) } else { self.rewriteSelection(at: location) }
        }
        guard settings.showScore else { return }
        bubble.setScore(.pending)
        Task { [weak self] in
            var resolved = text
            if resolved == nil { resolved = await SelectionReader.selectedText() }
            guard let self, self.selectionID == id else { return }
            guard let resolved else {
                self.bubble.setScore(.none)
                return
            }
            self.bubbleText = resolved
            let score = await self.client.score(
                resolved, modes: self.settings.modes,
                server: self.settings.serverURL, accessKey: self.settings.accessKey, installID: self.settings.installID
            )
            guard self.selectionID == id else { return }
            self.bubble.setScore(score.map { .value($0) } ?? .none)
        }
    }

    private func rewriteSelection(at location: NSPoint = NSEvent.mouseLocation) {
        bubble.hide()
        guard SelectionReader.isTrusted else {
            card.show(text: "", notice: .needsAccess, at: location)
            return
        }
        Task {
            let text = await SelectionReader.selectedText()
            card.show(text: text ?? "", notice: text == nil ? .noSelection : nil, at: location)
        }
    }

    @objc private func rewriteSelectionFromMenu() {
        // Let the menu close and focus go back to the app the text is in.
        Task {
            try? await Task.sleep(nanoseconds: 200_000_000)
            rewriteSelection()
        }
    }

    @objc private func rewriteClipboard() {
        let text = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        card.show(text: text, notice: text.isEmpty ? .noSelection : nil, at: NSEvent.mouseLocation)
    }

    @objc private func toggleEnabled() { settings.enabled.toggle() }
    @objc private func openSettings() { settingsWindow.show() }
    @objc private func openAccessibility() {
        SelectionReader.requestAccess()
        SelectionReader.openAccessibilitySettings()
    }
    @objc private func toggleLaunchAtLogin() { LaunchAtLogin.set(!LaunchAtLogin.isEnabled) }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let status = NSMenuItem(title: settings.enabled ? "WriteFlow Is On" : "WriteFlow Is Off", action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        menu.addItem(item(settings.enabled ? "Turn Off" : "Turn On", #selector(toggleEnabled)))
        if !SelectionReader.isTrusted {
            menu.addItem(item("Allow Accessibility Access…", #selector(openAccessibility)))
        }
        menu.addItem(.separator())
        menu.addItem(item("Rewrite Selected Text   \(settings.shortcut.display)", #selector(rewriteSelectionFromMenu)))
        menu.addItem(item("Rewrite Clipboard Text", #selector(rewriteClipboard)))
        menu.addItem(.separator())
        menu.addItem(item("Settings…", #selector(openSettings), key: ","))
        let login = item("Open at Login", #selector(toggleLaunchAtLogin))
        login.state = LaunchAtLogin.isEnabled ? .on : .off
        menu.addItem(login)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit WriteFlow", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }
}

enum StatusIcon {
    /// An 18-point template image, so macOS tints it for light and dark menu bars.
    static func image(on: Bool) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            let box = NSBezierPath(roundedRect: rect.insetBy(dx: 1.5, dy: 1.5), xRadius: 4, yRadius: 4)
            let letter = NSAttributedString(string: "W", attributes: [
                .font: NSFont.systemFont(ofSize: 10.5, weight: .heavy),
                .foregroundColor: NSColor.black,
            ])
            let size = letter.size()
            let origin = NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2)
            NSColor.black.set()
            if on {
                box.fill()
                NSGraphicsContext.current?.cgContext.setBlendMode(.destinationOut)
                letter.draw(at: origin)
            } else {
                box.lineWidth = 1.2
                box.stroke()
                letter.draw(at: origin)
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = on ? "WriteFlow (on)" : "WriteFlow (off)"
        return image
    }
}
