import Foundation
import GRDB
import os

/// Syncs one account's Gmail into the store: first sync, background backfill, history
/// polling, and on-demand body fetches. Never touches the UI.
public actor SyncEngine {
    public nonisolated let accountID: String
    let client: any GmailClient
    let database: AppDatabase
    let settings: @Sendable () -> SyncSettings
    let now: @Sendable () -> Date
    var sink: SyncEventSink
    var status = SyncStatus()
    let logger = Logger(subsystem: "app.swiftmail", category: "Sync")
    let signposter = OSSignposter(subsystem: "app.swiftmail", category: "Sync")

    static let inboxPageSize = 50
    static let backfillPageSize = 100
    static let fullBodyAge: TimeInterval = 90 * 24 * 3600

    public init(
        accountID: String,
        client: any GmailClient,
        database: AppDatabase,
        settings: @escaping @Sendable () -> SyncSettings = { SyncSettings() },
        sink: SyncEventSink = SyncEventSink(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.accountID = accountID
        self.client = client
        self.database = database
        self.settings = settings
        self.sink = sink
        self.now = now
    }

    public func setSink(_ sink: SyncEventSink) {
        self.sink = sink
    }

    func publish(_ phase: SyncStatus.Phase, success: Bool = false) {
        status.phase = phase
        if success {
            status.lastSuccess = now()
        }
        sink.status(status)
    }

    public func currentStatus() -> SyncStatus {
        status
    }

    func account() async throws -> AccountRecord? {
        let id = accountID
        return try await database.reader.read { db in try AccountRecord.fetchOne(db, key: id) }
    }

    func ownAddresses() async throws -> Set<String> {
        let id = accountID
        return try await database.reader.read { db in
            var addresses = try Set(String.fetchAll(db, sql: "SELECT lower(email) FROM send_as WHERE account_id = ?", arguments: [id]))
            if let email = try String.fetchOne(db, sql: "SELECT lower(email) FROM accounts WHERE id = ?", arguments: [id]) {
                addresses.insert(email)
            }
            return addresses
        }
    }

    // MARK: First sync

    /// Steps 1 to 4 of the first sync. The backfill (steps 5 to 7) runs separately.
    public func firstSync() async throws {
        let interval = signposter.beginInterval("FirstSync")
        defer { signposter.endInterval("FirstSync", interval) }
        publish(.firstSync)

        // 1. Store the profile's historyId first, so changes during the rest are picked up.
        let profile = try await client.getProfile()
        let id = accountID
        try await database.writer.write { db in
            try db.execute(
                sql: "UPDATE accounts SET history_id = COALESCE(history_id, ?), email = ? WHERE id = ?",
                arguments: [profile.historyId, profile.emailAddress, id]
            )
        }

        // 2. Labels and send-as aliases.
        try await refreshLabelsAndAliases()

        // 3. The inbox, full format, then show it.
        try await syncLabelPage(labelIDs: ["INBOX"], maxResults: Self.inboxPageSize, format: .full)
        sink.inboxReady()

        // 4. Unread inbox (for accurate counts), drafts, sent, starred, category tabs.
        try await RequestPriority.$current.withValue(.background) {
            try await syncLabelPages(labelIDs: ["INBOX", "UNREAD"], limit: 1000, format: .metadata)
            try await syncLabelPages(labelIDs: ["DRAFT"], limit: 10000, format: .full)
            try await syncDraftIDs()
            try await syncLabelPage(labelIDs: ["SENT"], maxResults: 50, format: .metadata)
            try await syncLabelPages(labelIDs: ["STARRED"], limit: 500, format: .metadata)
            for category in InboxCategory.allCases {
                let label = category.labelID ?? "CATEGORY_PERSONAL"
                try await syncLabelPage(labelIDs: ["INBOX", label], maxResults: 50, format: .metadata)
            }
        }
        try await finishFirstSync()
        publish(.idle, success: true)
    }

    private func finishFirstSync() async throws {
        let id = accountID
        let recent = now().addingTimeInterval(-30 * 24 * 3600).millis
        try await database.writer.write { db in
            // Tabs default to on only when category labels hold recent mail.
            let categoryMail = try Int.fetchOne(db, sql: """
            SELECT COUNT(*) FROM thread_labels WHERE account_id = ? AND last_date > ?
              AND label_id IN ('CATEGORY_SOCIAL','CATEGORY_PROMOTIONS','CATEGORY_UPDATES','CATEGORY_FORUMS')
            """, arguments: [id, recent]) ?? 0
            try db.execute(
                sql: "UPDATE accounts SET initial_sync_done = 1, categories_enabled = ?, status = 'ok', last_sync_at = ? WHERE id = ?",
                arguments: [categoryMail > 0, Date().millis, id]
            )
        }
    }

    public func refreshLabelsAndAliases() async throws {
        let labels = try await client.listLabels()
        let aliases = try await client.listSendAs()
        let id = accountID
        try await database.writer.write { db in
            try MailWriter.replaceLabels(db, accountID: id, labels: labels)
            try MailWriter.replaceSendAs(db, accountID: id, aliases: aliases)
        }
    }

    /// Lists one page of threads for the labels and writes them.
    func syncLabelPage(labelIDs: [String], maxResults: Int, format: MessageFormat) async throws {
        let list = try await client.listThreads(ThreadListQuery(labelIDs: labelIDs, maxResults: maxResults))
        try await fetchAndWrite(refs: list.threads ?? [], format: format, skipExisting: false)
    }

    /// Follows pages until `limit` threads were listed.
    func syncLabelPages(labelIDs: [String], limit: Int, format: MessageFormat) async throws {
        var pageToken: String?
        var listed = 0
        repeat {
            let list = try await client.listThreads(ThreadListQuery(
                labelIDs: labelIDs, pageToken: pageToken, maxResults: min(500, limit - listed)
            ))
            let refs = list.threads ?? []
            listed += refs.count
            try await fetchAndWrite(refs: refs, format: format, skipExisting: false)
            pageToken = list.nextPageToken
        } while pageToken != nil && listed < limit
    }

    /// Fetches the threads whose local copy is missing or outdated, and writes them.
    /// Returns the threads that were written.
    @discardableResult
    func fetchAndWrite(refs: [GmailThreadRef], format: MessageFormat, skipExisting: Bool) async throws -> [GmailThread] {
        guard !refs.isEmpty else { return [] }
        let id = accountID
        let localState = try await database.reader.read { db in
            try Row.fetchAll(db, sql: """
            SELECT t.id, t.history_id,
              (SELECT COUNT(*) FROM messages m WHERE m.account_id = t.account_id AND m.thread_id = t.id AND m.body_state != 'ready') AS missing
            FROM threads t WHERE t.account_id = ? AND t.id IN (\(databaseQuestionMarks(count: refs.count)))
            """, arguments: StatementArguments([id] + refs.map(\.id))).reduce(into: [String: LocalThreadState]()) { map, row in
                map[row["id"]] = LocalThreadState(historyID: row["history_id"], missingBodies: row["missing"])
            }
        }
        let toFetch = refs.filter { ref in
            guard let state = localState[ref.id] else { return true }
            if skipExisting {
                return false
            }
            if format == .full, state.missingBodies > 0 {
                return true
            }
            return ref.historyId == nil || state.historyID != ref.historyId
        }
        guard !toFetch.isEmpty else { return [] }
        let results = try await client.getThreads(ids: toFetch.map(\.id), format: format)
        var threads: [GmailThread] = []
        for ref in toFetch {
            switch results[ref.id] {
            case let .success(thread)?:
                try await threads.append(hydrateLargeBodies(thread, format: format))
            case .failure(.notFound)?, nil:
                continue
            case let .failure(error)?:
                if error == .offline || error == .needsSignIn {
                    throw error
                }
                logger.error("thread fetch failed: \(String(describing: error), privacy: .public)")
            }
        }
        let own = try await ownAddresses()
        let knownBefore = Set(localState.keys)
        let fetched = threads
        try await database.writer.write { db in
            for thread in fetched {
                // A thread that became local while this fetch was in flight is newer than our copy.
                if skipExisting, !knownBefore.contains(thread.id),
                   try Bool.fetchOne(db, sql: "SELECT 1 FROM threads WHERE account_id = ? AND id = ?", arguments: [id, thread.id]) == true {
                    continue
                }
                try MailWriter.upsertThread(db, accountID: id, thread: thread, format: format, ownAddresses: own)
            }
        }
        return threads
    }
}

struct LocalThreadState: Sendable {
    let historyID: String?
    let missingBodies: Int
}
