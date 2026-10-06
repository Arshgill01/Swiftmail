import Foundation
import GRDB
@testable import SwiftmailCore
import Testing

func makeMessage(
    _ id: String, thread: String, labels: [String], date: Int64, from: String = "Alex <alex@example.com>",
    subject: String = "Hi", body: String? = "body", format: MessageFormat = .full
) -> GmailMessage {
    var headers = [
        GmailHeader(name: "From", value: from), GmailHeader(name: "To", value: "me@example.com"),
        GmailHeader(name: "Subject", value: subject),
    ]
    var payload = GmailMessagePart(partId: "", mimeType: "text/plain", headers: headers)
    if format == .full, let body {
        headers.append(GmailHeader(name: "Content-Type", value: "text/plain; charset=utf-8"))
        payload = GmailMessagePart(
            partId: "",
            mimeType: "text/plain",
            headers: headers,
            body: GmailMessagePartBody(size: body.utf8.count, data: Base64URL.encode(Data(body.utf8)))
        )
    }
    return GmailMessage(
        id: id,
        threadId: thread,
        labelIds: labels,
        snippet: "snip &amp; more",
        historyId: "1",
        internalDate: String(date),
        sizeEstimate: 100,
        payload: payload
    )
}

func seededDatabase() async throws -> AppDatabase {
    let db = try AppDatabase.inMemory()
    try await db.upsertAccount(id: "acc", email: "me@example.com", displayName: "Me", avatarURL: nil)
    return db
}

struct MailWriterTests {
    @Test func threadLabelsAreTheUnionAndFlagsFollow() async throws {
        let db = try await seededDatabase()
        let thread = GmailThread(id: "t1", messages: [
            makeMessage("m1", thread: "t1", labels: ["INBOX", "STARRED"], date: 1000),
            makeMessage("m2", thread: "t1", labels: ["INBOX", "UNREAD", "Label_1"], date: 2000, from: "Bo <bo@x.com>"),
        ])
        _ = try await db.writer.write { db in
            try MailWriter.upsertThread(db, accountID: "acc", thread: thread, format: .full)
        }
        try await db.reader.read { db in
            let labels = try Set(String.fetchAll(db, sql: "SELECT label_id FROM thread_labels WHERE thread_id = 't1'"))
            #expect(labels == ["INBOX", "STARRED", "UNREAD", "Label_1"])
            let row = try #require(try ThreadRecord.fetchOne(db, key: ["account_id": "acc", "id": "t1"]))
            #expect(row.isUnread && row.isStarred && !row.isImportant)
            #expect(row.lastDate == 2000)
            #expect(row.messageCount == 2)
            #expect(row.snippet == "snip & more")
            #expect(EmailAddress.decodeJSON(row.participants).map(\.email) == ["alex@example.com", "bo@x.com"])
            let lastDates = try Set(Int64.fetchAll(db, sql: "SELECT last_date FROM thread_labels WHERE thread_id = 't1'"))
            #expect(lastDates == [2000])
        }
    }

    @Test func removingLabelsRecomputesTheThread() async throws {
        let db = try await seededDatabase()
        _ = try await db.writer.write { db in
            try MailWriter.upsertThread(db, accountID: "acc", thread: GmailThread(id: "t1", messages: [
                makeMessage("m1", thread: "t1", labels: ["INBOX", "UNREAD"], date: 1000),
            ]), format: .full)
            try MailWriter.modifyMessageLabels(db, accountID: "acc", messageID: "m1", add: [], remove: ["INBOX", "UNREAD"])
            try MailWriter.recomputeThread(db, accountID: "acc", threadID: "t1")
        }
        let inbox = try await db.reader.read { db in try ThreadQueries.threads(
            db,
            mailbox: Mailbox(accountID: "acc", kind: .inbox),
            limit: 10
        ) }
        #expect(inbox.isEmpty)
        let all = try await db.reader.read { db in try ThreadQueries.threads(
            db,
            mailbox: Mailbox(accountID: "acc", kind: .allMail),
            limit: 10
        ) }
        #expect(all.map(\.threadID) == ["t1"])
        #expect(all.first?.isUnread == false)
    }

    @Test func ftsIndexesMetadataThenBody() async throws {
        let db = try await seededDatabase()
        _ = try await db.writer.write { db in
            try MailWriter.upsertMessage(db, accountID: "acc", message: makeMessage(
                "m1", thread: "t1", labels: ["INBOX"], date: 1, subject: "Quarterly report", format: .metadata
            ), format: .metadata)
            try MailWriter.recomputeThread(db, accountID: "acc", threadID: "t1")
        }
        func hits(_ term: String) async throws -> Int {
            try await db.reader.read { db in
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM messages_fts WHERE messages_fts MATCH ?", arguments: [term]) ?? 0
            }
        }
        #expect(try await hits("quarterly") == 1)
        #expect(try await hits("pineapple") == 0)
        _ = try await db.writer.write { db in
            try MailWriter.upsertMessage(db, accountID: "acc", message: makeMessage(
                "m1", thread: "t1", labels: ["INBOX"], date: 1, subject: "Quarterly report", body: "pineapple numbers"
            ), format: .full)
        }
        #expect(try await hits("pineapple") == 1)
        #expect(try await hits("quarterly") == 1)
        _ = try await db.writer.write { db in
            _ = try MailWriter.deleteMessage(db, accountID: "acc", messageID: "m1")
        }
        #expect(try await hits("pineapple") == 0)
    }

    @Test func metadataUpdateKeepsDownloadedBody() async throws {
        let db = try await seededDatabase()
        _ = try await db.writer.write { db in
            try MailWriter.upsertMessage(
                db,
                accountID: "acc",
                message: makeMessage("m1", thread: "t1", labels: ["INBOX"], date: 1),
                format: .full
            )
            try MailWriter.upsertMessage(db, accountID: "acc", message: makeMessage(
                "m1", thread: "t1", labels: ["INBOX", "STARRED"], date: 1, format: .metadata
            ), format: .metadata)
        }
        let (state, body) = try await db.reader.read { db in
            try (
                String.fetchOne(db, sql: "SELECT body_state FROM messages WHERE id = 'm1'"),
                String.fetchOne(db, sql: "SELECT plain FROM message_bodies WHERE message_id = 'm1'")
            )
        }
        #expect(state == "ready")
        #expect(body == "body")
    }

    @Test func categoriesAndUnreadCounts() async throws {
        let db = try await seededDatabase()
        _ = try await db.writer.write { db in
            try MailWriter.upsertThread(db, accountID: "acc", thread: GmailThread(id: "p", messages: [
                makeMessage("m1", thread: "p", labels: ["INBOX", "UNREAD", "CATEGORY_PERSONAL"], date: 3),
            ]), format: .full)
            try MailWriter.upsertThread(db, accountID: "acc", thread: GmailThread(id: "promo", messages: [
                makeMessage("m2", thread: "promo", labels: ["INBOX", "UNREAD", "CATEGORY_PROMOTIONS"], date: 2),
            ]), format: .full)
        }
        let inbox = Mailbox(accountID: "acc", kind: .inbox)
        let primary = try await db.reader.read { db in try ThreadQueries.threads(db, mailbox: inbox, category: .primary, limit: 10) }
        let promos = try await db.reader.read { db in try ThreadQueries.threads(db, mailbox: inbox, category: .promotions, limit: 10) }
        #expect(primary.map(\.threadID) == ["p"])
        #expect(promos.map(\.threadID) == ["promo"])
        #expect(try await db.reader.read { db in try ThreadQueries.unreadInboxCount(db, accountID: nil, primaryWhenTabsOn: true) } == 1)
        let byCategory = try await db.reader.read { db in try ThreadQueries.unreadInboxCountsByCategory(db, accountID: "acc") }
        #expect(byCategory == [.primary: 1, .promotions: 1])
        try await db.setCategoriesEnabled("acc", false)
        #expect(try await db.reader.read { db in try ThreadQueries.unreadInboxCount(db, accountID: nil, primaryWhenTabsOn: true) } == 2)
    }
}
