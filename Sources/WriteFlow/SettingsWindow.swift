import AppKit
import Carbon.HIToolbox
import ServiceManagement
import SwiftUI
import WriteFlowCore

@MainActor
final class SettingsWindowController {
    private let settings: SettingsStore
    private let client: APIClient
    private var window: NSWindow?

    init(settings: SettingsStore, client: APIClient) {
        self.settings = settings
        self.client = client
    }

    func show() {
        let window = self.window ?? makeWindow()
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    /// Resizable and scrolling, so every section is reachable on small screens too.
    private func makeWindow() -> NSWindow {
        let hosting = NSHostingController(rootView: SettingsView(settings: settings, client: client))
        hosting.sizingOptions = []
        let window = NSWindow(contentViewController: hosting)
        window.title = "WriteFlow Settings"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.isReleasedWhenClosed = false
        let available = NSScreen.main?.visibleFrame.height ?? 800
        window.setContentSize(NSSize(width: 500, height: min(640, available - 80)))
        window.contentMinSize = NSSize(width: 440, height: 320)
        window.center()
        return window
    }
}

/// Opens WriteFlow when the user logs in. Works best once the app is in /Applications.
enum LaunchAtLogin {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    static func set(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("WriteFlow: launch at login: \(error.localizedDescription)")
        }
    }
}

struct SettingsView: View {
    @ObservedObject var settings: SettingsStore
    let client: APIClient

    @State private var trusted = SelectionReader.isTrusted
    @State private var launchAtLogin = LaunchAtLogin.isEnabled
    @State private var serverDraft = ""
    @State private var testResult: (text: String, ok: Bool)?
    @State private var testing = false
    private let poll = Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()

    var body: some View {
        Form {
            Section {
                Toggle("Show the W button when I select text", isOn: $settings.enabled)
                LabeledContent("Shortcut") {
                    ShortcutRecorder(shortcut: $settings.shortcut)
                }
                Text("Select text in any app and press the shortcut. It works even when the W button is off.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("Open WriteFlow at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { LaunchAtLogin.set($0) }
            }

            Section("Permission") {
                LabeledContent("Accessibility") {
                    if trusted {
                        Label("Allowed", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    } else {
                        Button("Allow…") {
                            SelectionReader.requestAccess()
                            SelectionReader.openAccessibilitySettings()
                        }
                    }
                }
                Text("Needed to read the text you select. WriteFlow never changes text in other apps: you copy and paste.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Suggestions") {
                ForEach(Mode.all) { mode in
                    Toggle(mode.label, isOn: modeBinding(mode.id))
                        .disabled(settings.modes == [mode.id])
                }
                Picker("Output language", selection: $settings.targetLanguage) {
                    ForEach(Languages.groups, id: \.name) { group in
                        Section(group.name) {
                            ForEach(group.languages) { Text($0.menuTitle).tag($0.tag) }
                        }
                    }
                }
                Toggle("Write it in English letters", isOn: romanizedBinding)
                    .disabled(!Languages.canRomanize(settings.targetLanguage))
                Text("For Indian languages: Marathi as \"tu kasa aahes?\", Tamil as \"eppadi irukkeenga?\".")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("Choose styles before each rewrite", isOn: $settings.askFirst)
            }

            Section("Server") {
                TextField("Server address", text: $serverDraft, prompt: Text(ServerURL.default))
                    .onSubmit(saveServer)
                SecureField("Access key (only for a private server)", text: $settings.accessKey)
                HStack {
                    Button(testing ? "Checking…" : "Test connection") { Task { await test() } }
                        .disabled(testing)
                    if serverDraft != ServerURL.default {
                        Button("Use default") {
                            serverDraft = ServerURL.default
                            saveServer()
                        }
                    }
                    Spacer()
                    if let testResult {
                        Text(testResult.text).foregroundStyle(testResult.ok ? .green : .red)
                    }
                }
            }

            Section {
                Text("WriteFlow \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev") · Only the text you ask about is sent, to make suggestions. It is not stored.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 440, minHeight: 320)
        .onAppear { serverDraft = settings.serverURL }
        .onDisappear(perform: saveServer)
        .onReceive(poll) { _ in
            trusted = SelectionReader.isTrusted
            launchAtLogin = LaunchAtLogin.isEnabled
        }
    }

    private func modeBinding(_ id: String) -> Binding<Bool> {
        Binding(
            get: { settings.modes.contains(id) },
            set: { on in
                let next = on ? settings.modes + [id] : settings.modes.filter { $0 != id }
                if !next.isEmpty { settings.modes = Mode.normalize(next) }
            }
        )
    }

    /// Shown unticked for languages it does not apply to, but the choice is kept for the next Indian language.
    private var romanizedBinding: Binding<Bool> {
        Binding(
            get: { settings.romanized && Languages.canRomanize(settings.targetLanguage) },
            set: { settings.romanized = $0 }
        )
    }

    private func saveServer() {
        let trimmed = serverDraft.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            settings.serverURL = ServerURL.default
            serverDraft = ServerURL.default
        } else if let url = ServerURL.normalize(trimmed) {
            settings.serverURL = url
            serverDraft = url
        } else {
            testResult = ("Enter an http:// or https:// address.", false)
        }
    }

    private func test() async {
        saveServer()
        guard let url = ServerURL.normalize(serverDraft) else { return }
        testing = true
        testResult = ("Checking… a sleeping free server can take up to a minute", true)
        let result = await client.checkConnection(server: url, accessKey: settings.accessKey)
        testing = false
        switch result {
        case .connected: testResult = ("Connected.", true)
        case .needsKey: testResult = ("This server needs an access key.", false)
        case .wrongKey: testResult = ("The access key is wrong.", false)
        case .failed(let message): testResult = (message, false)
        }
    }
}

/// Click, then press the keys you want, e.g. ⌃⌥W or ⇧⌘Space. Esc cancels.
struct ShortcutRecorder: View {
    @Binding var shortcut: Shortcut
    @State private var recording = false
    @State private var monitor: Any?
    @State private var problem: String?

    var body: some View {
        HStack(spacing: 8) {
            if let problem {
                Text(problem).font(.caption).foregroundStyle(.red)
            }
            if shortcut != .default && !recording {
                Button("Reset") { shortcut = .default }
                    .buttonStyle(.borderless)
            }
            Button(recording ? "Press keys…" : shortcut.display) {
                recording ? stop() : start()
            }
            .font(.body.monospaced())
            .help("Click, then press the shortcut you want")
        }
        .onDisappear(perform: stop)
    }

    private func start() {
        problem = nil
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == UInt16(kVK_Escape) {
                stop()
                return nil
            }
            let recorded = Shortcut(
                keyCode: Int(event.keyCode), modifiers: Self.carbonModifiers(event.modifierFlags), key: Self.keyName(event)
            )
            if recorded.isAllowed {
                shortcut = recorded
                stop()
            } else {
                problem = "Include ⌘ or ⌃"
            }
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recording = false
    }

    private static func carbonModifiers(_ flags: NSEvent.ModifierFlags) -> Int {
        var modifiers = 0
        if flags.contains(.command) { modifiers |= Shortcut.command }
        if flags.contains(.shift) { modifiers |= Shortcut.shift }
        if flags.contains(.option) { modifiers |= Shortcut.option }
        if flags.contains(.control) { modifiers |= Shortcut.control }
        return modifiers
    }

    private static func keyName(_ event: NSEvent) -> String {
        switch Int(event.keyCode) {
        case kVK_Space: return "Space"
        case kVK_Return: return "↩"
        case kVK_Tab: return "⇥"
        default:
            // Ignoring modifiers gives "w" for ⌥W instead of "∑".
            let characters = event.charactersIgnoringModifiers ?? ""
            return characters.isEmpty ? "Key \(event.keyCode)" : characters.uppercased()
        }
    }
}
