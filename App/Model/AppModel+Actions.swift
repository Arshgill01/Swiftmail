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
                if action == .markRead || action.removesFromList {
                    notifications.remove(threads: threads)
                }
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

    /// Posts notifications for new mail that passes the policy.
    func notify(_ items: [NewMailItem]) async {
        let plan = try? await database.reader.read { db in
            try NotificationPolicy.plan(items, db: db) { accountID in
                let defaults = UserDefaults.standard
                return NotificationPolicy.AccountSettings(
                    enabled: defaults.object(forKey: Preferences.accountKey(Preferences.notificationsEnabled, accountID)) as? Bool ?? true,
                    primaryOnly: defaults.object(forKey: Preferences.accountKey(Preferences.notifyPrimaryOnly, accountID)) as? Bool ?? true
                )
            }
        }
        if let plan {
            notifications.post(plan)
        }
    }

    /// Clicking a notification opens the thread in the main window.
    func openThread(_ id: ThreadSummary.ID?, accountID: String) {
        NSApp.activate(ignoringOtherApps: true)
        let window = NSApp.windows.first { WindowRegistry.model(for: $0) != nil }
        guard let window, let model = WindowRegistry.model(for: window) else {
            openWindowAction?(id: "main")
            return
        }
        window.makeKeyAndOrderFront(nil)
        model.mailbox = Mailbox(accountID: accountID, kind: .inbox)
        if let id {
            model.selectedThreads = [id]
        }
    }
}
