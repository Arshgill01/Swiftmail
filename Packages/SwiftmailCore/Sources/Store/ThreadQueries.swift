import Foundation
import GRDB

/// One row in the thread list. Loads no bodies.
public struct ThreadSummary: Sendable, Hashable, Identifiable, FetchableRecord {
    public struct ID: Hashable, Sendable, Codable {
        public let accountID: String
        public let threadID: String

        public init(accountID: String, threadID: String) {
            self.accountID = accountID
            self.threadID = threadID
        }
    }

    public var id: ID {
        ID(accountID: accountID, threadID: threadID)
    }

    public let accountID: String
    public let threadID: String
    public let subject: String?
    public let snippet: String?
    public let lastDate: Int64
    public let participants: [EmailAddress]
    public let messageCount: Int
    public let hasAttachments: Bool
    public let isUnread: Bool
    public let isStarred: Bool
    public let isImportant: Bool
    public let labelIDs: [String]
    public let hasDraft: Bool

    public init(row: Row) {
        accountID = row["account_id"]
        threadID = row["id"]
        subject = row["subject"]
        snippet = row["snippet"]
        lastDate = row["last_date"]
        participants = EmailAddress.decodeJSON(row["participants"])
        messageCount = row["message_count"]
        hasAttachments = row["has_attachments"]
        isUnread = row["is_unread"]
        isStarred = row["is_starred"]
        isImportant = row["is_important"]
        let labels: String? = row["label_ids"]
        labelIDs = labels?.split(separator: ",").map(String.init) ?? []
        hasDraft = labelIDs.contains("DRAFT")
    }
}

public enum ThreadQueries {
    static let summaryColumns = """
    t.account_id, t.id, t.subject, t.snippet, t.last_date, t.participants, t.message_count,
    t.has_attachments, t.is_unread, t.is_starred, t.is_important,
    (SELECT group_concat(x.label_id) FROM thread_labels x WHERE x.account_id = t.account_id AND x.thread_id = t.id) AS label_ids
    """

    static let otherCategories = MailWriter.categoryLabels.map { "'\($0)'" }.joined(separator: ",")

    /// Threads in a mailbox, newest first. `category` applies to inbox mailboxes of
    /// accounts with category tabs on.
    public static func threads(
        _ db: Database, mailbox: Mailbox, category: InboxCategory? = nil, limit: Int, onlyUnread: Bool = false
    ) throws -> [ThreadSummary] {
        var sql: String
        var arguments: StatementArguments = []
        if let labelID = mailbox.labelID {
            sql = """
            SELECT \(summaryColumns) FROM thread_labels tl
            JOIN threads t ON t.account_id = tl.account_id AND t.id = tl.thread_id
            WHERE tl.label_id = ?
            """
            arguments += [labelID]
            if let accountID = mailbox.accountID {
                sql += " AND tl.account_id = ?"
                arguments += [accountID]
            }
            if mailbox.kind == .inbox, let category {
                sql += categoryFilter(category)
            }
            if onlyUnread {
                sql += " AND t.is_unread = 1"
            }
            sql += " ORDER BY tl.last_date DESC LIMIT ?"
        } else {
            // All Mail: everything except spam and trash.
            sql = "SELECT \(summaryColumns) FROM threads t WHERE 1"
            if let accountID = mailbox.accountID {
                sql += " AND t.account_id = ?"
                arguments += [accountID]
            }
            sql += """
             AND NOT EXISTS (SELECT 1 FROM thread_labels x WHERE x.account_id = t.account_id AND x.thread_id = t.id
               AND x.label_id IN ('SPAM','TRASH'))
            """
            if onlyUnread {
                sql += " AND t.is_unread = 1"
            }
            sql += " ORDER BY t.last_date DESC LIMIT ?"
        }
        arguments += [limit]
        return try ThreadSummary.fetchAll(db, sql: sql, arguments: arguments)
    }

    /// Primary is the inbox minus the other categories; it only filters accounts with tabs on.
    static func categoryFilter(_ category: InboxCategory) -> String {
        let tabsOn = "(SELECT categories_enabled FROM accounts a WHERE a.id = tl.account_id) = 1"
        if let label = category.labelID {
            return """
             AND \(tabsOn) AND EXISTS (SELECT 1 FROM thread_labels c WHERE c.account_id = tl.account_id
               AND c.thread_id = tl.thread_id AND c.label_id = '\(label)')
            """
        }
        return """
         AND (NOT \(tabsOn) OR NOT EXISTS (SELECT 1 FROM thread_labels c WHERE c.account_id = tl.account_id
           AND c.thread_id = tl.thread_id AND c.label_id IN (\(otherCategories))))
        """
    }

    /// Specific threads, e.g. search results, in the given order.
    public static func threads(_ db: Database, ids: [ThreadSummary.ID]) throws -> [ThreadSummary] {
        guard !ids.isEmpty else { return [] }
        var results: [ThreadSummary.ID: ThreadSummary] = [:]
        for chunk in stride(from: 0, to: ids.count, by: 400).map({ Array(ids[$0 ..< min($0 + 400, ids.count)]) }) {
            let pairs = chunk.map { _ in "(t.account_id = ? AND t.id = ?)" }.joined(separator: " OR ")
            let arguments = StatementArguments(chunk.flatMap { [$0.accountID, $0.threadID] })
            for summary in try ThreadSummary.fetchAll(
                db,
                sql: "SELECT \(summaryColumns) FROM threads t WHERE \(pairs)",
                arguments: arguments
            ) {
                results[summary.id] = summary
            }
        }
        return ids.compactMap { results[$0] }
    }

    /// Unread inbox thread counts per category, local. Starts from the `UNREAD` rows of
    /// `thread_labels`, so the cost follows the number of unread threads, not the inbox size.
    /// Threads without a category label count as Primary.
    public static func unreadInboxCountsByCategory(_ db: Database, accountID: String) throws -> [InboxCategory: Int] {
        let rows = try Row.fetchAll(db, sql: """
        SELECT (SELECT c.label_id FROM thread_labels c WHERE c.account_id = u.account_id AND c.thread_id = u.thread_id
                  AND c.label_id IN (\(otherCategories)) LIMIT 1) AS category, COUNT(*) AS n
        FROM thread_labels u
        WHERE u.account_id = ? AND u.label_id = 'UNREAD'
          AND EXISTS (SELECT 1 FROM thread_labels i WHERE i.account_id = u.account_id AND i.thread_id = u.thread_id AND i.label_id = 'INBOX')
        GROUP BY category
        """, arguments: [accountID])
        var counts: [InboxCategory: Int] = [:]
        for row in rows {
            let label: String? = row["category"]
            let category = InboxCategory.allCases.first { $0.labelID == label } ?? .primary
            counts[category, default: 0] += row["n"] as Int
        }
        return counts
    }

    /// Unread inbox threads for an account (or all accounts). With `primaryWhenTabsOn`,
    /// accounts with category tabs count Primary only (the Dock badge rule).
    public static func unreadInboxCount(_ db: Database, accountID: String?, primaryWhenTabsOn: Bool = false) throws -> Int {
        let accounts: [AccountRecord] = if let accountID {
            try AccountRecord.fetchOne(db, key: accountID).map { [$0] } ?? []
        } else {
            try AccountRecord.fetchAll(db)
        }
        var total = 0
        for account in accounts {
            let counts = try unreadInboxCountsByCategory(db, accountID: account.id)
            total += primaryWhenTabsOn && account.categoriesEnabled ? counts[.primary] ?? 0 : counts.values.reduce(0, +)
        }
        return total
    }

    public static func threadCount(_ db: Database, accountID: String) throws -> Int {
        try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM threads WHERE account_id = ?", arguments: [accountID]) ?? 0
    }
}
