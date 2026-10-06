import Foundation

/// Everything that belongs to one signed-in account: its token provider and Gmail
/// client, and (from later milestones) its sync engine and action queue.
public actor AccountSession {
    public nonisolated let accountID: String
    public nonisolated let tokens: TokenProvider
    public nonisolated let client: any GmailClient
    public nonisolated let database: AppDatabase

    public init(accountID: String, tokens: TokenProvider, client: any GmailClient, database: AppDatabase) {
        self.accountID = accountID
        self.tokens = tokens
        self.client = client
        self.database = database
    }
}
