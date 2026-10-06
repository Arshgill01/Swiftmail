import Foundation
import GRDB
import os

/// `pending_actions.payload` for a send.
public struct SendPayload: Codable, Sendable, Equatable {
    /// The built RFC 5322 file, relative to the storage root (`Outbox/<account>/<id>.eml`).
    public var path: String
    public var threadID: String?
    public var gmailDraftID: String?
    /// The compose window as it was, to reopen it on undo.
    public var compose: ComposeState
    public var summary: String
}

/// The outbox: a send is a built MIME file plus a `send` row held for the undo delay. The
/// file is deleted only after Gmail returns the new message ID; failures wait for a retry.
public enum Outbox {
    static let logger = Logger(subsystem: "app.swiftmail", category: "Outbox")

    /// Builds the message, writes the outbox file, and queues a held send.
    @discardableResult
    public static func queue(
        _ state: ComposeState, fromName: String?, holdFor delay: TimeInterval, database: AppDatabase,
        builder: MIMEBuilder = MIMEBuilder(), now: Date = Date()
    ) async throws -> Int64 {
        let message = try OutgoingAssembler.assemble(state, fromName: fromName, date: now)
        let raw = builder.build(message)
        let relative = "Outbox/\(state.accountID)/\(state.id.uuidString).eml"
        let url = try AttachmentStorage.url(forRelativePath: relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try raw.write(to: url, options: .atomic)
        let to = state.to.first?.displayName ?? state.allRecipients.first?.displayName ?? ""
        let payload = SendPayload(
            path: relative, threadID: state.threadID, gmailDraftID: state.gmailDraftID, compose: state,
            summary: "\(state.subject.isEmpty ? "(no subject)" : state.subject) — to \(to)"
        )
        let json = try JSONEncoder.encodeString(payload)
        let notBefore = now.addingTimeInterval(delay).millis
        return try await database.writer.write { db in
            try db.execute(sql: "UPDATE local_drafts SET is_open = 0 WHERE id = ?", arguments: [state.id.uuidString])
            try PendingActionRecord(
                accountId: state.accountID, kind: PendingKind.send, payload: json, state: .held,
                notBefore: notBefore, createdAt: now.millis
            ).insert(db)
            return db.lastInsertedRowID
        }
    }

    /// Undo send: drops the held row and returns the compose state to reopen. Nil when the
    /// message is already on its way.
    public static func cancel(_ pendingID: Int64, database: AppDatabase) async throws -> ComposeState? {
        try await database.writer.write { db in
            guard let row = try PendingActionRecord.fetchOne(db, key: pendingID), row.kind == PendingKind.send,
                  row.state == .held || row.state == .queued || row.state == .failed
            else { return nil }
            let payload = try JSONDecoder.decode(SendPayload.self, string: row.payload)
            try row.delete(db)
            try db.execute(sql: "UPDATE local_drafts SET is_open = 1 WHERE id = ?", arguments: [payload.compose.id.uuidString])
            if let url = try? AttachmentStorage.url(forRelativePath: payload.path) {
                try? FileManager.default.removeItem(at: url)
            }
            return payload.compose
        }
    }

    /// Sends every held message now (quitting) and returns how many are waiting.
    public static func releaseHeld(database: AppDatabase, now: Date = Date()) async throws -> Int {
        try await database.writer.write { db in
            try db.execute(sql: "UPDATE pending_actions SET not_before = ? WHERE kind = 'send' AND state = 'held'", arguments: [now.millis])
            return try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM pending_actions WHERE kind = 'send' AND state IN ('held','queued','in_flight')") ?? 0
        }
    }

    /// Retries a failed send from the Outbox.
    public static func retry(_ pendingID: Int64, database: AppDatabase) async throws {
        try await database.writer.write { db in
            try db.execute(sql: "UPDATE pending_actions SET state = 'queued', attempts = 0, not_before = NULL WHERE id = ?", arguments: [pendingID])
        }
    }

    public struct Item: Sendable, Equatable, Identifiable {
        public let id: Int64
        public let accountID: String
        public let summary: String
        public let state: PendingActionState
        public let lastError: String?
    }

    public static func items(_ db: Database) throws -> [Item] {
        try PendingActionRecord.fetchAll(db, sql: """
        SELECT * FROM pending_actions WHERE kind = 'send' AND state != 'done' ORDER BY id
        """).compactMap { row in
            guard let id = row.id, let payload = try? JSONDecoder.decode(SendPayload.self, string: row.payload) else { return nil }
            return Item(id: id, accountID: row.accountId, summary: payload.summary, state: row.state, lastError: row.lastError)
        }
    }

    /// The queue's send step: `messages.send`, then delete the Gmail draft, then the file.
    public static func send(_ row: PendingActionRecord, client: any GmailClient, database: AppDatabase) async throws {
        let payload = try JSONDecoder.decode(SendPayload.self, string: row.payload)
        let url = try AttachmentStorage.url(forRelativePath: payload.path)
        let raw = try Data(contentsOf: url)
        let sent = try await client.sendMessage(raw: raw, threadID: payload.threadID)
        logger.info("sent message \(sent.id, privacy: .private)")
        if let draftID = payload.gmailDraftID {
            do {
                try await client.deleteDraft(id: draftID)
            } catch GmailError.notFound {}
        }
        try? FileManager.default.removeItem(at: url)
        try await database.deleteLocalDraft(payload.compose.id)
    }
}
