import SwiftmailCore
import SwiftUI

/// Menu bar commands. They act on the focused main window, through the same commands as
/// the single-key shortcuts and the toolbar.
struct MailCommands: Commands {
    @FocusedValue(\.mainWindow) private var window
    let app: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Message") { window?.perform(.compose) ?? app.handleComposeOrSearch(.compose, window: MainWindowModel()) }
                .keyboardShortcut("n")
            Button("New Window") { openWindow(id: "main") }
                .keyboardShortcut("n", modifiers: [.command, .option])
        }
        CommandGroup(replacing: .undoRedo) {
            Button("Undo") {
                // Text fields keep their own undo.
                if NSApp.keyWindow?.firstResponder is NSText {
                    NSApp.sendAction(Selector(("undo:")), to: nil, from: nil)
                } else {
                    app.undoLast()
                }
            }
            .keyboardShortcut("z")
            Button("Redo") { NSApp.sendAction(Selector(("redo:")), to: nil, from: nil) }
                .keyboardShortcut("z", modifiers: [.command, .shift])
        }
        CommandMenu("Message") {
            item("Reply", .reply, "r")
            item("Reply All", .replyAll, "r", [.command, .shift])
            item("Forward", .forward, "f", [.command, .shift])
            Divider()
            item("Archive", .archive, "e")
            item("Move to Trash", .trash, .delete)
            item("Report Spam", .spam)
            Divider()
            item("Star", .toggleStar, "l")
            item("Mark as Read/Unread", .toggleRead, "u", [.command, .shift])
            item("Mark as Important", .markImportant)
            item("Mark as Not Important", .markNotImportant)
            Divider()
            item("Label…", .labelPicker, "l", [.command, .shift])
            item("Move to…", .movePicker)
            Divider()
            item("Expand All Messages", .expandAll)
        }
        CommandMenu("Go") {
            item("Inbox", .goInbox, "1")
            item("Starred", .goStarred, "2")
            item("Sent", .goSent, "3")
            item("Drafts", .goDrafts, "4")
            item("All Mail", .goAllMail, "5")
            item("Label…", .goLabel)
            Divider()
            item("Next Thread", .nextThread)
            item("Previous Thread", .previousThread)
            Divider()
            item("Search", .search, "f", [.command, .option])
        }
        CommandGroup(after: .textFormatting) {
            Button("Bigger Message Text") { adjustFontSize(by: 1) }.keyboardShortcut("+")
            Button("Smaller Message Text") { adjustFontSize(by: -1) }.keyboardShortcut("-")
            Button("Actual Size") { UserDefaults.standard.set(14.0, forKey: Preferences.readerFontSize) }.keyboardShortcut("0")
        }
        CommandGroup(replacing: .help) {
            item("Keyboard Shortcuts", .showHelp, "/", [.command, .shift])
        }
    }

    private func item(_ title: String, _ command: MailCommand, _ key: KeyEquivalent? = nil, _ modifiers: EventModifiers = .command) -> some View {
        Button(title) { window?.perform(command) }
            .keyboardShortcut(key.map { KeyboardShortcut($0, modifiers: modifiers) })
            .disabled(window == nil)
    }

    private func adjustFontSize(by delta: Double) {
        let current = UserDefaults.standard.double(forKey: Preferences.readerFontSize)
        UserDefaults.standard.set(min(max((current == 0 ? 14 : current) + delta, 10), 28), forKey: Preferences.readerFontSize)
    }
}
