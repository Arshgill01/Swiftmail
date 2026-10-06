import Foundation

public enum BackfillWindow: String, CaseIterable, Codable, Sendable {
    case threeMonths, oneYear, everything

    public var title: String {
        switch self {
        case .threeMonths: "3 months"
        case .oneYear: "1 year"
        case .everything: "Everything"
        }
    }

    /// Oldest date the backfill downloads, or nil for everything.
    public func cutoff(from now: Date) -> Date? {
        switch self {
        case .threeMonths: Calendar.current.date(byAdding: .month, value: -3, to: now)
        case .oneYear: Calendar.current.date(byAdding: .year, value: -1, to: now)
        case .everything: nil
        }
    }
}

public struct SyncSettings: Sendable, Equatable {
    public var backfillWindow: BackfillWindow

    public init(backfillWindow: BackfillWindow = .oneYear) {
        self.backfillWindow = backfillWindow
    }
}

public struct SyncStatus: Sendable, Equatable {
    public enum Phase: Sendable, Equatable {
        case idle
        case firstSync
        case backfilling(threads: Int)
        case offline
        case needsSignIn
        case error(String)
    }

    public var phase: Phase
    public var lastSuccess: Date?

    public init(phase: Phase = .idle, lastSuccess: Date? = nil) {
        self.phase = phase
        self.lastSuccess = lastSuccess
    }
}

/// A message that is new in this sync and may deserve a notification.
public struct NewMailItem: Sendable, Equatable {
    public let accountID: String
    public let threadID: String
    public let messageID: String
    public let labelIDs: [String]
}

public struct SyncEventSink: Sendable {
    public var status: @Sendable (SyncStatus) -> Void
    public var inboxReady: @Sendable () -> Void
    public var newMail: @Sendable ([NewMailItem]) -> Void
    public var removedMessages: @Sendable ([String]) -> Void

    public init(
        status: @escaping @Sendable (SyncStatus) -> Void = { _ in },
        inboxReady: @escaping @Sendable () -> Void = {},
        newMail: @escaping @Sendable ([NewMailItem]) -> Void = { _ in },
        removedMessages: @escaping @Sendable ([String]) -> Void = { _ in }
    ) {
        self.status = status
        self.inboxReady = inboxReady
        self.newMail = newMail
        self.removedMessages = removedMessages
    }
}
