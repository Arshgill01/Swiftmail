import Foundation

public enum InboxCategory: String, CaseIterable, Codable, Sendable, Hashable {
    case primary, promotions, social, updates, forums

    public var labelID: String? {
        switch self {
        case .primary: nil
        case .promotions: "CATEGORY_PROMOTIONS"
        case .social: "CATEGORY_SOCIAL"
        case .updates: "CATEGORY_UPDATES"
        case .forums: "CATEGORY_FORUMS"
        }
    }

    public var title: String {
        rawValue.capitalized
    }
}

/// What the thread list shows: a system mailbox, a user label, or the outbox, for one
/// account or unified across all of them.
public struct Mailbox: Hashable, Codable, Sendable {
    public enum Kind: Hashable, Codable, Sendable {
        case inbox
        case starred
        case important
        case sent
        case drafts
        case allMail
        case spam
        case trash
        case outbox
        case label(String)
    }

    /// nil means unified across accounts.
    public var accountID: String?
    public var kind: Kind

    public init(accountID: String?, kind: Kind) {
        self.accountID = accountID
        self.kind = kind
    }

    public static let allInboxes = Mailbox(accountID: nil, kind: .inbox)

    public var labelID: String? {
        switch kind {
        case .inbox: "INBOX"
        case .starred: "STARRED"
        case .important: "IMPORTANT"
        case .sent: "SENT"
        case .drafts: "DRAFT"
        case .spam: "SPAM"
        case .trash: "TRASH"
        case let .label(id): id
        case .allMail, .outbox: nil
        }
    }

    public var isUnified: Bool {
        accountID == nil
    }

    public var systemImage: String {
        switch kind {
        case .inbox: "tray"
        case .starred: "star"
        case .important: "tag"
        case .sent: "paperplane"
        case .drafts: "doc"
        case .allMail: "archivebox"
        case .spam: "xmark.octagon"
        case .trash: "trash"
        case .outbox: "tray.and.arrow.up"
        case .label: "tag"
        }
    }

    public var defaultTitle: String {
        switch kind {
        case .inbox: accountID == nil ? "All Inboxes" : "Inbox"
        case .starred: "Starred"
        case .important: "Important"
        case .sent: "Sent"
        case .drafts: "Drafts"
        case .allMail: "All Mail"
        case .spam: "Spam"
        case .trash: "Trash"
        case .outbox: "Outbox"
        case let .label(id): id
        }
    }
}
