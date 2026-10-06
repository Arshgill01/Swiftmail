import Foundation
@testable import SwiftmailCore
import Synchronization
import Testing

final class Clock: Sendable {
    private let time = Mutex(Date(timeIntervalSince1970: 1_000_000))
    var now: Date {
        time.withLock { $0 }
    }

    func advance(_ seconds: TimeInterval) {
        time.withLock { $0 = $0.addingTimeInterval(seconds) }
    }
}

struct TokenProviderTests {
    @Test func refreshesSixtySecondsBeforeExpiry() async throws {
        let clock = Clock()
        let calls = Counter()
        let provider = TokenProvider(accountID: "a", secrets: InMemorySecretStore(["a": "refresh"]), refresher: { _ in
            let n = calls.increment()
            return TokenResponse(accessToken: "t\(n)", expiresIn: 3600, refreshToken: nil, idToken: nil, scope: nil)
        }, now: { clock.now })
        #expect(try await provider.accessToken() == "t1")
        clock.advance(3600 - 61)
        #expect(try await provider.accessToken() == "t1")
        clock.advance(2)
        #expect(try await provider.accessToken() == "t2")
        #expect(calls.current == 2)
    }

    @Test func concurrentCallersShareOneRefresh() async throws {
        let calls = Counter()
        let provider = TokenProvider(accountID: "a", secrets: InMemorySecretStore(["a": "refresh"]), refresher: { _ in
            calls.increment()
            try await Task.sleep(for: .milliseconds(50))
            return TokenResponse(accessToken: "shared", expiresIn: 3600, refreshToken: nil, idToken: nil, scope: nil)
        })
        let tokens = try await withThrowingTaskGroup(of: String.self) { group in
            for _ in 0 ..< 10 {
                group.addTask { try await provider.accessToken() }
            }
            return try await group.reduce(into: [String]()) { $0.append($1) }
        }
        #expect(Set(tokens) == ["shared"])
        #expect(calls.current == 1)
    }

    @Test func rejectedTokenForcesOneRefresh() async throws {
        let calls = Counter()
        let provider = TokenProvider(accountID: "a", secrets: InMemorySecretStore(["a": "refresh"]), refresher: { _ in
            let n = calls.increment()
            return TokenResponse(accessToken: "t\(n)", expiresIn: 3600, refreshToken: nil, idToken: nil, scope: nil)
        })
        await provider.seed(accessToken: "t0", expiresIn: 3600)
        #expect(try await provider.accessToken(rejected: "t0") == "t1")
        // A second caller holding the same stale token gets the new one without another refresh.
        #expect(try await provider.accessToken(rejected: "t0") == "t1")
        #expect(calls.current == 1)
    }

    @Test func invalidGrantMarksNeedsSignIn() async throws {
        let flagged = Counter()
        let provider = TokenProvider(accountID: "a", secrets: InMemorySecretStore(["a": "refresh"]), refresher: { _ in
            throw AuthError.needsSignIn
        })
        await provider.setNeedsSignInHandler { flagged.increment() }
        await #expect(throws: AuthError.needsSignIn) { _ = try await provider.accessToken() }
        #expect(flagged.current == 1)
    }

    @Test func rotatedRefreshTokenIsStored() async throws {
        let secrets = InMemorySecretStore(["a": "old"])
        let provider = TokenProvider(accountID: "a", secrets: secrets, refresher: { _ in
            TokenResponse(accessToken: "t", expiresIn: 3600, refreshToken: "new", idToken: nil, scope: nil)
        })
        _ = try await provider.accessToken()
        #expect(try secrets.load(account: "a") == "new")
    }
}
