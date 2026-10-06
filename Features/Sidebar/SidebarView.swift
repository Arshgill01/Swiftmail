import SwiftmailCore
import SwiftUI

struct SidebarView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        List {
            if model.accounts.isEmpty {
                Section {
                    Button("Add Gmail Account…") { model.addAccount() }
                        .disabled(model.isSigningIn)
                }
            }
            ForEach(model.accounts) { account in
                Section {
                    AccountRow(account: account)
                } header: {
                    Text(account.email)
                }
            }
        }
        .listStyle(.sidebar)
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
