import Foundation

public enum MessageFormat: String, Sendable {
    case full, metadata, minimal, raw
}

public struct GmailProfile: Codable, Sendable, Equatable {
    public var emailAddress: String
    public var messagesTotal: Int?
    public var threadsTotal: Int?
    public var historyId: String
}

public struct GmailLabelColor: Codable, Sendable, Equatable {
    public var textColor: String?
    public var backgroundColor: String?
}

public struct GmailLabel: Codable, Sendable, Equatable {
    public var id: String
    public var name: String
    public var type: String?
    public var messageListVisibility: String?
    public var labelListVisibility: String?
    public var color: GmailLabelColor?
    public var threadsTotal: Int?
    public var threadsUnread: Int?

    public init(id: String, name: String, type: String? = "user") {
        self.id = id
        self.name = name
        self.type = type
    }
}

struct GmailLabelList: Codable, Sendable {
    var labels: [GmailLabel]?
}

public struct GmailSendAs: Codable, Sendable, Equatable {
    public var sendAsEmail: String
    public var displayName: String?
    public var signature: String?
    public var isDefault: Bool?
    public var isPrimary: Bool?
    public var verificationStatus: String?

    public init(sendAsEmail: String, displayName: String? = nil, signature: String? = nil, isDefault: Bool? = nil, isPrimary: Bool? = nil) {
        self.sendAsEmail = sendAsEmail
        self.displayName = displayName
        self.signature = signature
        self.isDefault = isDefault
        self.isPrimary = isPrimary
    }
}

struct GmailSendAsList: Codable, Sendable {
    var sendAs: [GmailSendAs]?
}

public struct GmailHeader: Codable, Sendable, Equatable {
    public var name: String
    public var value: String

    public init(name: String, value: String) {
        self.name = name
        self.value = value
    }
}

public struct GmailMessagePartBody: Codable, Sendable, Equatable {
    public var attachmentId: String?
    public var size: Int?
    public var data: String?

    public init(attachmentId: String? = nil, size: Int? = nil, data: String? = nil) {
        self.attachmentId = attachmentId
        self.size = size
        self.data = data
    }
}

public struct GmailMessagePart: Codable, Sendable, Equatable {
    public var partId: String?
    public var mimeType: String?
    public var filename: String?
    public var headers: [GmailHeader]?
    public var body: GmailMessagePartBody?
    public var parts: [GmailMessagePart]?

    public init(
        partId: String? = nil, mimeType: String? = nil, filename: String? = nil,
        headers: [GmailHeader]? = nil, body: GmailMessagePartBody? = nil, parts: [GmailMessagePart]? = nil
    ) {
        self.partId = partId
        self.mimeType = mimeType
        self.filename = filename
        self.headers = headers
        self.body = body
        self.parts = parts
    }
}

public struct GmailMessage: Codable, Sendable, Equatable {
    public var id: String
    public var threadId: String
    public var labelIds: [String]?
    public var snippet: String?
    public var historyId: String?
    public var internalDate: String?
    public var sizeEstimate: Int?
    public var payload: GmailMessagePart?
    public var raw: String?

    public init(
        id: String, threadId: String, labelIds: [String]? = nil, snippet: String? = nil,
        historyId: String? = nil, internalDate: String? = nil, sizeEstimate: Int? = nil,
        payload: GmailMessagePart? = nil
    ) {
        self.id = id
        self.threadId = threadId
        self.labelIds = labelIds
        self.snippet = snippet
        self.historyId = historyId
        self.internalDate = internalDate
        self.sizeEstimate = sizeEstimate
        self.payload = payload
    }
}

public struct GmailThread: Codable, Sendable, Equatable {
    public var id: String
    public var historyId: String?
    public var snippet: String?
    public var messages: [GmailMessage]?

    public init(id: String, historyId: String? = nil, snippet: String? = nil, messages: [GmailMessage]? = nil) {
        self.id = id
        self.historyId = historyId
        self.snippet = snippet
        self.messages = messages
    }
}

public struct GmailThreadRef: Codable, Sendable, Equatable {
    public var id: String
    public var snippet: String?
    public var historyId: String?
}

public struct GmailThreadList: Codable, Sendable, Equatable {
    public var threads: [GmailThreadRef]?
    public var nextPageToken: String?
    public var resultSizeEstimate: Int?

    public init(threads: [GmailThreadRef]?, nextPageToken: String?) {
        self.threads = threads
        self.nextPageToken = nextPageToken
    }
}

public struct GmailMessageRef: Codable, Sendable, Equatable {
    public var id: String
    public var threadId: String
}

public struct GmailMessageList: Codable, Sendable, Equatable {
    public var messages: [GmailMessageRef]?
    public var nextPageToken: String?
    public var resultSizeEstimate: Int?

    public init(messages: [GmailMessageRef]?, nextPageToken: String?) {
        self.messages = messages
        self.nextPageToken = nextPageToken
    }
}

public struct GmailHistoryMessage: Codable, Sendable, Equatable {
    public var message: GmailMessage
    public var labelIds: [String]?

    public init(message: GmailMessage, labelIds: [String]? = nil) {
        self.message = message
        self.labelIds = labelIds
    }
}

public struct GmailHistory: Codable, Sendable, Equatable {
    public var id: String
    public var messagesAdded: [GmailHistoryMessage]?
    public var messagesDeleted: [GmailHistoryMessage]?
    public var labelsAdded: [GmailHistoryMessage]?
    public var labelsRemoved: [GmailHistoryMessage]?

    public init(
        id: String, messagesAdded: [GmailHistoryMessage]? = nil, messagesDeleted: [GmailHistoryMessage]? = nil,
        labelsAdded: [GmailHistoryMessage]? = nil, labelsRemoved: [GmailHistoryMessage]? = nil
    ) {
        self.id = id
        self.messagesAdded = messagesAdded
        self.messagesDeleted = messagesDeleted
        self.labelsAdded = labelsAdded
        self.labelsRemoved = labelsRemoved
    }
}

public struct GmailHistoryList: Codable, Sendable, Equatable {
    public var history: [GmailHistory]?
    public var nextPageToken: String?
    public var historyId: String

    public init(history: [GmailHistory]?, nextPageToken: String?, historyId: String) {
        self.history = history
        self.nextPageToken = nextPageToken
        self.historyId = historyId
    }
}

public struct GmailDraft: Codable, Sendable, Equatable {
    public var id: String
    public var message: GmailMessage?

    public init(id: String, message: GmailMessage?) {
        self.id = id
        self.message = message
    }
}

public struct GmailDraftList: Codable, Sendable, Equatable {
    public var drafts: [GmailDraft]?
    public var nextPageToken: String?

    public init(drafts: [GmailDraft]?, nextPageToken: String?) {
        self.drafts = drafts
        self.nextPageToken = nextPageToken
    }
}

struct GmailAttachmentBody: Codable, Sendable {
    var size: Int?
    var data: String?
}
