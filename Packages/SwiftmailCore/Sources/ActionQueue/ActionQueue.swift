import Foundation
import GRDB
import os

/// Drains one account's `pending_actions` in order: label changes, trash and undo
/// inverses here, sends from M6. Retries transient failures with backoff, keeps work queued
/// while offline, and after 5 failed attempts rolls the local change back.
public actor ActionQueue {
    public nonisolated let accountID: String
    let client: any GmailClient
    let database: AppDatabase
    let now: @Sendable () -> Date
    var onFailure: @Sendable (String) -> Void = { _ in }
    var onDrained: @Sendable () -> Void = {}
    var sendHandler: (@Sendable (PendingActionRecord) async throws -> Void)?
    private var draining = false
    private var rerun = false
    private var wakeTask: Task<Void, Never>?
    let logger = Logger(subsystem: "app.swiftmail", category: "ActionQueue")

    public static let maxAttempts = 5
    static let doneRetention: Int64 = 10 * 60 * 1000

    public init(accountID: String, client: any GmailClient, database: AppDatabase, now: @escaping @Sendable () -> Date = Date.init) {
        self.accountID = accountID
        self.client = client
        self.database = database
        self.now = now
    }

    public func setHandlers(onFailure: @escaping @Sendable (String) -> Void, onDrained: @escaping @Sendable () -> Void) {
        self.onFailure = onFailure
        self.onDrained = onDrained
    }

    public func setSendHandler(_ handler: @escaping @Sendable (PendingActionRecord) async throws -> Void) {
        sendHandler = handler
    }

    /// Rows left in flight by a crash go back to the queue.
    public func recover() async throws {
        let id = accountID
        try await database.writer.write { db in
            try db.execute(sql: "UPDATE pending_actions SET state = 'queued' WHERE account_id = ? AND state = 'in_flight'", arguments: [id])
        }
    }

    /// Sends every due row. Concurrent calls coalesce into one more pass.
    public func drain() async {
        if draining {
            rerun = true
            return
        }
        draining = true
        defer { draining = false }
        var didWork = false
        repeat {
            rerun = false
            while let row = try? await nextDue() {
                didWork = true
                guard await execute(row) else { break }
            }
        } while rerun
        try? await pruneDone()
        scheduleWake()
        if didWork {
            onDrained()
        }
    }

    private func nextDue() async throws -> PendingActionRecord? {
        let id = accountID
        let nowMillis = now().millis
        return try await database.writer.write { db in
            guard var row = try PendingActionRecord.fetchOne(db, sql: """
            SELECT * FROM pending_actions WHERE account_id = ? AND state IN ('queued', 'held')
              AND (not_before IS NULL OR not_before <= ?) ORDER BY id LIMIT 1
            """, arguments: [id, nowMillis]) else { return nil }
            row.state = .inFlight
            try row.update(db)
            return row
        }
    }

    /// Returns false when draining should stop (offline, signed out).
    private func execute(_ row: PendingActionRecord) async -> Bool {
        do {
            if row.kind == PendingKind.send {
                guard let sendHandler else { throw GmailError.invalidRequest("no send handler") }
                try await sendHandler(row)
            } else {
                try await performModify(row)
            }
            try await finish(row)
            return true
        } catch let error as GmailError where error == .offline || error == .needsSignIn {
            try? await setState(row, .queued, notBefore: nil, error: error)
            return false
        } catch {
            await fail(row, error: error)
            return true
        }
    }

    func performModify(_ row: PendingActionRecord) async throws {
        let payload = try JSONDecoder.decode(ModifyPayload.self, string: row.payload)
        if payload.untrash {
            for thread in payload.threadIDs {
                try await ignoringNotFound { try await client.untrashThread(id: thread) }
            }
        }
        if payload.trash {
            for thread in payload.threadIDs {
                try await ignoringNotFound { try await client.trashThread(id: thread) }
            }
            return
        }
        guard !payload.add.isEmpty || !payload.remove.isEmpty else { return }
        if payload.threadScope, payload.threadIDs.count <= 5 {
            for thread in payload.threadIDs {
                try await ignoringNotFound { try await client.modifyThread(id: thread, add: payload.add, remove: payload.remove) }
            }
        } else {
            try await ignoringNotFound { try await client.batchModifyMessages(ids: payload.messageIDs, add: payload.add, remove: payload.remove) }
        }
    }

    /// A thread or message deleted on the server needs no change.
    private func ignoringNotFound(_ body: () async throws -> Void) async throws {
        do {
            try await body()
        } catch GmailError.notFound {}
    }

    private func finish(_ row: PendingActionRecord) async throws {
        let nowMillis = now().millis
        try await database.writer.write { db in
            guard let current = try PendingActionRecord.fetchOne(db, key: row.id) else { return }
            if current.undoPayload == nil || current.kind == PendingKind.send {
                try current.delete(db)
            } else {
                try db.execute(sql: "UPDATE pending_actions SET state = 'done', not_before = ? WHERE id = ?", arguments: [nowMillis, row.id])
            }
        }
    }

    private func fail(_ row: PendingActionRecord, error: Error) async {
        let attempts = row.attempts + 1
        let transient = (error as? GmailError)?.isTransient ?? true
        logger.error("action \(row.kind, privacy: .public) failed (\(attempts)): \(String(describing: error), privacy: .public)")
        if transient, attempts < Self.maxAttempts {
            let delay = Backoff.delay(attempt: attempts - 1)
            let notBefore = now().millis + Int64(delay.components.seconds * 1000)
            try? await setState(row, .queued, notBefore: notBefore, error: error, attempts: attempts)
            return
        }
        if row.kind == PendingKind.send {
            // A send is never dropped: it waits in the Outbox for a retry.
            try? await setState(row, .failed, notBefore: nil, error: error, attempts: attempts)
            onFailure("A message couldn't be sent. It's waiting in the Outbox.")
            return
        }
        let payload = try? JSONDecoder.decode(ModifyPayload.self, string: row.payload)
        let id = accountID
        try? await database.writer.write { db in
            if let undoJSON = row.undoPayload, let undo = try? JSONDecoder.decode(UndoPayload.self, string: undoJSON) {
                try MailActions.restore(db, accountID: id, undo: undo)
            }
            try db.execute(sql: "DELETE FROM pending_actions WHERE id = ?", arguments: [row.id])
        }
        let count = payload?.threadIDs.count ?? 1
        let what = count == 1 ? "a conversation" : "\(count) conversations"
        onFailure("Couldn't \(payload?.title ?? "update") \(what). The change was undone.")
    }

    private func setState(
        _ row: PendingActionRecord, _ state: PendingActionState, notBefore: Int64?, error: Error, attempts: Int? = nil
    ) async throws {
        try await database.writer.write { db in
            try db.execute(sql: """
            UPDATE pending_actions SET state = ?, not_before = COALESCE(?, not_before), last_error = ?, attempts = ? WHERE id = ?
            """, arguments: [state.rawValue, notBefore, String(describing: error), attempts ?? row.attempts, row.id])
        }
    }

    private func pruneDone() async throws {
        let id = accountID
        let cutoff = now().millis - Self.doneRetention
        try await database.writer.write { db in
            try db.execute(sql: "DELETE FROM pending_actions WHERE account_id = ? AND state = 'done' AND not_before < ?", arguments: [id, cutoff])
        }
    }

    /// Wakes up for the earliest retry or held send.
    private func scheduleWake() {
        wakeTask?.cancel()
        let id = accountID
        let database = database
        let nowMillis = now().millis
        wakeTask = Task { [weak self] in
            guard let next = try? await database.reader.read({ db in
                try Int64.fetchOne(db, sql: """
                SELECT MIN(not_before) FROM pending_actions WHERE account_id = ? AND state IN ('queued', 'held') AND not_before > ?
                """, arguments: [id, nowMillis])
            }) else { return }
            try? await Task.sleep(for: .milliseconds(max(0, next - Date().millis) + 50))
            guard !Task.isCancelled else { return }
            await self?.drain()
        }
    }
}
