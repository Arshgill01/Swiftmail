import SwiftmailCore
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            Tab("General", systemImage: "gearshape") { GeneralSettingsView() }
            Tab("Accounts", systemImage: "at") { AccountsSettingsView() }
            Tab("Notifications", systemImage: "bell.badge") { NotificationSettingsView() }
        }
        .frame(width: 580, height: 460)
    }
}

struct GeneralSettingsView: View {
    @Environment(AppModel.self) private var model
    @AppStorage(Preferences.undoSendDelay) private var undoSendDelay = 10
    @AppStorage(Preferences.loadRemoteImages) private var loadRemoteImages = false
    @AppStorage(Preferences.dockBadge) private var dockBadge = true
    @AppStorage(Preferences.listDensity) private var density = ListDensity.comfortable.rawValue
    @AppStorage(Preferences.readerFontSize) private var fontSize = 14.0
    @AppStorage(Preferences.backfillWindow) private var backfillWindow = BackfillWindow.oneYear.rawValue
    @State private var isDefaultMailApp = false

    var body: some View {
        Form {
            Section {
                HStack {
                    Text(isDefaultMailApp ? "Swiftmail is your default mail app." : "Open mailto: links in Swiftmail.")
                    Spacer()
                    Button("Make Swiftmail the Default Mail App") { makeDefault() }
                        .disabled(isDefaultMailApp)
                }
            }
            Section("Sending") {
                Picker("Undo send", selection: $undoSendDelay) {
                    ForEach([5, 10, 20, 30], id: \.self) { Text("\($0) seconds").tag($0) }
                }
            }
            Section("Reading") {
                Picker("List density", selection: $density) {
                    Text("Comfortable").tag(ListDensity.comfortable.rawValue)
                    Text("Compact").tag(ListDensity.compact.rawValue)
                }
                Stepper("Message text size: \(Int(fontSize)) pt", value: $fontSize, in: 10 ... 28)
                Toggle("Load remote images in all messages", isOn: $loadRemoteImages)
                Text("Tracking pixels are never loaded.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Dock") {
                Toggle("Show unread count on the Dock icon", isOn: $dockBadge)
                    .onChange(of: dockBadge) { model.notifications.updateBadge(unread: model.sidebar.unifiedInboxUnread) }
            }
            Section("Offline mail") {
                Picker("Download mail from the last", selection: $backfillWindow) {
                    ForEach(BackfillWindow.allCases, id: \.rawValue) { Text($0.title).tag($0.rawValue) }
                }
                .onChange(of: backfillWindow) { model.restartBackfill() }
                Text("Older mail stays reachable through search and by scrolling to the end of a list. "
                    + "“Everything” can take hours on a large mailbox.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .task { refreshDefault() }
    }

    private func refreshDefault() {
        guard let url = URL(string: "mailto:test@example.com"),
              let handler = NSWorkspace.shared.urlForApplication(toOpen: url) else { return }
        isDefaultMailApp = Bundle(url: handler)?.bundleIdentifier == Bundle.main.bundleIdentifier
    }

    private func makeDefault() {
        NSWorkspace.shared.setDefaultApplication(at: Bundle.main.bundleURL, toOpenURLsWithScheme: "mailto") { _ in
            Task { @MainActor in refreshDefault() }
        }
    }
}

struct NotificationSettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            if model.accounts.isEmpty {
                Text("No accounts").foregroundStyle(.secondary)
            }
            ForEach(model.accounts) { account in
                Section(account.email) {
                    Toggle("Notify for new mail", isOn: setting(Preferences.notificationsEnabled, account.id))
                    Picker("Notify for", selection: setting(Preferences.notifyPrimaryOnly, account.id)) {
                        Text("Primary only").tag(true)
                        Text("All inbox mail").tag(false)
                    }
                    .disabled(!account.categoriesEnabled)
                }
            }
            Section {
                Button("Open System Notification Settings…") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func setting(_ key: String, _ accountID: String) -> Binding<Bool> {
        let full = Preferences.accountKey(key, accountID)
        return Binding(
            get: { UserDefaults.standard.object(forKey: full) as? Bool ?? true },
            set: { UserDefaults.standard.set($0, forKey: full) }
        )
    }
}
