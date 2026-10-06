import Foundation

/// The single seam between the app and the network. `URLSession` in production,
/// a stub in tests.
public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct URLSessionTransport: HTTPTransport {
    private let session: URLSession

    public init(session: URLSession = URLSessionTransport.makeSession()) {
        self.session = session
    }

    public static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 60
        config.httpCookieStorage = nil
        config.urlCache = nil
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        return (data, http)
    }
}

extension URLRequest {
    /// Form-encodes parameters into the body as `application/x-www-form-urlencoded`.
    mutating func setFormBody(_ parameters: [(String, String)]) {
        setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        httpMethod = "POST"
        httpBody = Data(FormEncoding.encode(parameters).utf8)
    }
}

enum FormEncoding {
    private static let allowed: CharacterSet = {
        var set = CharacterSet.alphanumerics
        set.insert(charactersIn: "-._~")
        return set
    }()

    static func escape(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    static func encode(_ parameters: [(String, String)]) -> String {
        parameters.map { "\(escape($0.0))=\(escape($0.1))" }.joined(separator: "&")
    }
}
