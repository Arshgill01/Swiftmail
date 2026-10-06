import SwiftmailCore
import SwiftUI

/// Non-blocking banner shown when an account's refresh token stopped working.
struct NeedsSignInBanner: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let accounts = model.accounts.filter { $0.status == .needsSignIn }
        if !accounts.isEmpty {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(message(for: accounts))
                    .lineLimit(1)
                Spacer()
                Button("Sign In") { model.addAccount() }
                    .disabled(model.isSigningIn)
            }
            .font(.callout)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.orange.opacity(0.12))
        }
    }

    private func message(for accounts: [AccountRecord]) -> String {
        if accounts.count == 1, let account = accounts.first {
            return "\(account.email) needs to sign in again. Cached mail stays available."
        }
        return "\(accounts.count) accounts need to sign in again."
    }
}
