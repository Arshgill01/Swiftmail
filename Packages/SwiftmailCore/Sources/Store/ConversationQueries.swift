import Foundation
import GRDB

public struct ConversationMessage: Sendable, Equatable, Identifiable {
    public var id: String {
        message.id
    }

    public let message: MessageRecord
    public let body: MessageBodyRecord?
    public let attachments: [AttachmentRecord]
    public let labelIDs: Set<String>

    public var from: EmailAddress {
        EmailAddress(name: message.fromName, email: message.fromEmail ?? "")
    }

    public var to: [EmailAddress] {
        EmailAddress.decodeJSON(message.toJson)
    }

    public var cc: [EmailAddress] {
        EmailAddress.decodeJSON(message.ccJson)
    }

    public var bcc: [EmailAddress] {
        EmailAddress.decodeJSON(message.bccJson)
    }

    public var isUnread: Bool {
        labelIDs.contains("UNREAD")
    }

    public var visibleAttachments: [AttachmentRecord] {
        attachments.filter { !$0.isInline }
    }
}

public struct Conversation: Sendable, Equatable {
    public let thread: ThreadRecord
    public let labelIDs: Set<String>
    public let messages: [ConversationMessage]
}

public enum ConversationQueries {
    /// The thread with its messages oldest first, bodies and attachments included.
    public static func conversation(_ db: Database, accountID: String, threadID: String) throws -> Conversation? {
        guard let thread = try ThreadRecord.fetchOne(db, key: ["account_id": accountID, "id": threadID]) else { return nil }
        let messages = try MessageRecord
            .filter(Column("account_id") == accountID && Column("thread_id") == threadID)
            .order(Column("internal_date"))
            .fetchAll(db)
        let ids = messages.map(\.id)
        let placeholders = databaseQuestionMarks(count: ids.count)
        let arguments = StatementArguments([accountID] + ids)
        let bodies = try MessageBodyRecord.fetchAll(
            db, sql: "SELECT * FROM message_bodies WHERE account_id = ? AND message_id IN (\(placeholders))", arguments: arguments
        )
        let attachments = try AttachmentRecord.fetchAll(
            db, sql: "SELECT * FROM attachments WHERE account_id = ? AND message_id IN (\(placeholders)) ORDER BY part_id", arguments: arguments
        )
        var labels: [String: Set<String>] = [:]
        for row in try Row.fetchAll(
            db, sql: "SELECT message_id, label_id FROM message_labels WHERE account_id = ? AND message_id IN (\(placeholders))", arguments: arguments
        ) {
            labels[row["message_id"], default: []].insert(row["label_id"])
        }
        let bodyByID = Dictionary(bodies.map { ($0.messageId, $0) }, uniquingKeysWith: { first, _ in first })
        let attachmentsByID = Dictionary(grouping: attachments, by: \.messageId)
        let threadLabels = try Set(String.fetchAll(
            db, sql: "SELECT label_id FROM thread_labels WHERE account_id = ? AND thread_id = ?", arguments: [accountID, threadID]
        ))
        return Conversation(
            thread: thread,
            labelIDs: threadLabels,
            messages: messages.map {
                ConversationMessage(message: $0, body: bodyByID[$0.id], attachments: attachmentsByID[$0.id] ?? [], labelIDs: labels[$0.id] ?? [])
            }
        )
    }

    /// Whether remote images are always allowed for this sender or their domain.
    public static func isRemoteContentAllowed(_ db: Database, accountID: String, sender: String) throws -> Bool {
        let address = sender.lowercased()
        let domain = address.split(separator: "@").last.map { "@" + $0 } ?? address
        return try Bool.fetchOne(
            db, sql: "SELECT 1 FROM remote_content_allow WHERE account_id = ? AND sender IN (?, ?)", arguments: [accountID, address, domain]
        ) ?? false
    }

    public static func allowRemoteContent(_ db: Database, accountID: String, sender: String) throws {
        try db.execute(sql: "INSERT OR IGNORE INTO remote_content_allow VALUES (?, ?)", arguments: [accountID, sender.lowercased()])
    }
}
