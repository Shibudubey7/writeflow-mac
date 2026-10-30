import AppKit
import Combine
import SwiftUI
import WriteFlowCore

/// What the card shows instead of suggestions when there is nothing to rewrite.
enum CardNotice: Equatable {
    case noSelection
    case needsAccess
}

/// State of one card: the selected text, the chosen styles and language, and the server's answer.
/// Style and language changes are saved, so the next card starts with them.
@MainActor
final class CardModel: ObservableObject {
    enum Phase: Equatable {
        case waiting
        case loading
        case done(Correction)
        case failed(WriteFlowError)
    }

    let text: String
    let notice: CardNotice?
    /// For the hint when nothing was selected, e.g. "⌃⌥W".
    let shortcut: String
    @Published var modes: [String] { didSet { settings.modes = modes; rerun() } }
    @Published var language: String { didSet { settings.targetLanguage = language; rerun() } }
    @Published var romanized: Bool { didSet { settings.romanized = romanized; if canRomanize { rerun() } } }
    @Published private(set) var phase: Phase = .waiting
    /// After a few seconds of loading: the free server is probably waking up.
    @Published private(set) var slow = false
    @Published private(set) var copied: String?

    var onClose: () -> Void = {}

    private let settings: SettingsStore
    private let client: APIClient
    private var task: Task<Void, Never>?

    init(text: String, notice: CardNotice?, settings: SettingsStore, client: APIClient) {
        self.text = text
        self.notice = notice
        shortcut = settings.shortcut.display
        self.settings = settings
        self.client = client
        modes = settings.modes
        language = settings.targetLanguage
        romanized = settings.romanized
    }

    var canRomanize: Bool { Languages.canRomanize(language) }

    func start() {
        guard notice == nil else { return }
        if !settings.askFirst { run() }
    }

    func toggle(_ mode: String) {
        if modes.contains(mode) {
            guard modes.count > 1 else { return }
            modes.removeAll { $0 == mode }
        } else {
            modes = Mode.normalize(modes + [mode])
        }
    }

    func run() {
        task?.cancel()
        if text.utf16.count > maxInputChars {
            phase = .failed(WriteFlowError(
                code: "INPUT_TOO_LONG",
                message: "That's more than \(maxInputChars.formatted()) characters. Select a shorter part."
            ))
            return
        }
        phase = .loading
        slow = false
        let request = CorrectionRequest(
            text: text, modes: modes, targetLanguage: Languages.requestTag(language, romanized: romanized)
        )
        let (server, key, installID) = (settings.serverURL, settings.accessKey, settings.installID)
        task = Task { [weak self, client] in
            let slowNote = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                if !Task.isCancelled, self?.phase == .loading { self?.slow = true }
            }
            let result = await client.correct(request, server: server, accessKey: key, installID: installID)
            slowNote.cancel()
            guard !Task.isCancelled, let self else { return }
            switch result {
            case .success(let correction): self.phase = .done(correction)
            case .failure(let error): self.phase = .failed(error)
            }
        }
    }

    /// Puts the suggestion in place of the selected text, then closes.
    func replace(_ suggestion: String) {
        onClose()
        Task { await SelectionReader.paste(suggestion) }
    }

    /// Copies one suggestion, then closes so it can be pasted straight away.
    func copy(_ mode: String, _ suggestion: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(suggestion, forType: .string)
        copied = mode
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 450_000_000)
            self?.onClose()
        }
    }

    func cancel() {
        task?.cancel()
    }

    /// Snapshots only: shows a state without asking the server.
    func debugShow(_ phase: Phase, slow: Bool = false) {
        self.phase = phase
        self.slow = slow
    }

    /// Changing styles or language after a run asks again; before the first run it just waits.
    private func rerun() {
        if phase != .waiting { run() }
    }
}

/// Opens, places and closes the suggestion card. Clicking anywhere outside it closes it.
@MainActor
final class CardController {
    static let width: CGFloat = 380

    private let settings: SettingsStore
    private let client: APIClient
    private var panel: FloatingPanel?
    private var model: CardModel?
    private var outsideClick: Any?
    private var changes: AnyCancellable?

    init(settings: SettingsStore, client: APIClient) {
        self.settings = settings
        self.client = client
    }

    var isOpen: Bool { panel?.isVisible == true }

    /// For the --demo-card self-test.
    var debugState: (model: CardModel?, frame: NSRect?) { (model, panel?.frame) }

    func show(text: String, notice: CardNotice? = nil, at mouse: NSPoint) {
        close()
        let model = CardModel(text: text, notice: notice, settings: settings, client: client)
        let panel = FloatingPanel(size: NSSize(width: Self.width, height: 120), acceptsKey: true)
        model.onClose = { [weak self] in self?.close() }
        panel.onCancel = { [weak self] in self?.close() }
        let hosting = NSHostingView(rootView: CardView(model: model))
        // Report the card's size, but let resize(to:) set the window so it also stays on screen.
        hosting.sizingOptions = [.intrinsicContentSize]
        panel.contentView = hosting
        panel.place(topLeft: NSPoint(x: mouse.x - 24, y: mouse.y - 14))
        panel.resize(to: hosting.intrinsicContentSize)
        // After every change (results arriving, a style toggled), once SwiftUI has applied it.
        changes = model.objectWillChange.sink { [weak panel, weak hosting] _ in
            DispatchQueue.main.async {
                guard let panel, let hosting else { return }
                panel.resize(to: hosting.intrinsicContentSize)
            }
        }
        panel.orderFrontRegardless()
        panel.makeKey()
        self.panel = panel
        self.model = model
        outsideClick = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }
        model.start()
    }

    func close() {
        if let outsideClick { NSEvent.removeMonitor(outsideClick) }
        outsideClick = nil
        changes = nil
        model?.cancel()
        panel?.orderOut(nil)
        panel = nil
        model = nil
    }
}

struct CardView: View {
    @ObservedObject var model: CardModel

    /// Leaves room for the card's header and controls on the screen.
    private static var maxResultsHeight: CGFloat {
        let screen = NSScreen.main?.visibleFrame.height ?? 800
        return max(200, min(520, screen - 280))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if let notice = model.notice {
                NoticeView(notice: notice, shortcut: model.shortcut)
            } else {
                Text(model.text)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.tail)
                controls
                Divider()
                content
            }
        }
        .padding(14)
        .frame(width: CardController.width, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .background(VisualEffect().clipShape(RoundedRectangle(cornerRadius: 12)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.12)))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .tint(Color(nsColor: .writeFlowAccent))
    }

    private func results(_ correction: Correction) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Mode.all.filter { model.modes.contains($0.id) }) { mode in
                if let suggestion = correction.suggestions[mode.id] {
                    SuggestionRow(
                        label: mode.label, text: suggestion, copied: model.copied == mode.id,
                        replace: { model.replace(suggestion) },
                        copy: { model.copy(mode.id, suggestion) }
                    )
                }
            }
            Text(correction.explanation)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("W")
                .font(.system(size: 12, weight: .heavy))
                .foregroundStyle(.white)
                .frame(width: 20, height: 20)
                .background(Color(nsColor: .writeFlowAccent), in: RoundedRectangle(cornerRadius: 5))
            Text("WriteFlow").font(.headline)
            Spacer()
            Button(action: model.onClose) {
                Image(systemName: "xmark").font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(.borderless)
            .help("Close (Esc)")
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                ForEach(Mode.all) { mode in
                    Chip(label: mode.label, selected: model.modes.contains(mode.id)) { model.toggle(mode.id) }
                }
            }
            HStack(spacing: 10) {
                Picker("Language", selection: $model.language) {
                    ForEach(Languages.groups, id: \.name) { group in
                        Section(group.name) {
                            ForEach(group.languages) { Text($0.menuTitle).tag($0.tag) }
                        }
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 210)
                // Shown unticked where it doesn't apply; the choice comes back with the next Indian language.
                Toggle("English letters", isOn: Binding(
                    get: { model.romanized && model.canRomanize },
                    set: { model.romanized = $0 }
                ))
                    .toggleStyle(.checkbox)
                    .disabled(!model.canRomanize)
                    .help(model.canRomanize ? "Write it in English (Roman) letters" : "Only for Indian languages")
            }
            .controlSize(.small)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .waiting:
            Button("Rewrite", action: model.run)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
        case .loading:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(model.slow ? "Waking up the server. The first request can take up to a minute…" : "Writing suggestions…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .done(let correction):
            // Long answers scroll inside the card, so it never runs off the screen.
            ScrollView {
                results(correction)
            }
            .frame(maxHeight: Self.maxResultsHeight)
        case .failed(let error):
            VStack(alignment: .leading, spacing: 8) {
                Text(error.message)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Try again", action: model.run)
            }
        }
    }
}

private struct Chip: View {
    let label: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .foregroundStyle(selected ? Color.white : Color.primary)
                .background(
                    selected ? Color(nsColor: .writeFlowAccent) : Color.primary.opacity(0.08),
                    in: Capsule()
                )
        }
        .buttonStyle(.plain)
    }
}

private struct SuggestionRow: View {
    let label: String
    let text: String
    let copied: Bool
    let replace: () -> Void
    let copy: () -> Void
    @State private var hovering = false

    /// Clicking anywhere on the suggestion replaces the selected text with it; Copy only copies.
    var body: some View {
        VStack(alignment: isRightToLeft ? .trailing : .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(label).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                Button(copied ? "Copied" : "Copy", action: copy)
                    .controlSize(.small)
                    .disabled(copied)
                Button("Replace", action: replace)
                    .controlSize(.small)
                    .buttonStyle(.borderedProminent)
            }
            Text(text)
                .multilineTextAlignment(isRightToLeft ? .trailing : .leading)
                .frame(maxWidth: .infinity, alignment: isRightToLeft ? .trailing : .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .background(
            hovering ? Color(nsColor: .writeFlowAccent).opacity(0.12) : Color.primary.opacity(0.05),
            in: RoundedRectangle(cornerRadius: 8)
        )
        .contentShape(RoundedRectangle(cornerRadius: 8))
        .onTapGesture(perform: replace)
        .onHover { hovering = $0 }
        .help("Click to replace the selected text")
    }

    /// Urdu, Kashmiri and Sindhi answers read right to left.
    private var isRightToLeft: Bool {
        guard let scalar = text.unicodeScalars.first(where: { CharacterSet.letters.contains($0) }) else { return false }
        return (0x0590...0x08FF).contains(scalar.value)
    }
}

private struct NoticeView: View {
    let notice: CardNotice
    let shortcut: String

    var body: some View {
        switch notice {
        case .noSelection:
            Text("Select some text in any app, then press \(shortcut). You can also copy text and choose Rewrite Clipboard Text from the W menu.")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
        case .needsAccess:
            VStack(alignment: .leading, spacing: 8) {
                Text("WriteFlow needs Accessibility access to read the text you select. It never changes text in other apps.")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Open Accessibility Settings") { SelectionReader.openAccessibilitySettings() }
                    .buttonStyle(.borderedProminent)
            }
        }
    }
}

/// The frosted background of macOS popovers.
struct VisualEffect: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .popover
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}
