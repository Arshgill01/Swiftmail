import Foundation

public struct TokenResponse: Sendable, Decodable, Equatable {
    public let accessToken: String
    public let expiresIn: Int
    public let refreshToken: String?
    public let idToken: String?
    public let scope: String?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case expiresIn = "expires_in"
        case refreshToken = "refresh_token"
        case idToken = "id_token"
        case scope
    }
}

/// Talks to Google's OAuth endpoints: authorization URL, code exchange, refresh, revoke.
public struct OAuthClient: Sendable {
    public let config: OAuthConfig
    private let transport: HTTPTransport

    public init(config: OAuthConfig, transport: HTTPTransport) {
        self.config = config
        self.transport = transport
    }

    public func authorizationURL(redirectURI: String, state: String, pkce: PKCE, loginHint: String? = nil) -> URL? {
        guard let endpoint = OAuthConfig.authorizationEndpoint,
              var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)
        else { return nil }
        var items = [
            URLQueryItem(name: "client_id", value: config.clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: config.scopes.joined(separator: " ")),
            URLQueryItem(name: "code_challenge", value: pkce.challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent"),
        ]
        if let loginHint {
            items.append(URLQueryItem(name: "login_hint", value: loginHint))
        }
        components.queryItems = items
        // URLComponents leaves "+" unescaped in queries; Google reads it as a space.
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return components.url
    }

    public func exchangeCode(_ code: String, verifier: String, redirectURI: String) async throws -> TokenResponse {
        try await tokenRequest([
            ("grant_type", "authorization_code"),
            ("code", code),
            ("client_id", config.clientID),
            ("client_secret", config.clientSecret),
            ("code_verifier", verifier),
            ("redirect_uri", redirectURI),
        ])
    }

    public func refresh(refreshToken: String) async throws -> TokenResponse {
        try await tokenRequest([
            ("grant_type", "refresh_token"),
            ("refresh_token", refreshToken),
            ("client_id", config.clientID),
            ("client_secret", config.clientSecret),
        ])
    }

    public func revoke(token: String) async throws {
        guard let endpoint = OAuthConfig.revokeEndpoint else { return }
        var request = URLRequest(url: endpoint)
        request.setFormBody([("token", token)])
        let (_, response) = try await transport.send(request)
        // 400 means the token is already invalid, which is the outcome we want.
        guard (200 ..< 300).contains(response.statusCode) || response.statusCode == 400 else {
            throw AuthError.invalidResponse("revoke \(response.statusCode)")
        }
    }

    private func tokenRequest(_ parameters: [(String, String)]) async throws -> TokenResponse {
        guard let endpoint = OAuthConfig.tokenEndpoint else { throw AuthError.notConfigured }
        var request = URLRequest(url: endpoint)
        request.setFormBody(parameters)
        let (data, response) = try await transport.send(request)
        if (200 ..< 300).contains(response.statusCode) {
            return try JSONDecoder().decode(TokenResponse.self, from: data)
        }
        struct OAuthErrorBody: Decodable {
            let error: String
            let errorDescription: String?
            enum CodingKeys: String, CodingKey {
                case error
                case errorDescription = "error_description"
            }
        }
        if let body = try? JSONDecoder().decode(OAuthErrorBody.self, from: data) {
            if body.error == "invalid_grant" {
                throw AuthError.needsSignIn
            }
            throw AuthError.tokenEndpoint(code: body.error, description: body.errorDescription)
        }
        throw AuthError.invalidResponse("token \(response.statusCode)")
    }
}
