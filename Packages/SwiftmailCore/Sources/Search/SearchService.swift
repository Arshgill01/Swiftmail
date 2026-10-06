import Foundation
import GRDB

/// Local full-text search over synced mail, Gmail's server search, and the merge of the two.
public enum LocalSearch {
    /// Threads matching the query, newest first.
    public static func threads(_ db: Database, query: SearchQuery, accountID: String?, limit: Int = 200) throws -> [ThreadSummary.ID] {
        guard !query.isEmpty else { return [] }
        var sql: String
        var arguments: StatementArguments = []
        if let expression = query.ftsExpression {
            sql = """
            SELECT m.account_id, m.thread_id, MAX(m.internal_date) AS newest FROM messages_fts f
            JOIN messages m ON m.rowid = f.rowid
            JOIN threads t ON t.account_id = m.account_id AND t.id = m.thread_id
            WHERE messages_fts MATCH ?
            """
            arguments += [expression]
        } else {
            sql = """
            SELECT t.account_id, t.id AS thread_id, t.last_date AS newest FROM threads t WHERE 1
            """
        }
        if let accountID {
            sql += " AND t.account_id = ?"
            arguments += [accountID]
        }
        if query.hasAttachment {
            sql += " AND t.has_attachments = 1"
        }
        if query.isUnread {
            sql += " AND t.is_unread = 1"
        }
        if query.isStarred {
            sql += " AND t.is_starred = 1"
        }
        if let label = query.label {
            sql += """
             AND EXISTS (SELECT 1 FROM thread_labels l WHERE l.account_id = t.account_id AND l.thread_id = t.id
               AND l.label_id IN (SELECT id FROM labels WHERE account_id = t.account_id AND (lower(name) = lower(?) OR lower(id) = lower(?))))
            """
            arguments += [label, label]
        }
        if query.ftsExpression != nil {
            sql += " GROUP BY m.account_id, m.thread_id"
        }
        sql += " ORDER BY newest DESC LIMIT ?"
        arguments += [limit]
        return try Row.fetchAll(db, sql: sql, arguments: arguments).map {
            ThreadSummary.ID(accountID: $0["account_id"], threadID: $0["thread_id"])
        }
    }
}

public extension SyncEngine {
    /// Gmail's server search with full query syntax. Threads that are not cached yet are
    /// fetched as metadata (user priority) so they open normally. Returns thread IDs in
    /// Gmail's order.
    func serverSearch(_ query: String, maxResults: Int = 50) async throws -> [String] {
        let list = try await client.listMessages(query: query, pageToken: nil, maxResults: maxResults)
        var threadIDs: [String] = []
        for ref in list.messages ?? [] where !threadIDs.contains(ref.threadId) {
            threadIDs.append(ref.threadId)
        }
        guard !threadIDs.isEmpty else { return [] }
        try await fetchAndWrite(refs: threadIDs.map { GmailThreadRef(id: $0, snippet: nil, historyId: nil) }, format: .metadata, skipExisting: true)
        return threadIDs
    }
}

/// Local hits first, then server-only hits, without duplicates.
public enum SearchMerge {
    public static func merge(local: [ThreadSummary.ID], server: [ThreadSummary.ID]) -> [ThreadSummary.ID] {
        var seen = Set(local)
        return local + server.filter { seen.insert($0).inserted }
    }
}
