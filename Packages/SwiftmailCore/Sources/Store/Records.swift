import Foundation
import GRDB

/// Shared snake_case column mapping for every record type.
public protocol SnakeCaseRecord: Codable, FetchableRecord, PersistableRecord {}

public extension SnakeCaseRecord {
    static var databaseColumnDecodingStrategy: DatabaseColumnDecodingStrategy {
        .convertFromSnakeCase
    }

    static var databaseColumnEncodingStrategy: DatabaseColumnEncodingStrategy {
        .convertToSnakeCase
    }
}

public enum AccountStatus: String, Codable, Sendable {
    case ok
    case needsSignIn = "needs_signin"
    case syncingFull = "syncing_full"
}

public struct AccountRecord: SnakeCaseRecord, Sendable, Equatable, Identifiable, Hashable {
    public static let databaseTableName = "accounts"
    public var id: String
    public var email: String
    public var displayName: String?
    public var avatarUrl: String?
    public var historyId: String?
    public var backfillCursor: String?
    public var backfillDone: Bool = false
    public var status: AccountStatus = .ok
    public var categoriesEnabled: Bool = true
    public var sortOrder: Int = 0
    public var addedAt: Int64
    public var initialSyncDone: Bool = false
    public var lastSyncAt: Int64?
    public var labelsRefreshedAt: Int64?

    public init(id: String, email: String, displayName: String? = nil, avatarUrl: String? = nil, sortOrder: Int = 0, addedAt: Int64) {
        self.id = id
        self.email = email
        self.displayName = displayName
        self.avatarUrl = avatarUrl
        self.sortOrder = sortOrder
        self.addedAt = addedAt
    }
}

public struct LabelRecord: SnakeCaseRecord, Sendable, Equatable, Hashable {
    public static let databaseTableName = "labels"
    public var accountId: String
    public var id: String
    public var name: String
    public var type: String
    public var colorBg: String?
    public var colorText: String?
    public var visibleInList: Bool = true
    public var threadsUnread: Int = 0
    public var threadsTotal: Int = 0

    public init(accountId: String, id: String, name: String, type: String) {
        self.accountId = accountId
        self.id = id
        self.name = name
        self.type = type
    }
}

public struct ThreadRecord: SnakeCaseRecord, Sendable, Equatable {
    public static let databaseTableName = "threads"
    public var accountId: String
    public var id: String
    public var subject: String?
    public var snippet: String?
    public var lastDate: Int64
    public var participants: String
    public var messageCount: Int
    public var hasAttachments: Bool
    public var isUnread: Bool
    public var isStarred: Bool
    public var isImportant: Bool
    public var historyId: String?
}

public enum BodyState: String, Codable, Sendable {
    case none, fetching, ready, failed
}

public struct MessageRecord: SnakeCaseRecord, Sendable, Equatable {
    public static let databaseTableName = "messages"
    public var rowid: Int64?
    public var accountId: String
    public var id: String
    public var threadId: String
    public var historyId: String?
    public var internalDate: Int64
    public var fromName: String?
    public var fromEmail: String?
    public var toJson: String?
    public var ccJson: String?
    public var bccJson: String?
    public var replyTo: String?
    public var subject: String?
    public var snippet: String?
    public var rfcMessageId: String?
    public var inReplyTo: String?
    public var referencesHdr: String?
    public var listUnsubscribe: String?
    public var listUnsubscribePost: String?
    public var sizeEstimate: Int?
    public var hasAttachments: Bool = false
    public var isUnread: Bool = false
    public var isDraft: Bool = false
    public var bodyState: BodyState = .none
    public var draftId: String?
}

public struct MessageBodyRecord: SnakeCaseRecord, Sendable, Equatable {
    public static let databaseTableName = "message_bodies"
    public var accountId: String
    public var messageId: String
    public var html: String?
    public var plain: String?
    public var displayHtml: String?
    public var bodyText: String?
    public var fetchedAt: Int64
    public var hasRemoteContent: Bool = false
    public var trackerCount: Int = 0
}

public struct AttachmentRecord: SnakeCaseRecord, Sendable, Equatable, Hashable {
    public static let databaseTableName = "attachments"
    public var accountId: String
    public var messageId: String
    public var partId: String
    public var attachmentId: String?
    public var filename: String?
    public var mimeType: String?
    public var size: Int?
    public var contentId: String?
    public var isInline: Bool = false
    public var localPath: String?
}

public struct ContactRecord: SnakeCaseRecord, Sendable, Equatable {
    public static let databaseTableName = "contacts"
    public var accountId: String
    public var email: String
    public var name: String?
    public var source: String
    public var lastSeen: Int64?
    public var timesSentTo: Int = 0
}

public struct SendAsRecord: SnakeCaseRecord, Sendable, Equatable, Hashable {
    public static let databaseTableName = "send_as"
    public var accountId: String
    public var email: String
    public var displayName: String?
    public var signatureHtml: String?
    public var isDefault: Bool = false
    public var isPrimary: Bool = false
}

public enum PendingActionState: String, Codable, Sendable {
    case queued, held, inFlight = "in_flight", failed
}

public struct PendingActionRecord: SnakeCaseRecord, Sendable, Equatable, Identifiable {
    public static let databaseTableName = "pending_actions"
    public var id: Int64?
    public var accountId: String
    public var kind: String
    public var payload: String
    public var undoPayload: String?
    public var state: PendingActionState = .queued
    public var notBefore: Int64?
    public var attempts: Int = 0
    public var lastError: String?
    public var createdAt: Int64
}

public extension Date {
    /// Milliseconds since the epoch, the unit used for every stored timestamp.
    var millis: Int64 {
        Int64((timeIntervalSince1970 * 1000).rounded())
    }

    init(millis: Int64) {
        self.init(timeIntervalSince1970: TimeInterval(millis) / 1000)
    }
}
