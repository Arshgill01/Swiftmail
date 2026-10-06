import AppKit
import SwiftmailCore

extension AppModel {
    /// Applies an action locally at once, shows the undo toast, and sends it in the background.
    func perform(_ action: MailAction, threads: [ThreadSummary.ID], showToast: Bool = true) {
        guard !threads.isEmpty else { return }
        let database = database
        Task {
            do {
                let records = try await MailActions.perform(action, threads: threads, in: database)
                if showToast {
                    undo.push(records)
                }
                for accountID in Set(threads.map(\.accountID)) {
                    await session(for: accountID)?.drainActions()
                }
            } catch {
                undo.show(Toast(message: "Couldn't \(action.failureVerb) that conversation.", canUndo: false))
            }
        }
    }

    /// Undoes the most recent action (Command-Z, `z`, or the toast's Undo button).
    func undoLast() {
        guard let records = undo.popLast() else { return }
        undo.dismiss()
        let database = database
        Task {
            for record in records {
                let outcome = try? await MailActions.undo(record, in: database)
                if outcome == .reversed {
                    await session(for: record.accountID)?.drainActions()
                }
            }
        }
    }

    /// Opening an unread thread marks it read, without a toast.
    func markReadOnOpen(_ thread: ThreadSummary) {
        guard thread.isUnread else { return }
        perform(.markRead, threads: [thread.id], showToast: false)
    }

    /// Wires a session's queue to toasts and to a sync once actions are delivered.
    func configureActions(_ session: AccountSession) async {
        await session.actions.setHandlers(
            onFailure: { message in
                Task { @MainActor [weak self] in self?.undo.show(Toast(message: message, canUndo: false)) }
            },
            onDrained: { [weak session] in
                Task { await session?.triggerSync() }
            }
        )
    }

    /// Compose commands from shortcuts and menus; search (M7) focuses the field.
    func handleComposeOrSearch(_ command: MailCommand, window: MainWindowModel) {
        switch command {
        case .compose: newMessage(accountID: window.mailbox?.accountID ?? window.focusedThread?.accountID)
        case .reply: reply(.reply, window: window)
        case .replyAll: reply(.replyAll, window: window)
        case .forward: reply(.forward, window: window)
        case .search: window.isSearchFocused = true
        default: break
        }
    }
}
