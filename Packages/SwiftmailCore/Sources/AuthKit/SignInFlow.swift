import Foundation

public struct SignInResult: Sendable, Equatable {
    public let identity: IDToken
    public let refreshToken: String
    public let accessToken: String
    public let expiresIn: Int
}

/// The installed-app OAuth flow: loopback redirect plus PKCE (spec steps 1 to 6).
/// Saving the token and the account row is left to the caller.
public struct SignInFlow: Sendable {
    public typealias URLOpener = @Sendable (URL) async -> Bool

    private let client: OAuthClient
    private let openURL: URLOpener
    private let timeout: Duration

    public init(client: OAuthClient, openURL: @escaping URLOpener, timeout: Duration = .seconds(300)) {
        self.client = client
        self.openURL = openURL
        self.timeout = timeout
    }

    public func run(loginHint: String? = nil) async throws -> SignInResult {
        let pkce = PKCE.generate()
        let state = PKCE.randomString(length: 32)
        let server = try await LoopbackServer.start()
        defer { server.stop() }
        let redirectURI = server.redirectURI

        guard let url = client.authorizationURL(redirectURI: redirectURI, state: state, pkce: pkce, loginHint: loginHint) else {
            throw AuthError.notConfigured
        }
        guard await openURL(url) else { throw AuthError.cancelled }

        let callback = try await server.waitForCallback(timeout: timeout)
        let code = try Self.validateCallback(callback, expectedState: state)

        let tokens = try await client.exchangeCode(code, verifier: pkce.verifier, redirectURI: redirectURI)
        guard let refreshToken = tokens.refreshToken else {
            throw AuthError.invalidResponse("no refresh token")
        }
        guard let idToken = tokens.idToken else { throw AuthError.invalidResponse("no id_token") }
        let identity = try IDToken(jwt: idToken)
        return SignInResult(
            identity: identity,
            refreshToken: refreshToken,
            accessToken: tokens.accessToken,
            expiresIn: tokens.expiresIn
        )
    }

    /// Checks `state` and returns the authorization code, or the error Google sent.
    public static func validateCallback(_ components: URLComponents, expectedState: String) throws -> String {
        let items = components.queryItems ?? []
        func value(_ name: String) -> String? {
            items.first { $0.name == name }?.value
        }
        guard value("state") == expectedState else { throw AuthError.stateMismatch }
        if let error = value("error") {
            throw AuthError.authorizationDenied(error)
        }
        guard let code = value("code"), !code.isEmpty else { throw AuthError.invalidResponse("no code") }
        return code
    }
}
