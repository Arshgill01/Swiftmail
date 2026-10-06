import Foundation
@testable import SwiftmailCore
import Testing

struct OAuthTests {
    let config = OAuthConfig(clientID: "client.apps.googleusercontent.com", clientSecret: "secret")

    @Test func authorizationURLCarriesEveryRequiredParameter() throws {
        let client = OAuthClient(config: config, transport: StubTransport { _, _ in (200, [:], Data()) })
        let pkce = PKCE(verifier: String(repeating: "a", count: 64))
        let url = try #require(client.authorizationURL(redirectURI: "http://127.0.0.1:5555", state: "xyz", pkce: pkce))
        let items = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        let query = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
        #expect(url.host == "accounts.google.com")
        #expect(query["client_id"] == config.clientID)
        #expect(query["redirect_uri"] == "http://127.0.0.1:5555")
        #expect(query["response_type"] == "code")
        #expect(query["code_challenge"] == pkce.challenge)
        #expect(query["code_challenge_method"] == "S256")
        #expect(query["state"] == "xyz")
        #expect(query["access_type"] == "offline")
        #expect(query["prompt"] == "consent")
        let scopes = Set((query["scope"] ?? "").split(separator: " ").map(String.init))
        #expect(scopes.contains("https://www.googleapis.com/auth/gmail.modify"))
        #expect(scopes.contains("https://www.googleapis.com/auth/gmail.settings.basic"))
        #expect(!scopes.contains("https://mail.google.com/"))
    }

    @Test func codeExchangeSendsVerifierAndRedirect() async throws {
        let transport = StubTransport { _, _ in (200, [:], tokenJSON(refresh: "r1", idToken: "x.y.z")) }
        let client = OAuthClient(config: config, transport: transport)
        let response = try await client.exchangeCode("CODE", verifier: "VERIFIER", redirectURI: "http://127.0.0.1:1")
        #expect(response.refreshToken == "r1")
        let body = try String(decoding: #require(transport.requests.first?.httpBody), as: UTF8.self)
        #expect(body.contains("grant_type=authorization_code"))
        #expect(body.contains("code_verifier=VERIFIER"))
        #expect(body.contains("code=CODE"))
        #expect(body.contains("redirect_uri=http%3A%2F%2F127.0.0.1%3A1"))
    }

    @Test func invalidGrantMapsToNeedsSignIn() async {
        let transport = StubTransport { _, _ in (400, [:], jsonData(["error": "invalid_grant"])) }
        let client = OAuthClient(config: config, transport: transport)
        await #expect(throws: AuthError.needsSignIn) {
            _ = try await client.refresh(refreshToken: "old")
        }
    }

    @Test func callbackValidation() throws {
        let ok = try #require(URLComponents(string: "http://127.0.0.1/?code=abc&state=s1"))
        #expect(try SignInFlow.validateCallback(ok, expectedState: "s1") == "abc")
        #expect(throws: AuthError.stateMismatch) { try SignInFlow.validateCallback(ok, expectedState: "other") }
        let denied = try #require(URLComponents(string: "http://127.0.0.1/?error=access_denied&state=s1"))
        #expect(throws: AuthError.authorizationDenied("access_denied")) {
            try SignInFlow.validateCallback(denied, expectedState: "s1")
        }
    }

    @Test func requestLineParsing() {
        let components = LoopbackServer.parseRequestLine("GET /?code=4%2F0Ab&state=xyz HTTP/1.1")
        #expect(components?.queryItems?.first { $0.name == "code" }?.value == "4/0Ab")
        #expect(LoopbackServer.parseRequestLine("POST / HTTP/1.1") == nil)
    }

    @Test func loopbackServerAnswersTheRedirect() async throws {
        let server = try await LoopbackServer.start()
        #expect(server.port > 0)
        async let callback = server.waitForCallback(timeout: .seconds(10))
        let session = URLSession(configuration: .ephemeral)
        let favicon = try #require(URL(string: "\(server.redirectURI)/favicon.ico"))
        let (_, faviconResponse) = try await session.data(from: favicon)
        #expect((faviconResponse as? HTTPURLResponse)?.statusCode == 404)
        let url = try #require(URL(string: "\(server.redirectURI)/?code=the-code&state=st"))
        let (data, response) = try await session.data(from: url)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        #expect(String(decoding: data, as: UTF8.self).contains("return to Swiftmail"))
        let components = try await callback
        #expect(try SignInFlow.validateCallback(components, expectedState: "st") == "the-code")
    }

    @Test func loopbackServerTimesOut() async throws {
        let server = try await LoopbackServer.start()
        await #expect(throws: AuthError.timedOut) {
            _ = try await server.waitForCallback(timeout: .milliseconds(50))
        }
    }
}
