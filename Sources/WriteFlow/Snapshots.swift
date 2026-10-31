import AppKit
import SwiftUI
import WriteFlowCore

/// Renders the card in its main states, Settings and the menu bar icons to PNGs, for checking the
/// layout and for the README. Uses throwaway settings, so nothing the user saved changes.
@MainActor
enum Snapshots {
    static func render(into folder: URL) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let defaults = UserDefaults(suiteName: "WriteFlowSnapshots")!
        defaults.removePersistentDomain(forName: "WriteFlowSnapshots")
        let settings = SettingsStore(defaults: defaults, keychain: Keychain(service: "WriteFlowSnapshots", account: "none"))
        let client = APIClient()
        let text = "hey can u send me the report by tmrw, i didnt got it yet and boss is asking"

        let results = CardModel(text: text, notice: nil, settings: settings, client: client)
        results.debugShow(.done(Correction(
            detectedLanguage: "en", targetLanguage: "en",
            suggestions: [
                "grammar": "Hey, can you send me the report by tomorrow? I didn't get it yet, and the boss is asking.",
                "casual": "Hey, could you send me the report by tomorrow? Still haven't got it and the boss is asking.",
                "professional": "Hello, could you please send me the report by tomorrow? I haven't received it yet, and my manager is asking for it.",
            ],
            explanation: "Fixed spelling, grammar and punctuation; adjusted the tone for each style."
        )))
        save(CardView(model: results), "card-results", into: folder)

        settings.targetLanguage = "mr"
        settings.romanized = true
        let marathi = CardModel(text: "How are you? I will come to the office tomorrow.", notice: nil, settings: settings, client: client)
        marathi.debugShow(.done(Correction(
            detectedLanguage: "en", targetLanguage: "mr-Latn",
            suggestions: ["grammar": "Tumhi kase aahat? Mi udya office la yein.", "casual": "Kasa aahes? Udya office la yeto.", "professional": "Aapan kase aahat? Mi udya karyalayat yein."],
            explanation: "Translated into Marathi written in Roman letters."
        )))
        save(CardView(model: marathi), "card-marathi", into: folder)

        let loading = CardModel(text: text, notice: nil, settings: settings, client: client)
        loading.debugShow(.loading, slow: true)
        save(CardView(model: loading), "card-loading", into: folder)

        save(CardView(model: CardModel(text: "", notice: .needsAccess, settings: settings, client: client)), "card-access", into: folder)
        let long = String(repeating: "This is a long paragraph that keeps going so the card has to scroll. ", count: 12)
        let longCard = CardModel(text: long, notice: nil, settings: settings, client: client)
        longCard.debugShow(.done(Correction(
            detectedLanguage: "en", targetLanguage: "en",
            suggestions: ["grammar": long, "casual": long, "professional": long],
            explanation: "Long answer."
        )))
        save(CardView(model: longCard), "card-long", into: folder)

        save(SettingsView(settings: settings, client: client), "settings", into: folder, size: NSSize(width: 500, height: 640))

        let sample = { (value: Int) in BubbleScore.value(Score(score: value, scores: ["grammar": value, "casual": value])) }
        for (name, score) in [("bubble-plain", BubbleScore.none), ("bubble-pending", .pending), ("bubble-50", sample(50)), ("bubble-70", sample(70)), ("bubble-92", sample(92))] {
            let view = BubbleView(frame: NSRect(x: 0, y: 0, width: score == .none ? 28 : 60, height: 28))
            view.score = score
            let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = view
            if let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: folder.appendingPathComponent("\(name).png"))
            }
        }

        for on in [true, false] {
            let image = StatusIcon.image(on: on)
            let big = NSImage(size: NSSize(width: 72, height: 72), flipped: false) { rect in
                NSColor.white.setFill()
                rect.fill()
                image.draw(in: rect)
                return true
            }
            write(big, to: folder.appendingPathComponent("menubar-\(on ? "on" : "off").png"))
        }
        print("Snapshots in \(folder.path)")
    }

    private static func save<V: View>(_ view: V, _ name: String, into folder: URL, size: NSSize? = nil) {
        let hosting = NSHostingView(rootView: view.environment(\.colorScheme, .light))
        hosting.frame.size = size ?? hosting.fittingSize
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.backgroundColor = .windowBackgroundColor
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        if let data = rep.representation(using: .png, properties: [:]) {
            try? data.write(to: folder.appendingPathComponent("\(name).png"))
        }
    }

    private static func write(_ image: NSImage, to url: URL) {
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let data = rep.representation(using: .png, properties: [:]) else { return }
        try? data.write(to: url)
    }
}
