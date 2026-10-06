import SwiftmailCore
import SwiftUI

/// Per-window state: each main window has its own mailbox and thread selection.
@MainActor
@Observable
final class MainWindowModel {
    var mailbox: Mailbox? = .allInboxes {
        didSet {
            if oldValue != mailbox {
                selectedThreads = []
            }
        }
    }

    var category: InboxCategory = .primary {
        didSet {
            if oldValue != category {
                selectedThreads = []
            }
        }
    }

    var selectedThreads: Set<ThreadSummary.ID> = []

    /// The single thread shown in the reader.
    var focusedThread: ThreadSummary.ID? {
        selectedThreads.count == 1 ? selectedThreads.first : nil
    }
}
