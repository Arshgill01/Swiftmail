import SwiftmailCore
import SwiftUI

struct ThreadListView: View {
    @Environment(AppModel.self) private var model
    @Bindable var window: MainWindowModel
    private var list: ThreadListModel {
        window.list
    }

    @AppStorage(Preferences.listDensity) private var densityRaw = ListDensity.comfortable.rawValue
    @FocusState private var searchFocused: Bool

    var body: some View {
        if window.mailbox?.kind == .outbox {
            OutboxListView().navigationTitle("Outbox")
        } else {
            threadList
        }
    }

    private var threadList: some View {
        VStack(spacing: 0) {
            NeedsSignInBanner()
            if showsCategoryBar {
                CategoryBar(selection: $window.category, counts: categoryCounts)
                Divider()
            }
            List(selection: $window.selectedThreads) {
                ForEach(list.threads) { thread in
                    row(thread)
                        .tag(thread.id)
                        .draggable(ThreadDrag.payload(for: thread.id, selection: window.selectedThreads))
                        .onAppear {
                            list.rowAppeared(thread.id) { await model.session(for: $0) }
                        }
                }
                if list.isLoadingOlder {
                    HStack {
                        Spacer()
                        ProgressView().controlSize(.small)
                        Spacer()
                    }
                }
            }
            .listStyle(.inset)
            .overlay {
                if list.hasLoaded, list.threads.isEmpty {
                    emptyState
                }
            }
        }
        .navigationTitle(window.search.isActive ? "Search" : title)
        .navigationSubtitle(window.search.isActive ? searchSubtitle : subtitle)
        .searchable(text: Bindable(window.search).text, tokens: Bindable(window.search).tokens, placement: .toolbar, prompt: "Search mail") { token in
            Text(token.label)
        }
        .searchSuggestions { searchSuggestions }
        .searchFocused($searchFocused)
        .onChange(of: window.isSearchFocused) {
            if window.isSearchFocused {
                searchFocused = true
                window.isSearchFocused = false
            }
        }
        .onAppear {
            window.search.app = model
            window.search.onResults = { [weak window] ids in
                guard let window else { return }
                if window.search.isActive {
                    window.list.observeSearch(database: model.database, ids: ids)
                } else {
                    window.list.observe(database: model.database, mailbox: window.mailbox, category: window.category)
                }
            }
            observe()
        }
        .onChange(of: window.mailbox) { observe() }
        .onChange(of: window.category) { observe() }
        .onChange(of: window.focusedThread) {
            if let id = window.focusedThread, let thread = list.threads.first(where: { $0.id == id }) {
                model.markReadOnOpen(thread)
            }
        }
        #if DEBUG
        .onReceive(NotificationCenter.default.publisher(for: DebugSnapshot.selectNotification)) { note in
            if let index = note.object as? Int, list.threads.indices.contains(index) {
                window.selectedThreads = [list.threads[index].id]
            }
        }
        #endif
    }

    private func observe() {
        window.search.accountID = window.mailbox?.accountID
        guard !window.search.isActive else { return }
        list.observe(database: model.database, mailbox: window.mailbox, category: window.category)
    }

    private var searchSubtitle: String {
        if window.search.isSearchingServer {
            return "Searching Gmail…"
        }
        if let error = window.search.serverError {
            return error
        }
        return "\(list.threads.count) results"
    }

    @ViewBuilder
    private var searchSuggestions: some View {
        if !window.search.tokens.contains(.hasAttachment) {
            Label("Has attachment", systemImage: "paperclip").searchCompletion(SearchToken.hasAttachment)
        }
        ForEach(window.search.suggestions, id: \.email) { contact in
            Label("From \(contact.display)", systemImage: "person").searchCompletion(SearchToken.from(contact.email))
        }
    }

    private func row(_ thread: ThreadSummary) -> some View {
        let account = model.sidebarAccount(thread.accountID)
        let unified = window.mailbox?.isUnified == true && model.accounts.count > 1
        return ThreadRow(
            thread: thread,
            density: ListDensity(rawValue: densityRaw) ?? .comfortable,
            ownAddresses: account?.ownAddresses ?? [],
            labels: account?.allLabels ?? [:],
            accountColor: unified ? AccountColors.color(model.accountColorIndex(thread.accountID)) : nil,
            isCursor: window.selectedThreads.count > 1 && window.cursor == thread.id,
            onAction: { action in
                window.selectedThreads.contains(thread.id) ? window.apply(action) : model.perform(action, threads: [thread.id])
            }
        )
    }

    @ViewBuilder
    private var emptyState: some View {
        if window.mailbox?.kind == .inbox {
            ContentUnavailableView("Nothing in your inbox", systemImage: "tray")
        } else {
            ContentUnavailableView("No conversations", systemImage: window.mailbox?.systemImage ?? "tray")
        }
    }

    private var showsCategoryBar: Bool {
        guard window.mailbox?.kind == .inbox, !window.search.isActive else { return false }
        if let accountID = window.mailbox?.accountID {
            return model.account(accountID)?.categoriesEnabled == true
        }
        return model.accounts.contains { $0.categoriesEnabled }
    }

    private var categoryCounts: [InboxCategory: Int] {
        let accounts = window.mailbox?.accountID.map { id in model.sidebar.accounts.filter { $0.id == id } } ?? model.sidebar.accounts
        var counts: [InboxCategory: Int] = [:]
        for account in accounts {
            for (category, count) in account.categoryUnread {
                counts[category, default: 0] += count
            }
        }
        return counts
    }

    private var title: String {
        guard let mailbox = window.mailbox else { return "Swiftmail" }
        if case let .label(id) = mailbox.kind, let accountID = mailbox.accountID {
            return model.sidebarAccount(accountID)?.allLabels[id]?.name ?? "Label"
        }
        return mailbox.defaultTitle
    }

    private var subtitle: String {
        guard let mailbox = window.mailbox else { return "" }
        let unread: Int = switch mailbox.kind {
        case .inbox:
            mailbox.accountID.flatMap { model.sidebarAccount($0)?.inboxUnread } ?? model.sidebar.unifiedInboxUnread
        case let .label(id):
            mailbox.accountID.flatMap { model.sidebarAccount($0)?.allLabels[id]?.threadsUnread } ?? 0
        default:
            0
        }
        return unread > 0 ? "\(unread.formatted()) unread" : ""
    }
}

/// Primary, Promotions, Social, Updates, Forums with unread counts.
struct CategoryBar: View {
    @Binding var selection: InboxCategory
    let counts: [InboxCategory: Int]

    var body: some View {
        Picker("Category", selection: $selection) {
            ForEach(InboxCategory.allCases, id: \.self) { category in
                let count = counts[category] ?? 0
                Text(count > 0 && category != .primary ? "\(category.title) \(count)" : category.title)
                    .tag(category)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .controlSize(.small)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }
}
