import Foundation
import GRDB

/// Local drafts (`local_drafts`) and contact suggestions.
public extension AppDatabase {
    func saveLocalDraft(_ state: ComposeState, isOpen: Bool = true) async throws {
        let json = try JSONEncoder.encodeString(state)
        try await writer.write { db in
            try db.execute(sql: """
            INSERT INTO local_drafts (id, account_id, state, is_open, updated_at) VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET account_id = excluded.account_id, state = excluded.state,
              is_open = excluded.is_open, updated_at = excluded.updated_at
            """, arguments: [state.id.uuidString, state.accountID, json, isOpen, Date().millis])
        }
    }

    func deleteLocalDraft(_ id: UUID) async throws {
        try await writer.write { db in
            try db.execute(sql: "DELETE FROM local_drafts WHERE id = ?", arguments: [id.uuidString])
        }
        if let folder = try? AttachmentStorage.url(forRelativePath: "Compose/\(id.uuidString)") {
            try? FileManager.default.removeItem(at: folder)
        }
    }

    func localDraft(_ id: UUID) async throws -> ComposeState? {
        let json = try await reader.read { db in
            try String.fetchOne(db, sql: "SELECT state FROM local_drafts WHERE id = ?", arguments: [id.uuidString])
        }
        return try json.map { try JSONDecoder.decode(ComposeState.self, string: $0) }
    }

    /// Compose windows that were open when the app last quit.
    func openLocalDrafts() async throws -> [UUID] {
        try await reader.read { db in
            try String.fetchAll(db, sql: "SELECT id FROM local_drafts WHERE is_open = 1 ORDER BY updated_at").compactMap(UUID.init)
        }
    }

    func setLocalDraftOpen(_ id: UUID, _ isOpen: Bool) async throws {
        try await writer.write { db in
            try db.execute(sql: "UPDATE local_drafts SET is_open = ? WHERE id = ?", arguments: [isOpen, id.uuidString])
        }
    }
}

public struct ContactSuggestion: Sendable, Equatable, Hashable {
    public let name: String?
    public let email: String

    public var display: String {
        name.map { "\($0) <\(email)>" } ?? email
    }
}

public enum ContactQueries {
    /// Addresses seen in local mail, ranked by how often you write to them.
    public static func suggest(_ db: Database, prefix: String, limit: Int = 8) throws -> [ContactSuggestion] {
        let term = prefix.trimmingCharacters(in: .whitespaces)
        guard !term.isEmpty else { return [] }
        let like = term.replacingOccurrences(of: "%", with: "").replacingOccurrences(of: "_", with: "") + "%"
        let rows = try Row.fetchAll(db, sql: """
        SELECT email, MAX(name) AS name, SUM(times_sent_to) AS sent, MAX(last_seen) AS seen FROM contacts
        WHERE email LIKE ? OR name LIKE ? OR name LIKE ?
        GROUP BY lower(email) ORDER BY sent DESC, seen DESC LIMIT ?
        """, arguments: [like, like, "% " + like, limit])
        return rows.map { ContactSuggestion(name: $0["name"], email: $0["email"]) }
    }
}
