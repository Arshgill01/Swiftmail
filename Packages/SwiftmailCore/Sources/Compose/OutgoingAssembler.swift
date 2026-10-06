import Foundation
import SwiftSoup

/// Turns a compose state into an `OutgoingMessage`: pasted and dropped images (data URLs in
/// the editor) become inline `cid:` parts, and attachments are read from disk.
public enum OutgoingAssembler {
    public static func assemble(_ state: ComposeState, fromName: String?, date: Date = Date()) throws -> OutgoingMessage {
        var message = OutgoingMessage(from: EmailAddress(name: fromName, email: state.from))
        message.to = state.to
        message.cc = state.cc
        message.bcc = state.bcc
        message.subject = state.subject
        message.inReplyTo = state.inReplyTo
        message.references = state.references
        message.date = date
        let (html, inline) = extractInlineImages(state.bodyHTML)
        message.html = html
        message.inlineImages = inline
        message.attachments = try state.attachments.map { attachment in
            try OutgoingPart(
                filename: attachment.filename, mimeType: attachment.mimeType,
                data: Data(contentsOf: AttachmentStorage.url(forRelativePath: attachment.path))
            )
        }
        return message
    }

    /// Replaces `<img src="data:image/...;base64,...">` with `cid:` references.
    public static func extractInlineImages(_ html: String) -> (String, [OutgoingPart]) {
        guard html.contains("data:image/"), let document = try? SwiftSoup.parseBodyFragment(html), let body = document.body() else {
            return (html, [])
        }
        var parts: [OutgoingPart] = []
        for image in (try? body.select("img[src^=data:image/]").array()) ?? [] {
            guard let src = try? image.attr("src"), let comma = src.firstIndex(of: ","),
                  let data = Data(base64Encoded: String(src[src.index(after: comma)...]))
            else { continue }
            let header = src[src.index(src.startIndex, offsetBy: 5) ..< comma]
            let mimeType = header.split(separator: ";").first.map(String.init) ?? "image/png"
            let ext = mimeType.split(separator: "/").last.map(String.init) ?? "png"
            let contentID = "ii_\(UUID().uuidString.prefix(12).lowercased())"
            parts.append(OutgoingPart(filename: "image\(parts.count + 1).\(ext)", mimeType: mimeType, data: data, contentID: contentID))
            _ = try? image.attr("src", "cid:\(contentID)")
            _ = try? image.removeAttr("data-cid")
        }
        return ((try? body.html()) ?? html, parts)
    }
}
