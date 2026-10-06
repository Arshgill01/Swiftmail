import GRDB
import os
import SwiftmailCore
import SwiftUI

/// Observes one mailbox's threads from the store, paging by growing the limit, and asks
/// Gmail for older pages when the cache runs out.
@MainActor
@Observable
final class ThreadListModel {
    private(set) var threads: [ThreadSummary] = []
    private(set) var isLoadingOlder = false
    private(set) var reachedServerEnd = false
    private(set) var hasLoaded = false

    @ObservationIgnored private var limit = ThreadListModel.pageSize
    @ObservationIgnored private var observation: Task<Void, Never>?
    @ObservationIgnored private var key: Key?
    @ObservationIgnored private var database: AppDatabase?
    @ObservationIgnored private static var reportedFirstRender = false

    static let pageSize = 150
    static let logger = Logger(subsystem: "app.swiftmail", category: "List")
    static let signposter = OSSignposter(subsystem: "app.swiftmail", category: "List")

    struct Key: Equatable {
        let mailbox: Mailbox
        let category: InboxCategory?
    }

    func observe(database: AppDatabase, mailbox: Mailbox?, category: InboxCategory?) {
        guard let mailbox else {
            observation?.cancel()
            threads = []
            key = nil
            return
        }
        let newKey = Key(mailbox: mailbox, category: mailbox.kind == .inbox ? category : nil)
        guard newKey != key else { return }
        key = newKey
        self.database = database
        limit = Self.pageSize
        reachedServerEnd = false
        hasLoaded = false
        restart()
    }

    private func restart() {
        guard let key, let database else { return }
        observation?.cancel()
        let limit = limit
        let observation = ValueObservation.tracking { db in
            try ThreadQueries.threads(db, mailbox: key.mailbox, category: key.category, limit: limit)
        }.removeDuplicates()
        let reader = database.reader
        self.observation = Task { [weak self] in
            do {
                for try await threads in observation.values(in: reader, scheduling: .immediate) {
                    guard let self else { return }
                    withAnimation(hasLoaded ? .easeOut(duration: 0.15) : nil) {
                        self.threads = threads
                    }
                    hasLoaded = true
                    if !threads.isEmpty {
                        Self.reportFirstRender()
                    }
                }
            } catch {
                Self.logger.error("thread list observation failed")
            }
        }
    }

    /// Grows the page when a row near the end appears.
    func rowAppeared(_ id: ThreadSummary.ID, sessions: @escaping (String) async -> AccountSession?) {
        guard let index = threads.lastIndex(where: { $0.id == id }), index >= threads.count - 20 else { return }
        if threads.count >= limit {
            limit += Self.pageSize * 2
            restart()
        } else {
            loadOlderFromServer(sessions: sessions)
        }
    }

    /// The cache is exhausted: fetch the next page older than the last row from Gmail.
    func loadOlderFromServer(sessions: @escaping (String) async -> AccountSession?) {
        guard let key, !isLoadingOlder, !reachedServerEnd, key.mailbox.kind != .outbox else { return }
        let before = threads.last?.lastDate ?? Date().millis
        let accountIDs: [String] = key.mailbox.accountID.map { [$0] } ?? Array(Set(threads.map(\.accountID)))
        guard !accountIDs.isEmpty else { return }
        isLoadingOlder = true
        Task {
            var added = 0
            for accountID in accountIDs {
                guard let session = await sessions(accountID) else { continue }
                await added += (try? session.sync.loadOlder(labelID: key.mailbox.labelID, before: before)) ?? 0
            }
            isLoadingOlder = false
            if added == 0 {
                reachedServerEnd = true
            }
        }
    }

    /// Logs time from process start to the first rendered list (budget: 500 ms).
    private static func reportFirstRender() {
        guard !reportedFirstRender else { return }
        reportedFirstRender = true
        signposter.emitEvent("FirstListRender")
        let elapsed = LaunchTiming.millisecondsSinceProcessStart()
        logger.info("first list render \(elapsed, privacy: .public) ms after process start")
    }
}
