import Foundation
import GRDB

extension MailWriter {
    /// Recomputes a thread row and its `thread_labels` (the union of its messages'
    /// labels) from the local messages. Deletes the thread when it has none left.
    public static func recomputeThread(_ db: Database, accountID: String, threadID: String) throws {
        let messages = try MessageRecord
            .filter(Column("account_id") == accountID && Column("thread_id") == threadID)
            .order(Column("internal_date"))
            .fetchAll(db)
        try db.execute(sql: "DELETE FROM thread_labels WHERE account_id = ? AND thread_id = ?", arguments: [accountID, threadID])
        guard !messages.isEmpty else {
            try db.execute(sql: "DELETE FROM threads WHERE account_id = ? AND id = ?", arguments: [accountID, threadID])
            return
        }
        // By primary key: a join on thread_id lets SQLite pick a full scan of message_labels.
        let ids = messages.map(\.id)
        let labelRows = try Row.fetchAll(db, sql: """
        SELECT message_id, label_id FROM message_labels
        WHERE account_id = ? AND message_id IN (\(databaseQuestionMarks(count: ids.count)))
        """, arguments: StatementArguments([accountID] + ids))
        var labelsByMessage: [String: Set<String>] = [:]
        for row in labelRows {
            labelsByMessage[row["message_id"], default: []].insert(row["label_id"])
        }
        // Gmail keeps trashed and spam messages out of every other view: other labels come
        // only from messages that are in neither.
        var union = Set<String>()
        for labels in labelsByMessage.values {
            if labels.contains("TRASH") || labels.contains("SPAM") {
                union.formUnion(labels.intersection(["TRASH", "SPAM", "UNREAD"]))
            } else {
                union.formUnion(labels)
            }
        }

        // Drafts only count when the thread has nothing else.
        let sent = messages.filter { !$0.isDraft }
        let base = sent.isEmpty ? messages : sent
        let lastDate = base.map(\.internalDate).max() ?? 0
        var seen = Set<String>()
        var participants: [EmailAddress] = []
        for message in base {
            guard let email = message.fromEmail, seen.insert(email.lowercased()).inserted else { continue }
            participants.append(EmailAddress(name: message.fromName, email: email))
        }
        let participantsJSON = EmailAddress.encodeJSON(participants) ?? "[]"
        let thread = ThreadRecord(
            accountId: accountID,
            id: threadID,
            subject: base.first { $0.subject?.isEmpty == false }?.subject ?? base.first?.subject,
            snippet: base.last?.snippet,
            lastDate: lastDate,
            participants: participantsJSON,
            messageCount: base.count,
            hasAttachments: messages.contains(where: \.hasAttachments),
            isUnread: union.contains("UNREAD"),
            isStarred: union.contains("STARRED"),
            isImportant: union.contains("IMPORTANT"),
            historyId: messages.compactMap(\.historyId).max { (UInt64($0) ?? 0) < (UInt64($1) ?? 0) }
        )
        try thread.save(db)
        for label in union {
            try db.execute(
                sql: "INSERT INTO thread_labels (account_id, thread_id, label_id, last_date) VALUES (?, ?, ?, ?)",
                arguments: [accountID, threadID, label, lastDate]
            )
        }
    }

    /// Keeps `messages_fts` in step with the message and its body, keyed by `messages.rowid`.
    static func indexFTS(_ db: Database, message: MessageRecord) throws {
        guard let rowid = message.rowid else { return }
        let bodyText = try String.fetchOne(
            db, sql: "SELECT body_text FROM message_bodies WHERE account_id = ? AND message_id = ?",
            arguments: [message.accountId, message.id]
        )
        let from = [message.fromName, message.fromEmail].compactMap(\.self).joined(separator: " ")
        let recipients = (EmailAddress.decodeJSON(message.toJson) + EmailAddress.decodeJSON(message.ccJson))
            .map { [$0.name, $0.email].compactMap(\.self).joined(separator: " ") }
            .joined(separator: " ")
        let body = [message.snippet, bodyText].compactMap(\.self).joined(separator: "\n")
        try db.execute(sql: "DELETE FROM messages_fts WHERE rowid = ?", arguments: [rowid])
        try db.execute(
            sql: "INSERT INTO messages_fts (rowid, subject, from_text, to_text, body_text) VALUES (?, ?, ?, ?, ?)",
            arguments: [rowid, message.subject ?? "", from, recipients, body]
        )
    }

    /// Autocomplete data: senders of received mail, and recipients of sent mail
    /// (ranked by how often they are written to).
    static func recordContacts(
        _ db: Database, accountID: String, headers: DecodedHeaders, labels: [String], date: Int64, own: Set<String>
    ) throws {
        if labels.contains("SENT") {
            for address in headers.to + headers.cc + headers.bcc where !own.contains(address.email.lowercased()) {
                try db.execute(sql: """
                INSERT INTO contacts (account_id, email, name, source, last_seen, times_sent_to)
                VALUES (?, ?, ?, 'sent', ?, 1)
                ON CONFLICT(account_id, email) DO UPDATE SET
                  times_sent_to = times_sent_to + 1,
                  name = COALESCE(excluded.name, contacts.name),
                  last_seen = MAX(COALESCE(contacts.last_seen, 0), excluded.last_seen),
                  source = 'sent'
                """, arguments: [accountID, address.email, address.name, date])
            }
        } else if let from = headers.from, !own.contains(from.email.lowercased()), !labels.contains("SPAM") {
            try db.execute(sql: """
            INSERT INTO contacts (account_id, email, name, source, last_seen) VALUES (?, ?, ?, 'received', ?)
            ON CONFLICT(account_id, email) DO UPDATE SET
              name = COALESCE(contacts.name, excluded.name),
              last_seen = MAX(COALESCE(contacts.last_seen, 0), excluded.last_seen)
            """, arguments: [accountID, from.email, from.name, date])
        }
    }
}
