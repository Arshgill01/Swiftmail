import Foundation
@testable import SwiftmailCore

/// In-memory model of the Gmail API subset the app uses, with switches for failures.
final class FakeGmailServer: GmailClient, @unchecked Sendable {
    struct Message {
        var id: String
        var threadID: String
        var labels: Set<String>
        var date: Int64
        var from: String
        var to: String
        var subject: String
        var html: String?
        var plain: String
        var historyID: Int
        var extraHeaders: [GmailHeader] = []
    }

    struct State {
        var messages: [String: Message] = [:]
        var labels: [GmailLabel] = FakeGmailServer.systemLabels
        var sendAs = [GmailSendAs(sendAsEmail: "me@example.com", displayName: "Me", isDefault: true, isPrimary: true)]
        var historyID = 1000
        var history: [GmailHistory] = []
        var oldestHistory = 1000
        var drafts: [String: String] = [:]
        var nextID = 1
        var calls: [String] = []
        var sent: [Data] = []
        // Switches
        var historyExpired = false
        var rateLimitNext = 0
        var serverErrorsNext = 0
        var offline = false
    }

    static let systemLabels: [GmailLabel] = [
        "INBOX", "SENT", "DRAFT", "STARRED", "IMPORTANT", "UNREAD", "SPAM", "TRASH",
        "CATEGORY_PERSONAL", "CATEGORY_SOCIAL", "CATEGORY_PROMOTIONS", "CATEGORY_UPDATES", "CATEGORY_FORUMS",
    ].map { GmailLabel(id: $0, name: $0, type: "system") }

    // Guarded by `lock`.
    private let lock = NSLock()
    private var storage = State()

    // MARK: Test controls

    func update<T>(_ body: (inout State) throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body(&storage)
    }

    var calls: [String] {
        update { $0.calls }
    }

    var currentHistoryID: String {
        update { String($0.historyID) }
    }

    @discardableResult
    func addMessage(
        threadID: String? = nil, from: String = "Alex <alex@example.com>", to: String = "me@example.com",
        subject: String = "Hello", body: String = "Body text", html: String? = nil,
        labels: Set<String> = ["INBOX", "UNREAD", "CATEGORY_PERSONAL"], date: Date = Date(), recordHistory: Bool = true
    ) -> (messageID: String, threadID: String) {
        update { state in
            let id = String(format: "m%05d", state.nextID)
            state.nextID += 1
            let thread = threadID ?? "t" + id.dropFirst()
            state.historyID += 1
            let message = Message(
                id: id, threadID: thread, labels: labels, date: date.millis, from: from, to: to,
                subject: subject, html: html, plain: body, historyID: state.historyID
            )
            state.messages[id] = message
            if recordHistory {
                state.history.append(GmailHistory(id: String(state.historyID), messagesAdded: [
                    GmailHistoryMessage(message: GmailMessage(id: id, threadId: thread, labelIds: Array(labels))),
                ]))
            }
            return (id, thread)
        }
    }

    func serverModify(messageID: String, add: Set<String> = [], remove: Set<String> = []) {
        update { state in
            Self.applyModify(&state, messageID: messageID, add: add, remove: remove)
        }
    }

    func serverDelete(messageID: String) {
        update { state in
            guard let message = state.messages.removeValue(forKey: messageID) else { return }
            state.historyID += 1
            state.history.append(GmailHistory(id: String(state.historyID), messagesDeleted: [
                GmailHistoryMessage(message: GmailMessage(id: message.id, threadId: message.threadID)),
            ]))
        }
    }

    /// Simulates Google dropping old history: any start before now gets a 404.
    func expireHistory() {
        update { state in
            state.oldestHistory = state.historyID
            state.historyExpired = true
        }
    }

    static func applyModify(_ state: inout State, messageID: String, add: Set<String>, remove: Set<String>) {
        guard var message = state.messages[messageID] else { return }
        let added = add.subtracting(message.labels)
        let removed = remove.intersection(message.labels)
        message.labels.formUnion(add)
        message.labels.subtract(remove)
        state.historyID += 1
        message.historyID = state.historyID
        state.messages[messageID] = message
        let ref = GmailMessage(id: messageID, threadId: message.threadID, labelIds: Array(message.labels))
        var record = GmailHistory(id: String(state.historyID))
        if !added.isEmpty {
            record.labelsAdded = [GmailHistoryMessage(message: ref, labelIds: Array(added))]
        }
        if !removed.isEmpty {
            record.labelsRemoved = [GmailHistoryMessage(message: ref, labelIds: Array(removed))]
        }
        if record.labelsAdded != nil || record.labelsRemoved != nil {
            state.history.append(record)
        }
    }

    // MARK: Failure switches

    private func gate(_ name: String) throws {
        try update { state in
            state.calls.append(name)
            if state.offline {
                throw GmailError.offline
            }
            if state.rateLimitNext > 0 {
                state.rateLimitNext -= 1
                throw GmailError.rateLimited
            }
            if state.serverErrorsNext > 0 {
                state.serverErrorsNext -= 1
                throw GmailError.server(503)
            }
        }
    }

    // MARK: Encoding

    static func gmailMessage(_ message: Message, format: MessageFormat) -> GmailMessage {
        var headers = [
            GmailHeader(name: "From", value: message.from),
            GmailHeader(name: "To", value: message.to),
            GmailHeader(name: "Subject", value: message.subject),
            GmailHeader(name: "Message-ID", value: "<\(message.id)@example.com>"),
        ] + message.extraHeaders
        var payload: GmailMessagePart
        if format == .full {
            var parts = [GmailMessagePart(
                partId: "0.0", mimeType: "text/plain", headers: [GmailHeader(name: "Content-Type", value: "text/plain; charset=UTF-8")],
                body: GmailMessagePartBody(size: message.plain.utf8.count, data: Base64URL.encode(Data(message.plain.utf8)))
            )]
            if let html = message.html {
                parts.append(GmailMessagePart(
                    partId: "0.1", mimeType: "text/html", headers: [GmailHeader(name: "Content-Type", value: "text/html; charset=UTF-8")],
                    body: GmailMessagePartBody(size: html.utf8.count, data: Base64URL.encode(Data(html.utf8)))
                ))
            }
            headers.append(GmailHeader(name: "Content-Type", value: "multipart/alternative; boundary=x"))
            payload = GmailMessagePart(
                partId: "",
                mimeType: "multipart/alternative",
                headers: headers,
                body: GmailMessagePartBody(size: 0),
                parts: parts
            )
        } else {
            payload = GmailMessagePart(mimeType: "multipart/alternative", headers: headers)
        }
        return GmailMessage(
            id: message.id, threadId: message.threadID, labelIds: Array(message.labels).sorted(),
            snippet: String(message.plain.prefix(80)), historyId: String(message.historyID),
            internalDate: String(message.date), sizeEstimate: message.plain.utf8.count, payload: payload
        )
    }

    private func threadMessages(_ state: State, _ threadID: String) -> [Message] {
        state.messages.values.filter { $0.threadID == threadID }.sorted { $0.date < $1.date }
    }

    // MARK: GmailClient

    func getProfile() async throws -> GmailProfile {
        try gate("getProfile")
        return update { GmailProfile(emailAddress: "me@example.com", historyId: String($0.historyID)) }
    }

    func listLabels() async throws -> [GmailLabel] {
        try gate("listLabels")
        return update { $0.labels }
    }

    func getLabel(id: String) async throws -> GmailLabel {
        try gate("getLabel")
        return try update { state in
            guard var label = state.labels.first(where: { $0.id == id }) else { throw GmailError.notFound }
            let threads = Dictionary(grouping: state.messages.values.filter { $0.labels.contains(id) }, by: \.threadID)
            label.threadsTotal = threads.count
            label.threadsUnread = threads.values.filter { $0.contains { $0.labels.contains("UNREAD") } }.count
            return label
        }
    }

    func listSendAs() async throws -> [GmailSendAs] {
        try gate("listSendAs")
        return update { $0.sendAs }
    }

    func listThreads(_ query: ThreadListQuery) async throws -> GmailThreadList {
        try gate("listThreads")
        return update { state in
            let required = Set(query.labelIDs)
            let excludeSpamTrash = !query.includeSpamTrash && required.isDisjoint(with: ["SPAM", "TRASH"])
            var before: Int64?
            var after: Int64?
            for token in (query.query ?? "").split(separator: " ") {
                if token.hasPrefix("before:"), let seconds = Int64(token.dropFirst(7)) {
                    before = seconds * 1000
                }
                if token.hasPrefix("after:"), let seconds = Int64(token.dropFirst(6)) {
                    after = seconds * 1000
                }
            }
            let threads = Dictionary(grouping: state.messages.values, by: \.threadID).compactMap { threadID, messages -> (
                String,
                Int64,
                Int
            )? in
                let matching = messages.filter { required.isSubset(of: $0.labels) }
                guard !matching.isEmpty else { return nil }
                if excludeSpamTrash, messages.allSatisfy({ !$0.labels.isDisjoint(with: ["SPAM", "TRASH"]) }) {
                    return nil
                }
                let last = messages.map(\.date).max() ?? 0
                if let before, !messages.contains(where: { $0.date < before }) {
                    return nil
                }
                if let after, !messages.contains(where: { $0.date > after }) {
                    return nil
                }
                return (threadID, last, messages.map(\.historyID).max() ?? 0)
            }.sorted { $0.1 > $1.1 }
            let offset = Int(query.pageToken ?? "0") ?? 0
            let page = threads.dropFirst(offset).prefix(query.maxResults)
            let next = offset + page.count < threads.count ? String(offset + page.count) : nil
            return GmailThreadList(
                threads: page.map { GmailThreadRef(id: $0.0, snippet: nil, historyId: String($0.2)) },
                nextPageToken: next
            )
        }
    }

    func getThread(id: String, format: MessageFormat) async throws -> GmailThread {
        try gate("getThread")
        return try update { state in
            let messages = threadMessages(state, id)
            guard !messages.isEmpty else { throw GmailError.notFound }
            return GmailThread(
                id: id, historyId: String(messages.map(\.historyID).max() ?? 0),
                messages: messages.map { Self.gmailMessage($0, format: format) }
            )
        }
    }

    func getThreads(ids: [String], format: MessageFormat) async throws -> [String: Result<GmailThread, GmailError>] {
        var results: [String: Result<GmailThread, GmailError>] = [:]
        for id in ids {
            do {
                results[id] = try await .success(getThread(id: id, format: format))
            } catch let error as GmailError {
                if error == .offline {
                    throw error
                }
                results[id] = .failure(error)
            }
        }
        return results
    }

    func getMessage(id: String, format: MessageFormat) async throws -> GmailMessage {
        try gate("getMessage")
        return try update { state in
            guard let message = state.messages[id] else { throw GmailError.notFound }
            return Self.gmailMessage(message, format: format)
        }
    }

    func getMessages(ids: [String], format: MessageFormat) async throws -> [String: Result<GmailMessage, GmailError>] {
        var results: [String: Result<GmailMessage, GmailError>] = [:]
        for id in ids {
            do {
                results[id] = try await .success(getMessage(id: id, format: format))
            } catch let error as GmailError {
                if error == .offline {
                    throw error
                }
                results[id] = .failure(error)
            }
        }
        return results
    }

    func listMessages(query: String, pageToken: String?, maxResults: Int) async throws -> GmailMessageList {
        try gate("listMessages")
        return update { state in
            let term = query.lowercased()
            let matches = state.messages.values
                .filter {
                    $0.subject.lowercased().contains(term) || $0.plain.lowercased().contains(term) || $0.from.lowercased().contains(term)
                }
                .sorted { $0.date > $1.date }
                .prefix(maxResults)
            return GmailMessageList(messages: matches.map { GmailMessageRef(id: $0.id, threadId: $0.threadID) }, nextPageToken: nil)
        }
    }

    func listHistory(startHistoryID: String, pageToken: String?) async throws -> GmailHistoryList {
        try gate("listHistory")
        return try update { state in
            guard let start = Int(startHistoryID), !state.historyExpired || start >= state.oldestHistory else {
                throw GmailError.notFound
            }
            let records = state.history.filter { (Int($0.id) ?? 0) > start }
            let offset = Int(pageToken ?? "0") ?? 0
            let page = Array(records.dropFirst(offset).prefix(3))
            let next = offset + page.count < records.count ? String(offset + page.count) : nil
            return GmailHistoryList(history: page, nextPageToken: next, historyId: String(state.historyID))
        }
    }

    func modifyThread(id: String, add: [String], remove: [String]) async throws {
        try gate("modifyThread")
        update { state in
            for message in threadMessages(state, id) {
                Self.applyModify(&state, messageID: message.id, add: Set(add), remove: Set(remove))
            }
        }
    }

    func batchModifyMessages(ids: [String], add: [String], remove: [String]) async throws {
        try gate("batchModify")
        update { state in
            for id in ids {
                Self.applyModify(&state, messageID: id, add: Set(add), remove: Set(remove))
            }
        }
    }

    func trashThread(id: String) async throws {
        try gate("trashThread")
        update { state in
            for message in threadMessages(state, id) {
                Self.applyModify(&state, messageID: message.id, add: ["TRASH"], remove: ["INBOX"])
            }
        }
    }

    func untrashThread(id: String) async throws {
        try gate("untrashThread")
        update { state in
            for message in threadMessages(state, id) {
                Self.applyModify(&state, messageID: message.id, add: [], remove: ["TRASH"])
            }
        }
    }

    func getAttachment(messageID: String, attachmentID: String) async throws -> Data {
        try gate("getAttachment")
        return Data("attachment \(attachmentID)".utf8)
    }

    func sendMessage(raw: Data, threadID: String?) async throws -> GmailMessage {
        try gate("send")
        let (id, thread) = addMessage(
            threadID: threadID,
            from: "Me <me@example.com>",
            to: "x@example.com",
            subject: "Sent",
            labels: ["SENT"]
        )
        update { $0.sent.append(raw) }
        return GmailMessage(id: id, threadId: thread, labelIds: ["SENT"])
    }

    func listDrafts(pageToken: String?) async throws -> GmailDraftList {
        try gate("listDrafts")
        return update { state in
            GmailDraftList(drafts: state.drafts.map { draftID, messageID in
                GmailDraft(id: draftID, message: GmailMessage(id: messageID, threadId: state.messages[messageID]?.threadID ?? ""))
            }, nextPageToken: nil)
        }
    }

    func createDraft(raw: Data, threadID: String?) async throws -> GmailDraft {
        try gate("createDraft")
        let (id, thread) = addMessage(threadID: threadID, from: "Me <me@example.com>", subject: "Draft", labels: ["DRAFT"])
        let draftID = "d" + id
        update { $0.drafts[draftID] = id }
        return GmailDraft(id: draftID, message: GmailMessage(id: id, threadId: thread, labelIds: ["DRAFT"]))
    }

    func updateDraft(id: String, raw: Data, threadID: String?) async throws -> GmailDraft {
        try gate("updateDraft")
        try await deleteDraftMessage(id)
        let (messageID, thread) = addMessage(threadID: threadID, from: "Me <me@example.com>", subject: "Draft", labels: ["DRAFT"])
        update { $0.drafts[id] = messageID }
        return GmailDraft(id: id, message: GmailMessage(id: messageID, threadId: thread, labelIds: ["DRAFT"]))
    }

    func deleteDraft(id: String) async throws {
        try gate("deleteDraft")
        try await deleteDraftMessage(id)
        update { _ = $0.drafts.removeValue(forKey: id) }
    }

    private func deleteDraftMessage(_ draftID: String) async throws {
        guard let messageID = update({ $0.drafts[draftID] }) else { throw GmailError.notFound }
        serverDelete(messageID: messageID)
    }
}
