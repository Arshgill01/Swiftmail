import Foundation
import GRDB
@testable import SwiftmailCore
import XCTest

/// Budgets: thread-list query fast enough for instant paging on 30,000 threads /
/// 100,000 messages. Each test builds the synthetic database once per class.
final class StorePerformanceTests: XCTestCase {
    nonisolated(unsafe) static var shared: AppDatabase?

    override static func setUp() {
        super.setUp()
        let database = try? AppDatabase.temporary()
        if let database {
            try? SyntheticDatabase.populate(database, threads: 30000, messages: 100_000)
        }
        shared = database
    }

    func database() throws -> AppDatabase {
        try XCTUnwrap(Self.shared)
    }

    func testInboxFirstPageQuery() throws {
        let db = try database()
        let mailbox = Mailbox(accountID: "acc", kind: .inbox)
        measure {
            _ = try? db.reader.read { db in try ThreadQueries.threads(db, mailbox: mailbox, category: .primary, limit: 150) }
        }
        let start = Date()
        let threads = try db.reader.read { db in try ThreadQueries.threads(db, mailbox: mailbox, category: .primary, limit: 150) }
        XCTAssertEqual(threads.count, 150)
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.05, "first inbox page must load in under 50 ms")
    }

    func testDeepPageQuery() throws {
        let db = try database()
        let mailbox = Mailbox.allInboxes
        let start = Date()
        let threads = try db.reader.read { db in try ThreadQueries.threads(db, mailbox: mailbox, limit: 10000) }
        XCTAssertEqual(threads.count, 10000)
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.5, "10,000 rows must page in under 500 ms")
    }

    func testSidebarSnapshot() throws {
        let db = try database()
        let start = Date()
        let snapshot = try db.reader.read { db in try SidebarQueries.snapshot(db) }
        XCTAssertEqual(snapshot.accounts.count, 1)
        XCTAssertGreaterThan(snapshot.unifiedInboxUnread, 0)
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.15, "sidebar counts must stay cheap")
    }

    func testOpenCachedConversation() throws {
        let db = try database()
        let start = Date()
        let conversation = try db.reader.read { db in try ConversationQueries.conversation(db, accountID: "acc", threadID: "t000100") }
        XCTAssertNotNil(conversation)
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.05, "opening a cached thread must read in under 50 ms")
    }

    func testLocalSearchOn100kMessages() throws {
        let db = try database()
        let query = SearchQuery("quarterly report")
        measure {
            _ = try? db.reader.read { db in try LocalSearch.threads(db, query: query, accountID: nil, limit: 50) }
        }
        for text in ["invoice", "from:priya", "budget meeting", "rev"] {
            let start = Date()
            let results = try db.reader.read { db in try LocalSearch.threads(db, query: SearchQuery(text), accountID: nil, limit: 50) }
            XCTAssertFalse(results.isEmpty, text)
            XCTAssertLessThan(Date().timeIntervalSince(start), 0.1, "local search for \(text) must answer in under 100 ms")
        }
    }
}
