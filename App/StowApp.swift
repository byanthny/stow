import AppKit

@main
struct StowApp {
    @MainActor static func main() {
        LaunchMetrics.begin()
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.regular)
        application.run()
        withExtendedLifetime(delegate) {}
    }
}
