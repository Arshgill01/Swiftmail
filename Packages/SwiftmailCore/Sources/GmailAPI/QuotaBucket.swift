import Foundation

public enum RequestPriority: Sendable {
    /// Opening a thread, an action, send, search: always goes first.
    case user
    /// Backfill and label counts: only spends while the bucket keeps its reserve.
    case background

    /// The priority of Gmail requests made from the current task.
    @TaskLocal public static var current: RequestPriority = .user
}

/// Per-account token bucket for Gmail's 6,000 units per user per minute.
public actor QuotaBucket {
    public static let capacity = 6000.0
    public static let backgroundReserve = 2000.0

    private let refillPerSecond: Double
    private var tokens: Double
    private var lastRefill: Date
    private let now: @Sendable () -> Date
    private let sleep: @Sendable (Duration) async throws -> Void

    public init(
        now: @escaping @Sendable () -> Date = Date.init,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        refillPerSecond = Self.capacity / 60
        tokens = Self.capacity
        self.now = now
        self.sleep = sleep
        lastRefill = now()
    }

    public var available: Double {
        refill()
        return tokens
    }

    /// Waits until `units` can be spent at `priority`, then spends them.
    public func acquire(_ units: Int, priority: RequestPriority = RequestPriority.current) async throws {
        let cost = Double(units)
        let floor = priority == .background ? Self.backgroundReserve : 0
        // A single request larger than what the floor allows still goes once the bucket is full.
        let needed = min(cost + floor, Self.capacity)
        while true {
            refill()
            if tokens >= needed {
                tokens -= cost
                return
            }
            let wait = (needed - tokens) / refillPerSecond
            try await sleep(.milliseconds(Int(wait * 1000) + 1))
        }
    }

    private func refill() {
        let current = now()
        let elapsed = current.timeIntervalSince(lastRefill)
        if elapsed > 0 {
            tokens = min(Self.capacity, tokens + elapsed * refillPerSecond)
            lastRefill = current
        }
    }
}

/// Gmail API quota units per method.
public enum QuotaCost {
    public static let threadsGet = 40
    public static let messagesGet = 20
    public static let attachmentsGet = 20
    public static let messagesTrash = 20
    public static let threadsTrash = 10
    public static let threadsList = 10
    public static let threadsModify = 10
    public static let messagesList = 5
    public static let messagesModify = 5
    public static let historyList = 2
    public static let profile = 1
    public static let labels = 1
    public static let sendAs = 1
    public static let batchModify = 50
    public static let send = 100
    public static let draftsCreate = 10
    public static let draftsUpdate = 15
    public static let draftsDelete = 10
    public static let draftsList = 5
}
