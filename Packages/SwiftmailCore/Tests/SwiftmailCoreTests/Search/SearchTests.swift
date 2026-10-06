import Foundation
import GRDB
@testable import SwiftmailCore
import Testing

struct SearchTests {
    @Test func parsesGmailSyntax() {
        let query = SearchQuery(#"from:alex subject:"quarterly report" has:attachment is:unread budget older_than:2d"#)
        #expect(query.from == ["alex"])
        #expect(query.subject == ["quarterly report"])
        #expect(query.hasAttachment && query.isUnread)
        #expect(query.terms == ["budget"])
        #expect(query.unsupported == ["older_than:2d"])
        #expect(!query.isFullyLocal)
        #expect(query.ftsExpression == #""budget"* AND from_text : ("alex"*) AND subject : ("quarterly"* "report"*)"#)
        // Odd input never produces an invalid MATCH expression.
        #expect(SearchQuery(#"a"b*c( NEAR"#).ftsExpression?.contains("(") == false)
    }

    func indexedDatabase() async throws -> AppDatabase {
        let db = try await seededDatabase()
        try await db.writer.write { db in
            let threads: [(String, String, String, String, [String])] = [
                ("t1", "Alex Rivera <alex@example.com>", "Quarterly report", "Numbers for the quarter", ["INBOX", "UNREAD"]),
                ("t2", "Sam Kim <sam@example.com>", "Lunch", "Pizza or tacos? Alex says tacos", ["INBOX"]),
                ("t3", "Priya Patel <priya@example.com>", "Trip photos", "Photos from the café", ["Label_1"]),
            ]
            for (index, (thread, from, subject, body, labels)) in threads.enumerated() {
                try MailWriter.upsertThread(db, accountID: "acc", thread: GmailThread(id: thread, messages: [
                    makeMessage("m\(index)", thread: thread, labels: labels, date: Int64(1000 * (index + 1)), from: from, subject: subject, body: body),
                ]), format: .full)
            }
            try db.execute(sql: "INSERT INTO labels (account_id, id, name, type) VALUES ('acc', 'Label_1', 'Travel', 'user')")
        }
        return db
    }

    func search(_ db: AppDatabase, _ text: String) async throws -> [String] {
        try await db.reader.read { db in try LocalSearch.threads(db, query: SearchQuery(text), accountID: nil).map(\.threadID) }
    }

    @Test func localSearchFindsBodiesSendersAndPrefixes() async throws {
        let db = try await indexedDatabase()
        #expect(try await search(db, "quart") == ["t1"])
        #expect(try await search(db, "tacos") == ["t2"])
        #expect(try await search(db, "alex") == ["t2", "t1"])
        #expect(try await search(db, "from:alex") == ["t1"])
        #expect(try await search(db, "subject:lunch") == ["t2"])
        #expect(try await search(db, "cafe") == ["t3"])
        #expect(try await search(db, "is:unread") == ["t1"])
        #expect(try await search(db, "label:travel") == ["t3"])
        #expect(try await search(db, "pineapple").isEmpty)
    }

    @Test func serverOnlyResultsAreFetchedAndOpenable() async throws {
        let server = FakeGmailServer()
        // A full backfill page of mail older than the window sits in front of the old invoice.
        for day in 100 ..< 220 {
            server.addMessage(
                subject: "Filler \(day)",
                labels: ["CATEGORY_PERSONAL"],
                date: Date().addingTimeInterval(-Double(day) * 86400),
                recordHistory: false
            )
        }
        server.addMessage(
            subject: "Ancient invoice",
            body: "from long ago",
            labels: ["CATEGORY_PERSONAL"],
            date: Date().addingTimeInterval(-900 * 86400),
            recordHistory: false
        )
        let db = try await seededDatabase()
        let engine = makeEngine(server, db: db, window: .threeMonths)
        try await engine.firstSync()
        try await engine.backfill()
        #expect(try await search(db, "invoice").isEmpty)
        let serverIDs = try await engine.serverSearch("invoice")
        #expect(serverIDs.count == 1)
        let summaries = try await db.reader.read { db in
            try ThreadQueries.threads(db, ids: serverIDs.map { ThreadSummary.ID(accountID: "acc", threadID: $0) })
        }
        #expect(summaries.first?.subject == "Ancient invoice")
        let conversation = try await db.reader.read { db in try ConversationQueries.conversation(db, accountID: "acc", threadID: serverIDs[0]) }
        #expect(conversation?.messages.count == 1)
    }

    @Test func mergeKeepsLocalFirstWithoutDuplicates() {
        let id = { (thread: String) in ThreadSummary.ID(accountID: "a", threadID: thread) }
        #expect(SearchMerge.merge(local: [id("1"), id("2")], server: [id("2"), id("3")]) == [id("1"), id("2"), id("3")])
    }
}
