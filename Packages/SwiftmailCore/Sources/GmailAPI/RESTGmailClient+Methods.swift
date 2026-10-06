import Foundation

public extension RESTGmailClient {
    private var me: String {
        Self.userPath
    }

    private func formatQuery(_ format: MessageFormat) -> [(String, String)] {
        var query = [("format", format.rawValue)]
        if format == .metadata {
            query += MetadataHeaders.names.map { ("metadataHeaders", $0) }
        }
        return query
    }

    func getProfile() async throws -> GmailProfile {
        try await decode(GmailProfile.self, from: perform(Endpoint(path: "\(me)/profile"), cost: QuotaCost.profile))
    }

    func listLabels() async throws -> [GmailLabel] {
        try await decode(GmailLabelList.self, from: perform(Endpoint(path: "\(me)/labels"), cost: QuotaCost.labels)).labels ?? []
    }

    func getLabel(id: String) async throws -> GmailLabel {
        try await decode(GmailLabel.self, from: perform(Endpoint(path: "\(me)/labels/\(escape(id))"), cost: QuotaCost.labels))
    }

    func listSendAs() async throws -> [GmailSendAs] {
        let data = try await perform(Endpoint(path: "\(me)/settings/sendAs"), cost: QuotaCost.sendAs)
        return try decode(GmailSendAsList.self, from: data).sendAs ?? []
    }

    func listThreads(_ query: ThreadListQuery) async throws -> GmailThreadList {
        var items = query.labelIDs.map { ("labelIds", $0) }
        items.append(("maxResults", String(query.maxResults)))
        if let q = query.query, !q.isEmpty {
            items.append(("q", q))
        }
        if let token = query.pageToken {
            items.append(("pageToken", token))
        }
        if query.includeSpamTrash {
            items.append(("includeSpamTrash", "true"))
        }
        let data = try await perform(Endpoint(path: "\(me)/threads", query: items), cost: QuotaCost.threadsList)
        return try decode(GmailThreadList.self, from: data)
    }

    func getThread(id: String, format: MessageFormat) async throws -> GmailThread {
        let endpoint = Endpoint(path: "\(me)/threads/\(escape(id))", query: formatQuery(format))
        return try await decode(GmailThread.self, from: perform(endpoint, cost: QuotaCost.threadsGet))
    }

    func getThreads(ids: [String], format: MessageFormat) async throws -> [String: Result<GmailThread, GmailError>] {
        let items = ids.map { id in
            GmailBatch.Item(id: id, path: Endpoint(path: "\(me)/threads/\(escape(id))", query: formatQuery(format)).pathAndQuery)
        }
        return try await batchGet(items, costPerItem: QuotaCost.threadsGet).mapValues { result in
            result.flatMap { data in
                Result { try decode(GmailThread.self, from: data) }.mapError { $0 as? GmailError ?? .decoding("thread") }
            }
        }
    }

    func getMessage(id: String, format: MessageFormat) async throws -> GmailMessage {
        let endpoint = Endpoint(path: "\(me)/messages/\(escape(id))", query: formatQuery(format))
        return try await decode(GmailMessage.self, from: perform(endpoint, cost: QuotaCost.messagesGet))
    }

    func getMessages(ids: [String], format: MessageFormat) async throws -> [String: Result<GmailMessage, GmailError>] {
        let items = ids.map { id in
            GmailBatch.Item(id: id, path: Endpoint(path: "\(me)/messages/\(escape(id))", query: formatQuery(format)).pathAndQuery)
        }
        return try await batchGet(items, costPerItem: QuotaCost.messagesGet).mapValues { result in
            result.flatMap { data in
                Result { try decode(GmailMessage.self, from: data) }.mapError { $0 as? GmailError ?? .decoding("message") }
            }
        }
    }

    func listMessages(query: String, pageToken: String?, maxResults: Int) async throws -> GmailMessageList {
        var items = [("q", query), ("maxResults", String(maxResults))]
        if let pageToken {
            items.append(("pageToken", pageToken))
        }
        let data = try await perform(Endpoint(path: "\(me)/messages", query: items), cost: QuotaCost.messagesList)
        return try decode(GmailMessageList.self, from: data)
    }

    func listHistory(startHistoryID: String, pageToken: String?) async throws -> GmailHistoryList {
        var items = [("startHistoryId", startHistoryID), ("maxResults", "500")]
        if let pageToken {
            items.append(("pageToken", pageToken))
        }
        let data = try await perform(Endpoint(path: "\(me)/history", query: items), cost: QuotaCost.historyList)
        return try decode(GmailHistoryList.self, from: data)
    }

    func modifyThread(id: String, add: [String], remove: [String]) async throws {
        let body = json(["addLabelIds": add, "removeLabelIds": remove])
        _ = try await perform(
            Endpoint(method: "POST", path: "\(me)/threads/\(escape(id))/modify", body: body),
            cost: QuotaCost.threadsModify
        )
    }

    func batchModifyMessages(ids: [String], add: [String], remove: [String]) async throws {
        var start = 0
        while start < ids.count {
            let chunk = Array(ids[start ..< min(start + 1000, ids.count)])
            let body = json(["ids": chunk, "addLabelIds": add, "removeLabelIds": remove])
            _ = try await perform(Endpoint(method: "POST", path: "\(me)/messages/batchModify", body: body), cost: QuotaCost.batchModify)
            start += 1000
        }
    }

    func trashThread(id: String) async throws {
        _ = try await perform(Endpoint(method: "POST", path: "\(me)/threads/\(escape(id))/trash"), cost: QuotaCost.threadsTrash)
    }

    func untrashThread(id: String) async throws {
        _ = try await perform(Endpoint(method: "POST", path: "\(me)/threads/\(escape(id))/untrash"), cost: QuotaCost.threadsTrash)
    }

    func getAttachment(messageID: String, attachmentID: String) async throws -> Data {
        let path = "\(me)/messages/\(escape(messageID))/attachments/\(escape(attachmentID))"
        let body = try await decode(GmailAttachmentBody.self, from: perform(Endpoint(path: path), cost: QuotaCost.attachmentsGet))
        guard let encoded = body.data, let data = Base64URL.decode(encoded) else { throw GmailError.decoding("attachment") }
        return data
    }

    func sendMessage(raw: Data, threadID: String?) async throws -> GmailMessage {
        let data = try await upload(raw: raw, threadID: threadID, path: "messages/send", method: "POST", cost: QuotaCost.send) {
            var object: [String: Any] = ["raw": Base64URL.encode(raw)]
            if let threadID {
                object["threadId"] = threadID
            }
            return object
        }
        return try decode(GmailMessage.self, from: data)
    }

    func listDrafts(pageToken: String?) async throws -> GmailDraftList {
        var items = [("maxResults", "500")]
        if let pageToken {
            items.append(("pageToken", pageToken))
        }
        return try await decode(
            GmailDraftList.self,
            from: perform(Endpoint(path: "\(me)/drafts", query: items), cost: QuotaCost.draftsList)
        )
    }

    func createDraft(raw: Data, threadID: String?) async throws -> GmailDraft {
        let data = try await upload(raw: raw, threadID: threadID, path: "drafts", method: "POST", cost: QuotaCost.draftsCreate) {
            ["message": messageObject(raw: raw, threadID: threadID)]
        }
        return try decode(GmailDraft.self, from: data)
    }

    func updateDraft(id: String, raw: Data, threadID: String?) async throws -> GmailDraft {
        let path = "drafts/\(escape(id))"
        let data = try await upload(raw: raw, threadID: threadID, path: path, method: "PUT", cost: QuotaCost.draftsUpdate) {
            ["id": id, "message": messageObject(raw: raw, threadID: threadID)]
        }
        return try decode(GmailDraft.self, from: data)
    }

    func deleteDraft(id: String) async throws {
        _ = try await perform(Endpoint(method: "DELETE", path: "\(me)/drafts/\(escape(id))"), cost: QuotaCost.draftsDelete)
    }

    private func messageObject(raw: Data, threadID: String?) -> [String: Any] {
        var message: [String: Any] = ["raw": Base64URL.encode(raw)]
        if let threadID {
            message["threadId"] = threadID
        }
        return message
    }

    /// Small messages go as JSON with a `raw` field; above 5 MB, the media upload
    /// endpoint takes the raw MIME bytes as a `multipart/related` body.
    private func upload(
        raw: Data, threadID: String?, path: String, method: String, cost: Int, jsonBody: () -> [String: Any]
    ) async throws -> Data {
        if raw.count <= Self.uploadThreshold {
            return try await perform(Endpoint(method: method, path: "\(me)/\(path)", body: json(jsonBody())), cost: cost)
        }
        var metadata = jsonBody()
        if var message = metadata["message"] as? [String: Any] {
            message.removeValue(forKey: "raw")
            metadata["message"] = message
        } else {
            metadata.removeValue(forKey: "raw")
        }
        let boundary = "upload_\(UUID().uuidString)"
        var body = Data("--\(boundary)\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n".utf8)
        body.append(json(metadata) ?? Data("{}".utf8))
        body.append(Data("\r\n--\(boundary)\r\nContent-Type: message/rfc822\r\n\r\n".utf8))
        body.append(raw)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        let endpoint = Endpoint(
            method: method, path: "/upload/gmail/v1/users/me/\(path)", query: [("uploadType", "multipart")],
            body: body, contentType: "multipart/related; boundary=\(boundary)"
        )
        return try await perform(endpoint, cost: cost)
    }

    private func escape(_ component: String) -> String {
        component.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) ?? component
    }
}
