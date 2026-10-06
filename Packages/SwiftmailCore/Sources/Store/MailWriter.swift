import Foundation
import GRDB

/// Writes Gmail data into the store. Every function runs inside the caller's write
/// transaction, so a sync page or an action is applied atomically.
public enum MailWriter {
    public static let categoryLabels = ["CATEGORY_SOCIAL", "CATEGORY_PROMOTIONS", "CATEGORY_UPDATES", "CATEGORY_FORUMS"]

    // MARK: Labels and aliases

    public static func replaceLabels(_ db: Database, accountID: String, labels: [GmailLabel]) throws {
        let ids = labels.map(\.id)
        try db.execute(
            sql: "DELETE FROM labels WHERE account_id = ? AND id NOT IN (\(databaseQuestionMarks(count: ids.count)))",
            arguments: StatementArguments([accountID] + ids)
        )
        for label in labels {
            try labelRecord(accountID: accountID, label).save(db)
        }
    }

    public static func updateLabelCounts(_ db: Database, accountID: String, label: GmailLabel) throws {
        try db.execute(
            sql: "UPDATE labels SET threads_unread = ?, threads_total = ? WHERE account_id = ? AND id = ?",
            arguments: [label.threadsUnread ?? 0, label.threadsTotal ?? 0, accountID, label.id]
        )
    }

    static func labelRecord(accountID: String, _ label: GmailLabel) -> LabelRecord {
        var record = LabelRecord(accountId: accountID, id: label.id, name: label.name, type: label.type ?? "user")
        record.colorBg = label.color?.backgroundColor
        record.colorText = label.color?.textColor
        record.visibleInList = label.labelListVisibility != "labelHide"
        record.threadsUnread = label.threadsUnread ?? 0
        record.threadsTotal = label.threadsTotal ?? 0
        return record
    }

    public static func replaceSendAs(_ db: Database, accountID: String, aliases: [GmailSendAs]) throws {
        try db.execute(sql: "DELETE FROM send_as WHERE account_id = ?", arguments: [accountID])
        for alias in aliases where alias.verificationStatus == nil || alias.verificationStatus == "accepted" {
            try SendAsRecord(
                accountId: accountID, email: alias.sendAsEmail, displayName: alias.displayName,
                signatureHtml: alias.signature?.isEmpty == false ? alias.signature : nil,
                isDefault: alias.isDefault ?? false, isPrimary: alias.isPrimary ?? false
            ).save(db)
        }
    }

    // MARK: Threads and messages

    /// Writes every message of a thread, then recomputes the thread row.
    /// Local messages missing from a full thread response are deleted.
    @discardableResult
    public static func upsertThread(
        _ db: Database, accountID: String, thread: GmailThread, format: MessageFormat, ownAddresses: Set<String> = []
    ) throws -> [MessageChange] {
        var changes: [MessageChange] = []
        let remoteIDs = Set((thread.messages ?? []).map(\.id))
        for message in thread.messages ?? [] {
            try changes.append(upsertMessage(db, accountID: accountID, message: message, format: format, ownAddresses: ownAddresses))
        }
        let localIDs = try String.fetchAll(
            db, sql: "SELECT id FROM messages WHERE account_id = ? AND thread_id = ?", arguments: [accountID, thread.id]
        )
        for id in localIDs where !remoteIDs.contains(id) {
            try deleteMessageRow(db, accountID: accountID, messageID: id)
        }
        try recomputeThread(db, accountID: accountID, threadID: thread.id)
        return changes
    }

    public struct MessageChange: Sendable, Equatable {
        public let messageID: String
        public let threadID: String
        public let isNew: Bool
        public let labelIDs: [String]
    }

    /// Inserts or updates one message, its labels and (for `full`) its body and attachments.
    /// Call `recomputeThread` afterwards.
    @discardableResult
    public static func upsertMessage(
        _ db: Database, accountID: String, message: GmailMessage, format: MessageFormat, ownAddresses: Set<String> = []
    ) throws -> MessageChange {
        let existing = try MessageRecord.filter(Column("account_id") == accountID && Column("id") == message.id).fetchOne(db)
        let labels = message.labelIds ?? []
        let payload = message.payload
        let decoded = payload.map(MessageDecoder.decode)
        let headers = decoded?.headers ?? DecodedHeaders(payload?.headers ?? [])
        let hasHeaders = !(payload?.headers ?? []).isEmpty

        var record = existing ?? MessageRecord(
            accountId: accountID, id: message.id, threadId: message.threadId, internalDate: 0
        )
        record.threadId = message.threadId
        record.historyId = message.historyId ?? record.historyId
        if let internalDate = message.internalDate.flatMap(Int64.init) {
            record.internalDate = internalDate
        }
        if let snippet = message.snippet {
            record.snippet = HTMLEntities.decode(snippet)
        }
        if let size = message.sizeEstimate {
            record.sizeEstimate = size
        }
        if hasHeaders {
            record.fromName = headers.from?.name
            record.fromEmail = headers.from?.email
            record.toJson = EmailAddress.encodeJSON(headers.to)
            record.ccJson = EmailAddress.encodeJSON(headers.cc)
            record.bccJson = EmailAddress.encodeJSON(headers.bcc)
            record.replyTo = headers.replyTo.first?.email
            record.subject = headers.subject
            record.rfcMessageId = headers.messageID
            record.inReplyTo = headers.inReplyTo
            record.referencesHdr = headers.references
            record.listUnsubscribe = headers.listUnsubscribe
            record.listUnsubscribePost = headers.listUnsubscribePost
        }
        if message.labelIds != nil {
            record.isUnread = labels.contains("UNREAD")
            record.isDraft = labels.contains("DRAFT")
        }
        if format == .full, let decoded {
            record.hasAttachments = decoded.attachments.contains { !$0.isInline }
            record.bodyState = decoded.pendingBodyParts.isEmpty ? .ready : .none
        } else if format == .metadata, existing == nil {
            record.hasAttachments = payloadLooksLikeAttachment(payload)
        }
        if existing == nil {
            try record.insert(db)
            record.rowid = db.lastInsertedRowID
        } else {
            try record.update(db)
        }

        if message.labelIds != nil {
            try setMessageLabels(db, accountID: accountID, messageID: message.id, labels: labels)
        }
        if format == .full, let decoded {
            try writeBody(db, accountID: accountID, messageID: message.id, decoded: decoded)
        }
        try indexFTS(db, message: record)
        if existing == nil, hasHeaders {
            try recordContacts(db, accountID: accountID, headers: headers, labels: labels, date: record.internalDate, own: ownAddresses)
        }
        return MessageChange(messageID: message.id, threadID: message.threadId, isNew: existing == nil, labelIDs: labels)
    }

    /// Metadata responses only carry the top-level Content-Type; `multipart/mixed` usually
    /// means attachments.
    static func payloadLooksLikeAttachment(_ payload: GmailMessagePart?) -> Bool {
        let type = payload?.headers?.first { $0.name.caseInsensitiveCompare("Content-Type") == .orderedSame }?.value
        return type?.lowercased().hasPrefix("multipart/mixed") ?? false
    }

    static func writeBody(_ db: Database, accountID: String, messageID: String, decoded: DecodedMessage) throws {
        let previous = try MessageBodyRecord.fetchOne(db, key: ["account_id": accountID, "message_id": messageID])
        let bodyText = BodyText.extract(html: decoded.html, plain: decoded.plain)
        var body = MessageBodyRecord(
            accountId: accountID, messageId: messageID, html: decoded.html, plain: decoded.plain,
            displayHtml: nil, bodyText: bodyText, fetchedAt: Date().millis
        )
        // Sanitize once; keep the stored rendering when the source did not change.
        if let previous, previous.html == decoded.html, previous.plain == decoded.plain, previous.displayHtml != nil {
            body.displayHtml = previous.displayHtml
            body.hasRemoteContent = previous.hasRemoteContent
            body.trackerCount = previous.trackerCount
        } else {
            let rendered = BodyRenderer.render(decoded, accountID: accountID, messageID: messageID)
            body.displayHtml = rendered.html
            body.hasRemoteContent = rendered.hasRemoteContent
            body.trackerCount = rendered.trackerCount
        }
        try body.save(db)

        let existingPaths = try Row.fetchAll(
            db, sql: "SELECT part_id, local_path FROM attachments WHERE account_id = ? AND message_id = ?",
            arguments: [accountID, messageID]
        ).reduce(into: [String: String]()) { map, row in
            if let path: String = row["local_path"] {
                map[row["part_id"]] = path
            }
        }
        try db.execute(sql: "DELETE FROM attachments WHERE account_id = ? AND message_id = ?", arguments: [accountID, messageID])
        for attachment in decoded.attachments {
            try AttachmentRecord(
                accountId: accountID, messageId: messageID, partId: attachment.partID,
                attachmentId: attachment.attachmentID, filename: attachment.filename, mimeType: attachment.mimeType,
                size: attachment.size, contentId: attachment.contentID, isInline: attachment.isInline,
                localPath: existingPaths[attachment.partID]
            ).insert(db)
        }
        try InlineDataCache.store(db, accountID: accountID, messageID: messageID, attachments: decoded.attachments)
    }

    public static func setMessageLabels(_ db: Database, accountID: String, messageID: String, labels: [String]) throws {
        try db.execute(sql: "DELETE FROM message_labels WHERE account_id = ? AND message_id = ?", arguments: [accountID, messageID])
        for label in Set(labels) {
            try db.execute(sql: "INSERT INTO message_labels VALUES (?, ?, ?)", arguments: [accountID, messageID, label])
        }
        try db.execute(
            sql: "UPDATE messages SET is_unread = ?, is_draft = ? WHERE account_id = ? AND id = ?",
            arguments: [labels.contains("UNREAD"), labels.contains("DRAFT"), accountID, messageID]
        )
    }

    /// Adds and removes labels on one message. Returns its thread ID, or nil when unknown.
    @discardableResult
    public static func modifyMessageLabels(
        _ db: Database, accountID: String, messageID: String, add: [String], remove: [String]
    ) throws -> String? {
        guard let threadID = try String.fetchOne(
            db, sql: "SELECT thread_id FROM messages WHERE account_id = ? AND id = ?", arguments: [accountID, messageID]
        ) else { return nil }
        var labels = try Set(String.fetchAll(
            db, sql: "SELECT label_id FROM message_labels WHERE account_id = ? AND message_id = ?", arguments: [accountID, messageID]
        ))
        labels.subtract(remove)
        labels.formUnion(add)
        try setMessageLabels(db, accountID: accountID, messageID: messageID, labels: Array(labels))
        return threadID
    }

    /// Deletes a message and returns its thread ID. Call `recomputeThread` afterwards.
    @discardableResult
    public static func deleteMessage(_ db: Database, accountID: String, messageID: String) throws -> String? {
        let threadID = try String.fetchOne(
            db, sql: "SELECT thread_id FROM messages WHERE account_id = ? AND id = ?", arguments: [accountID, messageID]
        )
        try deleteMessageRow(db, accountID: accountID, messageID: messageID)
        return threadID
    }

    static func deleteMessageRow(_ db: Database, accountID: String, messageID: String) throws {
        if let rowid = try Int64.fetchOne(
            db,
            sql: "SELECT rowid FROM messages WHERE account_id = ? AND id = ?",
            arguments: [accountID, messageID]
        ) {
            try db.execute(sql: "DELETE FROM messages_fts WHERE rowid = ?", arguments: [rowid])
        }
        for table in ["message_labels", "message_bodies", "attachments"] {
            try db.execute(sql: "DELETE FROM \(table) WHERE account_id = ? AND message_id = ?", arguments: [accountID, messageID])
        }
        try db.execute(sql: "DELETE FROM messages WHERE account_id = ? AND id = ?", arguments: [accountID, messageID])
    }

    /// Deletes a thread and all its messages.
    public static func deleteThread(_ db: Database, accountID: String, threadID: String) throws {
        let ids = try String.fetchAll(
            db, sql: "SELECT id FROM messages WHERE account_id = ? AND thread_id = ?", arguments: [accountID, threadID]
        )
        for id in ids {
            try deleteMessageRow(db, accountID: accountID, messageID: id)
        }
        try recomputeThread(db, accountID: accountID, threadID: threadID)
    }
}
