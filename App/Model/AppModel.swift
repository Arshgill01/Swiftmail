import AppKit
import GRDB
import os
import SwiftmailCore

/// App-wide state: the database, accounts and their sessions. One instance, shared by
/// every window.
@MainActor
@Observable
final class AppModel {
    let database: AppDatabase
    let accountManager: AccountManager
    private(set) var accounts: [AccountRecord] = []
    private(set) var isSigningIn = false
    var lastError: String?

    @ObservationIgnored private var accountsObservation: Task<Void, Never>?
    @ObservationIgnored let logger = Logger(subsystem: "app.swiftmail", category: "App")

    init(database: AppDatabase, accountManager: AccountManager) {
        self.database = database
        self.accountManager = accountManager
    }

    static func live() -> AppModel {
        let database: AppDatabase
        do {
            database = try AppDatabase.openDefault()
        } catch {
            Logger(subsystem: "app.swiftmail", category: "App")
                .fault("database open failed: \(String(describing: error), privacy: .public)")
            // Fall back to memory so the app still opens and can show the error.
            database = (try? AppDatabase.inMemory()) ?? { fatalError("SQLite unavailable") }()
        }
        let manager = AccountManager(
            database: database,
            secrets: KeychainStore(),
            config: OAuthConfig.fromBundle(),
            transport: URLSessionTransport()
        )
        return AppModel(database: database, accountManager: manager)
    }

    var isOAuthConfigured: Bool {
        OAuthConfig.fromBundle() != nil
    }

    func start() {
        observeAccounts()
        Task {
            do {
                try await accountManager.restoreSessions()
            } catch {
                logger.error("restore sessions failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    private func observeAccounts() {
        let observation = ValueObservation.tracking { db in
            try AccountRecord.order(Column("sort_order"), Column("added_at")).fetchAll(db)
        }
        let reader = database.reader
        accountsObservation = Task { [weak self] in
            do {
                for try await accounts in observation.values(in: reader) {
                    self?.accounts = accounts
                }
            } catch {
                self?.logger.error("accounts observation failed")
            }
        }
    }

    func addAccount() {
        guard !isSigningIn else { return }
        isSigningIn = true
        lastError = nil
        Task {
            defer { isSigningIn = false }
            do {
                _ = try await accountManager.signIn { url in
                    await MainActor.run { NSWorkspace.shared.open(url) }
                }
            } catch AuthError.cancelled {
                return
            } catch {
                lastError = error.localizedDescription
            }
        }
    }

    func removeAccount(_ id: String) {
        Task {
            do {
                try await accountManager.removeAccount(id)
            } catch {
                lastError = error.localizedDescription
            }
        }
    }

    func account(_ id: String) -> AccountRecord? {
        accounts.first { $0.id == id }
    }
}
