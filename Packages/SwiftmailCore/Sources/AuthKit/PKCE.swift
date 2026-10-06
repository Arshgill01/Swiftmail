import CryptoKit
import Foundation

/// PKCE (RFC 7636) verifier and S256 challenge, plus the random `state` value.
public struct PKCE: Sendable, Equatable {
    public let verifier: String
    public let challenge: String

    static let unreserved = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    public init(verifier: String) {
        self.verifier = verifier
        challenge = PKCE.challenge(for: verifier)
    }

    /// A fresh 64-character verifier from the unreserved character set.
    public static func generate() -> PKCE {
        PKCE(verifier: randomString(length: 64))
    }

    public static func challenge(for verifier: String) -> String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return Base64URL.encode(Data(digest))
    }

    public static func randomString(length: Int) -> String {
        var generator = SystemRandomNumberGenerator()
        return String((0 ..< length).map { _ in unreserved[Int(generator.next(upperBound: UInt(unreserved.count)))] })
    }
}
