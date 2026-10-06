import SwiftmailCore
import SwiftUI

@main
struct SwiftmailApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup("Swiftmail", id: "main") {
            MainWindow()
        }
        .defaultSize(width: 1200, height: 760)

        Settings {
            SettingsView()
        }
    }
}
