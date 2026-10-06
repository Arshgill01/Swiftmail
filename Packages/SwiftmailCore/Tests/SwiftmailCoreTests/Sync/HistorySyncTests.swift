import Foundation
import GRDB
@testable import SwiftmailCore
import Synchronization
import Testing

final class EventLog: Sendable {
    private let items = Mutex<[NewMailItem]>([])
    private let removed = Mutex<[String]>([])
    var newMail: [NewMailItem] {
        items.withLock { $0 }
    }

    var removedIDs: [String] {
        removed.withLock { $0 }
    }

    var sink: SyncEventSink {
        SyncEventSink(
            newMail: { mail in self.items.withLock { $0 += mail } },
            removedMessages: { ids in self.removed.withLock { $0 += ids } }
        )
    }
}

/// Local message labels, for comparing with the server.
func localState(_ db: AppDatabase) async throws -> [String: Set<String>] {
    try await db.reader.read { db in
        var state: [String: Set<String>] = [:]
        for id in try String.fetchAll(db, sql: "SELECT id FROM messages") {
            state[id] = []
        }
        for row in try Row.fetchAll(db, sql: "SELECT message_id, label_id FROM message_labels") {
            state[row["message_id"], default: []].insert(row["label_id"])
        }
        return state
    }
}

func serverState(_ server: FakeGmailServer) -> [String: Set<String>] {
    server.update { state in state.messages.mapValues(\.labels) }
}

struct HistorySyncTests {
    func syncedEngine(threads: Int = 20) async throws -> (FakeGmailServer, AppDatabase, SyncEngine, EventLog) {
        let server = FakeGmailServer()
        seedServer(server, threads: threads)
        let db = try await seededDatabase()
        let engine = makeEngine(server, db: db)
        try await engine.firstSync()
        try await engine.backfill()
        let log = EventLog()
        await engine.setSink(log.sink)
        return (server, db, engine, log)
    }

    @Test func newMailAppearsAndIsReported() async throws {
        let (server, db, engine, log) = try await syncedEngine()
        let (messageID, threadID) = server.addMessage(subject: "Fresh", body: "brand new")
        #expect(try await engine.incrementalSync())
        let inbox = try await db.reader.read { db in try ThreadQueries.threads(db, mailbox: .allInboxes, limit: 5) }
        #expect(inbox.first?.threadID == threadID)
        #expect(log.newMail.map(\.messageID) == [messageID])
        #expect(try await db.account(id: "acc")?.historyId == server.currentHistoryID)
        // A reply in an existing thread is fetched with messages.get.
        server.addMessage(threadID: threadID, subject: "Re: Fresh")
        try await engine.incrementalSync()
        #expect(try await db.reader.read { db in try Int.fetchOne(db, sql: "SELECT message_count FROM threads WHERE id = ?", arguments: [threadID]) } == 2)
        #expect(server.calls.contains("getMessage"))
    }

    @Test func archiveReadAndLabelChangesFromGmailWeb() async throws {
        let (server, db, engine, log) = try await syncedEngine()
        let ids = server.update { Array($0.messages.values.filter { $0.labels.contains("INBOX") && $0.labels.contains("UNREAD") }.map(\.id).prefix(3)) }
        server.serverModify(messageID: ids[0], remove: ["INBOX"])
        server.serverModify(messageID: ids[1], remove: ["UNREAD"])
        server.serverModify(messageID: ids[2], add: ["Label_9", "STARRED"])
        server.update { $0.labels.append(GmailLabel(id: "Label_9", name: "Receipts")) }
        try await engine.incrementalSync()
        let local = try await localState(db)
        #expect(local[ids[0]]?.contains("INBOX") == false)
        #expect(local[ids[1]]?.contains("UNREAD") == false)
        #expect(local[ids[2]]?.isSuperset(of: ["Label_9", "STARRED"]) == true)
        // The unknown label triggered a labels refresh.
        let labelName = try await db.reader.read { db in try String.fetchOne(db, sql: "SELECT name FROM labels WHERE id = 'Label_9'") }
        #expect(labelName == "Receipts")
        #expect(Set(log.removedIDs).isSuperset(of: [ids[0], ids[1]]))
    }

    @Test func deletedMessagesAreRemoved() async throws {
        let (server, db, engine, _) = try await syncedEngine()
        let id = try #require(server.update { $0.messages.keys.sorted().first })
        server.serverDelete(messageID: id)
        try await engine.incrementalSync()
        #expect(try await localState(db)[id] == nil)
    }

    @Test func addedThenDeletedMessageIsSkipped() async throws {
        let (server, db, engine, log) = try await syncedEngine()
        let (messageID, _) = server.addMessage(subject: "Gone soon")
        server.serverDelete(messageID: messageID)
        try await engine.incrementalSync()
        #expect(try await localState(db)[messageID] == nil)
        #expect(log.newMail.isEmpty)
    }

    @Test func duplicateAndReplayedRecordsAreIdempotent() async throws {
        let (server, db, engine, _) = try await syncedEngine()
        let id = try #require(server.update { $0.messages.keys.sorted().first })
        let thread = try #require(server.update { $0.messages[id]?.threadID })
        let ref = GmailMessage(id: id, threadId: thread)
        let records = [
            GmailHistory(id: "1", labelsAdded: [GmailHistoryMessage(message: ref, labelIds: ["STARRED"])]),
            GmailHistory(id: "1", labelsAdded: [GmailHistoryMessage(message: ref, labelIds: ["STARRED"])]),
            GmailHistory(id: "2", labelsRemoved: [GmailHistoryMessage(message: ref, labelIds: ["STARRED"])]),
            GmailHistory(id: "3", labelsAdded: [GmailHistoryMessage(message: ref, labelIds: ["STARRED"])]),
        ]
        _ = try await engine.apply(records, finalHistoryID: nil)
        _ = try await engine.apply(records, finalHistoryID: nil)
        #expect(try await localState(db)[id]?.contains("STARRED") == true)
        #expect(try await db.reader.read { db in try Bool.fetchOne(db, sql: "SELECT is_starred FROM threads WHERE id = ?", arguments: [thread]) } == true)
        // Records for messages that were never local and whose thread is gone are skipped.
        let ghost = GmailMessage(id: "nope", threadId: "nothread")
        _ = try await engine.apply([GmailHistory(id: "4", labelsRemoved: [GmailHistoryMessage(message: ghost, labelIds: ["INBOX"])])], finalHistoryID: nil)
    }

    @Test func expiredHistoryResyncsKeepingBodies() async throws {
        let (server, db, engine, log) = try await syncedEngine(threads: 30)
        let bodiesBefore = try await db.reader.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM message_bodies") ?? 0 }
        // While the app was away: one thread deleted, one archived, one new.
        let all = server.update { $0.messages.values.sorted { $0.date > $1.date } }
        server.serverDelete(messageID: all[1].id)
        server.serverModify(messageID: all[2].id, remove: ["INBOX"])
        let (newID, _) = server.addMessage(subject: "Arrived during expiry")
        server.expireHistory()

        try await engine.incrementalSync()
        #expect(try await db.account(id: "acc")?.status == .syncingFull)
        try await engine.backfill()

        #expect(try await db.account(id: "acc")?.status == .ok)
        #expect(try await db.account(id: "acc")?.historyId == server.currentHistoryID)
        let local = try await localState(db)
        #expect(local[all[1].id] == nil)
        #expect(local[all[2].id]?.contains("INBOX") == false)
        #expect(local[newID] != nil)
        #expect(log.newMail.isEmpty)
        let bodiesAfter = try await db.reader.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM message_bodies") ?? 0 }
        // Every body except the deleted message's survived.
        #expect(bodiesAfter >= bodiesBefore - 1)
        #expect(try await localState(db) == serverState(server))
    }

    @Test func randomServerChangesConverge() async throws {
        let (server, db, engine, _) = try await syncedEngine(threads: 40)
        var random = SyntheticDatabase.Generator(state: 7)
        let labels = ["INBOX", "UNREAD", "STARRED", "IMPORTANT", "Label_1", "TRASH"]
        for round in 0 ..< 5 {
            for _ in 0 ..< 15 {
                let ids = server.update { $0.messages.keys.sorted() }
                switch random.next() % 5 {
                case 0:
                    let existing = random.pick(ids)
                    let thread: String? = random.next() % 2 == 0 ? nil : server.update { $0.messages[existing]?.threadID }
                    server.addMessage(threadID: thread, subject: "Round \(round)")
                case 1:
                    server.serverDelete(messageID: random.pick(ids))
                default:
                    let label = random.pick(labels)
                    if random.next() % 2 == 0 {
                        server.serverModify(messageID: random.pick(ids), add: [label])
                    } else {
                        server.serverModify(messageID: random.pick(ids), remove: [label])
                    }
                }
            }
            try await engine.incrementalSync()
            #expect(try await localState(db) == serverState(server), "round \(round)")
        }
        // Thread rows agree with their messages.
        let mismatches = try await db.reader.read { db in
            try Int.fetchOne(db, sql: """
            SELECT COUNT(*) FROM threads t WHERE t.is_unread != EXISTS (
              SELECT 1 FROM message_labels ml JOIN messages m ON m.id = ml.message_id
              WHERE m.thread_id = t.id AND ml.label_id = 'UNREAD')
            """) ?? -1
        }
        #expect(mismatches == 0)
    }

    @Test func labelCountsRefreshAtMostOncePerMinute() async throws {
        let (server, _, engine, _) = try await syncedEngine()
        try await engine.refreshLabelCountsIfDue(force: true)
        let first = server.calls.filter { $0 == "getLabel" }.count
        #expect(first > 0)
        try await engine.refreshLabelCountsIfDue()
        #expect(server.calls.filter { $0 == "getLabel" }.count == first)
    }

    @Test func offlineDuringSyncReportsOffline() async throws {
        let (server, _, engine, _) = try await syncedEngine()
        server.update { $0.offline = true }
        await #expect(throws: GmailError.offline) { try await engine.incrementalSync() }
        await engine.report(GmailError.offline)
        #expect(await engine.currentStatus().phase == .offline)
    }
}

struct SessionSchedulingTests {
    @Test func triggersDuringARunCoalesce() async throws {
        let server = FakeGmailServer()
        seedServer(server, threads: 5)
        let db = try await seededDatabase()
        let tokens = TokenProvider(accountID: "acc", secrets: InMemorySecretStore(), refresher: { _ in throw AuthError.needsSignIn })
        let session = AccountSession(accountID: "acc", tokens: tokens, client: server, database: db, settings: { SyncSettings(backfillWindow: .everything) })
        await session.start()
        for _ in 0 ..< 20 {
            await session.triggerSync()
        }
        try await Task.sleep(for: .milliseconds(500))
        let runs = await session.runCount
        #expect(runs >= 1)
        #expect(runs <= 3)
        #expect(try await db.account(id: "acc")?.initialSyncDone == true)
        await session.stop()
    }
}
