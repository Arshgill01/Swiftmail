import Foundation

/// Hands out access tokens for one account. Refreshes 60 seconds before expiry, and
/// concurrent callers share one in-flight refresh. Access tokens stay in memory only.
public actor TokenProvider {
    public typealias Refresher = @Sendable (_ refreshToken: String) async throws -> TokenResponse

    public let accountID: String
    private let secrets: SecretStore
    private let refresher: Refresher
    private let now: @Sendable () -> Date
    private var current: (token: String, expiry: Date)?
    private var refreshTask: Task<String, Error>?
    private var needsSignInHandler: (@Sendable () async -> Void)?

    public init(
        accountID: String,
        secrets: SecretStore,
        refresher: @escaping Refresher,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.accountID = accountID
        self.secrets = secrets
        self.refresher = refresher
        self.now = now
    }

    public func setNeedsSignInHandler(_ handler: @escaping @Sendable () async -> Void) {
        needsSignInHandler = handler
    }

    /// Seeds the token obtained during sign-in so the first request needs no refresh.
    public func seed(accessToken: String, expiresIn: Int) {
        current = (accessToken, now().addingTimeInterval(TimeInterval(expiresIn)))
    }

    /// Returns a valid access token. Pass the token that just got a 401 as `rejected`
    /// to force a refresh; if another caller already replaced it, the new one is returned.
    public func accessToken(rejected: String? = nil) async throws -> String {
        if let current {
            let fresh = current.expiry.timeIntervalSince(now()) > 60
            if fresh, rejected == nil || rejected != current.token {
                return current.token
            }
        }
        if let refreshTask {
            return try await refreshTask.value
        }
        let task = Task { try await self.performRefresh() }
        refreshTask = task
        defer { refreshTask = nil }
        return try await task.value
    }

    /// Drops the in-memory access token, e.g. to test a forced expiry.
    public func invalidate() {
        current = nil
    }

    private func performRefresh() async throws -> String {
        guard let refreshToken = try secrets.load(account: accountID) else {
            await needsSignInHandler?()
            throw AuthError.needsSignIn
        }
        do {
            let response = try await refresher(refreshToken)
            current = (response.accessToken, now().addingTimeInterval(TimeInterval(response.expiresIn)))
            if let rotated = response.refreshToken, rotated != refreshToken {
                try secrets.save(rotated, account: accountID)
            }
            return response.accessToken
        } catch AuthError.needsSignIn {
            current = nil
            await needsSignInHandler?()
            throw AuthError.needsSignIn
        }
    }
}
