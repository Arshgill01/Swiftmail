import Foundation
import GRDB
@testable import SwiftmailCore
import Testing

func makeEngine(_ server: FakeGmailServer, db: AppDatabase, window: BackfillWindow = .everything) -> SyncEngine {
    SyncEngine(accountID: "acc", client: server, database: db, settings: { SyncSettings(backfillWindow: window) })
}

/// Seeds `count` threads spread one day apart, newest first; every third is archived.
func seedServer(_ server: FakeGmailServer, threads count: Int, unread: Bool = true, now: Date = Date()) {
    for index in 0 ..< count {
        let labels: Set<String> = index % 3 == 2 ? ["CATEGORY_PERSONAL"] : ["INBOX", "CATEGORY_PERSONAL"]
        server.addMessage(
            subject: "Thread \(index)",
            labels: labels.union(unread && index % 2 == 0 ? ["UNREAD"] : []),
            date: now.addingTimeInterval(-Double(index) * 86400),
            recordHistory: false
        )
    }
}

struct FirstSyncTests {
    @Test func firstSyncShowsInboxThenBackfillsEverything() async throws {
        let server = FakeGmailServer()
        seedServer(server, threads: 130)
        server.addMessage(subject: "Promo", labels: ["INBOX", "CATEGORY_PROMOTIONS"], recordHistory: false)
        let db = try await seededDatabase()
        let engine = makeEngine(server, db: db)
        try await engine.firstSync()

        let account = try #require(try await db.account(id: "acc"))
        #expect(account.initialSyncDone)
        #expect(account.historyId == "1131")
        #expect(account.categoriesEnabled)
        let inbox = try await db.reader.read { db in
            try ThreadQueries.threads(db, mailbox: Mailbox(accountID: "acc", kind: .inbox), category: .primary, limit: 500)
        }
        #expect(inbox.count >= 50)
        // Inbox threads were fetched with bodies.
        let firstBody = try await db.reader.read { db in
            try String.fetchOne(
                db,
                sql: "SELECT body_state FROM messages m JOIN threads t ON t.id = m.thread_id ORDER BY t.last_date DESC LIMIT 1"
            )
        }
        #expect(firstBody == "ready")
        let labels = try await db.reader.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM labels") ?? 0 }
        #expect(labels == FakeGmailServer.systemLabels.count)

        try await engine.backfill()
        let total = try await db.reader.read { db in try ThreadQueries.threadCount(db, accountID: "acc") }
        #expect(total == 131)
        #expect(try await db.account(id: "acc")?.backfillDone == true)
    }

    @Test func backfillStopsAtTheWindow() async throws {
        let server = FakeGmailServer()
        seedServer(server, threads: 400, unread: false)
        let db = try await seededDatabase()
        let engine = makeEngine(server, db: db, window: .threeMonths)
        try await engine.firstSync()
        try await engine.backfill()
        let oldest = try await db.reader.read { db in try Int64.fetchOne(db, sql: "SELECT MIN(last_date) FROM threads") ?? 0 }
        let total = try await db.reader.read { db in try ThreadQueries.threadCount(db, accountID: "acc") }
        // Pages of 100 threads, one per day: stops after the page that crosses ~92 days.
        #expect(total <= 200)
        #expect(Date(millis: oldest) < Date().addingTimeInterval(-85 * 86400))
        #expect(try await db.account(id: "acc")?.backfillDone == true)
    }

    @Test func backfillResumesFromTheSavedCursor() async throws {
        let server = FakeGmailServer()
        seedServer(server, threads: 250)
        let db = try await seededDatabase()
        try await makeEngine(server, db: db).firstSync()

        // The first engine goes offline after its first backfill page.
        let calls = server.calls.count
        let engine = makeEngine(server, db: db)
        let task = Task { try await engine.backfill() }
        while server.calls.filter({ $0 == "listThreads" }).count < server.calls.prefix(calls).filter({ $0 == "listThreads" }).count + 2 {
            await Task.yield()
        }
        server.update { $0.offline = true }
        _ = await task.result
        let cursor = try await db.account(id: "acc")?.backfillCursor
        #expect(cursor != nil)

        server.update { $0.offline = false }
        let before = server.calls.count
        try await makeEngine(server, db: db).backfill()
        let lists = server.calls.dropFirst(before).filter { $0 == "listThreads" }.count
        #expect(lists <= 2)
        #expect(try await db.reader.read { db in try ThreadQueries.threadCount(db, accountID: "acc") } == 250)
    }

    @Test func bodiesAreFetchedOnDemand() async throws {
        let server = FakeGmailServer()
        server.addMessage(
            subject: "Old",
            body: "archived body",
            labels: ["CATEGORY_PERSONAL"],
            date: Date().addingTimeInterval(-400 * 86400),
            recordHistory: false
        )
        let db = try await seededDatabase()
        let engine = makeEngine(server, db: db)
        try await engine.firstSync()
        try await engine.backfill()
        let threadID = try #require(try await db.reader.read { db in try String.fetchOne(db, sql: "SELECT id FROM threads") })
        #expect(try await db.reader.read { db in try String.fetchOne(db, sql: "SELECT body_state FROM messages") } == "none")
        try await engine.fetchBodies(threadID: threadID)
        #expect(try await db.reader.read { db in try String.fetchOne(db, sql: "SELECT plain FROM message_bodies") } == "archived body")
    }

    @Test func loadOlderPagesPastTheCache() async throws {
        let server = FakeGmailServer()
        seedServer(server, threads: 300, unread: false)
        let db = try await seededDatabase()
        let engine = makeEngine(server, db: db, window: .threeMonths)
        try await engine.firstSync()
        try await engine.backfill()
        let before = try await db.reader.read { db in try ThreadQueries.threadCount(db, accountID: "acc") }
        let oldest = try await db.reader.read { db in try Int64.fetchOne(db, sql: "SELECT MIN(last_date) FROM threads") ?? 0 }
        let added = try await engine.loadOlder(labelID: nil, before: oldest)
        #expect(added > 0)
        #expect(try await db.reader.read { db in try ThreadQueries.threadCount(db, accountID: "acc") } == before + added)
    }
}
