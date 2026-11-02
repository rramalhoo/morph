import AppKit

@main
enum MorphMain {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        // Unit tests run hosted in this binary and must not bring up the overlay.
        let isTesting = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        let delegate: AppDelegate? = isTesting ? nil : AppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) {
            app.run()
        }
    }
}
