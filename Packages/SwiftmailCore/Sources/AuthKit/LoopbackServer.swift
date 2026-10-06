import Foundation
import Network

/// One-shot HTTP listener on 127.0.0.1 with an OS-assigned port, used as the OAuth
/// redirect target. It answers the first request that carries `code`, `error` or
/// `state` and then stops; other requests (such as /favicon.ico) get a 404.
public final class LoopbackServer: @unchecked Sendable {
    // All mutable state is confined to `queue`.
    private let queue = DispatchQueue(label: "app.swiftmail.loopback")
    private let listener: NWListener
    private var continuation: CheckedContinuation<URLComponents, Error>?
    private var readyContinuation: CheckedContinuation<Void, Error>?
    private var pendingResult: Result<URLComponents, Error>?
    private var finished = false
    public private(set) var port: UInt16 = 0

    public var redirectURI: String {
        "http://127.0.0.1:\(port)"
    }

    private init(listener: NWListener) {
        self.listener = listener
    }

    /// Starts listening and returns once the OS has assigned a port.
    public static func start() async throws -> LoopbackServer {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: .any)
        parameters.allowLocalEndpointReuse = true
        let listener = try NWListener(using: parameters)
        let server = LoopbackServer(listener: listener)
        try await server.run()
        return server
    }

    private func run() async throws {
        try await withCheckedThrowingContinuation { (ready: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                readyContinuation = ready
                listener.stateUpdateHandler = { [weak self] state in
                    self?.listenerStateChanged(state)
                }
                listener.newConnectionHandler = { [weak self] connection in
                    self?.handle(connection)
                }
                listener.start(queue: queue)
            }
        }
    }

    private func listenerStateChanged(_ state: NWListener.State) {
        switch state {
        case .ready:
            port = listener.port?.rawValue ?? 0
            readyContinuation?.resume()
            readyContinuation = nil
        case let .failed(error):
            readyContinuation?.resume(throwing: error)
            readyContinuation = nil
            finish(.failure(error))
        case .cancelled:
            readyContinuation?.resume(throwing: AuthError.cancelled)
            readyContinuation = nil
        default:
            break
        }
    }

    /// Waits for the browser redirect. Throws `AuthError.timedOut` after `timeout`.
    public func waitForCallback(timeout: Duration = .seconds(300)) async throws -> URLComponents {
        let timeoutTask = Task { [queue] in
            try await Task.sleep(for: timeout)
            queue.async { self.finish(.failure(AuthError.timedOut)) }
        }
        defer { timeoutTask.cancel() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    if let result = self.pendingResult {
                        continuation.resume(with: result)
                    } else {
                        self.continuation = continuation
                    }
                }
            }
        } onCancel: {
            queue.async { self.finish(.failure(AuthError.cancelled)) }
        }
    }

    public func stop() {
        queue.async { self.finish(.failure(AuthError.cancelled)) }
    }

    private func finish(_ result: Result<URLComponents, Error>) {
        guard !finished else { return }
        finished = true
        listener.cancel()
        if let continuation {
            self.continuation = nil
            continuation.resume(with: result)
        } else {
            pendingResult = result
        }
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(on: connection, buffer: Data())
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = buffer
            if let data {
                buffer.append(data)
            }
            let headerEnd = Data("\r\n\r\n".utf8)
            if buffer.range(of: headerEnd) == nil, !isComplete, error == nil, buffer.count < 65536 {
                receive(on: connection, buffer: buffer)
                return
            }
            respond(to: buffer, on: connection)
        }
    }

    private func respond(to request: Data, on connection: NWConnection) {
        let firstLine = String(decoding: request.prefix(4096), as: UTF8.self)
            .components(separatedBy: "\r\n").first ?? ""
        guard !finished, let components = Self.parseRequestLine(firstLine), Self.isCallback(components) else {
            send(status: "404 Not Found", body: "", on: connection)
            return
        }
        send(status: "200 OK", body: Self.successPage, on: connection)
        finish(.success(components))
    }

    private func send(status: String, body: String, on connection: NWConnection) {
        let bodyData = Data(body.utf8)
        let head = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\n"
            + "Content-Length: \(bodyData.count)\r\nConnection: close\r\nCache-Control: no-store\r\n\r\n"
        connection.send(content: Data(head.utf8) + bodyData, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    /// Parses `GET /?code=…&state=… HTTP/1.1` into URL components.
    public static func parseRequestLine(_ line: String) -> URLComponents? {
        let parts = line.split(separator: " ")
        guard parts.count >= 2, parts[0] == "GET" else { return nil }
        return URLComponents(string: "http://127.0.0.1" + parts[1])
    }

    static func isCallback(_ components: URLComponents) -> Bool {
        let names = Set((components.queryItems ?? []).map(\.name))
        return !names.isDisjoint(with: ["code", "error", "state"])
    }

    static let successPage = """
    <!doctype html><html><head><meta charset="utf-8"><title>Swiftmail</title>
    <style>body{font:15px -apple-system,system-ui;display:grid;place-items:center;height:90vh;color:#333}
    @media (prefers-color-scheme:dark){body{background:#1e1e1e;color:#ddd}}</style></head>
    <body><p>You can close this tab and return to Swiftmail.</p></body></html>
    """
}
