import Foundation
@testable import SwiftmailCore
import Testing

func batchResponse(boundary: String, parts: [(Int, Int, String)]) -> Data {
    var text = ""
    for (index, status, body) in parts {
        text += "--\(boundary)\r\nContent-Type: application/http\r\nContent-ID: <response-item\(index)>\r\n\r\n"
        text += "HTTP/1.1 \(status) X\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n\(body)\r\n"
    }
    text += "--\(boundary)--\r\n"
    return Data(text.utf8)
}

struct BatchTests {
    @Test func requestBodyHasOnePartPerItem() {
        let body = String(decoding: GmailBatch.body(for: [
            .init(id: "a", path: "/gmail/v1/users/me/threads/a?format=full"),
            .init(id: "b", path: "/gmail/v1/users/me/threads/b?format=full"),
        ], boundary: "B"), as: UTF8.self)
        #expect(body.contains("Content-ID: <item0>"))
        #expect(body.contains("GET /gmail/v1/users/me/threads/b?format=full"))
        #expect(body.hasSuffix("--B--\r\n"))
    }

    @Test func parsesResponsesOutOfOrder() {
        let data = batchResponse(boundary: "xyz", parts: [(1, 404, #"{"error":{}}"#), (0, 200, #"{"id":"t0"}"#)])
        let parsed = GmailBatch.parse(data, boundary: "xyz")
        #expect(parsed[0]?.status == 200)
        let firstBody = String(decoding: parsed[0]?.body ?? Data(), as: UTF8.self)
        #expect(firstBody.contains("t0"))
        #expect(parsed[1]?.status == 404)
        #expect(GmailBatch.boundary(fromContentType: "multipart/mixed; boundary=batch_abc") == "batch_abc")
    }

    @Test func failedPartsAreRetriedOnTheirOwn() async throws {
        let transport = StubTransport { request, index in
            let body = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
            let headers = ["Content-Type": "multipart/mixed; boundary=resp"]
            if index == 0 {
                #expect(body.components(separatedBy: "Content-ID").count - 1 == 3)
                return (200, headers, batchResponse(boundary: "resp", parts: [
                    (0, 200, #"{"id":"t0","messages":[]}"#),
                    (1, 429, #"{"error":{"code":429}}"#),
                    (2, 404, #"{"error":{"code":404}}"#),
                ]))
            }
            // Only the rate-limited item is retried.
            #expect(body.components(separatedBy: "Content-ID").count - 1 == 1)
            #expect(body.contains("threads/t1"))
            return (200, headers, batchResponse(boundary: "resp", parts: [(0, 200, #"{"id":"t1"}"#)]))
        }
        let tokens = TokenProvider(accountID: "a", secrets: InMemorySecretStore(["a": "r"]), refresher: { _ in
            TokenResponse(accessToken: "x", expiresIn: 3600, refreshToken: nil, idToken: nil, scope: nil)
        })
        let client = RESTGmailClient(transport: transport, tokens: tokens, quota: QuotaBucket(), sleep: { _ in })
        let results = try await client.getThreads(ids: ["t0", "t1", "t2"], format: .full)
        #expect(try results["t0"]?.get().id == "t0")
        #expect(try results["t1"]?.get().id == "t1")
        if case .failure(.notFound)? = results["t2"] {} else {
            Issue.record("t2 should be notFound")
        }
        #expect(transport.requests.count == 2)
    }

    @Test func largeRequestsAreSplitIntoBatchesOfFifty() async throws {
        let transport = StubTransport { request, _ in
            let body = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
            let count = body.components(separatedBy: "Content-ID").count - 1
            #expect(count <= 50)
            let parts = (0 ..< count).map { ($0, 200, #"{"id":"m","threadId":"t"}"#) }
            return (200, ["Content-Type": "multipart/mixed; boundary=r"], batchResponse(boundary: "r", parts: parts))
        }
        let tokens = TokenProvider(accountID: "a", secrets: InMemorySecretStore(["a": "r"]), refresher: { _ in
            TokenResponse(accessToken: "x", expiresIn: 3600, refreshToken: nil, idToken: nil, scope: nil)
        })
        let client = RESTGmailClient(transport: transport, tokens: tokens, quota: QuotaBucket(), sleep: { _ in })
        let results = try await client.getMessages(ids: (0 ..< 120).map { "m\($0)" }, format: .metadata)
        #expect(results.count == 120)
        #expect(transport.requests.count == 3)
    }
}

struct QuotaBucketTests {
    @Test func backgroundKeepsTheReserveAndUserDoesNot() async throws {
        let clock = Clock()
        let bucket = QuotaBucket(now: { clock.now }, sleep: { duration in
            clock.advance(Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18)
        })
        try await bucket.acquire(4000, priority: .user)
        #expect(await bucket.available == 2000)
        let before = clock.now
        try await bucket.acquire(40, priority: .background)
        // Background had to wait until the bucket held 2,040 units.
        #expect(clock.now.timeIntervalSince(before) >= 0.39)
        let userStart = clock.now
        try await bucket.acquire(1500, priority: .user)
        #expect(clock.now == userStart)
    }
}
