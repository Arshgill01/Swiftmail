import Foundation
import GRDB
@testable import SwiftmailCore
import Synchronization
import Testing

final class Messages: Sendable {
    private let items = Mutex<[String]>([])
    var all: [String] {
        items.withLock { $0 }
    }

    func append(_ text: String) {
        items.withLock { $0.append(text) }
    }
}

struct ActionQueueTests {
    struct Setup {
        let server: FakeGmailServer
        let db: AppDatabase
        let engine: SyncEngine
        let queue: ActionQueue
        let clock: Clock
        let failures: Messages
    }

    func setUp(threads: Int = 10) async throws -> Setup {
        let server = FakeGmailServer()
        seedServer(server, threads: threads)
        let db = try await seededDatabase()
        let engine = makeEngine(server, db: db)
        try await engine.firstSync()
        try await engine.backfill()
        let clock = Clock()
        let queue = ActionQueue(accountID: "acc", client: server, database: db, now: { clock.now })
        let failures = Messages()
        await queue.setHandlers(onFailure: { failures.append($0) }, onDrained: {})
        return Setup(server: server, db: db, engine: engine, queue: queue, clock: clock, failures: failures)
    }

    func inboxIDs(_ db: AppDatabase) async throws -> [String] {
        try await db.reader.read { db in
            try ThreadQueries.threads(db, mailbox: Mailbox(accountID: "acc", kind: .inbox), limit: 1000).map(\.threadID)
        }
    }

    func id(_ thread: String) -> ThreadSummary.ID {
        ThreadSummary.ID(accountID: "acc", threadID: thread)
    }

    func serverThreadLabels(_ server: FakeGmailServer, _ thread: String) -> Set<String> {
        server.update { $0.messages.values.filter { $0.threadID == thread }.reduce(into: Set<String>()) { $0.formUnion($1.labels) } }
    }

    @Test func archiveAppliesLocallyAtOnceThenSyncs() async throws {
        let setup = try await setUp()
        let target = try #require(try await inboxIDs(setup.db).first)
        let start = Date()
        let undo = try await MailActions.perform(.archive, threads: [id(target)], in: setup.db)
        #expect(Date().timeIntervalSince(start) < 0.05)
        #expect(undo.count == 1)
        #expect(try await !inboxIDs(setup.db).contains(target))
        #expect(serverThreadLabels(setup.server, target).contains("INBOX"))
        await setup.queue.drain()
        #expect(!serverThreadLabels(setup.server, target).contains("INBOX"))
        #expect(setup.server.calls.contains("modifyThread"))
    }

    @Test func manyThreadsUseBatchModify() async throws {
        let setup = try await setUp(threads: 20)
        let targets = try await inboxIDs(setup.db).prefix(8).map { id($0) }
        try await MailActions.perform(.markRead, threads: Array(targets), in: setup.db)
        await setup.queue.drain()
        #expect(setup.server.calls.contains("batchModify"))
        #expect(!setup.server.calls.contains("modifyThread"))
    }

    @Test func offlineActionsApplyAfterReconnecting() async throws {
        let setup = try await setUp()
        let target = try #require(try await inboxIDs(setup.db).first)
        setup.server.update { $0.offline = true }
        try await MailActions.perform(.star, threads: [id(target)], in: setup.db)
        await setup.queue.drain()
        let pending = try await setup.db.reader.read { db in try PendingActionRecord.fetchAll(db) }
        #expect(pending.first?.state == .queued)
        #expect(pending.first?.attempts == 0)
        #expect(try await setup.db.reader.read { db in try Bool.fetchOne(db, sql: "SELECT is_starred FROM threads WHERE id = ?", arguments: [target]) } == true)
        setup.server.update { $0.offline = false }
        await setup.queue.drain()
        #expect(serverThreadLabels(setup.server, target).contains("STARRED"))
        #expect(setup.failures.all.isEmpty)
    }

    @Test func undoBeforeSendingCancelsTheAction() async throws {
        let setup = try await setUp()
        let target = try #require(try await inboxIDs(setup.db).first)
        let records = try await MailActions.perform(.archive, threads: [id(target)], in: setup.db)
        let outcome = try await MailActions.undo(#require(records.first), in: setup.db)
        #expect(outcome == .cancelled)
        #expect(try await inboxIDs(setup.db).contains(target))
        await setup.queue.drain()
        #expect(!setup.server.calls.contains("modifyThread"))
    }

    @Test func undoAfterSendingReversesServerState() async throws {
        let setup = try await setUp()
        let target = try #require(try await inboxIDs(setup.db).first)
        let before = serverThreadLabels(setup.server, target)
        let records = try await MailActions.perform(.trash, threads: [id(target)], in: setup.db)
        await setup.queue.drain()
        #expect(serverThreadLabels(setup.server, target).contains("TRASH"))
        let outcome = try await MailActions.undo(#require(records.first), in: setup.db)
        #expect(outcome == .reversed)
        #expect(try await inboxIDs(setup.db).contains(target))
        await setup.queue.drain()
        #expect(serverThreadLabels(setup.server, target) == before)
        // A second undo has nothing left to do.
        #expect(try await MailActions.undo(#require(records.first), in: setup.db) == .nothingToUndo)
    }

    @Test func failingActionRollsBackAfterFiveAttempts() async throws {
        let setup = try await setUp()
        let target = try #require(try await inboxIDs(setup.db).first)
        setup.server.update { $0.failNext = Array(repeating: GmailError.server(503), count: 10) }
        try await MailActions.perform(.archive, threads: [id(target)], in: setup.db)
        for _ in 0 ..< 6 {
            await setup.queue.drain()
            setup.clock.advance(120)
        }
        #expect(try await inboxIDs(setup.db).contains(target))
        #expect(try await setup.db.reader.read { db in try PendingActionRecord.fetchCount(db) } == 0)
        #expect(setup.failures.all.count == 1)
        #expect(setup.failures.all.first?.contains("archive") == true)
    }

    @Test func permanentErrorRollsBackImmediately() async throws {
        let setup = try await setUp()
        let target = try #require(try await inboxIDs(setup.db).first)
        setup.server.update { $0.failNext = [GmailError.http(400, reason: "invalidArgument")] }
        try await MailActions.perform(.archive, threads: [id(target)], in: setup.db)
        await setup.queue.drain()
        #expect(try await inboxIDs(setup.db).contains(target))
        #expect(setup.failures.all.count == 1)
    }

    @Test func historyDuringAPendingActionKeepsTheOptimisticState() async throws {
        let setup = try await setUp()
        let target = try #require(try await inboxIDs(setup.db).first)
        setup.server.update { $0.offline = false }
        try await MailActions.perform(.archive, threads: [id(target)], in: setup.db)
        // Gmail web stars the thread before our archive is sent.
        let message = try #require(setup.server.update { $0.messages.values.first { $0.threadID == target }?.id })
        setup.server.serverModify(messageID: message, add: ["STARRED"])
        try await setup.engine.incrementalSync()
        let labels = try await setup.db.reader.read { db in
            try Set(String.fetchAll(db, sql: "SELECT label_id FROM thread_labels WHERE thread_id = ?", arguments: [target]))
        }
        #expect(labels.contains("STARRED"))
        #expect(!labels.contains("INBOX"))
        await setup.queue.drain()
        try await setup.engine.incrementalSync()
        #expect(try await localState(setup.db) == serverState(setup.server))
    }

    @Test func trashedThreadsLeaveOtherViews() async throws {
        let setup = try await setUp()
        let target = try #require(try await inboxIDs(setup.db).first)
        try await MailActions.perform(.star, threads: [id(target)], in: setup.db)
        try await MailActions.perform(.trash, threads: [id(target)], in: setup.db)
        let starred = try await setup.db.reader.read { db in
            try ThreadQueries.threads(db, mailbox: Mailbox(accountID: "acc", kind: .starred), limit: 100).map(\.threadID)
        }
        let trash = try await setup.db.reader.read { db in
            try ThreadQueries.threads(db, mailbox: Mailbox(accountID: "acc", kind: .trash), limit: 100).map(\.threadID)
        }
        #expect(!starred.contains(target))
        #expect(trash.contains(target))
    }

    @Test func starAndUnreadTouchOnlyTheNewestMessage() async throws {
        let setup = try await setUp()
        let target = try #require(try await inboxIDs(setup.db).first)
        setup.server.addMessage(threadID: target, subject: "Re", labels: ["INBOX"])
        try await setup.engine.incrementalSync()
        try await MailActions.perform(.markRead, threads: [id(target)], in: setup.db)
        try await MailActions.perform(.markUnread, threads: [id(target)], in: setup.db)
        let unread = try await setup.db.reader.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM messages WHERE thread_id = ? AND is_unread = 1", arguments: [target])
        }
        #expect(unread == 1)
    }
}

struct CommandRouterTests {
    @Test(arguments: CommandRouter.singleKeys.sorted { $0.key < $1.key })
    func singleKeysMap(_ pair: (key: String, value: MailCommand)) {
        var router = CommandRouter()
        #expect(router.route(.character(pair.key), modifiers: [], isTextInput: false) == pair.value)
    }

    @Test func goSequences() {
        var router = CommandRouter()
        let start = Date()
        for (key, command) in CommandRouter.goKeys {
            #expect(router.route(.character("g"), modifiers: [], isTextInput: false, now: start) == nil)
            #expect(router.route(.character(key), modifiers: [], isTextInput: false, now: start.addingTimeInterval(0.5)) == command)
        }
        // Too slow: the second key acts on its own.
        _ = router.route(.character("g"), modifiers: [], isTextInput: false, now: start)
        #expect(router.route(.character("s"), modifiers: [], isTextInput: false, now: start.addingTimeInterval(3)) == .toggleStar)
    }

    @Test func ignoredInTextFieldsAndWithModifiers() {
        var router = CommandRouter()
        #expect(router.route(.character("e"), modifiers: [], isTextInput: true) == nil)
        #expect(router.route(.character("e"), modifiers: [.command], isTextInput: false) == nil)
        #expect(router.route(.character("e"), modifiers: [.option], isTextInput: false) == nil)
        #expect(router.route(.character("I"), modifiers: [.shift], isTextInput: false) == .markRead)
        #expect(router.route(.returnKey, modifiers: [], isTextInput: false) == .open)
        #expect(router.route(.escape, modifiers: [], isTextInput: false) == .back)
        #expect(router.route(.delete, modifiers: [], isTextInput: false) == .trash)
        #expect(router.route(.delete, modifiers: [], isTextInput: true) == nil)
    }
}
