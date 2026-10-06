import Foundation

public enum GmailError: Error, Sendable, Equatable, LocalizedError {
    case notFound
    case unauthorized
    case needsSignIn
    case rateLimited
    case server(Int)
    case http(Int, reason: String?)
    case offline
    case timedOut
    case decoding(String)
    case invalidRequest(String)

    /// Worth retrying later without user involvement.
    public var isTransient: Bool {
        switch self {
        case .rateLimited, .server, .offline, .timedOut: true
        default: false
        }
    }

    public var errorDescription: String? {
        switch self {
        case .notFound: "Not found on the server."
        case .unauthorized: "Gmail rejected the credentials."
        case .needsSignIn: "This account needs to sign in again."
        case .rateLimited: "Gmail is rate limiting requests."
        case let .server(code): "Gmail server error (\(code))."
        case let .http(code, reason): "Gmail error \(code)\(reason.map { ": \($0)" } ?? "")."
        case .offline: "You're offline."
        case .timedOut: "The request timed out."
        case let .decoding(what): "Unexpected response from Gmail (\(what))."
        case let .invalidRequest(what): "Invalid request: \(what)."
        }
    }

    static func from(urlError: URLError) -> GmailError {
        switch urlError.code {
        case .timedOut: .timedOut
        case .notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .cannotConnectToHost,
             .dnsLookupFailed, .dataNotAllowed, .internationalRoamingOff, .secureConnectionFailed:
            .offline
        default: .http(urlError.errorCode, reason: urlError.localizedDescription)
        }
    }

    /// Maps an HTTP status and Gmail's JSON error body to a typed error.
    static func from(status: Int, body: Data) -> GmailError {
        struct Envelope: Decodable {
            struct Inner: Decodable {
                struct Item: Decodable { let reason: String? }
                let message: String?
                let errors: [Item]?
            }

            let error: Inner?
        }
        let envelope = try? JSONDecoder().decode(Envelope.self, from: body)
        let reasons = Set(envelope?.error?.errors?.compactMap(\.reason) ?? [])
        switch status {
        case 401: return .unauthorized
        case 404: return .notFound
        case 429: return .rateLimited
        case 403 where !reasons.isDisjoint(with: ["rateLimitExceeded", "userRateLimitExceeded"]):
            return .rateLimited
        case 500 ... 599: return .server(status)
        default: return .http(status, reason: reasons.first ?? envelope?.error?.message)
        }
    }
}
