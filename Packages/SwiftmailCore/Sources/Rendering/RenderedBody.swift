import Foundation

/// A message body ready for the webview, stored in `message_bodies.display_html`.
public struct RenderedBody: Sendable, Equatable {
    public var html: String
    public var hasRemoteContent: Bool
    public var trackerCount: Int
    public var usesPaper: Bool
}

/// Content-Security-Policy for the reader. The stored HTML carries the blocking policy;
/// allowing remote images swaps it at display time.
public enum ReaderCSP {
    public static let blocked = "default-src 'none'; style-src 'unsafe-inline'; img-src swiftmail-cid: data:"
    public static let allowed = "default-src 'none'; style-src 'unsafe-inline'; img-src swiftmail-cid: data: https: http:; font-src https:"

    public static func metaTag(_ policy: String) -> String {
        "<meta http-equiv=\"Content-Security-Policy\" content=\"\(policy)\">"
    }

    /// The same HTML with remote images allowed.
    public static func allowingRemoteContent(_ html: String) -> String {
        html.replacingOccurrences(of: metaTag(blocked), with: metaTag(allowed))
    }
}

/// Picks HTML over plain text and renders either into the reader document.
public enum BodyRenderer {
    public static func render(_ message: DecodedMessage, accountID: String, messageID: String) -> RenderedBody {
        let inline = Set(message.attachments.compactMap { $0.isInline ? $0.contentID?.lowercased() : nil })
        if let html = message.html, !html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return HTMLSanitizer.render(html: html, accountID: accountID, messageID: messageID, inlineContentIDs: inline)
        }
        let body = PlainTextRenderer.html(message.plain ?? "", flowed: message.plainIsFlowed, delSp: message.plainDelSp)
        return RenderedBody(
            html: ReaderDocument.wrap(head: "", body: body, bodyClass: "sm-simple sm-plain", wrapperStyle: nil),
            hasRemoteContent: false, trackerCount: 0, usesPaper: false
        )
    }
}

/// The document shell every body is rendered into.
enum ReaderDocument {
    static let baseStyle = """
    :root{color-scheme:light dark}
    html,body{margin:0;padding:0;background:transparent}
    body{font:14px -apple-system,BlinkMacSystemFont,system-ui,sans-serif;line-height:1.45;overflow-wrap:anywhere;-webkit-text-size-adjust:none}
    .sm-content{max-width:760px;margin:0 auto}
    body.sm-simple{color:#1d1d1f}
    body.sm-plain .sm-content{white-space:pre-wrap;font-family:-apple-system,system-ui,sans-serif}
    img{max-width:100%;height:auto}
    pre{white-space:pre-wrap}
    blockquote{margin:0 0 0 .8ex;border-left:2px solid rgba(128,128,128,.45);padding-left:1ex}
    details.sm-quote{margin:6px 0}
    details.sm-quote>summary{list-style:none;display:inline-block;cursor:pointer;padding:0 7px;border-radius:7px;
      background:rgba(128,128,128,.18);color:#888;font-size:12px;line-height:15px;letter-spacing:1px}
    details.sm-quote>summary::-webkit-details-marker{display:none}
    @media (prefers-color-scheme:dark){
      body.sm-simple{color:#e8e8ea}
      body.sm-simple a{color:#6cb0ff}
      body.sm-paper .sm-content{background:#fff;color:#1d1d1f;border-radius:10px;padding:14px;color-scheme:light}
    }
    """

    static func wrap(head: String, body: String, bodyClass: String, wrapperStyle: String?) -> String {
        let style = wrapperStyle.map { " style=\"\(escapeAttribute($0))\"" } ?? ""
        return """
        <!doctype html><html><head><meta charset="utf-8">\(ReaderCSP.metaTag(ReaderCSP.blocked))
        <meta name="viewport" content="width=device-width"><style>\(baseStyle)</style>\(head)</head>
        <body class="\(bodyClass)"><div class="sm-content"\(style)>\(body)</div></body></html>
        """
    }

    static func escapeAttribute(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;")
    }

    static func escapeText(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}
