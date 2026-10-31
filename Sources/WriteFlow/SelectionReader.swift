import AppKit
import ApplicationServices
import Carbon.HIToolbox
import os

/// Diagnostics in Console.app (subsystem io.github.shibudubey7.writeflow). Never logs the text itself.
let log = Logger(subsystem: "io.github.shibudubey7.writeflow", category: "selection")

/// Reads the text selected in the frontmost app. Needs Accessibility access (System Settings →
/// Privacy & Security → Accessibility). Never changes the other app's text.
enum SelectionReader {
    /// Chromium browsers only expose page text to Accessibility when asked to.
    private static let chromiumBrowsers: Set<String> = [
        "com.google.Chrome", "com.google.Chrome.canary", "com.microsoft.edgemac", "com.brave.Browser",
        "company.thebrowser.Browser", "com.vivaldi.Vivaldi", "com.operasoftware.Opera", "org.chromium.Chromium",
    ]

    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Shows macOS's own "WriteFlow would like to control this computer" prompt.
    static func requestAccess() {
        let prompt = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        AXIsProcessTrustedWithOptions([prompt: true] as CFDictionary)
    }

    static func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    static func prepare(_ app: NSRunningApplication?) {
        guard let app, let id = app.bundleIdentifier, chromiumBrowsers.contains(id) else { return }
        let element = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetAttributeValue(element, "AXManualAccessibility" as CFString, kCFBooleanTrue)
    }

    /// The selection as the frontmost app reports it to Accessibility; nil when it reports none.
    static func selectedTextViaAccessibility() -> String? {
        let system = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID()
        else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(focused as! AXUIElement, kAXSelectedTextAttribute as CFString, &value) == .success,
              let text = value as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return text
    }

    /// Roles of elements whose text can be selected; the W button may show over these even when the
    /// app does not report its selection, and is then read with ⌘C on click.
    private static let textRoles: Set<String> = [
        "AXStaticText", "AXTextArea", "AXTextField", "AXWebArea", "AXComboBox", "AXSearchField", "AXHeading", "AXLink",
    ]

    /// The Accessibility role of whatever is under the pointer (AppKit coordinates).
    static func role(at point: NSPoint) -> String? {
        guard let primary = NSScreen.screens.first else { return nil }
        var element: AXUIElement?
        let flipped = Float(primary.frame.maxY - point.y)
        guard AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(point.x), flipped, &element) == .success,
              let element
        else { return nil }
        var role: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
        return role as? String
    }

    private static func focusedElement() -> AXUIElement? {
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(AXUIElementCreateSystemWide(), kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID()
        else { return nil }
        return (focused as! AXUIElement)
    }

    static func focusedRole() -> String? {
        guard let element = focusedElement() else { return nil }
        var role: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
        return role as? String
    }

    /// Where the selected text is on screen (AppKit coordinates), when the app reports it.
    static func selectionBounds() -> NSRect? {
        guard let element = focusedElement(), let primary = NSScreen.screens.first else { return nil }
        var range: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &range) == .success,
              let range
        else { return nil }
        var bounds: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(element, kAXBoundsForRangeParameterizedAttribute as CFString, range, &bounds) == .success,
              let bounds, CFGetTypeID(bounds) == AXValueGetTypeID()
        else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(bounds as! AXValue, .cgRect, &rect), rect.width > 0 || rect.height > 0 else { return nil }
        // Accessibility measures from the top of the main screen; AppKit from the bottom.
        return NSRect(x: rect.minX, y: primary.frame.maxY - rect.maxY, width: rect.width, height: rect.height)
    }

    static func isTextRole(_ role: String?) -> Bool {
        role.map(textRoles.contains) ?? false
    }

    /// True while the pointer is the text cursor (I-beam). Electron apps such as Slack report no
    /// selection or text role, but still show this cursor over text.
    static var pointerIsTextCursor: Bool {
        guard let current = NSCursor.currentSystem else { return false }
        let iBeam = NSCursor.iBeam
        return current.hotSpot == iBeam.hotSpot && current.image.size == iBeam.image.size
    }

    /// For the shortcut: Accessibility first, then ⌘C in the frontmost app with the clipboard put
    /// back afterwards (some apps, like many Electron ones, report no selection to Accessibility).
    static func selectedText() async -> String? {
        prepare(NSWorkspace.shared.frontmostApplication)
        if let text = selectedTextViaAccessibility() { return text }
        let copied = await selectedTextViaCopy()
        log.notice("read via copy: \(copied?.count ?? 0, privacy: .public) characters")
        return copied
    }

    @MainActor
    private static func selectedTextViaCopy() async -> String? {
        guard isTrusted else { return nil }
        let pasteboard = NSPasteboard.general
        let saved = pasteboard.pasteboardItems?.map { item in
            item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
        } ?? []
        let before = pasteboard.changeCount

        // Let go of the shortcut's ⌥⇧ first, or the app would see ⌥⇧⌘C.
        try? await Task.sleep(nanoseconds: 120_000_000)
        pressCommand(kVK_ANSI_C)
        for _ in 0..<25 where pasteboard.changeCount == before {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        guard pasteboard.changeCount != before else { return nil }
        let text = pasteboard.string(forType: .string)

        pasteboard.clearContents()
        let items = saved.map { pairs -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in pairs { item.setData(data, forType: type) }
            // Clipboard managers (Maccy and others) skip items marked transient, so putting the
            // user's clipboard back doesn't add a duplicate to their history.
            item.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
            return item
        }
        if !items.isEmpty { pasteboard.writeObjects(items) }

        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return text
    }

    /// Replaces the selection in the frontmost app: puts `text` on the clipboard and presses ⌘V.
    /// The text stays on the clipboard, so it can still be pasted by hand where ⌘V does nothing
    /// (text on a web page that can't be edited, for example).
    @MainActor
    static func paste(_ text: String) async {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        // Let the card close so the keys go to the app the text is in.
        try? await Task.sleep(nanoseconds: 150_000_000)
        pressCommand(kVK_ANSI_V)
        log.notice("replaced selection with \(text.count, privacy: .public) characters")
    }

    /// Set on keys WriteFlow presses itself (⌘C, ⌘V), so its key watchers can ignore them.
    static let syntheticKeyMarker: Int64 = 0x5746_4C57

    static func isSynthetic(_ event: NSEvent) -> Bool {
        event.cgEvent?.getIntegerValueField(.eventSourceUserData) == syntheticKeyMarker
    }

    private static func pressCommand(_ keyCode: Int) {
        let source = CGEventSource(stateID: .combinedSessionState)
        let key = CGKeyCode(keyCode)
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: down)
            event?.flags = .maskCommand
            event?.setIntegerValueField(.eventSourceUserData, value: syntheticKeyMarker)
            event?.post(tap: .cghidEventTap)
        }
    }
}
