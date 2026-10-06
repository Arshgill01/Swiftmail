import Foundation
import GRDB

/// One notification to post.
public struct MailNotification: Sendable, Equatable {
    public let identifier: String
    public let threadIdentifier: String
    public let accountID: String
    public let threadID: String
    public let title: String
    public let subtitle: String
    public let body: String
}

public enum NotificationPlan: Sendable, Equatable {
    case none
    case messages([MailNotification])
    /// More than 10 new messages in one sync: one "12 new messages" summary.
    case summary(accountID: String, count: Int)
}

/// Which new mail deserves a notification: new in this sync, in the inbox and unread,
/// Primary only when tabs are on (unless the account wants all inbox mail), and not from
/// one of your own addresses.
public enum NotificationPolicy {
    public static let summaryThreshold = 10

    public struct AccountSettings: Sendable {
        public var enabled: Bool
        public var primaryOnly: Bool

        public init(enabled: Bool = true, primaryOnly: Bool = true) {
            self.enabled = enabled
            self.primaryOnly = primaryOnly
        }
    }

    public static func plan(_ items: [NewMailItem], db: Database, settings: (String) -> AccountSettings) throws -> NotificationPlan {
        var notifications: [MailNotification] = []
        for item in items {
            let accountSettings = settings(item.accountID)
            guard accountSettings.enabled else { continue }
            guard let account = try AccountRecord.fetchOne(db, key: item.accountID) else { continue }
            // Labels as they are now: read or archived elsewhere means no notification.
            let labels = try Set(String.fetchAll(
                db, sql: "SELECT label_id FROM message_labels WHERE account_id = ? AND message_id = ?", arguments: [item.accountID, item.messageID]
            ))
            guard labels.contains("INBOX"), labels.contains("UNREAD"), !labels.contains("DRAFT") else { continue }
            if account.categoriesEnabled, accountSettings.primaryOnly,
               !labels.isDisjoint(with: MailWriter.categoryLabels) {
                continue
            }
            guard let message = try MessageRecord.filter(Column("account_id") == item.accountID && Column("id") == item.messageID).fetchOne(db)
            else { continue }
            let own = try Set(String.fetchAll(db, sql: "SELECT lower(email) FROM send_as WHERE account_id = ?", arguments: [item.accountID]))
                .union([account.email.lowercased()])
            if let from = message.fromEmail?.lowercased(), own.contains(from) {
                continue
            }
            notifications.append(MailNotification(
                identifier: identifier(accountID: item.accountID, messageID: item.messageID),
                threadIdentifier: threadIdentifier(accountID: item.accountID, threadID: item.threadID),
                accountID: item.accountID,
                threadID: item.threadID,
                title: message.fromName ?? message.fromEmail ?? "New message",
                subtitle: message.subject?.isEmpty == false ? message.subject ?? "" : "(no subject)",
                body: message.snippet ?? ""
            ))
        }
        if notifications.isEmpty {
            return .none
        }
        if notifications.count > summaryThreshold, let first = notifications.first {
            return .summary(accountID: first.accountID, count: notifications.count)
        }
        return .messages(notifications)
    }

    public static func identifier(accountID: String, messageID: String) -> String {
        "\(accountID):\(messageID)"
    }

    public static func threadIdentifier(accountID: String, threadID: String) -> String {
        "\(accountID):\(threadID)"
    }
}
