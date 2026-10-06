import Foundation
import GRDB

/// Account rows: add or update on sign-in, status changes, removal of all account data.
public extension AppDatabase {
    /// Inserts the account, or updates name and avatar when it already exists (re-sign-in).
    /// Returns true when the account is new.
    @discardableResult
    func upsertAccount(id: String, email: String, displayName: String?, avatarURL: String?) async throws -> Bool {
        try await writer.write { db in
            if var existing = try AccountRecord.fetchOne(db, key: id) {
                existing.email = email
                existing.displayName = displayName ?? existing.displayName
                existing.avatarUrl = avatarURL ?? existing.avatarUrl
                if existing.status == .needsSignIn {
                    existing.status = .ok
                }
                try existing.update(db)
                return false
            }
            let order = try Int.fetchOne(db, sql: "SELECT COALESCE(MAX(sort_order) + 1, 0) FROM accounts") ?? 0
            let account = AccountRecord(
                id: id, email: email, displayName: displayName, avatarUrl: avatarURL,
                sortOrder: order, addedAt: Date().millis
            )
            try account.insert(db)
            return true
        }
    }

    func setAccountStatus(_ id: String, _ status: AccountStatus) async throws {
        try await writer.write { db in
            try db.execute(sql: "UPDATE accounts SET status = ? WHERE id = ?", arguments: [status.rawValue, id])
        }
    }

    func setCategoriesEnabled(_ id: String, _ enabled: Bool) async throws {
        try await writer.write { db in
            try db.execute(sql: "UPDATE accounts SET categories_enabled = ? WHERE id = ?", arguments: [enabled, id])
        }
    }

    func account(id: String) async throws -> AccountRecord? {
        try await reader.read { db in try AccountRecord.fetchOne(db, key: id) }
    }

    func allAccounts() async throws -> [AccountRecord] {
        try await reader.read { db in
            try AccountRecord.order(Column("sort_order"), Column("added_at")).fetchAll(db)
        }
    }

    /// Deletes every row that belongs to the account, including FTS entries.
    func deleteAccountData(_ id: String) async throws {
        try await writer.write { db in
            try db.execute(sql: """
            DELETE FROM messages_fts WHERE rowid IN (SELECT rowid FROM messages WHERE account_id = ?)
            """, arguments: [id])
            for table in [
                "thread_labels", "message_labels", "message_bodies", "attachments", "contacts",
                "send_as", "pending_actions", "remote_content_allow",
            ] {
                try db.execute(sql: "DELETE FROM \(table) WHERE account_id = ?", arguments: [id])
            }
            // labels, threads and messages cascade from accounts.
            try db.execute(sql: "DELETE FROM accounts WHERE id = ?", arguments: [id])
        }
    }
}
