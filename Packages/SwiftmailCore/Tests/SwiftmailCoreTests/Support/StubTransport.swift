import Foundation
@testable import SwiftmailCore
import Synchronization

/// HTTP transport whose responses come from a closure; records every request.
final class StubTransport: HTTPTransport {
    typealias Handler = @Sendable (URLRequest, Int) throws -> (Int, [String: String], Data)

    private let handler: Handler
    private let log = Mutex<[URLRequest]>([])

    init(_ handler: @escaping Handler) {
        self.handler = handler
    }

    var requests: [URLRequest] {
        log.withLock { $0 }
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let index = log.withLock { log in
            log.append(request)
            return log.count - 1
        }
        let (status, headers, body) = try handler(request, index)
        guard let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)
        else { throw URLError(.badServerResponse) }
        return (body, response)
    }
}

/// Thread-safe counter for use inside `@Sendable` closures.
final class Counter: Sendable {
    private let value = Mutex(0)

    @discardableResult
    func increment() -> Int {
        value.withLock { value in
            value += 1
            return value
        }
    }

    var current: Int {
        value.withLock { $0 }
    }
}

func jsonData(_ object: Any) -> Data {
    (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
}

func tokenJSON(access: String = "access-1", expiresIn: Int = 3600, refresh: String? = nil, idToken: String? = nil) -> Data {
    var object: [String: Any] = ["access_token": access, "expires_in": expiresIn, "token_type": "Bearer"]
    if let refresh {
        object["refresh_token"] = refresh
    }
    if let idToken {
        object["id_token"] = idToken
    }
    return jsonData(object)
}

func makeIDToken(sub: String, email: String, name: String? = nil) -> String {
    var claims: [String: Any] = ["sub": sub, "email": email, "iss": "https://accounts.google.com"]
    if let name {
        claims["name"] = name
    }
    let header = Base64URL.encode(Data(#"{"alg":"RS256","typ":"JWT"}"#.utf8))
    return "\(header).\(Base64URL.encode(jsonData(claims))).signature"
}
