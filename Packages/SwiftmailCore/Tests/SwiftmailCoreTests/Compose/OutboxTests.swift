import Foundation
import GRDB
@testable import SwiftmailCore
import Testing

@Suite(.serialized)
struct OutboxTests {
    func setUp() async throws -> (FakeGmailServer, AppDatabase, ActionQueue, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("outbox-\(UUID().uuidString)")
        AttachmentStorage.setRoot(root)
        let server = FakeGmailServer()
        let db = try await seededDatabase()
        let queue = ActionQueue(accountID: "acc", client: server, database: db)
        await queue.setSendHandler { row in try await Outbox.send(row, client: server, database: db) }
        return (server, db, queue, root)
    }

    func compose() -> ComposeState {
        var state = ComposeState(accountID: "acc", from: "me@example.com")
        state.to = [EmailAddress(name: "Alex", email: "alex@example.com")]
        state.subject = "Réunion — ünïcode"
        state.bodyHTML = "<p>Hello</p>"
        return state
    }

    @Test func heldSendGoesOutAfterTheDelayAndCleansUp() async throws {
        let (server, db, queue, root) = try await setUp()
        defer { AttachmentStorage.setRoot(nil) }
        let state = compose()
        try await db.saveLocalDraft(state)
        try await Outbox.queue(state, fromName: "Me", holdFor: 0.3, database: db)
        await queue.drain()
        #expect(server.update { $0.sent.isEmpty })
        #expect(try await db.reader.read { db in try Outbox.items(db).count } == 1)
        try await Task.sleep(for: .milliseconds(400))
        await queue.drain()
        let sent = try #require(server.update { $0.sent.first })
        #expect(MessageDecoder.decode(EMLParser.parse(sent)).headers.subject == "Réunion — ünïcode")
        #expect(try await db.reader.read { db in try Outbox.items(db).isEmpty })
        #expect(try await db.localDraft(state.id) == nil)
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("Outbox/acc").path)) ?? []
        #expect(leftovers.isEmpty)
    }

    @Test func undoSendReturnsTheComposeState() async throws {
        let (server, db, queue, _) = try await setUp()
        defer { AttachmentStorage.setRoot(nil) }
        let state = compose()
        let id = try await Outbox.queue(state, fromName: nil, holdFor: 10, database: db)
        let reopened = try await Outbox.cancel(id, database: db)
        #expect(reopened == state)
        await queue.drain()
        #expect(server.update { $0.sent.isEmpty })
    }

    @Test func failedSendsWaitInTheOutbox() async throws {
        let (server, db, queue, _) = try await setUp()
        defer { AttachmentStorage.setRoot(nil) }
        server.update { $0.failNext = [GmailError.http(400, reason: "invalidArgument")] }
        let id = try await Outbox.queue(compose(), fromName: nil, holdFor: 0, database: db)
        await queue.drain()
        let items = try await db.reader.read { db in try Outbox.items(db) }
        #expect(items.first?.state == .failed)
        try await Outbox.retry(id, database: db)
        await queue.drain()
        #expect(server.update { $0.sent.count } == 1)
    }

    @Test func quittingReleasesHeldSends() async throws {
        let (server, db, queue, _) = try await setUp()
        defer { AttachmentStorage.setRoot(nil) }
        try await Outbox.queue(compose(), fromName: nil, holdFor: 30, database: db)
        #expect(try await Outbox.releaseHeld(database: db) == 1)
        await queue.drain()
        #expect(server.update { $0.sent.count } == 1)
    }

    @Test func sendingDeletesTheGmailDraft() async throws {
        let (server, db, queue, _) = try await setUp()
        defer { AttachmentStorage.setRoot(nil) }
        let draft = try await server.createDraft(raw: Data(), threadID: nil)
        var state = compose()
        state.gmailDraftID = draft.id
        try await Outbox.queue(state, fromName: nil, holdFor: 0, database: db)
        await queue.drain()
        #expect(server.update { $0.drafts.isEmpty })
    }

    @Test func contactSuggestionsRankBySent() async throws {
        let db = try await seededDatabase()
        try await db.writer.write { db in
            try db.execute(sql: "INSERT INTO contacts VALUES ('acc', 'alex@example.com', 'Alex Rivera', 'sent', 1, 5)")
            try db.execute(sql: "INSERT INTO contacts VALUES ('acc', 'alana@example.com', 'Alana', 'received', 9, 0)")
            try db.execute(sql: "INSERT INTO contacts VALUES ('acc', 'bob@example.com', 'Bob Al', 'received', 9, 0)")
        }
        let results = try await db.reader.read { db in try ContactQueries.suggest(db, prefix: "al") }
        #expect(results.map(\.email) == ["alex@example.com", "alana@example.com", "bob@example.com"])
        #expect(results.first?.display == "Alex Rivera <alex@example.com>")
    }
}
