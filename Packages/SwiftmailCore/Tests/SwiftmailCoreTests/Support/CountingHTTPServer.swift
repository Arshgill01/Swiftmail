import Foundation
import Network
import Synchronization

/// Local HTTP server that counts requests, to prove the reader makes no remote loads.
final class CountingHTTPServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "counting-server")
    private let count = Mutex(0)
    private(set) var port: UInt16 = 0

    var requests: Int {
        count.withLock { $0 }
    }

    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        listener = try NWListener(using: parameters)
    }

    func start() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let resumed = Mutex(false)
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    self?.port = self?.listener.port?.rawValue ?? 0
                    if resumed.withLock({ let was = $0; $0 = true; return !was }) {
                        continuation.resume()
                    }
                case let .failed(error):
                    if resumed.withLock({ let was = $0; $0 = true; return !was }) {
                        continuation.resume(throwing: error)
                    }
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                guard let self else { return }
                count.withLock { $0 += 1 }
                connection.start(queue: queue)
                let body = Data([0x47, 0x49, 0x46, 0x38, 0x39, 0x61, 0x01, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x3B])
                let head = "HTTP/1.1 200 OK\r\nContent-Type: image/gif\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
                connection.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in connection.cancel() })
            }
            listener.start(queue: queue)
        }
    }

    func stop() {
        listener.cancel()
    }
}
