import Foundation
import GRDB
@testable import SwiftmailCore
import Testing

/// Prints the slowest SQL statements of one archive on a large store. Diagnostic only;
/// enabled with SWIFTMAIL_PROFILE=1.
struct ActionProfileTool {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["SWIFTMAIL_PROFILE"] != nil))
    func profileArchive() async throws {
        let db = try AppDatabase.temporary()
        try SyntheticDatabase.populate(db, threads: 30000, messages: 100_000)
        try await db.writer.write { db in
            db.trace(options: .profile) { event in
                if case let .profile(statement, duration) = event, duration > 0.002 {
                    print("SLOW_SQL \(Int(duration * 1000)) ms: \(statement.sql.prefix(160))")
                }
            }
        }
        try await MailActions.perform(.archive, threads: [ThreadSummary.ID(accountID: "acc", threadID: "t001000")], in: db)
    }
}
