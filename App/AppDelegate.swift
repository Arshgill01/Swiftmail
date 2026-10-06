import AppKit
import SwiftmailCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        #if DEBUG
            if CommandLine.arguments.contains("--keychain-selftest") {
                runKeychainSelfTest()
            }
            DebugSnapshot.runIfRequested()
        #endif
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// `mailto:` links open a compose window.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme?.lowercased() == "mailto" {
            AppModel.shared?.openMailto(url)
        }
    }

    /// Clicking the Dock icon with no windows reopens the main window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            AppModel.shared?.openWindowAction?(id: "main")
        }
        return true
    }

    /// Messages held for undo send go out now; wait up to 10 seconds before quitting.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model = AppModel.shared else { return .terminateNow }
        Task { @MainActor in
            let waiting = await model.sendHeldMessagesBeforeQuit()
            sender.reply(toApplicationShouldTerminate: true)
            _ = waiting
        }
        return .terminateLater
    }

    #if DEBUG
        /// Saves, reads and deletes a throwaway item, prints the result and quits.
        private func runKeychainSelfTest() {
            let store = KeychainStore()
            let account = "selftest-\(UUID().uuidString)"
            do {
                try store.save("value", account: account)
                let loaded = try store.load(account: account)
                try store.delete(account: account)
                let gone = try store.load(account: account) == nil
                print("KEYCHAIN_SELFTEST \(loaded == "value" && gone ? "OK" : "MISMATCH")")
            } catch {
                print("KEYCHAIN_SELFTEST FAILED \(error)")
            }
            NSApp.terminate(nil)
        }
    #endif
}
