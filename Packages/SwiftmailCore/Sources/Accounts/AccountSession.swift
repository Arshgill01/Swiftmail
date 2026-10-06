import Foundation
import os

/// Everything that belongs to one signed-in account: its token provider, Gmail client,
/// sync engine and action queue. Owns the account's sync loop: one run at a time, and a
/// trigger during a run schedules exactly one more run.
public actor AccountSession {
    public nonisolated let accountID: String
    public nonisolated let tokens: TokenProvider
    public nonisolated let client: any GmailClient
    public nonisolated let database: AppDatabase
    public nonisolated let sync: SyncEngine
    public nonisolated let actions: ActionQueue

    public static let activeInterval: Duration = .seconds(30)
    public static let backgroundInterval: Duration = .seconds(120)

    private var triggers: AsyncStream<Void>.Continuation?
    private var loopTask: Task<Void, Never>?
    private var timerTask: Task<Void, Never>?
    private var backfillTask: Task<Void, Never>?
    private var isAppActive = true
    private var isPaused = false
    private(set) var runCount = 0
    private var afterRun: [@Sendable () async -> Void] = []
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
        actions = ActionQueue(accountID: accountID, client: client, database: database)
    }

    public func setSink(_ sink: SyncEventSink) async {
        await sync.setSink(sink)
    }

    /// Work to run after every sync run, e.g. draining the action queue.
    public func addAfterRun(_ work: @escaping @Sendable () async -> Void) {
        afterRun.append(work)
    }

    /// Starts the sync loop with an immediate first run.
    public func start() {
        guard loopTask == nil else { return }
        let actions = actions
        Task {
            try? await actions.recover()
            await actions.drain()
        }
        let (stream, continuation) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        triggers = continuation
        loopTask = Task {
            for await _ in stream {
                await runOnce()
            }
        }
        scheduleTimer()
        continuation.yield()
    }

    public func stop() {
        triggers?.finish()
        triggers = nil
        loopTask?.cancel()
        timerTask?.cancel()
        backfillTask?.cancel()
        loopTask = nil
        timerTask = nil
        backfillTask = nil
    }

    /// Sends queued actions now (after a local change, or when the network returns).
    public func drainActions() {
        let actions = actions
        Task { await actions.drain() }
    }

    /// Requests a sync now. Coalesces with a run in progress.
    public func triggerSync() {
        triggers?.yield()
    }

    /// 30 seconds while the app is active, 120 in the background.
    public func setAppActive(_ active: Bool) {
        guard active != isAppActive else { return }
        isAppActive = active
        scheduleTimer()
        if active {
            triggerSync()
        }
    }

    /// Pauses polling while the Mac sleeps.
    public func pause() {
        isPaused = true
        timerTask?.cancel()
        timerTask = nil
    }

    /// Resumes polling and syncs at once (wake from sleep).
    public func resume() {
        isPaused = false
        scheduleTimer()
        triggerSync()
    }

    private func scheduleTimer() {
        timerTask?.cancel()
        guard !isPaused, triggers != nil else { return }
        let interval = isAppActive ? Self.activeInterval : Self.backgroundInterval
        timerTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled else { return }
                await self?.triggerSync()
            }
        }
    }

    private func runOnce() async {
        runCount += 1
        do {
            guard let account = try await database.account(id: accountID) else { return }
            // Keep cached mail and queued actions; wait for the user to sign in again.
            guard account.status != .needsSignIn else { return }
            if !account.initialSyncDone {
                try await sync.firstSync()
            } else {
                try await sync.incrementalSync()
            }
            startBackfill()
        } catch {
            await sync.report(error)
        }
        await actions.drain()
        for work in afterRun {
            await work()
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
