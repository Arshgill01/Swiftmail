import Foundation
import os

/// Everything that belongs to one signed-in account: its token provider, Gmail client,
/// sync engine and (from M5) action queue. Owns the account's background tasks.
public actor AccountSession {
    public nonisolated let accountID: String
    public nonisolated let tokens: TokenProvider
    public nonisolated let client: any GmailClient
    public nonisolated let database: AppDatabase
    public nonisolated let sync: SyncEngine

    private var bootstrapTask: Task<Void, Never>?
    private var backfillTask: Task<Void, Never>?
    private let logger = Logger(subsystem: "app.swiftmail", category: "Session")

    public init(
        accountID: String,
        tokens: TokenProvider,
        client: any GmailClient,
        database: AppDatabase,
        settings: @escaping @Sendable () -> SyncSettings = { SyncSettings() }
    ) {
        self.accountID = accountID
        self.tokens = tokens
        self.client = client
        self.database = database
        sync = SyncEngine(accountID: accountID, client: client, database: database, settings: settings)
    }

    public func setSink(_ sink: SyncEventSink) async {
        await sync.setSink(sink)
    }

    /// Runs the first sync if it never finished, then resumes the backfill.
    public func start() {
        guard bootstrapTask == nil else { return }
        bootstrapTask = Task { await bootstrap() }
    }

    public func stop() {
        bootstrapTask?.cancel()
        backfillTask?.cancel()
        bootstrapTask = nil
        backfillTask = nil
    }

    private func bootstrap() async {
        do {
            guard let account = try await database.account(id: accountID) else { return }
            if !account.initialSyncDone {
                try await sync.firstSync()
            }
            startBackfill()
        } catch {
            await sync.report(error)
            // Let a later trigger retry the bootstrap.
            bootstrapTask = nil
        }
    }

    /// Starts or resumes the backfill if it is not running.
    public func startBackfill() {
        guard backfillTask == nil else { return }
        backfillTask = Task {
            do {
                try await sync.backfill()
            } catch {
                await sync.report(error)
            }
            backfillFinished()
        }
    }

    private func backfillFinished() {
        backfillTask = nil
    }
}

public extension SyncEngine {
    /// Maps an error to the status the sidebar footer shows.
    func report(_ error: Error) {
        switch error {
        case GmailError.offline, GmailError.timedOut:
            publish(.offline)
        case GmailError.needsSignIn, AuthError.needsSignIn:
            publish(.needsSignIn)
        case is CancellationError:
            break
        default:
            logger.error("sync error: \(String(describing: error), privacy: .public)")
            publish(.error((error as? LocalizedError)?.errorDescription ?? "Sync failed"))
        }
    }
}
