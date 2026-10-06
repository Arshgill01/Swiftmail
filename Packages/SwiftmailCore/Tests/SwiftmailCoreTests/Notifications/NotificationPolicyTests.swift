import Foundation
import GRDB
@testable import SwiftmailCore
import Testing

struct NotificationPolicyTests {
    func setUp(_ messages: [(String, [String], String)]) async throws -> (AppDatabase, [NewMailItem]) {
        let db = try await seededDatabase()
        try await db.writer.write { db in
            for (index, (id, labels, from)) in messages.enumerated() {
                try MailWriter.upsertThread(db, accountID: "acc", thread: GmailThread(id: "t\(index)", messages: [
                    makeMessage(id, thread: "t\(index)", labels: labels, date: Int64(index), from: from, subject: "Subject \(index)"),
                ]), format: .full)
            }
        }
        let items = messages.enumerated().map { index, message in
            NewMailItem(accountID: "acc", threadID: "t\(index)", messageID: message.0, labelIDs: message.1)
        }
        return (db, items)
    }

    func plan(_ db: AppDatabase, _ items: [NewMailItem], settings: NotificationPolicy.AccountSettings = .init()) async throws -> NotificationPlan {
        try await db.reader.read { db in try NotificationPolicy.plan(items, db: db, settings: { _ in settings }) }
    }

    @Test func onlyUnreadPrimaryInboxMailFromOthers() async throws {
        let (db, items) = try await setUp([
            ("ok", ["INBOX", "UNREAD", "CATEGORY_PERSONAL"], "Alex <alex@example.com>"),
            ("read", ["INBOX", "CATEGORY_PERSONAL"], "Alex <alex@example.com>"),
            ("archived", ["UNREAD"], "Alex <alex@example.com>"),
            ("promo", ["INBOX", "UNREAD", "CATEGORY_PROMOTIONS"], "Shop <shop@example.com>"),
            ("mine", ["INBOX", "UNREAD"], "Me <me@example.com>"),
        ])
        guard case let .messages(list) = try await plan(db, items) else { Issue.record("expected messages"); return }
        #expect(list.map(\.identifier) == ["acc:ok"])
        #expect(list.first?.title == "Alex")
        #expect(list.first?.subtitle == "Subject 0")
        #expect(list.first?.threadIdentifier == "acc:t0")
    }

    @Test func allInboxModeAndTabsOff() async throws {
        let (db, items) = try await setUp([("promo", ["INBOX", "UNREAD", "CATEGORY_PROMOTIONS"], "Shop <shop@example.com>")])
        #expect(try await plan(db, items, settings: .init(primaryOnly: false)) != .none)
        try await db.setCategoriesEnabled("acc", false)
        #expect(try await plan(db, items) != .none)
        #expect(try await plan(db, items, settings: .init(enabled: false)) == .none)
    }

    @Test func moreThanTenBecomesASummary() async throws {
        let (db, items) = try await setUp((0 ..< 12).map { ("m\($0)", ["INBOX", "UNREAD"], "Alex <alex@example.com>") })
        #expect(try await plan(db, items) == .summary(accountID: "acc", count: 12))
    }

    @Test func firstSyncNeverNotifies() async throws {
        let server = FakeGmailServer()
        seedServer(server, threads: 20)
        let db = try await seededDatabase()
        let log = EventLog()
        let engine = makeEngine(server, db: db)
        await engine.setSink(log.sink)
        try await engine.firstSync()
        try await engine.backfill()
        #expect(log.newMail.isEmpty)
        server.expireHistory()
        try await engine.incrementalSync()
        try await engine.backfill()
        #expect(log.newMail.isEmpty)
    }
}
