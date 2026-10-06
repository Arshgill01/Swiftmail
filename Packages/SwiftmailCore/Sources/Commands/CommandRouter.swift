import Foundation

/// Every named command. Shortcuts, menus, the toolbar and (P1) the command palette all
/// call the same commands.
public enum MailCommand: String, CaseIterable, Sendable {
    case compose, reply, replyAll, forward
    case archive, trash, spam, toggleStar, markImportant, markNotImportant, markRead, markUnread, toggleRead
    case labelPicker, movePicker, toggleSelection
    case nextThread, previousThread, nextMessage, previousMessage, open, expandAll, back
    case search, undo, showHelp
    case goInbox, goStarred, goSent, goDrafts, goAllMail, goLabel

    public var title: String {
        switch self {
        case .compose: "New message"
        case .reply: "Reply"
        case .replyAll: "Reply all"
        case .forward: "Forward"
        case .archive: "Archive"
        case .trash: "Move to Trash"
        case .spam: "Report spam"
        case .toggleStar: "Star or unstar"
        case .markImportant: "Mark important"
        case .markNotImportant: "Mark not important"
        case .markRead: "Mark as read"
        case .markUnread: "Mark as unread"
        case .toggleRead: "Toggle read"
        case .labelPicker: "Label…"
        case .movePicker: "Move to…"
        case .toggleSelection: "Select or deselect thread"
        case .nextThread: "Next thread"
        case .previousThread: "Previous thread"
        case .nextMessage: "Next message"
        case .previousMessage: "Previous message"
        case .open: "Open thread / expand message"
        case .expandAll: "Expand all messages"
        case .back: "Back to the list"
        case .search: "Search"
        case .undo: "Undo last action"
        case .showHelp: "Keyboard shortcuts"
        case .goInbox: "Go to Inbox"
        case .goStarred: "Go to Starred"
        case .goSent: "Go to Sent"
        case .goDrafts: "Go to Drafts"
        case .goAllMail: "Go to All Mail"
        case .goLabel: "Go to label…"
        }
    }
}

/// Gmail-compatible single-key shortcuts. Ignored while typing in a text field and when
/// Command, Control or Option is held (the menus own those).
public struct CommandRouter: Sendable {
    public struct Modifiers: OptionSet, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) {
            self.rawValue = rawValue
        }

        public static let shift = Modifiers(rawValue: 1)
        public static let command = Modifiers(rawValue: 2)
        public static let control = Modifiers(rawValue: 4)
        public static let option = Modifiers(rawValue: 8)
    }

    /// Special keys, from `NSEvent.keyCode`.
    public enum Key: Sendable, Equatable {
        case character(String)
        case returnKey, escape, delete, forwardDelete, down, up
    }

    static let goTimeout: TimeInterval = 1.5
    private var pendingGo: Date?

    public init() {}

    /// True after "g", while the second key of a go sequence is expected.
    public var isAwaitingGo: Bool {
        pendingGo != nil
    }

    public static let singleKeys: [String: MailCommand] = [
        "c": .compose, "r": .reply, "a": .replyAll, "f": .forward,
        "e": .archive, "y": .archive, "#": .trash, "!": .spam, "s": .toggleStar,
        "+": .markImportant, "=": .markImportant, "-": .markNotImportant,
        "I": .markRead, "U": .markUnread, "l": .labelPicker, "v": .movePicker, "x": .toggleSelection,
        "j": .nextThread, "k": .previousThread, "n": .nextMessage, "p": .previousMessage,
        "o": .open, ";": .expandAll, "/": .search, "z": .undo, "?": .showHelp,
    ]

    public static let goKeys: [String: MailCommand] = [
        "i": .goInbox, "s": .goStarred, "t": .goSent, "d": .goDrafts, "a": .goAllMail, "l": .goLabel,
    ]

    public mutating func route(_ key: Key, modifiers: Modifiers, isTextInput: Bool, now: Date = Date()) -> MailCommand? {
        guard !isTextInput else {
            pendingGo = nil
            return nil
        }
        guard modifiers.isDisjoint(with: [.command, .control, .option]) else { return nil }
        switch key {
        case .returnKey:
            pendingGo = nil
            return .open
        case .escape:
            pendingGo = nil
            return .back
        case .delete, .forwardDelete:
            pendingGo = nil
            return .trash
        case .down:
            return nil
        case .up:
            return nil
        case let .character(text):
            if let started = pendingGo {
                pendingGo = nil
                if now.timeIntervalSince(started) <= Self.goTimeout, let command = Self.goKeys[text.lowercased()] {
                    return command
                }
            }
            if text == "g" {
                pendingGo = now
                return nil
            }
            return Self.singleKeys[text]
        }
    }
}
