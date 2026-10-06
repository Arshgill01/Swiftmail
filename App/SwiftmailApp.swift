import SwiftmailCore
import SwiftUI

@main
struct SwiftmailApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model: AppModel

    init() {
        let model = AppModel.live()
        _model = State(initialValue: model)
        model.start()
    }

    var body: some Scene {
        WindowGroup("Swiftmail", id: "main") {
            MainWindow()
                .environment(model)
        }
        .defaultSize(width: 1200, height: 760)
        .commands { MailCommands(app: model) }

        WindowGroup("New Message", id: "compose", for: UUID.self) { $id in
            ComposeWindow(id: id)
                .environment(model)
        }
        .defaultSize(width: 720, height: 600)
        .commandsRemoved()

        Settings {
            SettingsView()
                .environment(model)
        }
    }
}
