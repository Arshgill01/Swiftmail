import Foundation
import GRDB

extension SyncEngine {
    /// One incremental sync: follow `history.list` from the stored historyId and apply
    /// every record in order. Returns true when anything changed. A 404 means the
    /// history expired and starts a full resync.
    @discardableResult
    public func incrementalSync() async throws -> Bool {
        guard let account = try await account(), account.initialSyncDone else { return false }
        guard let startID = account.historyId else {
            try await startFullResync()
            return true
        }
        let interval = signposter.beginInterval("HistorySync")
        defer { signposter.endInterval("HistorySync", interval) }
        var pageToken: String?
        var changed = false
        var unknownLabels = false
        var newMail: [NewMailItem] = []
        var removed: [String] = []
        let knownLabels = try await localLabelIDs()
        repeat {
            let page: GmailHistoryList
            do {
                page = try await client.listHistory(startHistoryID: startID, pageToken: pageToken)
            } catch GmailError.notFound {
                logger.info("history expired; starting full resync")
                try await startFullResync()
                return true
            }
            pageToken = page.nextPageToken
            let records = page.history ?? []
            let isLast = pageToken == nil
            let result = try await apply(records, finalHistoryID: isLast ? page.historyId : nil)
            changed = changed || result.changed
            newMail += result.newMail
            removed += result.removedMessageIDs
            unknownLabels = unknownLabels || !result.labelIDs.isSubset(of: knownLabels)
        } while pageToken != nil

        if unknownLabels {
            try await refreshLabelsAndAliases()
        }
        if !newMail.isEmpty {
            sink.newMail(newMail)
        }
        if !removed.isEmpty {
            sink.removedMessages(removed)
        }
        let id = accountID
        try await database.writer.write { db in
            try db.execute(sql: "UPDATE accounts SET last_sync_at = ? WHERE id = ?", arguments: [Date().millis, id])
        }
        if changed || unknownLabels {
            try await refreshLabelCountsIfDue()
        }
        if status.phase == .offline || status.phase == .needsSignIn || status.phase == .firstSync || isErrorPhase {
            publish(.idle, success: true)
        } else {
            status.lastSuccess = now()
            sink.status(status)
        }
        return changed
    }

    private var isErrorPhase: Bool {
        if case .error = status.phase {
            return true
        }
        return false
    }

    struct HistoryResult {
        var changed = false
        var newMail: [NewMailItem] = []
        var removedMessageIDs: [String] = []
        var labelIDs: Set<String> = []
    }

    /// Applies one page of history records. New messages are fetched first (outside the
    /// transaction); then every record is applied in order in one transaction, which also
    /// stores the new historyId on the last page.
    func apply(_ records: [GmailHistory], finalHistoryID: String?) async throws -> HistoryResult {
        var result = HistoryResult()
        let id = accountID
        let addedIDs = records.flatMap { $0.messagesAdded ?? [] }.map(\.message)
        let labelTouched = records.flatMap { ($0.labelsAdded ?? []) + ($0.labelsRemoved ?? []) }.map(\.message)
        for record in records {
            for entry in (record.labelsAdded ?? []) + (record.labelsRemoved ?? []) {
                result.labelIDs.formUnion(entry.labelIds ?? [])
            }
        }

        // Which messages and threads are already local?
        let candidateIDs = Array(Set((addedIDs + labelTouched).map(\.id)))
        let candidateThreads = Array(Set((addedIDs + labelTouched).map(\.threadId)))
        let (localMessages, localThreads) = try await database.reader.read { db in
            let messages = try Set(String.fetchAll(db, sql: """
            SELECT id FROM messages WHERE account_id = ? AND id IN (\(databaseQuestionMarks(count: candidateIDs.count)))
            """, arguments: StatementArguments([id] + candidateIDs)))
            let threads = try Set(String.fetchAll(db, sql: """
            SELECT id FROM threads WHERE account_id = ? AND id IN (\(databaseQuestionMarks(count: candidateThreads.count)))
            """, arguments: StatementArguments([id] + candidateThreads)))
            return (messages, threads)
        }

        // New messages: messages.get when the thread is local, threads.get when it is new.
        // Label changes on messages we don't have also pull their thread (e.g. un-archived old mail).
        var messageFetches: [String] = []
        var threadFetches = Set<String>()
        for message in addedIDs where !localMessages.contains(message.id) {
            if localThreads.contains(message.threadId) {
                messageFetches.append(message.id)
            } else {
                threadFetches.insert(message.threadId)
            }
        }
        for message in labelTouched where !localMessages.contains(message.id) && !localThreads.contains(message.threadId) {
            threadFetches.insert(message.threadId)
        }
        messageFetches = Array(Set(messageFetches))
        let fetchedMessages = try await fetchForHistory(messageIDs: messageFetches)
        let fetchedThreads = try await fetchThreadsForHistory(Array(threadFetches))
        let own = try await ownAddresses()
        let markSeen = resyncing

        let outcome = try await database.writer.write { db in
            try Self.write(
                db, accountID: id, records: records, threads: fetchedThreads, messages: fetchedMessages,
                own: own, finalHistoryID: finalHistoryID, markSeen: markSeen
            )
        }
        result.changed = outcome.changed
        // Only messages the history reported as added count as new mail.
        let addedSet = Set(addedIDs.map(\.id))
        result.newMail = outcome.newMail.filter { addedSet.contains($0.messageID) }
        result.removedMessageIDs = outcome.removedMessageIDs
        return result
    }

    /// Applies fetched threads and messages, then every record in order, in one transaction.
    static func write(
        _ db: Database, accountID id: String, records: [GmailHistory], threads fetchedThreads: [GmailThread],
        messages fetchedMessages: [GmailMessage], own: Set<String>, finalHistoryID: String?, markSeen: Bool
    ) throws -> HistoryResult {
        var outcome = HistoryResult()
        var touchedThreads = Set<String>()
        for thread in fetchedThreads {
            let changes = try MailWriter.upsertThread(db, accountID: id, thread: thread, format: .full, ownAddresses: own)
            touchedThreads.insert(thread.id)
            outcome.newMail += changes.filter(\.isNew).map {
                NewMailItem(accountID: id, threadID: $0.threadID, messageID: $0.messageID, labelIDs: $0.labelIDs)
            }
        }
        for message in fetchedMessages {
            let change = try MailWriter.upsertMessage(db, accountID: id, message: message, format: .full, ownAddresses: own)
            touchedThreads.insert(message.threadId)
            if change.isNew {
                outcome.newMail.append(NewMailItem(accountID: id, threadID: change.threadID, messageID: change.messageID, labelIDs: change.labelIDs))
            }
        }
        for record in records {
            for entry in record.messagesDeleted ?? [] {
                if let thread = try MailWriter.deleteMessage(db, accountID: id, messageID: entry.message.id) {
                    touchedThreads.insert(thread)
                    outcome.removedMessageIDs.append(entry.message.id)
                }
            }
            for entry in record.labelsAdded ?? [] {
                if let thread = try MailWriter.modifyMessageLabels(
                    db, accountID: id, messageID: entry.message.id, add: entry.labelIds ?? [], remove: []
                ) {
                    touchedThreads.insert(thread)
                }
            }
            for entry in record.labelsRemoved ?? [] {
                let labels = entry.labelIds ?? []
                if let thread = try MailWriter.modifyMessageLabels(db, accountID: id, messageID: entry.message.id, add: [], remove: labels) {
                    touchedThreads.insert(thread)
                }
                if labels.contains("UNREAD") || labels.contains("INBOX") {
                    outcome.removedMessageIDs.append(entry.message.id)
                }
            }
        }
        for thread in touchedThreads {
            try MailWriter.recomputeThread(db, accountID: id, threadID: thread)
        }
        try PendingOverlay.reapply(db, accountID: id, threadIDs: touchedThreads)
        if markSeen {
            try Self.markSeen(db, accountID: id, threadIDs: touchedThreads)
        }
        if let finalHistoryID {
            try db.execute(sql: "UPDATE accounts SET history_id = ? WHERE id = ?", arguments: [finalHistoryID, id])
        }
        outcome.changed = !records.isEmpty
        return outcome
    }

    private func fetchForHistory(messageIDs: [String]) async throws -> [GmailMessage] {
        guard !messageIDs.isEmpty else { return [] }
        let results = try await client.getMessages(ids: messageIDs, format: .full)
        var messages: [GmailMessage] = []
        for messageID in messageIDs {
            // A 404 means the message is already gone; skip it.
            guard case let .success(message)? = results[messageID] else { continue }
            try await messages.append(hydrateLargeBodies(message))
        }
        return messages
    }

    private func fetchThreadsForHistory(_ threadIDs: [String]) async throws -> [GmailThread] {
        guard !threadIDs.isEmpty else { return [] }
        let results = try await client.getThreads(ids: threadIDs, format: .full)
        var threads: [GmailThread] = []
        for threadID in threadIDs {
            guard case let .success(thread)? = results[threadID] else { continue }
            try await threads.append(hydrateLargeBodies(thread, format: .full))
        }
        return threads
    }

    private func localLabelIDs() async throws -> Set<String> {
        let id = accountID
        return try await database.reader.read { db in
            try Set(String.fetchAll(db, sql: "SELECT id FROM labels WHERE account_id = ?", arguments: [id]))
        }
    }

    // MARK: Label counts

    /// Refreshes unread and total counts with `labels.get` for the inbox, categories and
    /// visible user labels, at most once a minute.
    public func refreshLabelCountsIfDue(force: Bool = false) async throws {
        guard let account = try await account() else { return }
        let nowMillis = now().millis
        if !force, let last = account.labelsRefreshedAt, nowMillis - last < 60000 {
            return
        }
        let id = accountID
        try await database.writer.write { db in
            try db.execute(sql: "UPDATE accounts SET labels_refreshed_at = ? WHERE id = ?", arguments: [nowMillis, id])
        }
        let labelIDs = try await database.reader.read { db in
            try String.fetchAll(db, sql: """
            SELECT id FROM labels WHERE account_id = ? AND (
              id IN ('INBOX','DRAFT','SPAM','CATEGORY_SOCIAL','CATEGORY_PROMOTIONS','CATEGORY_UPDATES','CATEGORY_FORUMS','CATEGORY_PERSONAL')
              OR (type = 'user' AND visible_in_list = 1))
            """, arguments: [id])
        }
        try await RequestPriority.$current.withValue(.background) {
            var labels: [GmailLabel] = []
            for labelID in labelIDs {
                do {
                    try await labels.append(client.getLabel(id: labelID))
                } catch GmailError.notFound {
                    continue
                }
            }
            let fetched = labels
            try await database.writer.write { db in
                for label in fetched {
                    try MailWriter.updateLabelCounts(db, accountID: id, label: label)
                }
            }
        }
    }
}
