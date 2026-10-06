import Foundation

public struct ThreadListQuery: Sendable, Equatable {
    public var labelIDs: [String]
    public var query: String?
    public var pageToken: String?
    public var maxResults: Int
    public var includeSpamTrash: Bool

    public init(
        labelIDs: [String] = [],
        query: String? = nil,
        pageToken: String? = nil,
        maxResults: Int = 50,
        includeSpamTrash: Bool = false
    ) {
        self.labelIDs = labelIDs
        self.query = query
        self.pageToken = pageToken
        self.maxResults = maxResults
        self.includeSpamTrash = includeSpamTrash
    }
}

/// The subset of the Gmail REST API the app uses. `RESTGmailClient` in production,
/// `FakeGmailServer` in tests.
public protocol GmailClient: Sendable {
    func getProfile() async throws -> GmailProfile
    func listLabels() async throws -> [GmailLabel]
    func getLabel(id: String) async throws -> GmailLabel
    func listSendAs() async throws -> [GmailSendAs]

    func listThreads(_ query: ThreadListQuery) async throws -> GmailThreadList
    func getThread(id: String, format: MessageFormat) async throws -> GmailThread
    /// Batched `threads.get`; each ID has its own result.
    func getThreads(ids: [String], format: MessageFormat) async throws -> [String: Result<GmailThread, GmailError>]
    func getMessage(id: String, format: MessageFormat) async throws -> GmailMessage
    /// Batched `messages.get`; each ID has its own result.
    func getMessages(ids: [String], format: MessageFormat) async throws -> [String: Result<GmailMessage, GmailError>]
    func listMessages(query: String, pageToken: String?, maxResults: Int) async throws -> GmailMessageList
    func listHistory(startHistoryID: String, pageToken: String?) async throws -> GmailHistoryList

    func modifyThread(id: String, add: [String], remove: [String]) async throws
    func batchModifyMessages(ids: [String], add: [String], remove: [String]) async throws
    func trashThread(id: String) async throws
    func untrashThread(id: String) async throws

    func getAttachment(messageID: String, attachmentID: String) async throws -> Data

    func sendMessage(raw: Data, threadID: String?) async throws -> GmailMessage
    func listDrafts(pageToken: String?) async throws -> GmailDraftList
    func createDraft(raw: Data, threadID: String?) async throws -> GmailDraft
    func updateDraft(id: String, raw: Data, threadID: String?) async throws -> GmailDraft
    func deleteDraft(id: String) async throws
}

/// Headers requested with `format=metadata`.
public enum MetadataHeaders {
    public static let names = [
        "From", "To", "Cc", "Bcc", "Reply-To", "Subject", "Date", "Message-ID",
        "In-Reply-To", "References", "List-Unsubscribe", "List-Unsubscribe-Post", "Content-Type",
    ]
}
