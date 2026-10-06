import GRDB
import os
import SwiftmailCore
import SwiftUI

/// Observes one conversation from the store, downloads missing bodies, and keeps the
/// reader's expand and remote-image state.
@MainActor
@Observable
final class ReaderModel {
    struct Snapshot: Equatable {
        var conversation: Conversation?
        var remoteAllowed: Set<String>
    }

    private(set) var snapshot: Snapshot?
    private(set) var threadID: ThreadSummary.ID?
    var expanded: Set<String> = []
    var allowedThisSession: Set<String> = []
    var hoveredLink: String?
    private(set) var bodyError: String?
    private(set) var isFetching = false

    @ObservationIgnored private var observation: Task<Void, Never>?
    @ObservationIgnored private var openedAt: Date?
    @ObservationIgnored private var lastMessageIDs: [String] = []
    static let logger = Logger(subsystem: "app.swiftmail", category: "Reader")

    var conversation: Conversation? {
        snapshot?.conversation
    }

    func show(_ id: ThreadSummary.ID?, model: AppModel) {
        guard id != threadID else { return }
        threadID = id
        observation?.cancel()
        snapshot = nil
        expanded = []
        allowedThisSession = []
        bodyError = nil
        lastMessageIDs = []
        guard let id else { return }
        openedAt = Date()
        let observation = ValueObservation.tracking { db -> Snapshot in
            let conversation = try ConversationQueries.conversation(db, accountID: id.accountID, threadID: id.threadID)
            var allowed = Set<String>()
            for message in conversation?.messages ?? [] where message.body?.hasRemoteContent == true {
                if try ConversationQueries.isRemoteContentAllowed(db, accountID: id.accountID, sender: message.message.fromEmail ?? "") {
                    allowed.insert(message.id)
                }
            }
            return Snapshot(conversation: conversation, remoteAllowed: allowed)
        }.removeDuplicates()
        let reader = model.database.reader
        self.observation = Task { [weak self] in
            do {
                for try await snapshot in observation.values(in: reader, scheduling: .immediate) {
                    self?.apply(snapshot, model: model)
                }
            } catch {
                Self.logger.error("conversation observation failed")
            }
        }
    }

    private func apply(_ snapshot: Snapshot, model: AppModel) {
        let first = self.snapshot == nil
        self.snapshot = snapshot
        guard let messages = snapshot.conversation?.messages else { return }
        let ids = messages.map(\.id)
        if first || ids != lastMessageIDs {
            // Newest expanded, plus unread ones; a newly arrived message expands too.
            if let newest = messages.last {
                expanded.insert(newest.id)
            }
            for message in messages where message.isUnread || !lastMessageIDs.isEmpty && !lastMessageIDs.contains(message.id) {
                expanded.insert(message.id)
            }
            lastMessageIDs = ids
        }
        if messages.contains(where: { $0.message.bodyState != .ready }) {
            fetchBodies(model: model)
        }
    }

    private func fetchBodies(model: AppModel) {
        guard !isFetching, let id = threadID else { return }
        isFetching = true
        bodyError = nil
        Task {
            defer { isFetching = false }
            do {
                guard let session = await model.session(for: id.accountID) else { return }
                try await session.sync.fetchBodies(threadID: id.threadID)
            } catch GmailError.offline {
                bodyError = "You're offline. This message hasn't been downloaded yet."
            } catch {
                bodyError = "Couldn't download this message."
            }
        }
    }

    func retry(model: AppModel) {
        fetchBodies(model: model)
    }

    func toggle(_ messageID: String) {
        if expanded.contains(messageID) {
            expanded.remove(messageID)
        } else {
            expanded.insert(messageID)
        }
    }

    func expandAll() {
        expanded = Set(conversation?.messages.map(\.id) ?? [])
    }

    func allowsRemote(_ message: ConversationMessage, globally: Bool) -> Bool {
        globally || allowedThisSession.contains(message.id) || snapshot?.remoteAllowed.contains(message.id) == true
    }

    /// Logs time from selection to the first rendered body (budget: 150 ms to full HTML).
    func bodyFinished() {
        guard let openedAt else { return }
        self.openedAt = nil
        let elapsed = Int(Date().timeIntervalSince(openedAt) * 1000)
        Self.logger.info("open thread to first body rendered: \(elapsed, privacy: .public) ms")
    }
}
