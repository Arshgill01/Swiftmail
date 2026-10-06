import Foundation
import os

/// Signs accounts in and out and owns one `AccountSession` per account.
/// On launch it reuses stored refresh tokens and never starts a consent flow.
public actor AccountManager {
    public typealias SessionFactory = @Sendable (_ accountID: String, _ tokens: TokenProvider) -> any GmailClient

    private let database: AppDatabase
    private let secrets: SecretStore
    private let config: OAuthConfig?
    private let transport: HTTPTransport
    private let makeClient: SessionFactory
    private var sessions: [String: AccountSession] = [:]
    private let logger = Logger(subsystem: "app.swiftmail", category: "Accounts")

    public init(
        database: AppDatabase,
        secrets: SecretStore,
        config: OAuthConfig?,
        transport: HTTPTransport,
        makeClient: SessionFactory? = nil
    ) {
        self.database = database
        self.secrets = secrets
        self.config = config
        self.transport = transport
        self.makeClient = makeClient ?? { _, tokens in
            RESTGmailClient(transport: transport, tokens: tokens, quota: QuotaBucket())
        }
    }

    public var isConfigured: Bool {
        config != nil
    }

    public func session(for accountID: String) -> AccountSession? {
        sessions[accountID]
    }

    public func allSessions() -> [AccountSession] {
        Array(sessions.values)
    }

    /// Creates sessions for every stored account. Accounts without a refresh token are
    /// marked as needing sign-in; their cached mail stays readable.
    @discardableResult
    public func restoreSessions() async throws -> [AccountSession] {
        for account in try await database.allAccounts() where sessions[account.id] == nil {
            if try secrets.load(account: account.id) == nil {
                try await database.setAccountStatus(account.id, .needsSignIn)
            }
            sessions[account.id] = makeSession(accountID: account.id)
        }
        return Array(sessions.values)
    }

    /// Runs the browser sign-in, confirms Gmail access, stores the refresh token and the
    /// account. Signing in to an existing account updates its token instead of duplicating it.
    public func signIn(openURL: @escaping SignInFlow.URLOpener) async throws -> AccountRecord {
        guard let config else { throw AuthError.notConfigured }
        let oauth = OAuthClient(config: config, transport: transport)
        let result = try await SignInFlow(client: oauth, openURL: openURL).run()
        let accountID = result.identity.sub

        // Step 6: confirm Gmail access with the fresh access token before saving anything.
        let probeTokens = TokenProvider(
            accountID: accountID,
            secrets: InMemorySecretStore([accountID: result.refreshToken]),
            refresher: { try await oauth.refresh(refreshToken: $0) }
        )
        await probeTokens.seed(accessToken: result.accessToken, expiresIn: result.expiresIn)
        let profile = try await makeClient(accountID, probeTokens).getProfile()

        // Step 7 and 8: the token goes to the Keychain; an existing account is updated.
        try secrets.save(result.refreshToken, account: accountID)
        try await database.upsertAccount(
            id: accountID,
            email: profile.emailAddress,
            displayName: result.identity.name,
            avatarURL: result.identity.picture
        )
        let session = sessions[accountID] ?? makeSession(accountID: accountID)
        await session.tokens.seed(accessToken: result.accessToken, expiresIn: result.expiresIn)
        sessions[accountID] = session
        guard let account = try await database.account(id: accountID) else {
            throw AuthError.invalidResponse("account row")
        }
        logger.info("signed in \(account.email, privacy: .private)")
        return account
    }

    /// Revokes the token, deletes the Keychain item, the account's rows and its files.
    public func removeAccount(_ accountID: String) async throws {
        sessions.removeValue(forKey: accountID)
        if let config, let token = try? secrets.load(account: accountID) {
            do {
                try await OAuthClient(config: config, transport: transport).revoke(token: token)
            } catch {
                logger.error("revoke failed: \(String(describing: error), privacy: .public)")
            }
        }
        try secrets.delete(account: accountID)
        try await database.deleteAccountData(accountID)
        if let base = try? SwiftmailCore.appSupportDirectory() {
            for folder in ["Attachments", "Outbox"] {
                try? FileManager.default.removeItem(at: base.appendingPathComponent(folder).appendingPathComponent(accountID))
            }
        }
    }

    private func makeSession(accountID: String) -> AccountSession {
        let config = config
        let transport = transport
        let tokens = TokenProvider(accountID: accountID, secrets: secrets) { refreshToken in
            guard let config else { throw AuthError.notConfigured }
            return try await OAuthClient(config: config, transport: transport).refresh(refreshToken: refreshToken)
        }
        let database = database
        Task {
            await tokens.setNeedsSignInHandler {
                try? await database.setAccountStatus(accountID, .needsSignIn)
            }
        }
        return AccountSession(accountID: accountID, tokens: tokens, client: makeClient(accountID, tokens), database: database)
    }
}
