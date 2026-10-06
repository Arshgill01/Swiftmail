import Foundation

public enum ComposeMode: String, Codable, Sendable {
    case new, reply, replyAll, forward
}

public struct ComposeAttachment: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var filename: String
    public var mimeType: String
    public var size: Int
    /// Relative to the attachment storage root (`Compose/<draft>/...`).
    public var path: String

    public init(id: UUID = UUID(), filename: String, mimeType: String, size: Int, path: String) {
        self.id = id
        self.filename = filename
        self.mimeType = mimeType
        self.size = size
        self.path = path
    }
}

/// Everything a compose window holds; saved as a local draft from the first keystroke.
public struct ComposeState: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var accountID: String
    public var from: String
    public var to: [EmailAddress] = []
    public var cc: [EmailAddress] = []
    public var bcc: [EmailAddress] = []
    public var subject = ""
    public var bodyHTML = ""
    public var attachments: [ComposeAttachment] = []
    public var mode: ComposeMode = .new
    public var threadID: String?
    public var inReplyTo: String?
    public var references: String?
    public var gmailDraftID: String?
    public var showCcBcc = false

    public init(id: UUID = UUID(), accountID: String, from: String) {
        self.id = id
        self.accountID = accountID
        self.from = from
    }

    public var hasContent: Bool {
        !to.isEmpty || !cc.isEmpty || !bcc.isEmpty || !subject.isEmpty || !attachments.isEmpty
            || !PlainTextConverter.convert(bodyHTML).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public var allRecipients: [EmailAddress] {
        to + cc + bcc
    }

    public var attachmentBytes: Int {
        attachments.reduce(0) { $0 + $1.size }
    }

    /// Problems that block sending.
    public func validationError(inlineBytes: Int = 0) -> String? {
        if allRecipients.isEmpty {
            return "Add at least one recipient."
        }
        if let bad = allRecipients.first(where: { !Self.isValidAddress($0.email) }) {
            return "\"\(bad.email)\" isn't a valid email address."
        }
        if attachmentBytes + inlineBytes > MIMEBuilder.maxAttachmentBytes {
            return "Attachments are larger than Gmail's 25 MB limit. Remove some, or share them with a link."
        }
        return nil
    }

    public static func isValidAddress(_ email: String) -> Bool {
        email.range(of: #"^[^@\s<>]+@[^@\s<>]+\.[^@\s<>]+$"#, options: .regularExpression) != nil
    }
}
