import Foundation
@testable import SwiftmailCore
import Testing

struct PKCETests {
    @Test func rfc7636AppendixBVector() {
        let pkce = PKCE(verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
        #expect(pkce.challenge == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    @Test func generatedVerifierIs64UnreservedCharacters() {
        let pkce = PKCE.generate()
        #expect(pkce.verifier.count == 64)
        #expect(pkce.verifier.allSatisfy { PKCE.unreserved.contains($0) })
        #expect(PKCE.generate().verifier != pkce.verifier)
    }

    @Test func base64URLRoundTripWithoutPadding() {
        for length in 0 ..< 20 {
            let data = Data((0 ..< length).map { UInt8(truncatingIfNeeded: $0 * 37 + 251) })
            let encoded = Base64URL.encode(data)
            #expect(!encoded.contains("="))
            #expect(!encoded.contains("+"))
            #expect(!encoded.contains("/"))
            #expect(Base64URL.decode(encoded) == data)
        }
        #expect(Base64URL.decode("_-8") == Data([0xFF, 0xEF]))
    }

    @Test func idTokenClaims() throws {
        let token = try IDToken(jwt: makeIDToken(sub: "123", email: "a@example.com", name: "Alex"))
        #expect(token.sub == "123")
        #expect(token.email == "a@example.com")
        #expect(token.name == "Alex")
        #expect(throws: AuthError.self) { try IDToken(jwt: "garbage") }
    }
}
