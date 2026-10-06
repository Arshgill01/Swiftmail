import AppKit
import GRDB
import SwiftmailCore
import SwiftUI

extension AppModel {
    /// Saves the state as a local draft and opens it in a compose window.
    func openCompose(_ state: ComposeState) {
        Task {
            try? await database.saveLocalDraft(state)
            openWindowAction?(id: "compose", value: state.id)
        }
    }

    func newMessage(
        accountID: String? = nil,
        to: [EmailAddress] = [],
        cc: [EmailAddress] = [],
        bcc: [EmailAddress] = [],
        subject: String = "",
        body: String = ""
    ) {
        guard let account = accountID.flatMap(account) ?? accounts.first else {
            undo.show(Toast(message: "Add a Gmail account in Settings first.", canUndo: false))
            return
        }
        Task {
            let aliases = await aliases(for: account.id)
            let alias = aliases.first(where: \.isDefault) ?? aliases.first
            var state = ComposeState(accountID: account.id, from: alias?.email ?? account.email)
            state.to = to
            state.cc = cc
            state.bcc = bcc
            state.showCcBcc = !cc.isEmpty || !bcc.isEmpty
            state.subject = subject
            state.bodyHTML = (body.isEmpty ? "" : "<div dir=\"ltr\">\(ReplyBuilder.escapeHTML(body).replacingOccurrences(of: "\n", with: "<br>"))</div>")
                + ReplyBuilder.body(mode: .new, original: nil, signature: alias?.signatureHTML)
            openCompose(state)
        }
    }

    func aliases(for accountID: String) async -> [ReplyBuilder.Alias] {
        let rows = await (try? database.reader.read { db in
            try SendAsRecord.filter(Column("account_id") == accountID).fetchAll(db)
        }) ?? []
        let account = account(accountID)
        if rows.isEmpty, let account {
            return [ReplyBuilder.Alias(email: account.email, name: account.displayName, signatureHTML: nil, isDefault: true)]
        }
        return rows.map { ReplyBuilder.Alias(email: $0.email, name: $0.displayName, signatureHTML: $0.signatureHtml, isDefault: $0.isDefault) }
    }

    /// Reply, reply all or forward to the focused message (or the newest one).
    func reply(_ mode: ComposeMode, window: MainWindowModel) {
        guard let conversation = window.reader.conversation else { return NSSound.beep() }
        let messages = conversation.messages.filter { !$0.message.isDraft }
        guard let message = window.reader.focusedMessage.flatMap({ id in messages.first { $0.id == id } }) ?? messages.last else { return }
        reply(mode, to: message, threadID: conversation.thread.id)
    }

    func reply(_ mode: ComposeMode, to message: ConversationMessage, threadID: String) {
        let accountID = message.message.accountId
        Task {
            let original = ReplyBuilder.Original(
                from: message.from, replyTo: message.message.replyTo.map { [EmailAddress(email: $0)] } ?? [],
                to: message.to, cc: message.cc, subject: message.message.subject ?? "",
                date: Date(millis: message.message.internalDate), messageID: message.message.rfcMessageId,
                references: message.message.referencesHdr, threadID: threadID,
                quotableHTML: HTMLSanitizer.quotable(html: message.body?.html, plain: message.body?.plain ?? message.message.snippet)
            )
            var state = await ReplyBuilder.make(mode, original: original, accountID: accountID, aliases: aliases(for: accountID))
            if mode == .forward {
                state.attachments = await copyForForward(message.visibleAttachments, draftID: state.id)
            }
            openCompose(state)
        }
    }

    /// Forwards carry the original attachments, downloaded first if needed.
    private func copyForForward(_ attachments: [AttachmentRecord], draftID: UUID) async -> [ComposeAttachment] {
        guard !attachments.isEmpty, let session = await session(for: attachments[0].accountId) else { return [] }
        if attachments.count > 0 {
            undo.show(Toast(message: "Preparing attachments…", canUndo: false))
        }
        let loader = AttachmentLoader(database: database, client: session.client)
        var copies: [ComposeAttachment] = []
        for attachment in attachments {
            guard let source = try? await loader.localURL(for: attachment), let data = try? Data(contentsOf: source) else { continue }
            let name = attachment.filename ?? "attachment"
            let path = "Compose/\(draftID.uuidString)/\(UUID().uuidString.prefix(8))-\(name.replacingOccurrences(of: "/", with: "_"))"
            guard let url = try? AttachmentStorage.url(forRelativePath: path) else { continue }
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            guard (try? data.write(to: url)) != nil else { continue }
            copies.append(ComposeAttachment(filename: name, mimeType: attachment.mimeType ?? "application/octet-stream", size: data.count, path: path))
        }
        undo.dismiss()
        return copies
    }

    /// Opens a draft (also one made in Gmail web) for editing.
    func editDraft(_ message: ConversationMessage, threadID: String) {
        var state = ComposeState(accountID: message.message.accountId, from: message.from.email)
        state.to = message.to
        state.cc = message.cc
        state.bcc = message.bcc
        state.showCcBcc = !message.cc.isEmpty || !message.bcc.isEmpty
        state.subject = message.message.subject ?? ""
        state.bodyHTML = HTMLSanitizer.quotable(html: message.body?.html, plain: message.body?.plain)
        state.gmailDraftID = message.message.draftId
        state.threadID = threadID
        state.inReplyTo = message.message.inReplyTo
        state.references = message.message.referencesHdr
        state.mode = message.message.inReplyTo == nil ? .new : .reply
        openCompose(state)
    }

    /// Holds the message for the undo-send delay with a "Sending… Undo" toast.
    func queueSend(_ state: ComposeState, fromName: String?) async throws {
        let delay = max(5, min(30, UserDefaults.standard.integer(forKey: Preferences.undoSendDelay)))
        let pendingID = try await Outbox.queue(state, fromName: fromName, holdFor: TimeInterval(delay), database: database)
        await session(for: state.accountID)?.drainActions()
        undo.show(Toast(message: "Sending…", canUndo: true, duration: .seconds(delay)) { [weak self] in
            self?.undoSend(pendingID)
        })
    }

    func undoSend(_ pendingID: Int64) {
        Task {
            if let state = try? await Outbox.cancel(pendingID, database: database) {
                openCompose(state)
            } else {
                undo.show(Toast(message: "The message was already sent.", canUndo: false))
            }
        }
    }

    /// Compose windows that were open when the app quit come back.
    func reopenUnsentCompose() {
        guard !reopenedCompose else { return }
        reopenedCompose = true
        Task {
            for id in await (try? database.openLocalDrafts()) ?? [] {
                openWindowAction?(id: "compose", value: id)
            }
        }
    }

    /// `mailto:` links open a compose window with To, Cc, Bcc, Subject and Body filled in,
    /// from the default account.
    func openMailto(_ url: URL) {
        guard let parsed = MailtoLink(url) else { return }
        newMessage(to: parsed.to, cc: parsed.cc, bcc: parsed.bcc, subject: parsed.subject, body: parsed.body)
    }

    /// Sends held messages immediately, showing "Sending 1 message…", for up to 10 seconds.
    func sendHeldMessagesBeforeQuit() async -> Int {
        guard let waiting = try? await Outbox.releaseHeld(database: database), waiting > 0 else { return 0 }
        let panel = QuitProgressPanel(count: waiting)
        panel.show()
        defer { panel.close() }
        for session in await accountManager.allSessions() {
            await session.drainActions()
        }
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            let remaining = await (try? database.reader.read { db in
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM pending_actions WHERE kind = 'send' AND state IN ('held','queued','in_flight')")
            }) ?? 0
            if remaining == 0 {
                break
            }
            try? await Task.sleep(for: .milliseconds(200))
        }
        return waiting
    }
}

/// A small floating panel shown while quitting waits for sends.
@MainActor
final class QuitProgressPanel {
    private let panel: NSPanel

    init(count: Int) {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 260, height: 64),
            styleMask: [.titled, .hudWindow, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        panel.title = "Swiftmail"
        let label = NSTextField(labelWithString: count == 1 ? "Sending 1 message…" : "Sending \(count) messages…")
        let spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.startAnimation(nil)
        let stack = NSStackView(views: [spinner, label])
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        panel.contentView = stack
        panel.center()
    }

    func show() {
        panel.orderFrontRegardless()
    }

    func close() {
        panel.close()
    }
}
