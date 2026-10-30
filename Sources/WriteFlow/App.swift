import AppKit

@main
enum WriteFlowApp {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        // `WriteFlow --snapshot <folder>` renders the card and Settings to PNGs instead of running.
        let arguments = CommandLine.arguments
        if let index = arguments.firstIndex(of: "--snapshot"), index + 1 < arguments.count {
            Snapshots.render(into: URL(fileURLWithPath: arguments[index + 1]))
            return
        }
        if arguments.contains("--demo-card") {
            DemoCard.run()
            return
        }
        let delegate = AppDelegate()
        app.delegate = delegate
        // A menu bar app: no Dock icon and no app menu.
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }
}
