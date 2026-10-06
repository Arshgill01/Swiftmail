import AppKit
import SwiftmailCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        #if DEBUG
            if CommandLine.arguments.contains("--keychain-selftest") {
                runKeychainSelfTest()
            }
        #endif
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
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
