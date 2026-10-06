import AppKit
import GRDB
import os
import SwiftmailCore
import UniformTypeIdentifiers

/// One compose window. Saved locally from the first keystroke; the Gmail draft is created
/// after 2 seconds of content and updated at most every 3 seconds, and on close.
@MainActor
@Observable
final class ComposeModel {
    var state: ComposeState {
        didSet {
            if state != oldValue {
                contentChanged()
            }
        }
    }

    private(set) var aliases: [SendAsRecord] = []
    var error: String?
    var isSending = false
    let editor = ComposeEditorController()

    @ObservationIgnored private let app: AppModel
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var draftTask: Task<Void, Never>?
    @ObservationIgnored private var lastDraftSync: Date?
    @ObservationIgnored private var draftDirty = false
    @ObservationIgnored private var closed = false
    static let logger = Logger(subsystem: "app.swiftmail", category: "Compose")

    init(state: ComposeState, app: AppModel) {
        self.state = state
        self.app = app
        editor.onChange = { [weak self] html in self?.state.bodyHTML = html }
        editor.onFiles = { [weak self] urls in self?.addFiles(urls) }
        editor.setContent(state.bodyHTML)
        loadAliases()
    }

    var fromName: String? {
        aliases.first { $0.email == state.from }?.displayName ?? app.account(state.accountID)?.displayName
    }

    var title: String {
        state.subject.isEmpty ? "New Message" : state.subject
    }

    private func loadAliases() {
        let accountID = state.accountID
        Task {
            let rows = await (try? app.database.reader.read { db in
                try SendAsRecord.filter(Column("account_id") == accountID).order(Column("is_default").desc).fetchAll(db)
            }) ?? []
            aliases = rows
            if state.from.isEmpty {
                state.from = rows.first?.email ?? app.account(accountID)?.email ?? ""
            }
        }
    }

    /// Switching the From alias swaps the signature.
    func selectFrom(_ email: String) {
        guard email != state.from else { return }
        state.from = email
        editor.setSignature(aliases.first { $0.email == email }?.signatureHtml)
    }

    // MARK: Saving

    private func contentChanged() {
        guard !closed else { return }
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard let self, !Task.isCancelled else { return }
            try? await app.database.saveLocalDraft(state)
        }
        draftDirty = true
        scheduleDraftSync()
    }

    private func scheduleDraftSync() {
        guard draftTask == nil, state.hasContent else { return }
        let wait: TimeInterval = if let lastDraftSync {
            max(0, 3 - Date().timeIntervalSince(lastDraftSync))
        } else {
            2
        }
        draftTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(wait))
            guard let self, !Task.isCancelled else { return }
            draftTask = nil
            await syncGmailDraft()
            if draftDirty {
                scheduleDraftSync()
            }
        }
    }

    /// Creates or updates the Gmail draft. Offline failures are retried on the next change.
    func syncGmailDraft() async {
        guard draftDirty, state.hasContent, let session = await app.session(for: state.accountID) else { return }
        draftDirty = false
        lastDraftSync = Date()
        if let html = await editor.content() {
            state.bodyHTML = html
        }
        do {
            let message = try OutgoingAssembler.assemble(state, fromName: fromName)
            let raw = MIMEBuilder().build(message)
            let draft = if let id = state.gmailDraftID {
                try await session.client.updateDraft(id: id, raw: raw, threadID: state.threadID)
            } else {
                try await session.client.createDraft(raw: raw, threadID: state.threadID)
            }
            if state.gmailDraftID != draft.id {
                state.gmailDraftID = draft.id
            }
            try? await app.database.saveLocalDraft(state)
        } catch GmailError.notFound where state.gmailDraftID != nil {
            // The draft was sent or deleted elsewhere; make a new one next time.
            state.gmailDraftID = nil
            draftDirty = true
        } catch {
            draftDirty = true
            Self.logger.error("draft sync failed: \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: Attachments

    func addFiles(_ urls: [URL]) {
        for url in urls {
            let type = UTType(filenameExtension: url.pathExtension) ?? .data
            let access = url.startAccessingSecurityScopedResource()
            defer {
                if access {
                    url.stopAccessingSecurityScopedResource()
                }
            }
            guard let data = try? Data(contentsOf: url) else { continue }
            if type.conforms(to: .image), data.count < 5 * 1024 * 1024 {
                editor.insertImage(dataURL: "data:\(type.preferredMIMEType ?? "image/png");base64,\(data.base64EncodedString())", name: url.lastPathComponent)
                continue
            }
            addAttachment(data: data, filename: url.lastPathComponent, mimeType: type.preferredMIMEType ?? "application/octet-stream")
        }
    }

    func addAttachment(data: Data, filename: String, mimeType: String) {
        let path = "Compose/\(state.id.uuidString)/\(UUID().uuidString.prefix(8))-\(filename.replacingOccurrences(of: "/", with: "_"))"
        do {
            let url = try AttachmentStorage.url(forRelativePath: path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
            state.attachments.append(ComposeAttachment(filename: filename, mimeType: mimeType, size: data.count, path: path))
            if state.attachmentBytes > MIMEBuilder.maxAttachmentBytes {
                error = "Attachments are over Gmail's 25 MB limit; the message can't be sent until some are removed."
            }
        } catch {
            self.error = "Couldn't attach \(filename)."
        }
    }

    func removeAttachment(_ id: UUID) {
        guard let attachment = state.attachments.first(where: { $0.id == id }) else { return }
        state.attachments.removeAll { $0.id == id }
        try? FileManager.default.removeItem(at: AttachmentStorage.url(forRelativePath: attachment.path))
        if state.attachmentBytes <= MIMEBuilder.maxAttachmentBytes {
            error = nil
        }
    }

    func chooseFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK else { return }
        addFiles(panel.urls)
    }

    // MARK: Send and discard

    /// Validates, builds the MIME file into the outbox, and holds it for the undo delay.
    func send() async -> Bool {
        if let html = await editor.content() {
            state.bodyHTML = html
        }
        let inlineBytes = OutgoingAssembler.extractInlineImages(state.bodyHTML).1.reduce(0) { $0 + $1.data.count }
        if let problem = state.validationError(inlineBytes: inlineBytes) {
            error = problem
            return false
        }
        isSending = true
        defer { isSending = false }
        closed = true
        saveTask?.cancel()
        draftTask?.cancel()
        do {
            try await app.queueSend(state, fromName: fromName)
            return true
        } catch {
            closed = false
            self.error = "Couldn't prepare the message: \(error.localizedDescription)"
            return false
        }
    }

    /// Deletes the local draft and the Gmail draft.
    func discard() async {
        closed = true
        saveTask?.cancel()
        draftTask?.cancel()
        if let draftID = state.gmailDraftID, let session = await app.session(for: state.accountID) {
            try? await session.client.deleteDraft(id: draftID)
        }
        try? await app.database.deleteLocalDraft(state.id)
    }

    /// The window closed without sending: save the Gmail draft one last time.
    func windowClosed() async {
        guard !closed else { return }
        closed = true
        saveTask?.cancel()
        draftTask?.cancel()
        if let html = await editor.content() {
            state.bodyHTML = html
        }
        if state.hasContent {
            draftDirty = true
            await syncGmailDraft()
            try? await app.database.saveLocalDraft(state, isOpen: false)
        } else {
            try? await app.database.deleteLocalDraft(state.id)
        }
    }
}
