import os
import SwiftmailCore
import SwiftUI

enum SearchToken: Identifiable, Hashable {
    case from(String)
    case hasAttachment

    var id: String {
        query
    }

    var query: String {
        switch self {
        case let .from(address): "from:\(address)"
        case .hasAttachment: "has:attachment"
        }
    }

    var label: String {
        switch self {
        case let .from(address): "From: \(address)"
        case .hasAttachment: "Has attachment"
        }
    }
}

/// Search as you type: local results at once, Gmail's server search shortly after,
/// merged with local hits first.
@MainActor
@Observable
final class SearchModel {
    var text = "" {
        didSet {
            if text != oldValue {
                schedule()
            }
        }
    }

    var tokens: [SearchToken] = [] {
        didSet {
            if tokens != oldValue {
                schedule()
            }
        }
    }

    private(set) var results: [ThreadSummary.ID] = []
    private(set) var isSearchingServer = false
    private(set) var serverError: String?
    private(set) var suggestions: [ContactSuggestion] = []

    @ObservationIgnored weak var app: AppModel?
    @ObservationIgnored var accountID: String?
    @ObservationIgnored var onResults: ([ThreadSummary.ID]) -> Void = { _ in }
    @ObservationIgnored private var localTask: Task<Void, Never>?
    @ObservationIgnored private var serverTask: Task<Void, Never>?
    static let signposter = OSSignposter(subsystem: "app.swiftmail", category: "Search")

    var isActive: Bool {
        !query.isEmpty
    }

    var query: String {
        (tokens.map(\.query) + [text]).joined(separator: " ").trimmingCharacters(in: .whitespaces)
    }

    func clear() {
        text = ""
        tokens = []
    }

    private func schedule() {
        localTask?.cancel()
        serverTask?.cancel()
        serverError = nil
        let query = query
        guard !query.isEmpty, let app else {
            results = []
            isSearchingServer = false
            onResults([])
            return
        }
        let accountID = accountID
        let database = app.database
        localTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(60))
            guard !Task.isCancelled else { return }
            let interval = Self.signposter.beginInterval("LocalSearch")
            let parsed = SearchQuery(query)
            let local = await (try? database.reader.read { db in try LocalSearch.threads(db, query: parsed, accountID: accountID) }) ?? []
            Self.signposter.endInterval("LocalSearch", interval)
            guard !Task.isCancelled, let self else { return }
            results = local
            onResults(local)
            await loadSuggestions(for: parsed)
        }
        serverTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled else { return }
            await self?.searchServer(query, accountID: accountID)
        }
    }

    private func searchServer(_ query: String, accountID: String?) async {
        guard let app else { return }
        isSearchingServer = true
        defer { isSearchingServer = false }
        let sessions = await app.accountManager.allSessions().filter { accountID == nil || $0.accountID == accountID }
        var server: [ThreadSummary.ID] = []
        for session in sessions {
            do {
                let ids = try await session.sync.serverSearch(query)
                server += ids.map { ThreadSummary.ID(accountID: session.accountID, threadID: $0) }
            } catch GmailError.offline {
                serverError = "Offline — showing results from this Mac only."
            } catch GmailError.needsSignIn {
                serverError = "Sign in again to search Gmail — showing results from this Mac."
            } catch {
                serverError = "Gmail search isn't available right now."
            }
        }
        guard !Task.isCancelled, query == self.query else { return }
        results = SearchMerge.merge(local: results, server: server)
        onResults(results)
    }

    /// Contacts for the `from:` token suggestions.
    private func loadSuggestions(for query: SearchQuery) async {
        guard let app, !text.isEmpty, !text.contains(" ") else {
            suggestions = []
            return
        }
        let prefix = text.hasPrefix("from:") ? String(text.dropFirst(5)) : text
        suggestions = await (try? app.database.reader.read { db in try ContactQueries.suggest(db, prefix: prefix, limit: 5) }) ?? []
    }
}
