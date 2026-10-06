import AppKit
import SwiftmailCore
import SwiftUI

/// Per-window state: mailbox, selection, the list and reader models, and every command
/// the shortcuts, menus and toolbar send to this window.
@MainActor
@Observable
final class MainWindowModel {
    var mailbox: Mailbox? = .allInboxes {
        didSet {
            if oldValue != mailbox {
                selectedThreads = []; cursor = nil
            }
        }
    }

    var category: InboxCategory = .primary {
        didSet {
            if oldValue != category {
                selectedThreads = []; cursor = nil
            }
        }
    }

    var selectedThreads: Set<ThreadSummary.ID> = [] {
        didSet {
            if selectedThreads.count == 1 {
                cursor = selectedThreads.first
            }
        }
    }

    /// The row j/k move from, also while several threads are selected with `x`.
    var cursor: ThreadSummary.ID?
    var sheet: Sheet?
    var isSearchFocused = false
    let list = ThreadListModel()
    let reader = ReaderModel()
    @ObservationIgnored weak var app: AppModel?

    enum Sheet: Identifiable {
        case labels, move, goToLabel, shortcuts
        var id: Self {
            self
        }
    }

    /// The single thread shown in the reader.
    var focusedThread: ThreadSummary.ID? {
        selectedThreads.count == 1 ? selectedThreads.first : nil
    }

    var selectionOrCursor: [ThreadSummary.ID] {
        if !selectedThreads.isEmpty {
            return list.threads.map(\.id).filter(selectedThreads.contains)
        }
        return cursor.map { [$0] } ?? []
    }

    var selectedSummaries: [ThreadSummary] {
        let ids = Set(selectionOrCursor)
        return list.threads.filter { ids.contains($0.id) }
    }

    // MARK: Commands

    func perform(_ command: MailCommand) {
        switch command {
        case .archive: apply(.archive)
        case .trash: apply(mailbox?.kind == .trash ? .moveToInbox : .trash)
        case .spam: apply(mailbox?.kind == .spam ? .notSpam : .spam)
        case .toggleStar: apply(selectedSummaries.allSatisfy(\.isStarred) ? .unstar : .star)
        case .markImportant: apply(.markImportant)
        case .markNotImportant: apply(.markNotImportant)
        case .markRead: apply(.markRead)
        case .markUnread: apply(.markUnread)
        case .toggleRead: apply(selectedSummaries.contains(where: \.isUnread) ? .markRead : .markUnread)
        case .labelPicker: if !selectionOrCursor.isEmpty {
                sheet = .labels
            }
        case .movePicker: if !selectionOrCursor.isEmpty {
                sheet = .move
            }
        case .goLabel: sheet = .goToLabel
        case .showHelp: sheet = .shortcuts
        case .toggleSelection: toggleCursorSelection()
        case .nextThread: moveCursor(by: 1)
        case .previousThread: moveCursor(by: -1)
        case .nextMessage: reader.moveFocus(by: 1)
        case .previousMessage: reader.moveFocus(by: -1)
        case .open: openCursor()
        case .expandAll: reader.expandAll()
        case .back: selectedThreads = []
        case .undo: app?.undoLast()
        case .goInbox: go(.inbox)
        case .goStarred: go(.starred)
        case .goSent: go(.sent)
        case .goDrafts: go(.drafts)
        case .goAllMail: go(.allMail)
        case .compose, .reply, .replyAll, .forward, .search:
            app?.handleComposeOrSearch(command, window: self)
        }
    }

    /// Applies an action to the selection; when the threads leave the list, selection
    /// moves to the thread below, as in Mimestream.
    func apply(_ action: MailAction) {
        let targets = selectionOrCursor
        guard !targets.isEmpty, let app else { return }
        if action.removesFromList || leavesCurrentMailbox(action) {
            let ids = list.threads.map(\.id)
            let removed = Set(targets)
            let lastIndex = ids.lastIndex { removed.contains($0) } ?? 0
            let next = ids[(lastIndex + 1)...].first { !removed.contains($0) } ?? ids[..<lastIndex].last { !removed.contains($0) }
            withAnimation(.easeOut(duration: 0.15)) {
                selectedThreads = next.map { [$0] } ?? []
            }
            cursor = next
        }
        app.perform(action, threads: targets)
    }

    private func leavesCurrentMailbox(_ action: MailAction) -> Bool {
        switch (mailbox?.kind, action) {
        case (.starred, .unstar), (.important, .markNotImportant): true
        case let (.label(id), .removeLabels(labels)): labels.contains(id)
        default: false
        }
    }

    private func moveCursor(by offset: Int) {
        let ids = list.threads.map(\.id)
        guard !ids.isEmpty else { return }
        let current = cursor.flatMap { ids.firstIndex(of: $0) } ?? (offset > 0 ? -1 : ids.count)
        let index = min(max(current + offset, 0), ids.count - 1)
        cursor = ids[index]
        // With several threads picked by `x`, j/k move only the cursor.
        if selectedThreads.count <= 1 {
            selectedThreads = [ids[index]]
        }
    }

    private func toggleCursorSelection() {
        guard let cursor else { return }
        if selectedThreads.contains(cursor) {
            selectedThreads.remove(cursor)
        } else {
            selectedThreads.insert(cursor)
        }
    }

    private func openCursor() {
        if focusedThread == nil, let cursor {
            selectedThreads = [cursor]
        } else {
            reader.expandFocused()
        }
    }

    private func go(_ kind: Mailbox.Kind) {
        mailbox = Mailbox(accountID: mailbox?.accountID, kind: kind)
    }
}
