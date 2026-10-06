import Foundation
import GRDB

extension SyncEngine {
    /// History expired (404): take a fresh historyId, re-list the mailbox as metadata
    /// (keeping every downloaded body), and prune local threads that vanished on the
    /// server once the window has been re-listed. No notifications come from a resync.
    func startFullResync() async throws {
        publish(.firstSync)
        let profile = try await client.getProfile()
        let id = accountID
        try await database.writer.write { db in
            try db.execute(sql: """
            UPDATE accounts SET status = 'syncing_full', history_id = ?, backfill_cursor = NULL, backfill_done = 0 WHERE id = ?
            """, arguments: [profile.historyId, id])
            try db.execute(sql: "DELETE FROM resync_seen WHERE account_id = ?", arguments: [id])
        }
        resyncing = true
        try await syncLabelPage(labelIDs: ["INBOX"], maxResults: Self.inboxPageSize, format: .metadata)
        try await RequestPriority.$current.withValue(.background) {
            try await syncLabelPages(labelIDs: ["INBOX", "UNREAD"], limit: 1000, format: .metadata)
            try await syncLabelPages(labelIDs: ["DRAFT"], limit: 10000, format: .full)
            try await syncDraftIDs()
            try await syncLabelPage(labelIDs: ["SENT"], maxResults: 50, format: .metadata)
            try await syncLabelPages(labelIDs: ["STARRED"], limit: 500, format: .metadata)
        }
        try await publish(.backfilling(threads: database.reader.read { db in try ThreadQueries.threadCount(db, accountID: id) }))
        // The backfill (started by the session) re-lists the rest and calls `finishFullResync`.
    }

    /// Deletes local threads inside the backfill window that the re-list did not see.
    func finishFullResync() async throws {
        let id = accountID
        let cutoff = settings().backfillWindow.cutoff(from: now())?.millis ?? 0
        let pruned = try await database.writer.write { db -> Int in
            let stale = try String.fetchAll(db, sql: """
            SELECT id FROM threads WHERE account_id = ? AND last_date >= ?
              AND id NOT IN (SELECT thread_id FROM resync_seen WHERE account_id = ?)
            """, arguments: [id, cutoff, id])
            for threadID in stale {
                try MailWriter.deleteThread(db, accountID: id, threadID: threadID)
            }
            try db.execute(sql: "DELETE FROM resync_seen WHERE account_id = ?", arguments: [id])
            try db.execute(sql: "UPDATE accounts SET status = 'ok' WHERE id = ? AND status = 'syncing_full'", arguments: [id])
            return stale.count
        }
        resyncing = false
        logger.info("resync finished, pruned \(pruned) threads")
    }

    static func markSeen(_ db: Database, accountID: String, threadIDs: some Sequence<String>) throws {
        for threadID in threadIDs {
            try db.execute(sql: "INSERT OR IGNORE INTO resync_seen VALUES (?, ?)", arguments: [accountID, threadID])
        }
    }
}
