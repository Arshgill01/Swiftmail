import Foundation
import os

/// The real Gmail client: `URLSession` (through `HTTPTransport`), bearer tokens from
/// `TokenProvider`, the per-account `QuotaBucket`, backoff and batch requests.
public final class RESTGmailClient: GmailClient {
    static let baseURL = "https://gmail.googleapis.com"
    static let userPath = "/gmail/v1/users/me"
    static let uploadThreshold = 5 * 1024 * 1024

    let transport: HTTPTransport
    let tokens: TokenProvider
    let quota: QuotaBucket
    let sleep: @Sendable (Duration) async throws -> Void
    let logger = Logger(subsystem: "app.swiftmail", category: "GmailAPI")

    public init(
        transport: HTTPTransport,
        tokens: TokenProvider,
        quota: QuotaBucket,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.transport = transport
        self.tokens = tokens
        self.quota = quota
        self.sleep = sleep
    }

    struct Endpoint {
        var method = "GET"
        var path: String
        var query: [(String, String)] = []
        var body: Data?
        var contentType = "application/json"
        var base = RESTGmailClient.baseURL

        var pathAndQuery: String {
            query.isEmpty ? path : path + "?" + FormEncoding.encode(query)
        }
    }

    // MARK: Request execution

    func accessToken(rejected: String? = nil) async throws -> String {
        do {
            return try await tokens.accessToken(rejected: rejected)
        } catch is AuthError {
            // Any credential problem waits for the user to sign in; queued work is kept.
            throw GmailError.needsSignIn
        } catch let error as URLError {
            throw GmailError.from(urlError: error)
        }
    }

    /// Sends one request with quota, 401 refresh-and-retry, and backoff for 429/5xx/timeouts.
    func perform(_ endpoint: Endpoint, cost: Int) async throws -> Data {
        var attempt = 0
        var rejected: String?
        var refreshed = false
        while true {
            try await quota.acquire(cost)
            let token = try await accessToken(rejected: rejected)
            guard let url = URL(string: endpoint.base + endpoint.pathAndQuery) else {
                throw GmailError.invalidRequest(endpoint.path)
            }
            var request = URLRequest(url: url)
            request.httpMethod = endpoint.method
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            if let body = endpoint.body {
                request.httpBody = body
                request.setValue(endpoint.contentType, forHTTPHeaderField: "Content-Type")
            }
            let error: GmailError
            var retryAfter: TimeInterval?
            do {
                let (data, response) = try await transport.send(request)
                if (200 ..< 300).contains(response.statusCode) {
                    return data
                }
                error = GmailError.from(status: response.statusCode, body: data)
                retryAfter = Backoff.retryAfter(from: response)
            } catch let urlError as URLError {
                error = GmailError.from(urlError: urlError)
            }
            if error == .unauthorized, !refreshed {
                refreshed = true
                rejected = token
                continue
            }
            // Offline is not retried here; the caller keeps the work queued until the network returns.
            guard error.isTransient, error != .offline, attempt + 1 < Backoff.maxAttempts else { throw error }
            logger.debug("retrying \(endpoint.method, privacy: .public) after \(String(describing: error), privacy: .public)")
            try await sleep(Backoff.delay(attempt: attempt, retryAfter: retryAfter))
            attempt += 1
        }
    }

    func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw GmailError.decoding(String(describing: type))
        }
    }

    func json(_ object: [String: Any]) -> Data? {
        try? JSONSerialization.data(withJSONObject: object)
    }

    // MARK: Batch

    /// Runs GETs through the batch endpoint, 50 per batch; retries failed parts on their own.
    func batchGet(_ items: [GmailBatch.Item], costPerItem: Int) async throws -> [String: Result<Data, GmailError>] {
        var results: [String: Result<Data, GmailError>] = [:]
        var start = 0
        while start < items.count {
            let chunk = Array(items[start ..< min(start + GmailBatch.maxItems, items.count)])
            try await runBatch(chunk, costPerItem: costPerItem, into: &results)
            start += GmailBatch.maxItems
        }
        return results
    }

    private func runBatch(
        _ chunk: [GmailBatch.Item], costPerItem: Int, into results: inout [String: Result<Data, GmailError>]
    ) async throws {
        var pending = chunk
        var attempt = 0
        var rejected: String?
        var refreshed = false
        while !pending.isEmpty {
            try await quota.acquire(costPerItem * pending.count)
            let token = try await accessToken(rejected: rejected)
            rejected = nil
            let boundary = "batch_\(UUID().uuidString)"
            guard let url = URL(string: Self.baseURL + "/batch/gmail/v1") else { return }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("multipart/mixed; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
            request.httpBody = GmailBatch.body(for: pending, boundary: boundary)

            var parsed: [Int: GmailBatch.Response] = [:]
            var batchError: GmailError?
            var retryAfter: TimeInterval?
            do {
                let (data, response) = try await transport.send(request)
                if (200 ..< 300).contains(response.statusCode),
                   let responseBoundary = GmailBatch.boundary(fromContentType: response.value(forHTTPHeaderField: "Content-Type") ?? "") {
                    parsed = GmailBatch.parse(data, boundary: responseBoundary)
                } else {
                    batchError = GmailError.from(status: response.statusCode, body: data)
                    retryAfter = Backoff.retryAfter(from: response)
                }
            } catch let urlError as URLError {
                batchError = GmailError.from(urlError: urlError)
            }

            var retry: [GmailBatch.Item] = []
            var needsRefresh = false
            for (index, item) in pending.enumerated() {
                let error: GmailError
                if let batchError {
                    error = batchError
                } else if let part = parsed[index] {
                    if (200 ..< 300).contains(part.status) {
                        results[item.id] = .success(part.body)
                        continue
                    }
                    error = GmailError.from(status: part.status, body: part.body)
                } else {
                    error = .server(502)
                }
                if error == .unauthorized, !refreshed {
                    needsRefresh = true
                    retry.append(item)
                } else if error.isTransient, error != .offline, attempt + 1 < Backoff.maxAttempts {
                    retry.append(item)
                } else {
                    results[item.id] = .failure(error)
                }
            }
            if batchError == .offline {
                throw GmailError.offline
            }
            if batchError == .needsSignIn {
                throw GmailError.needsSignIn
            }
            pending = retry
            guard !pending.isEmpty else { return }
            if needsRefresh {
                refreshed = true
                rejected = token
            } else {
                try await sleep(Backoff.delay(attempt: attempt, retryAfter: retryAfter))
                attempt += 1
            }
        }
    }
}
