import Foundation
import GRDB

extension SyncEngine {

    // MARK: Backfill (first sync steps 5 to 7)

    /// Downloads older mail newest first, 100 threads a page, resuming from the saved
    /// cursor. Threads from the last 90 days come with bodies (`after:` the boundary),
    /// older ones as metadata (`before:` it) down to the window. Spends quota only while
    /// the bucket keeps its reserve for the user.
    public func backfill() async throws {
        try await RequestPriority.$current.withValue(.background) {
            while !Task.isCancelled {
                guard let account = try await account(), account.initialSyncDone, !account.backfillDone else { return }
                let nowDate = now()
                var cursor = BackfillCursor(account.backfillCursor)
                    ?? BackfillCursor(phase: .recent, boundary: Int64(nowDate.addingTimeInterval(-Self.fullBodyAge).timeIntervalSince1970), pageToken: nil)
                let list = try await client.listThreads(ThreadListQuery(
                    query: cursor.query, pageToken: cursor.pageToken, maxResults: Self.backfillPageSize
                ))
                let refs = list.threads ?? []
                let written = try await fetchAndWrite(refs: refs, format: cursor.phase == .recent ? .full : .metadata, skipExisting: true)
                var done = false
                if let next = list.nextPageToken {
                    cursor.pageToken = next
                } else if cursor.phase == .recent {
                    cursor = BackfillCursor(phase: .older, boundary: cursor.boundary, pageToken: nil)
                } else {
                    done = true
                }
                if cursor.phase == .older, let cutoff = settings().backfillWindow.cutoff(from: nowDate),
                   let oldest = try await oldestDate(of: refs.map(\.id)), Date(millis: oldest) < cutoff {
                    done = true
                }
                let id = accountID
                let saved = done ? nil : cursor.encoded
                let finished = done
                try await database.writer.write { db in
                    try db.execute(
                        sql: "UPDATE accounts SET backfill_cursor = ?, backfill_done = ? WHERE id = ?",
                        arguments: [saved, finished, id]
                    )
                }
                let count = try await database.reader.read { db in try ThreadQueries.threadCount(db, accountID: id) }
                publish(done ? .idle : .backfilling(threads: count), success: true)
                logger.debug("backfill page: \(written.count) written, done=\(done)")
                if done {
                    return
                }
            }
        }
    }

    private func oldestDate(of threadIDs: [String]) async throws -> Int64? {
        guard !threadIDs.isEmpty else { return nil }
        let id = accountID
        return try await database.reader.read { db in
            try Int64.fetchOne(db, sql: """
            SELECT MIN(last_date) FROM threads WHERE account_id = ? AND id IN (\(databaseQuestionMarks(count: threadIDs.count)))
            """, arguments: StatementArguments([id] + threadIDs))
        }
    }

    /// Restarts the backfill from the newest mail, e.g. after the window setting grew.
    public func restartBackfill() async throws {
        let id = accountID
        try await database.writer.write { db in
            try db.execute(sql: "UPDATE accounts SET backfill_cursor = NULL, backfill_done = 0 WHERE id = ?", arguments: [id])
        }
    }

    // MARK: On demand

    /// Loads one more page of a mailbox older than what is cached, through Gmail's
    /// `before:` search. Returns the number of threads written.
    @discardableResult
    public func loadOlder(labelID: String?, before: Int64) async throws -> Int {
        let seconds = before / 1000
        var query = ThreadListQuery(query: "before:\(seconds)", maxResults: 50)
        if let labelID {
            query.labelIDs = [labelID]
        }
        let list = try await client.listThreads(query)
        return try await fetchAndWrite(refs: list.threads ?? [], format: .metadata, skipExisting: true).count
    }

    /// Downloads the bodies of a thread's messages that were synced as metadata.
    /// User priority: this is what the reader waits on.
    public func fetchBodies(threadID: String) async throws {
        let id = accountID
        let missing = try await database.reader.read { db in
            try String.fetchAll(db, sql: """
            SELECT id FROM messages WHERE account_id = ? AND thread_id = ? AND body_state != 'ready'
            """, arguments: [id, threadID])
        }
        guard !missing.isEmpty else { return }
        try await fetchMessages(ids: missing, format: .full)
    }

    /// Fetches messages and writes them, recomputing their threads. 404s are skipped.
    @discardableResult
    func fetchMessages(ids: [String], format: MessageFormat) async throws -> [WrittenMessage] {
        guard !ids.isEmpty else { return [] }
        let results = try await client.getMessages(ids: ids, format: format)
        var messages: [GmailMessage] = []
        for messageID in ids {
            switch results[messageID] {
            case let .success(message)?:
                try await messages.append(hydrateLargeBodies(message))
            case .failure(.notFound)?, nil:
                continue
            case let .failure(error)?:
                if error == .offline || error == .needsSignIn {
                    throw error
                }
                logger.error("message fetch failed: \(String(describing: error), privacy: .public)")
            }
        }
        let own = try await ownAddresses()
        let id = accountID
        let fetched = messages
        return try await database.writer.write { db in
            var written: [WrittenMessage] = []
            var threads = Set<String>()
            for message in fetched {
                let change = try MailWriter.upsertMessage(db, accountID: id, message: message, format: format, ownAddresses: own)
                written.append(WrittenMessage(change: change))
                threads.insert(message.threadId)
            }
            for thread in threads {
                try MailWriter.recomputeThread(db, accountID: id, threadID: thread)
            }
            return written
        }
    }

    struct WrittenMessage: Sendable {
        let change: MailWriter.MessageChange
    }

    // MARK: Drafts

    /// Maps Gmail draft IDs onto their messages so drafts can be updated or deleted.
    func syncDraftIDs() async throws {
        var pageToken: String?
        var pairs: [(String, String)] = []
        repeat {
            let list = try await client.listDrafts(pageToken: pageToken)
            for draft in list.drafts ?? [] {
                if let messageID = draft.message?.id {
                    pairs.append((messageID, draft.id))
                }
            }
            pageToken = list.nextPageToken
        } while pageToken != nil
        let id = accountID
        let mapping = pairs
        try await database.writer.write { db in
            for (messageID, draftID) in mapping {
                try db.execute(
                    sql: "UPDATE messages SET draft_id = ? WHERE account_id = ? AND id = ?",
                    arguments: [draftID, id, messageID]
                )
            }
        }
    }

    // MARK: Large bodies

    /// Text bodies too large to arrive inline come as attachments; fetch them so the
    /// message decodes completely.
    func hydrateLargeBodies(_ thread: GmailThread, format: MessageFormat) async throws -> GmailThread {
        guard format == .full, let messages = thread.messages else { return thread }
        var copy = thread
        var hydrated: [GmailMessage] = []
        for message in messages {
            try await hydrated.append(hydrateLargeBodies(message))
        }
        copy.messages = hydrated
        return copy
    }

    func hydrateLargeBodies(_ message: GmailMessage) async throws -> GmailMessage {
        guard var payload = message.payload else { return message }
        let pending = MessageDecoder.decode(payload).pendingBodyParts
        guard !pending.isEmpty else { return message }
        var bodies: [String: String] = [:]
        for part in pending {
            let data = try await client.getAttachment(messageID: message.id, attachmentID: part.attachmentID)
            bodies[part.attachmentID] = Base64URL.encode(data)
        }
        Self.fill(&payload, with: bodies)
        var copy = message
        copy.payload = payload
        return copy
    }

    static func fill(_ part: inout GmailMessagePart, with bodies: [String: String]) {
        if let id = part.body?.attachmentId, let data = bodies[id], part.filename?.isEmpty ?? true {
            part.body?.data = data
            part.body?.attachmentId = nil
        }
        guard var children = part.parts else { return }
        for index in children.indices {
            fill(&children[index], with: bodies)
        }
        part.parts = children
    }
}

/// Saved as `accounts.backfill_cursor`: `<phase>:<boundary seconds>:<page token>`.
struct BackfillCursor: Equatable {
    enum Phase: String { case recent, older }

    var phase: Phase
    var boundary: Int64
    var pageToken: String?

    init(phase: Phase, boundary: Int64, pageToken: String?) {
        self.phase = phase
        self.boundary = boundary
        self.pageToken = pageToken
    }

    init?(_ encoded: String?) {
        guard let parts = encoded?.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false), parts.count == 3,
              let phase = Phase(rawValue: String(parts[0])), let boundary = Int64(parts[1])
        else { return nil }
        self.phase = phase
        self.boundary = boundary
        pageToken = parts[2].isEmpty ? nil : String(parts[2])
    }

    var encoded: String {
        "\(phase.rawValue):\(boundary):\(pageToken ?? "")"
    }

    var query: String {
        phase == .recent ? "after:\(boundary)" : "before:\(boundary)"
    }
}
