import Foundation
import GRDB
@testable import SwiftmailCore

/// Builds a large synthetic mailbox directly with SQL (fast), for performance tests and
/// for previewing the UI with a debug-only database. Never part of the app target.
enum SyntheticDatabase {
    static let firstNames = ["Alex", "Sam", "Priya", "Jordan", "Mina", "Chen", "Lucía", "Omar", "Hana", "Ravi", "Zoe", "Kai"]
    static let lastNames = ["Rivera", "Patel", "Kim", "Okafor", "Novak", "Silva", "Haddad", "Larsen", "Ito", "Moreau"]
    static let words = """
    project update meeting invoice quarterly report design review launch plan budget travel itinerary dinner
    weekend photos contract draft feedback roadmap hiring interview offer receipt order shipping delivery
    newsletter release notes security alert password reset welcome onboarding schedule agenda notes summary
    """.split(whereSeparator: \.isWhitespace).map(String.init)

    struct Generator {
        var state: UInt64

        mutating func next() -> UInt64 {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return state >> 33
        }

        mutating func pick<T>(_ items: [T]) -> T {
            items[Int(next() % UInt64(items.count))]
        }

        mutating func sentence(_ count: Int) -> String {
            (0 ..< count).map { _ in pick(SyntheticDatabase.words) }.joined(separator: " ")
        }
    }

    /// `threads` threads holding `messages` messages in total, for one account.
    static func populate(_ database: AppDatabase, accountID: String = "acc", threads: Int, messages: Int, now: Date = Date()) throws {
        try database.writer.write { db in
            try db.execute(sql: """
            INSERT OR IGNORE INTO accounts (id, email, display_name, added_at, initial_sync_done, backfill_done)
            VALUES (?, 'me@example.com', 'Me', 0, 1, 1)
            """, arguments: [accountID])
            for label in [
                "INBOX",
                "SENT",
                "DRAFT",
                "STARRED",
                "IMPORTANT",
                "UNREAD",
                "SPAM",
                "TRASH",
                "CATEGORY_PERSONAL",
                "CATEGORY_SOCIAL",
                "CATEGORY_PROMOTIONS",
                "CATEGORY_UPDATES",
                "CATEGORY_FORUMS",
            ] {
                try db.execute(
                    sql: "INSERT OR IGNORE INTO labels (account_id, id, name, type) VALUES (?, ?, ?, 'system')",
                    arguments: [accountID, label, label]
                )
            }
            let userLabels = [("Label_1", "Work", "#16a766"), ("Label_2", "Work/Clients", "#4a86e8"), ("Label_3", "Travel", "#f691b3")]
            for (id, name, color) in userLabels {
                try db.execute(
                    sql: "INSERT OR IGNORE INTO labels (account_id, id, name, type, color_bg, color_text) VALUES (?, ?, ?, 'user', ?, '#ffffff')",
                    arguments: [accountID, id, name, color]
                )
            }
            var random = Generator(state: 42)
            let insertMessage = try db.makeStatement(sql: """
            INSERT INTO messages (account_id, id, thread_id, internal_date, from_name, from_email, to_json, subject, snippet,
              is_unread, body_state) VALUES (?, ?, ?, ?, ?, ?, '[{"email":"me@example.com"}]', ?, ?, ?, 'ready')
            """)
            let insertLabel = try db.makeStatement(sql: "INSERT INTO message_labels VALUES (?, ?, ?)")
            let insertBody = try db.makeStatement(sql: """
            INSERT INTO message_bodies (account_id, message_id, plain, body_text, fetched_at) VALUES (?, ?, ?, ?, 0)
            """)
            let insertFTS = try db.makeStatement(sql: "INSERT INTO messages_fts (rowid, subject, from_text, to_text, body_text) VALUES (?, ?, ?, ?, ?)")
            let insertThread = try db.makeStatement(sql: """
            INSERT INTO threads (account_id, id, subject, snippet, last_date, participants, message_count, has_attachments,
              is_unread, is_starred, is_important) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0)
            """)
            let insertThreadLabel = try db.makeStatement(sql: "INSERT INTO thread_labels VALUES (?, ?, ?, ?)")
            let perThread = max(1, messages / threads)
            var messageIndex = 0
            for threadIndex in 0 ..< threads {
                let threadID = String(format: "t%06d", threadIndex)
                let lastDate = now.millis - Int64(threadIndex) * 7 * 60 * 1000
                let subject = random.sentence(4).capitalized
                let first = random.pick(firstNames)
                let last = random.pick(lastNames)
                let name = "\(first) \(last)"
                let email = "\(first.lowercased()).\(last.lowercased())@example.com"
                let count = threadIndex == threads - 1 ? max(1, messages - messageIndex) : perThread
                var labels: Set<String> = threadIndex % 4 == 3 ? ["CATEGORY_PERSONAL"] : ["INBOX", "CATEGORY_PERSONAL"]
                if threadIndex % 9 == 0 {
                    labels = ["INBOX", "CATEGORY_PROMOTIONS"]
                }
                if threadIndex % 13 == 0 {
                    labels.insert("STARRED")
                }
                if threadIndex % 17 == 0 {
                    labels.insert("Label_1")
                }
                if threadIndex % 23 == 0 {
                    labels.insert("Label_3")
                }
                let unread = threadIndex % 5 == 0
                var snippet = ""
                for position in 0 ..< count {
                    let messageID = String(format: "m%07d", messageIndex)
                    messageIndex += 1
                    let date = lastDate - Int64(count - 1 - position) * 3_600_000
                    let body = random.sentence(40)
                    snippet = String(body.prefix(90))
                    let isUnread = unread && position == count - 1
                    try insertMessage.execute(arguments: [accountID, messageID, threadID, date, name, email, subject, snippet, isUnread])
                    let rowid = db.lastInsertedRowID
                    var messageLabels = labels
                    if isUnread {
                        messageLabels.insert("UNREAD")
                    }
                    for label in messageLabels {
                        try insertLabel.execute(arguments: [accountID, messageID, label])
                    }
                    try insertBody.execute(arguments: [accountID, messageID, body, body])
                    try insertFTS.execute(arguments: [rowid, subject, "\(name) \(email)", "me@example.com", snippet + "\n" + body])
                }
                if unread {
                    labels.insert("UNREAD")
                }
                let participants = "[{\"name\":\"\(name)\",\"email\":\"\(email)\"}]"
                try insertThread.execute(arguments: [
                    accountID, threadID, subject, snippet, lastDate, participants, count, threadIndex % 11 == 0, unread, labels.contains("STARRED"),
                ])
                for label in labels {
                    try insertThreadLabel.execute(arguments: [accountID, threadID, label, lastDate])
                }
            }
        }
    }
}

extension SyntheticDatabase {
    /// Fills `display_html` for synthetic plain bodies (slow; preview database only).
    static func renderPlainBodies(_ database: AppDatabase) throws {
        try database.writer.write { db in
            let rows = try Row.fetchAll(db, sql: "SELECT account_id, message_id, plain FROM message_bodies WHERE display_html IS NULL")
            let update = try db.makeStatement(sql: "UPDATE message_bodies SET display_html = ? WHERE account_id = ? AND message_id = ?")
            for row in rows {
                let plain: String = row["plain"] ?? ""
                let html = ReaderDocument.wrap(head: "", body: ReaderDocument.escapeText(plain), bodyClass: "sm-simple sm-plain", wrapperStyle: nil)
                try update.execute(arguments: [html, row["account_id"], row["message_id"]])
            }
        }
    }
}

enum GRDBPool {
    static func open(_ path: String) throws -> DatabasePool {
        try DatabasePool(path: path, configuration: AppDatabase.makeConfiguration())
    }
}
