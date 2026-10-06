import Foundation
import GRDB
@testable import SwiftmailCore
import Testing

struct AccountStoreTests {
    @Test func upsertUpdatesInsteadOfDuplicating() async throws {
        let db = try AppDatabase.inMemory()
        #expect(try await db.upsertAccount(id: "sub1", email: "a@example.com", displayName: "A", avatarURL: nil))
        try await db.setAccountStatus("sub1", .needsSignIn)
        #expect(try await !db.upsertAccount(id: "sub1", email: "a@example.com", displayName: "A2", avatarURL: "pic"))
        let accounts = try await db.allAccounts()
        #expect(accounts.count == 1)
        #expect(accounts[0].displayName == "A2")
        #expect(accounts[0].status == .ok)
    }

    @Test func deletingAnAccountRemovesAllItsRows() async throws {
        let db = try AppDatabase.inMemory()
        try await db.upsertAccount(id: "a", email: "a@example.com", displayName: nil, avatarURL: nil)
        try await db.upsertAccount(id: "b", email: "b@example.com", displayName: nil, avatarURL: nil)
        try await db.writer.write { db in
            for account in ["a", "b"] {
                try db.execute(
                    sql: "INSERT INTO labels (account_id, id, name, type) VALUES (?, 'INBOX', 'INBOX', 'system')",
                    arguments: [account]
                )
                try db.execute(sql: "INSERT INTO thread_labels VALUES (?, 't', 'INBOX', 1)", arguments: [account])
                try db.execute(
                    sql: "INSERT INTO pending_actions (account_id, kind, payload, created_at) VALUES (?, 'x', '{}', 1)",
                    arguments: [account]
                )
            }
        }
        try await db.deleteAccountData("a")
        let counts = try await db.reader.read { db in
            try ["accounts", "labels", "thread_labels", "pending_actions"].map {
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \($0) WHERE \($0 == "accounts" ? "id" : "account_id") = 'a'") ?? -1
            }
        }
        #expect(counts == [0, 0, 0, 0])
        #expect(try await db.allAccounts().map(\.id) == ["b"])
    }

    @Test func managerRestoresSessionsAndFlagsMissingTokens() async throws {
        let db = try AppDatabase.inMemory()
        try await db.upsertAccount(id: "a", email: "a@example.com", displayName: nil, avatarURL: nil)
        try await db.upsertAccount(id: "b", email: "b@example.com", displayName: nil, avatarURL: nil)
        let manager = AccountManager(
            database: db, secrets: InMemorySecretStore(["a": "refresh"]),
            config: OAuthConfig(clientID: "x.apps.googleusercontent.com", clientSecret: ""),
            transport: StubTransport { _, _ in (500, [:], Data()) }
        )
        let sessions = try await manager.restoreSessions()
        #expect(sessions.count == 2)
        #expect(try await db.account(id: "a")?.status == .ok)
        #expect(try await db.account(id: "b")?.status == .needsSignIn)
    }

    @Test func removingAnAccountRevokesAndDeletesTheToken() async throws {
        let db = try AppDatabase.inMemory()
        try await db.upsertAccount(id: "a", email: "a@example.com", displayName: nil, avatarURL: nil)
        let secrets = InMemorySecretStore(["a": "refresh"])
        let transport = StubTransport { _, _ in (200, [:], Data()) }
        let manager = AccountManager(
            database: db, secrets: secrets,
            config: OAuthConfig(clientID: "x.apps.googleusercontent.com", clientSecret: ""), transport: transport
        )
        try await manager.restoreSessions()
        try await manager.removeAccount("a")
        #expect(transport.requests.first?.url?.absoluteString == "https://oauth2.googleapis.com/revoke")
        #expect(String(decoding: transport.requests.first?.httpBody ?? Data(), as: UTF8.self) == "token=refresh")
        #expect(try secrets.load(account: "a") == nil)
        #expect(try await db.allAccounts().isEmpty)
        #expect(await manager.session(for: "a") == nil)
    }
}
