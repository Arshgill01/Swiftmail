import Foundation
import GRDB

/// Everything the sidebar shows for one account, read in one pass.
public struct SidebarAccount: Sendable, Equatable, Identifiable {
    public var id: String {
        account.id
    }

    public let account: AccountRecord
    public let inboxUnread: Int
    public let categoryUnread: [InboxCategory: Int]
    public let systemCounts: [String: Int]
    public let userLabels: [LabelRecord]
    public let threadCount: Int
    public let hasMailInCategories: Bool
    public let ownAddresses: Set<String>
    public let allLabels: [String: LabelRecord]
}

public struct SidebarSnapshot: Sendable, Equatable {
    public let accounts: [SidebarAccount]
    public let unifiedInboxUnread: Int
    public let outboxCount: Int

    public static let empty = SidebarSnapshot(accounts: [], unifiedInboxUnread: 0, outboxCount: 0)
}

public enum SidebarQueries {
    public static func snapshot(_ db: Database) throws -> SidebarSnapshot {
        let accounts = try AccountRecord.order(Column("sort_order"), Column("added_at")).fetchAll(db)
        var result: [SidebarAccount] = []
        var unifiedUnread = 0
        for account in accounts {
            let labels = try LabelRecord.filter(Column("account_id") == account.id).fetchAll(db)
            let tabs = account.categoriesEnabled
            let categories = try ThreadQueries.unreadInboxCountsByCategory(db, accountID: account.id)
            let inboxUnread = tabs ? categories[.primary] ?? 0 : categories.values.reduce(0, +)
            unifiedUnread += inboxUnread
            var system: [String: Int] = [:]
            for label in labels where label.type == "system" {
                // Gmail shows the total for drafts and unread for the rest.
                system[label.id] = label.id == "DRAFT" ? label.threadsTotal : label.threadsUnread
            }
            let userLabels = labels
                .filter { $0.type == "user" && $0.visibleInList }
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            let categoryMail = try Int.fetchOne(db, sql: """
            SELECT COUNT(*) FROM thread_labels WHERE account_id = ? AND label_id IN ('CATEGORY_SOCIAL','CATEGORY_PROMOTIONS')
            """, arguments: [account.id]) ?? 0
            try result.append(SidebarAccount(
                account: account,
                inboxUnread: inboxUnread,
                categoryUnread: tabs ? categories : [:],
                systemCounts: system,
                userLabels: userLabels,
                threadCount: ThreadQueries.threadCount(db, accountID: account.id),
                hasMailInCategories: categoryMail > 0,
                ownAddresses: Set(String.fetchAll(
                    db, sql: "SELECT lower(email) FROM send_as WHERE account_id = ? UNION SELECT lower(?)",
                    arguments: [account.id, account.email]
                )),
                allLabels: Dictionary(labels.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            ))
        }
        let outbox = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM pending_actions WHERE kind = 'send'") ?? 0
        return SidebarSnapshot(accounts: result, unifiedInboxUnread: unifiedUnread, outboxCount: outbox)
    }
}
