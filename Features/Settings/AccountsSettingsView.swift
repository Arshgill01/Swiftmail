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
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            AccountRow(account: account)
                            Spacer()
                            if account.status == .needsSignIn {
                                Button("Sign In") { model.addAccount() }
                            }
                            Button("Remove…") { pendingRemoval = account }
                        }
                        // The API can't tell whether inbox tabs are on, so it's a switch.
                        Toggle("Inbox category tabs", isOn: Binding(
                            get: { account.categoriesEnabled },
                            set: { enabled in Task { try? await model.database.setCategoriesEnabled(account.id, enabled) } }
                        ))
                        .font(.callout)
                    }
                }
            }
            Section {
                HStack {
                    Button(model.isSigningIn ? "Waiting for browser…" : "Add Gmail Account…") { model.addAccount() }
                        .disabled(model.isSigningIn || !model.isOAuthConfigured)
                    if model.isSigningIn {
                        ProgressView().controlSize(.small)
                    }
                }
                if let error = model.lastError {
                    Text(error).foregroundStyle(.red).font(.callout)
                }
            }
        }
        .formStyle(.grouped)
        .confirmationDialog(
            "Remove \(pendingRemoval?.email ?? "account")?",
            isPresented: Binding(get: { pendingRemoval != nil }, set: {
                if !$0 {
                    pendingRemoval = nil
                }
            }),
            presenting: pendingRemoval
        ) { account in
            Button("Remove Account", role: .destructive) { model.removeAccount(account.id) }
        } message: { _ in
            Text("Signs out, revokes Swiftmail's access, and deletes this account's cached mail from this Mac.")
        }
    }
}

struct AccountRow: View {
    let account: AccountRecord

    var body: some View {
        HStack(spacing: 8) {
            AvatarView(name: account.displayName ?? account.email, email: account.email, size: 20)
            VStack(alignment: .leading, spacing: 0) {
                Text(account.displayName ?? account.email)
                    .lineLimit(1)
                if account.displayName != nil {
                    Text(account.email)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if account.status == .needsSignIn {
                    Text("Needs sign-in")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}
