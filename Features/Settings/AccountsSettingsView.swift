import SwiftmailCore
import SwiftUI

struct AccountsSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var pendingRemoval: AccountRecord?

    var body: some View {
        Form {
            if !model.isOAuthConfigured {
                Section {
                    Label(
                        "Google sign-in isn't set up yet. Add your OAuth client to Config/Secrets.xcconfig (see README) and rebuild.",
                        systemImage: "info.circle"
                    )
                    .foregroundStyle(.secondary)
                }
            }
            Section("Accounts") {
                if model.accounts.isEmpty {
                    Text("No accounts").foregroundStyle(.secondary)
                }
                ForEach(model.accounts) { account in
                    HStack {
                        AccountRow(account: account)
                        Spacer()
                        if account.status == .needsSignIn {
                            Button("Sign In") { model.addAccount() }
                        }
                        Button("Remove…") { pendingRemoval = account }
                    }
                }
            }
            Section {
                HStack {
                    Button(model.isSigningIn ? "Waiting for browser…" : "Add Gmail Account…") { model.addAccount() }
                        .disabled(model.isSigningIn || !model.isOAuthConfigured)
                    if model.isSigningIn { ProgressView().controlSize(.small) }
                }
                if let error = model.lastError {
                    Text(error).foregroundStyle(.red).font(.callout)
                }
            }
        }
        .formStyle(.grouped)
        .confirmationDialog(
            "Remove \(pendingRemoval?.email ?? "account")?",
            isPresented: Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }),
            presenting: pendingRemoval
        ) { account in
            Button("Remove Account", role: .destructive) { model.removeAccount(account.id) }
        } message: { _ in
            Text("Signs out, revokes Swiftmail's access, and deletes this account's cached mail from this Mac.")
        }
    }
}
