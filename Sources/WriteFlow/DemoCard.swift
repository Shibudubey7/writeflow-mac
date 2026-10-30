import AppKit
import WriteFlowCore

/// `WriteFlow --demo-card`: opens the real card near the bottom of the screen with an error and then
/// with results, prints where it ended up, and quits. Checks the card stays on screen.
@MainActor
enum DemoCard {
    static func run() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let defaults = UserDefaults(suiteName: "WriteFlowDemo")!
        let settings = SettingsStore(defaults: defaults, keychain: Keychain(service: "WriteFlowDemo", account: "none"))
        settings.askFirst = true // nothing is sent
        let controller = CardController(settings: settings, client: APIClient())
        let visible = NSScreen.main!.visibleFrame
        print("screen visible:", visible)
        controller.show(text: "kya hal chal bhai", at: NSPoint(x: visible.minX + 300, y: visible.minY + 60))
        report("opened", controller, visible)

        Task {
            try? await Task.sleep(nanoseconds: 700_000_000)
            controller.debugState.model?.debugShow(.failed(WriteFlowError(code: "NETWORK", message: "Can't reach the WriteFlow server at https://writeflow-api-gcd5.onrender.com. Check your internet connection.")))
            try? await Task.sleep(nanoseconds: 700_000_000)
            report("error", controller, visible)
            controller.debugState.model?.debugShow(.done(Correction(
                detectedLanguage: "hi-Latn", targetLanguage: "en",
                suggestions: ["grammar": "Hey, how's everything going, brother?", "casual": "Hey bro, what's up?", "professional": "Hello, how are you doing?"],
                explanation: "Translated from Hinglish into English."
            )))
            try? await Task.sleep(nanoseconds: 700_000_000)
            report("results", controller, visible)
            controller.close()
            exit(0)
        }
        app.run()
    }

    private static func report(_ label: String, _ controller: CardController, _ visible: NSRect) {
        guard let frame = controller.debugState.frame else { return print(label, "no panel") }
        let inside = frame.minY >= visible.minY && frame.maxY <= visible.maxY
        let content = controller.debugState.model.map { _ in "" } ?? ""
        print(label, "frame:", frame, inside ? "inside screen" : "OUTSIDE screen", content)
    }
}
