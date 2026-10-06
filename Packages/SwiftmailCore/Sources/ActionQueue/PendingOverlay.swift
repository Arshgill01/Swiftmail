import Foundation
import GRDB

/// Merge rule: while a thread has a queued or in-flight action, incoming history is
/// applied underneath it and the local optimistic state is shown until it completes.
enum PendingOverlay {
    static func reapply(_ db: Database, accountID: String, threadIDs: Set<String>) throws {
        guard !threadIDs.isEmpty else { return }
        let rows = try PendingActionRecord.fetchAll(db, sql: """
        SELECT * FROM pending_actions WHERE account_id = ? AND kind = ? AND state IN ('queued', 'in_flight') ORDER BY id
        """, arguments: [accountID, PendingKind.modify])
        for row in rows {
            guard let payload = try? JSONDecoder.decode(ModifyPayload.self, string: row.payload),
                  !threadIDs.isDisjoint(with: payload.threadIDs) else { continue }
            let messages = try String.fetchAll(db, sql: """
            SELECT id FROM messages WHERE account_id = ? AND id IN (\(databaseQuestionMarks(count: payload.messageIDs.count)))
            """, arguments: StatementArguments([accountID] + payload.messageIDs))
            try MailActions.applyLocally(db, accountID: accountID, messageIDs: messages, add: payload.add, remove: payload.remove)
        }
    }
}
