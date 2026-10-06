import Foundation
@testable import SwiftmailCore
import Synchronization
import Testing

final class SleepRecorder: Sendable {
    private let log = Mutex<[Duration]>([])
    var sleeps: [Duration] {
        log.withLock { $0 }
    }

    var sleeper: @Sendable (Duration) async throws -> Void {
        { duration in self.log.withLock { $0.append(duration) } }
    }
}

struct RESTClientTests {
    func makeClient(
        _ transport: StubTransport,
        sleeps: SleepRecorder = SleepRecorder(),
        refreshes: Counter = Counter()
    ) -> RESTGmailClient {
        let tokens = TokenProvider(accountID: "a", secrets: InMemorySecretStore(["a": "r"]), refresher: { _ in
            let n = refreshes.increment()
            return TokenResponse(accessToken: "fresh\(n)", expiresIn: 3600, refreshToken: nil, idToken: nil, scope: nil)
        })
        return RESTGmailClient(transport: transport, tokens: tokens, quota: QuotaBucket(), sleep: sleeps.sleeper)
    }

    let profile = jsonData(["emailAddress": "me@example.com", "historyId": "42"])

    @Test func unauthorizedTriggersOneRefreshAndRetry() async throws {
        let refreshes = Counter()
        let transport = StubTransport { request, index in
            let auth = request.value(forHTTPHeaderField: "Authorization")
            if index == 0 {
                return (401, [:], Data())
            }
            #expect(auth == "Bearer fresh2")
            return (200, [:], profile)
        }
        let client = makeClient(transport, refreshes: refreshes)
        let result = try await client.getProfile()
        #expect(result.historyId == "42")
        #expect(refreshes.current == 2)
        #expect(transport.requests.count == 2)
    }

    @Test func repeatedUnauthorizedFails() async {
        let transport = StubTransport { _, _ in (401, [:], Data()) }
        await #expect(throws: GmailError.unauthorized) { _ = try await makeClient(transport).getProfile() }
        #expect(transport.requests.count == 2)
    }

    @Test func rateLimitHonorsRetryAfter() async throws {
        let sleeps = SleepRecorder()
        let transport = StubTransport { _, index in
            index == 0 ? (429, ["Retry-After": "3"], Data()) : (200, [:], profile)
        }
        _ = try await makeClient(transport, sleeps: sleeps).getProfile()
        #expect(sleeps.sleeps == [.seconds(3)])
    }

    @Test func userRateLimitExceededIsRetriedWithBackoff() async throws {
        let sleeps = SleepRecorder()
        let body = jsonData(["error": ["code": 403, "errors": [["reason": "userRateLimitExceeded"]]]])
        let transport = StubTransport { _, index in
            index < 2 ? (403, [:], body) : (200, [:], profile)
        }
        _ = try await makeClient(transport, sleeps: sleeps).getProfile()
        #expect(sleeps.sleeps.count == 2)
        #expect(sleeps.sleeps[0] >= .seconds(1) && sleeps.sleeps[0] <= .seconds(2))
        #expect(sleeps.sleeps[1] >= .seconds(2) && sleeps.sleeps[1] <= .seconds(3))
    }

    @Test func serverErrorsStopAfterFiveAttempts() async {
        let transport = StubTransport { _, _ in (503, [:], Data()) }
        await #expect(throws: GmailError.server(503)) { _ = try await makeClient(transport).getProfile() }
        #expect(transport.requests.count == 5)
    }

    @Test func forbiddenWithoutRateReasonIsNotRetried() async {
        let body = jsonData(["error": ["code": 403, "errors": [["reason": "insufficientPermissions"]]]])
        let transport = StubTransport { _, _ in (403, [:], body) }
        await #expect(throws: GmailError.http(403, reason: "insufficientPermissions")) {
            _ = try await makeClient(transport).getProfile()
        }
        #expect(transport.requests.count == 1)
    }

    @Test func backoffIsCappedAt64Seconds() {
        #expect(Backoff.delay(attempt: 10, jitter: 0.5) == .seconds(64))
        #expect(Backoff.delay(attempt: 0, jitter: 0) == .seconds(1))
        #expect(Backoff.delay(attempt: 3, jitter: 0) == .seconds(8))
        #expect(Backoff.delay(attempt: 1, retryAfter: 100) == .seconds(64))
    }

    @Test func offlineIsReportedWithoutRetrying() async {
        let transport = StubTransport { _, _ in throw URLError(.notConnectedToInternet) }
        await #expect(throws: GmailError.offline) { _ = try await makeClient(transport).getProfile() }
        #expect(transport.requests.count == 1)
    }
}
