import Foundation

public struct OutgoingPart: Sendable, Equatable {
    public var filename: String
    public var mimeType: String
    public var data: Data
    /// Set for inline images referenced as `cid:` from the HTML.
    public var contentID: String?

    public init(filename: String, mimeType: String, data: Data, contentID: String? = nil) {
        self.filename = filename
        self.mimeType = mimeType
        self.data = data
        self.contentID = contentID
    }
}

public struct OutgoingMessage: Sendable, Equatable {
    public var from: EmailAddress
    public var to: [EmailAddress] = []
    public var cc: [EmailAddress] = []
    public var bcc: [EmailAddress] = []
    public var subject: String = ""
    public var html: String = ""
    /// Generated from the HTML when nil.
    public var plain: String?
    public var inlineImages: [OutgoingPart] = []
    public var attachments: [OutgoingPart] = []
    public var inReplyTo: String?
    public var references: String?
    public var date = Date()
    public var messageID: String?

    public init(from: EmailAddress) {
        self.from = from
    }

    public var attachmentBytes: Int {
        (attachments + inlineImages).reduce(0) { $0 + $1.data.count }
    }
}

/// Builds RFC 5322 messages: CRLF line endings, lines under 998 characters, RFC 2047
/// headers, RFC 2231 file names, and `multipart/mixed` › `multipart/related` ›
/// `multipart/alternative`, leaving out wrappers that would hold a single child.
public struct MIMEBuilder: Sendable {
    public typealias BoundaryMaker = @Sendable () -> String

    private let makeBoundary: BoundaryMaker
    private let makeMessageID: @Sendable (String) -> String

    public init(
        makeBoundary: @escaping BoundaryMaker = { "sm_" + UUID().uuidString.replacingOccurrences(of: "-", with: "") },
        makeMessageID: @escaping @Sendable (String) -> String = { domain in "<\(UUID().uuidString.lowercased())@\(domain)>" }
    ) {
        self.makeBoundary = makeBoundary
        self.makeMessageID = makeMessageID
    }

    public static let maxAttachmentBytes = 25 * 1024 * 1024

    public func build(_ message: OutgoingMessage) -> Data {
        var headers: [(String, String)] = [
            ("From", Self.encodeAddress(message.from)),
        ]
        if !message.to.isEmpty {
            headers.append(("To", message.to.map(Self.encodeAddress).joined(separator: ", ")))
        }
        if !message.cc.isEmpty {
            headers.append(("Cc", message.cc.map(Self.encodeAddress).joined(separator: ", ")))
        }
        // Bcc stays in the raw message; Gmail removes it from the copies recipients get.
        if !message.bcc.isEmpty {
            headers.append(("Bcc", message.bcc.map(Self.encodeAddress).joined(separator: ", ")))
        }
        headers.append(("Subject", Self.encodeWord(message.subject)))
        headers.append(("Date", Self.rfc5322Date(message.date)))
        let domain = message.from.email.split(separator: "@").last.map(String.init) ?? "swiftmail.local"
        headers.append(("Message-ID", message.messageID ?? makeMessageID(domain)))
        if let inReplyTo = message.inReplyTo, !inReplyTo.isEmpty {
            headers.append(("In-Reply-To", inReplyTo))
        }
        if let references = message.references, !references.isEmpty {
            headers.append(("References", references))
        }
        headers.append(("MIME-Version", "1.0"))

        let plain = message.plain ?? PlainTextConverter.convert(message.html)
        var body = alternative(plain: plain, html: message.html)
        if !message.inlineImages.isEmpty {
            body = multipart("related", [body] + message.inlineImages.map { binaryPart($0, inline: true) })
        }
        if !message.attachments.isEmpty {
            body = multipart("mixed", [body] + message.attachments.map { binaryPart($0, inline: false) })
        }
        var text = headers.map { Self.fold("\($0.0): \($0.1)") }.joined(separator: "\r\n") + "\r\n"
        text += body.headers.map { Self.fold($0) }.joined(separator: "\r\n") + "\r\n\r\n"
        var data = Data(text.utf8)
        data.append(body.body)
        return data
    }

    struct Part {
        var headers: [String]
        var body: Data
    }

    private func alternative(plain: String, html: String) -> Part {
        let textPart = textPart(plain, subtype: "plain")
        guard !html.isEmpty else { return textPart }
        return multipart("alternative", [textPart, self.textPart(html, subtype: "html")])
    }

    private func textPart(_ text: String, subtype: String) -> Part {
        Part(
            headers: ["Content-Type: text/\(subtype); charset=\"UTF-8\"", "Content-Transfer-Encoding: base64"],
            body: Self.base64Lines(Data(text.utf8))
        )
    }

    private func binaryPart(_ part: OutgoingPart, inline: Bool) -> Part {
        var headers = [
            "Content-Type: \(part.mimeType); name=\(Self.quotedParameter(part.filename))",
            "Content-Disposition: \(inline ? "inline" : "attachment"); \(Self.filenameParameter(part.filename))",
            "Content-Transfer-Encoding: base64",
        ]
        if let contentID = part.contentID {
            headers.append("Content-ID: <\(contentID)>")
            headers.append("X-Attachment-Id: \(contentID)")
        }
        return Part(headers: headers, body: Self.base64Lines(part.data))
    }

    private func multipart(_ subtype: String, _ parts: [Part]) -> Part {
        if parts.count == 1, let only = parts.first {
            return only
        }
        let boundary = makeBoundary()
        var body = Data()
        for part in parts {
            body.append(Data("--\(boundary)\r\n".utf8))
            body.append(Data((part.headers.map { Self.fold($0) }.joined(separator: "\r\n") + "\r\n\r\n").utf8))
            body.append(part.body)
            body.append(Data("\r\n".utf8))
        }
        body.append(Data("--\(boundary)--\r\n".utf8))
        return Part(headers: ["Content-Type: multipart/\(subtype); boundary=\"\(boundary)\""], body: body)
    }

    // MARK: Encoding helpers

    static func base64Lines(_ data: Data) -> Data {
        Data(data.base64EncodedString(options: [.lineLength76Characters, .endLineWithCarriageReturn, .endLineWithLineFeed]).utf8)
    }

    /// RFC 2047 B-encoding for non-ASCII text, split into encoded words of at most 75 characters.
    public static func encodeWord(_ text: String) -> String {
        guard text.unicodeScalars.contains(where: { !$0.isASCII || $0.value < 0x20 }) else { return text }
        var words: [String] = []
        var chunk = ""
        for character in text {
            let candidate = chunk + String(character)
            // 45 bytes of UTF-8 become 60 base64 characters; with the wrapper that stays under 75.
            if candidate.utf8.count > 45 {
                words.append(chunk)
                chunk = String(character)
            } else {
                chunk = candidate
            }
        }
        if !chunk.isEmpty {
            words.append(chunk)
        }
        return words.map { "=?UTF-8?B?\(Data($0.utf8).base64EncodedString())?=" }.joined(separator: " ")
    }

    static func encodeAddress(_ address: EmailAddress) -> String {
        guard let name = address.name, !name.isEmpty else { return address.email }
        if name.unicodeScalars.contains(where: { !$0.isASCII }) {
            return "\(encodeWord(name)) <\(address.email)>"
        }
        let specials = CharacterSet(charactersIn: "()<>[]:;@\\,.\"")
        if name.unicodeScalars.contains(where: specials.contains) {
            let escaped = name.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            return "\"\(escaped)\" <\(address.email)>"
        }
        return "\(name) <\(address.email)>"
    }

    static func quotedParameter(_ value: String) -> String {
        if value.unicodeScalars.contains(where: { !$0.isASCII }) {
            return "\"\(encodeWord(value))\""
        }
        return "\"\(value.replacingOccurrences(of: "\"", with: "'"))\""
    }

    /// RFC 2231 `filename*=UTF-8''...` for non-ASCII names, plain `filename="..."` otherwise.
    static func filenameParameter(_ filename: String) -> String {
        guard filename.unicodeScalars.contains(where: { !$0.isASCII }) else {
            return "filename=\"\(filename.replacingOccurrences(of: "\"", with: "'"))\""
        }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "!#$&+-.^_`|~"))
        var encoded = ""
        for byte in Array(filename.utf8) {
            let scalar = Unicode.Scalar(byte)
            if byte < 0x80, allowed.contains(scalar) {
                encoded.append(Character(scalar))
            } else {
                encoded += String(format: "%%%02X", byte)
            }
        }
        return "filename*=UTF-8''\(encoded)"
    }

    /// Folds header lines longer than 76 characters at spaces (RFC 5322 §2.2.3).
    static func fold(_ line: String) -> String {
        guard line.count > 76 else { return line }
        var result = ""
        var current = ""
        for (index, word) in line.split(separator: " ", omittingEmptySubsequences: false).enumerated() {
            // Never break between the header name and its first word.
            if index > 1, !current.isEmpty, current.count + 1 + word.count > 76 {
                result += current + "\r\n"
                current = " " + word
            } else {
                current += current.isEmpty ? String(word) : " " + word
            }
        }
        return result + current
    }

    static func rfc5322Date(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE, d MMM yyyy HH:mm:ss Z"
        return formatter.string(from: date)
    }
}
