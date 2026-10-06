import AppKit
import GRDB
import os
import SwiftmailCore

/// App-wide state shared by every window: the database, accounts, their sessions,
/// sync status and the sidebar snapshot.
@MainActor
@Observable
final class AppModel {
    let database: AppDatabase
    let accountManager: AccountManager
    private(set) var accounts: [AccountRecord] = []
    private(set) var sidebar = SidebarSnapshot.empty
    private(set) var syncStatus: [String: SyncStatus] = [:]
    private(set) var isSigningIn = false
    var lastError: String?

    @ObservationIgnored private var observations: [Task<Void, Never>] = []
    @ObservationIgnored private var startedSessions: Set<String> = []
    @ObservationIgnored let triggers: SyncTriggers
    @ObservationIgnored let readerServices: ReaderServices
    let undo = UndoCenter()
    @ObservationIgnored let keyboard = KeyboardShortcuts()
    @ObservationIgnored let logger = Logger(subsystem: "app.swiftmail", category: "App")

    init(database: AppDatabase, accountManager: AccountManager) {
        self.database = database
        self.accountManager = accountManager
        triggers = SyncTriggers { await accountManager.allSessions() }
        readerServices = ReaderServices { accountID, messageID, contentID in
            guard let session = await accountManager.session(for: accountID) else { throw GmailError.notFound }
            return try await AttachmentLoader(database: database, client: session.client)
                .inlineImage(accountID: accountID, messageID: messageID, contentID: contentID)
        }
    }

    static func live() -> AppModel {
        Preferences.registerDefaults()
        let database: AppDatabase
        do {
            database = try AppDatabase.openDefault(fileName: AppModel.databaseFileName)
        } catch {
            Logger(subsystem: "app.swiftmail", category: "App").fault("database open failed: \(String(describing: error), privacy: .public)")
            // Fall back to memory so the app still opens and can show the error.
            database = (try? AppDatabase.inMemory()) ?? { fatalError("SQLite unavailable") }()
        }
        let manager = AccountManager(
            database: database,
            secrets: KeychainStore(),
            config: OAuthConfig.fromBundle(),
            transport: URLSessionTransport(),
            syncSettings: { Preferences.syncSettings }
        )
        return AppModel(database: database, accountManager: manager)
    }

    var isOAuthConfigured: Bool {
        OAuthConfig.fromBundle() != nil
    }

    /// Debug builds accept `--database <file>` to open another store, e.g. the synthetic
    /// `Preview.sqlite` from `scripts/preview-db.sh`.
    static var databaseFileName: String {
        #if DEBUG
            let arguments = CommandLine.arguments
            if let index = arguments.firstIndex(of: "--database"), index + 1 < arguments.count {
                return arguments[index + 1]
            }
        #endif
        return "Mail.sqlite"
    }

    func start() {
        observeAccounts()
        observeSidebar()
        triggers.start()
        readerServices.prewarm()
        keyboard.install()
        Task {
            do {
                for session in try await accountManager.restoreSessions() {
                    await startSession(session)
                }
            } catch {
                logger.error("restore sessions failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    // MARK: Observation

    private func observeAccounts() {
        let observation = ValueObservation.tracking { db in
            try AccountRecord.order(Column("sort_order"), Column("added_at")).fetchAll(db)
        }
        let reader = database.reader
        observations.append(Task { [weak self] in
            do {
                for try await accounts in observation.values(in: reader) {
                    self?.accounts = accounts
                }
            } catch {
                self?.logger.error("accounts observation failed")
            }
        })
    }

    private func observeSidebar() {
        let observation = ValueObservation.tracking(SidebarQueries.snapshot).removeDuplicates()
        let reader = database.reader
        observations.append(Task { [weak self] in
            do {
                for try await snapshot in observation.values(in: reader) {
                    self?.sidebar = snapshot
                }
            } catch {
                self?.logger.error("sidebar observation failed")
            }
        })
    }

    // MARK: Sessions

    func session(for accountID: String) async -> AccountSession? {
        await accountManager.session(for: accountID)
    }

    private func startSession(_ session: AccountSession) async {
        let id = session.accountID
        guard startedSessions.insert(id).inserted else { return }
        let sink = SyncEventSink(status: { status in
            Task { @MainActor [weak self] in self?.syncStatus[id] = status }
        })
        await session.setSink(sink)
        await configureActions(session)
        await session.start()
    }

    // MARK: Accounts

    func addAccount() {
        guard !isSigningIn else { return }
        isSigningIn = true
        lastError = nil
        Task {
            defer { isSigningIn = false }
            do {
                let account = try await accountManager.signIn { url in
                    await MainActor.run { NSWorkspace.shared.open(url) }
                }
                if let session = await accountManager.session(for: account.id) {
                    await startSession(session)
                }
            } catch AuthError.cancelled {
                return
            } catch {
                lastError = error.localizedDescription
            }
        }
    }

    func removeAccount(_ id: String) {
        startedSessions.remove(id)
        syncStatus[id] = nil
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

    func sidebarAccount(_ id: String) -> SidebarAccount? {
        sidebar.accounts.first { $0.id == id }
    }

    /// Stable color per account, by its position.
    func accountColorIndex(_ id: String) -> Int {
        accounts.firstIndex { $0.id == id } ?? 0
    }
}
