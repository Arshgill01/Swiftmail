import Foundation

/// A user action on threads. Each one applies locally at once and syncs in the background.
public enum MailAction: Sendable, Equatable {
    case archive
    case trash
    case star
    case unstar
    case markRead
    case markUnread
    case markImportant
    case markNotImportant
    case spam
    case notSpam
    case moveToInbox
    case addLabels([String])
    case removeLabels([String])
    /// Adds the label and removes the mailbox the threads are in (Gmail's "Move to").
    case move(to: String, from: String?)

    /// Labels to add and remove on the affected messages.
    var delta: (add: [String], remove: [String]) {
        switch self {
        case .archive: ([], ["INBOX"])
        case .trash: (["TRASH"], ["INBOX"])
        case .star: (["STARRED"], [])
        case .unstar: ([], ["STARRED"])
        case .markRead: ([], ["UNREAD"])
        case .markUnread: (["UNREAD"], [])
        case .markImportant: (["IMPORTANT"], [])
        case .markNotImportant: ([], ["IMPORTANT"])
        case .spam: (["SPAM"], ["INBOX"])
        case .notSpam: (["INBOX"], ["SPAM"])
        case .moveToInbox: (["INBOX"], ["TRASH", "SPAM"])
        case let .addLabels(labels): (labels, [])
        case let .removeLabels(labels): ([], labels)
        case let .move(to, from): ([to], [from ?? "INBOX"].filter { $0 != to })
        }
    }

    /// Gmail stars and marks unread the newest message only; everything else is thread-wide.
    var latestMessageOnly: Bool {
        self == .star || self == .markUnread
    }

    /// Removes the threads from most mailboxes; the list moves its selection.
    public var removesFromList: Bool {
        switch self {
        case .archive, .trash, .spam, .notSpam, .move: true
        default: false
        }
    }

    public func title(count: Int) -> String {
        let noun = count == 1 ? "conversation" : "\(count) conversations"
        switch self {
        case .archive: return count == 1 ? "Archived" : "Archived \(count) conversations"
        case .trash: return count == 1 ? "Moved to Trash" : "Moved \(count) conversations to Trash"
        case .star: return "Starred"
        case .unstar: return "Unstarred"
        case .markRead: return "Marked as read"
        case .markUnread: return "Marked as unread"
        case .markImportant: return "Marked as important"
        case .markNotImportant: return "Marked as not important"
        case .spam: return "Reported \(noun) as spam"
        case .notSpam: return "Moved \(noun) to Inbox"
        case .moveToInbox: return "Moved \(noun) to Inbox"
        case .addLabels: return "Label added"
        case .removeLabels: return "Label removed"
        case .move: return "Moved \(noun)"
        }
    }

    public var failureVerb: String {
        switch self {
        case .archive: "archive"
        case .trash: "move to Trash"
        case .star, .unstar: "change the star on"
        case .markRead, .markUnread: "change read status of"
        case .markImportant, .markNotImportant: "change importance of"
        case .spam, .notSpam: "change spam status of"
        default: "update"
        }
    }
}

/// `pending_actions.payload` for label changes.
struct ModifyPayload: Codable, Equatable {
    var threadIDs: [String]
    var messageIDs: [String]
    var add: [String]
    var remove: [String]
    /// Thread-wide (threads.modify for up to 5 threads) or exact messages (batchModify).
    var threadScope: Bool
    var trash = false
    var untrash = false
    var title: String?
}

/// `pending_actions.undo_payload`: each message's state of the affected labels before.
struct UndoPayload: Codable, Equatable {
    var threadIDs: [String]
    var affected: [String]
    var prior: [String: [String]]
    var title: String?
}

enum PendingKind {
    static let modify = "modify_labels"
    static let send = "send"
}

extension JSONEncoder {
    static func encodeString(_ value: some Encodable) throws -> String {
        try String(decoding: JSONEncoder().encode(value), as: UTF8.self)
    }
}

extension JSONDecoder {
    static func decode<T: Decodable>(_ type: T.Type, string: String) throws -> T {
        try JSONDecoder().decode(type, from: Data(string.utf8))
    }
}
