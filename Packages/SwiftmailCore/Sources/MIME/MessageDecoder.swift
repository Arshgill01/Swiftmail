import Foundation

public struct DecodedAttachment: Sendable, Equatable {
    public var partID: String
    public var attachmentID: String?
    public var filename: String
    public var mimeType: String
    public var size: Int
    public var contentID: String?
    public var isInline: Bool
    /// Present for small parts that arrived inline in `body.data`.
    public var data: Data?
}

/// A text body part too large to arrive inline; fetched with `messages.attachments.get`.
public struct PendingBodyPart: Sendable, Equatable {
    public var attachmentID: String
    public var isHTML: Bool
    public var charset: String?
}

public struct DecodedHeaders: Sendable, Equatable {
    public var from: EmailAddress?
    public var to: [EmailAddress] = []
    public var cc: [EmailAddress] = []
    public var bcc: [EmailAddress] = []
    public var replyTo: [EmailAddress] = []
    public var subject: String?
    public var date: String?
    public var messageID: String?
    public var inReplyTo: String?
    public var references: String?
    public var listUnsubscribe: String?
    public var listUnsubscribePost: String?

    public init(_ headers: [GmailHeader]) {
        func value(_ name: String) -> String? {
            headers.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
        }
        from = EmailAddress.parseList(value("From")).first
        to = EmailAddress.parseList(value("To"))
        cc = EmailAddress.parseList(value("Cc"))
        bcc = EmailAddress.parseList(value("Bcc"))
        replyTo = EmailAddress.parseList(value("Reply-To"))
        subject = value("Subject").map { HeaderDecoding.decode($0).replacingOccurrences(of: "\r\n", with: "") }
        date = value("Date")
        messageID = value("Message-ID") ?? value("Message-Id")
        inReplyTo = value("In-Reply-To")
        references = value("References")
        listUnsubscribe = value("List-Unsubscribe")
        listUnsubscribePost = value("List-Unsubscribe-Post")
    }
}

public struct DecodedMessage: Sendable, Equatable {
    public var headers: DecodedHeaders
    public var html: String?
    public var plain: String?
    public var plainIsFlowed = false
    public var plainDelSp = false
    public var attachments: [DecodedAttachment] = []
    public var pendingBodyParts: [PendingBodyPart] = []
    public var calendarPart: String?
}

/// Walks a Gmail MIME part tree: `text/html` for display with `text/plain` as fallback,
/// parts with a filename or `attachmentId` as attachments, and `Content-ID` parts the
/// HTML references as inline images.
public enum MessageDecoder {
    public static func decode(_ payload: GmailMessagePart) -> DecodedMessage {
        var message = DecodedMessage(headers: DecodedHeaders(payload.headers ?? []))
        walk(payload, into: &message)
        markInlineParts(&message)
        return message
    }

    private static func walk(_ part: GmailMessagePart, into message: inout DecodedMessage) {
        let headers = part.headers ?? []
        let contentType = HeaderParameters(header("Content-Type", in: headers) ?? part.mimeType ?? "text/plain")
        let mimeType = (part.mimeType?.lowercased()).flatMap { $0.isEmpty ? nil : $0 } ?? contentType.value
        let disposition = header("Content-Disposition", in: headers).map(HeaderParameters.init)

        if mimeType.hasPrefix("multipart/") {
            for child in part.parts ?? [] {
                walk(child, into: &message)
            }
            return
        }

        let filename = (part.filename?.isEmpty == false ? part.filename : nil)
            ?? disposition?["filename"] ?? contentType["name"]
        let isAttachmentDisposition = disposition?.value == "attachment"
        let isText = mimeType == "text/html" || mimeType == "text/plain"

        if isText, filename == nil, !isAttachmentDisposition {
            appendText(part, mimeType: mimeType, contentType: contentType, into: &message)
            return
        }
        if mimeType == "text/calendar", message.calendarPart == nil, let data = bodyData(part) {
            message.calendarPart = Charset.decode(data, charset: contentType["charset"])
        }
        let contentID = header("Content-ID", in: headers).map {
            $0.trimmingCharacters(in: CharacterSet(charactersIn: "<> "))
        }
        guard filename != nil || part.body?.attachmentId != nil || contentID != nil else { return }
        message.attachments.append(DecodedAttachment(
            partID: part.partId ?? String(message.attachments.count),
            attachmentID: part.body?.attachmentId,
            filename: filename ?? defaultFilename(for: mimeType),
            mimeType: mimeType,
            size: part.body?.size ?? 0,
            contentID: contentID,
            isInline: false,
            data: bodyData(part)
        ))
    }

    private static func appendText(
        _ part: GmailMessagePart, mimeType: String, contentType: HeaderParameters, into message: inout DecodedMessage
    ) {
        let isHTML = mimeType == "text/html"
        let charset = contentType["charset"]
        guard let data = bodyData(part) else {
            if let attachmentID = part.body?.attachmentId {
                message.pendingBodyParts.append(PendingBodyPart(attachmentID: attachmentID, isHTML: isHTML, charset: charset))
            }
            return
        }
        let text = Charset.decode(data, charset: charset)
        if isHTML {
            // A second HTML part in multipart/mixed (e.g. a list footer) is appended.
            message.html = message.html.map { $0 + "\n" + text } ?? text
        } else if message.plain == nil {
            message.plain = text
            message.plainIsFlowed = contentType["format"]?.lowercased() == "flowed"
            message.plainDelSp = contentType["delsp"]?.lowercased() == "yes"
        } else {
            message.plain? += "\n" + text
        }
    }

    /// Inline when the HTML references the part's Content-ID.
    private static func markInlineParts(_ message: inout DecodedMessage) {
        guard let html = message.html?.lowercased() else { return }
        for index in message.attachments.indices {
            guard let cid = message.attachments[index].contentID?.lowercased(), !cid.isEmpty else { continue }
            if html.contains("cid:\(cid)") {
                message.attachments[index].isInline = true
            }
        }
    }

    static func bodyData(_ part: GmailMessagePart) -> Data? {
        guard let encoded = part.body?.data, !encoded.isEmpty else {
            return part.body?.attachmentId == nil && part.body?.size == 0 ? Data() : nil
        }
        return Base64URL.decode(encoded)
    }

    static func header(_ name: String, in headers: [GmailHeader]) -> String? {
        headers.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    static func defaultFilename(for mimeType: String) -> String {
        switch mimeType {
        case "image/png": "image.png"
        case "image/jpeg", "image/jpg": "image.jpg"
        case "image/gif": "image.gif"
        case "text/calendar": "invite.ics"
        case "message/rfc822": "message.eml"
        default: "attachment"
        }
    }
}
