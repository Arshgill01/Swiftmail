import Foundation
import GRDB

/// What undo needs to reverse one action for one account.
public struct UndoRecord: Sendable, Equatable {
    public let accountID: String
    public let pendingID: Int64
    public let title: String
}

/// Optimistic actions: each writes its local change and its `pending_actions` row in one
/// transaction, so the list updates at once and the queue syncs it later.
public enum MailActions {
    /// Applies `action` to the threads, one pending row per account. Returns undo records.
    @discardableResult
    public static func perform(_ action: MailAction, threads: [ThreadSummary.ID], in database: AppDatabase) async throws -> [UndoRecord] {
        let byAccount = Dictionary(grouping: threads, by: \.accountID)
        return try await database.writer.write { db in
            var records: [UndoRecord] = []
            for (accountID, ids) in byAccount.sorted(by: { $0.key < $1.key }) {
                if let record = try perform(action, accountID: accountID, threadIDs: ids.map(\.threadID), db: db) {
                    records.append(record)
                }
            }
            return records
        }
    }

    static func perform(_ action: MailAction, accountID: String, threadIDs: [String], db: Database) throws -> UndoRecord? {
        let (add, remove) = action.delta
        let affected = Array(Set(add + remove))
        var messageIDs: [String] = []
        for threadID in threadIDs {
            let ids = try String.fetchAll(db, sql: """
            SELECT id FROM messages WHERE account_id = ? AND thread_id = ? ORDER BY is_draft, internal_date
            """, arguments: [accountID, threadID])
            if action.latestMessageOnly {
                // The newest message that is not a draft (drafts sort first).
                let nonDrafts = try String.fetchAll(db, sql: """
                SELECT id FROM messages WHERE account_id = ? AND thread_id = ? AND is_draft = 0 ORDER BY internal_date DESC LIMIT 1
                """, arguments: [accountID, threadID])
                messageIDs += nonDrafts.isEmpty ? ids.suffix(1) : nonDrafts
            } else {
                messageIDs += ids
            }
        }
        guard !messageIDs.isEmpty else { return nil }
        let prior = try priorLabels(db, accountID: accountID, messageIDs: messageIDs, affected: affected)
        try applyLocally(db, accountID: accountID, messageIDs: messageIDs, add: add, remove: remove)
        let title = action.title(count: threadIDs.count)
        let payload = ModifyPayload(
            threadIDs: threadIDs, messageIDs: messageIDs, add: add, remove: remove,
            threadScope: !action.latestMessageOnly, trash: action == .trash, title: action.failureVerb
        )
        let undo = UndoPayload(threadIDs: threadIDs, affected: affected, prior: prior, title: title)
        let id = try insertPending(db, accountID: accountID, payload: payload, undo: undo)
        return UndoRecord(accountID: accountID, pendingID: id, title: title)
    }

    static func priorLabels(_ db: Database, accountID: String, messageIDs: [String], affected: [String]) throws -> [String: [String]] {
        var prior: [String: [String]] = Dictionary(uniqueKeysWithValues: messageIDs.map { ($0, []) })
        guard !affected.isEmpty else { return prior }
        let rows = try Row.fetchAll(db, sql: """
        SELECT message_id, label_id FROM message_labels WHERE account_id = ?
          AND message_id IN (\(databaseQuestionMarks(count: messageIDs.count)))
          AND label_id IN (\(databaseQuestionMarks(count: affected.count)))
        """, arguments: StatementArguments([accountID] + messageIDs + affected))
        for row in rows {
            prior[row["message_id"], default: []].append(row["label_id"])
        }
        return prior
    }

    /// Adds and removes labels on messages, then recomputes their threads.
    static func applyLocally(_ db: Database, accountID: String, messageIDs: [String], add: [String], remove: [String]) throws {
        var threads = Set<String>()
        for messageID in messageIDs {
            if let thread = try MailWriter.modifyMessageLabels(db, accountID: accountID, messageID: messageID, add: add, remove: remove) {
                threads.insert(thread)
            }
        }
        for thread in threads {
            try MailWriter.recomputeThread(db, accountID: accountID, threadID: thread)
        }
    }

    /// Restores each message's affected labels to what they were.
    static func restore(_ db: Database, accountID: String, undo: UndoPayload) throws {
        var threads = Set<String>()
        for (messageID, before) in undo.prior {
            let remove = undo.affected.filter { !before.contains($0) }
            if let thread = try MailWriter.modifyMessageLabels(db, accountID: accountID, messageID: messageID, add: before, remove: remove) {
                threads.insert(thread)
            }
        }
        for thread in threads {
            try MailWriter.recomputeThread(db, accountID: accountID, threadID: thread)
        }
    }

    @discardableResult
    static func insertPending(
        _ db: Database,
        accountID: String,
        payload: ModifyPayload,
        undo: UndoPayload?,
        state: PendingActionState = .queued
    ) throws -> Int64 {
        let record = try PendingActionRecord(
            accountId: accountID, kind: PendingKind.modify, payload: JSONEncoder.encodeString(payload),
            undoPayload: undo.map(JSONEncoder.encodeString), state: state, createdAt: Date().millis
        )
        try record.insert(db)
        return db.lastInsertedRowID
    }

    // MARK: Undo

    public enum UndoOutcome: Sendable, Equatable {
        /// The action had not been sent: the row was dropped and local state restored.
        case cancelled
        /// The action already reached Gmail: an inverse action was queued.
        case reversed
        case nothingToUndo
    }

    /// Undo while the row is still queued deletes it and restores local state; undo after it
    /// was sent queues the inverse action.
    public static func undo(_ record: UndoRecord, in database: AppDatabase) async throws -> UndoOutcome {
        try await database.writer.write { db in
            guard let row = try PendingActionRecord.fetchOne(db, key: record.pendingID),
                  let undoJSON = row.undoPayload else { return .nothingToUndo }
            let undo = try JSONDecoder.decode(UndoPayload.self, string: undoJSON)
            switch row.state {
            case .queued, .held, .failed:
                try row.delete(db)
                try restore(db, accountID: record.accountID, undo: undo)
                return .cancelled
            case .inFlight:
                // Queue the inverse behind it; keep the row so the queue can finish it.
                try db.execute(sql: "UPDATE pending_actions SET undo_payload = NULL WHERE id = ?", arguments: [row.id])
                try queueInverse(db, accountID: record.accountID, undo: undo, wasTrash: row.payloadIsTrash)
                return .reversed
            case .done:
                try row.delete(db)
                try queueInverse(db, accountID: record.accountID, undo: undo, wasTrash: row.payloadIsTrash)
                return .reversed
            }
        }
    }

    /// Restores local state and queues the server-side inverse, grouped by identical changes.
    static func queueInverse(_ db: Database, accountID: String, undo: UndoPayload, wasTrash: Bool) throws {
        try restore(db, accountID: accountID, undo: undo)
        var groups: [String: (add: [String], remove: [String], messages: [String])] = [:]
        for (messageID, before) in undo.prior {
            let add = before.sorted()
            let remove = undo.affected.filter { !before.contains($0) }.sorted()
            let key = add.joined(separator: ",") + "|" + remove.joined(separator: ",")
            groups[key, default: (add, remove, [])].messages.append(messageID)
        }
        for (index, group) in groups.values.enumerated() {
            let payload = ModifyPayload(
                threadIDs: undo.threadIDs, messageIDs: group.messages, add: group.add, remove: group.remove,
                threadScope: false, untrash: wasTrash && index == 0, title: "undo"
            )
            try insertPending(db, accountID: accountID, payload: payload, undo: nil)
        }
    }
}

extension PendingActionRecord {
    var payloadIsTrash: Bool {
        (try? JSONDecoder.decode(ModifyPayload.self, string: payload))?.trash ?? false
    }
}
