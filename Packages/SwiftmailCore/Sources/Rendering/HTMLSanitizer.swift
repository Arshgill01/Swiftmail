import Foundation
import SwiftSoup

/// Cleans untrusted email HTML: removes active content, event handlers and script URLs,
/// rewrites `cid:` images to the app's scheme, drops tracking pixels, detects remote
/// content and colors, collapses quoted text, and wraps it in the reader document.
public enum HTMLSanitizer {
    static let removedElements = [
        "script", "iframe", "frame", "frameset", "object", "embed", "applet", "form", "input", "button",
        "textarea", "select", "meta", "base", "link", "param", "portal", "title", "noscript",
    ]
    static let urlAttributes = ["href", "src", "action", "formaction", "background", "poster", "xlink:href", "data", "lowsrc", "dynsrc", "srcset"]
    static let trackerHosts = [
        "google-analytics.com", "mailtrack", "list-manage.com/track", "sendgrid.net/wf/open", "mandrillapp.com/track",
        "sidekickopen", "mailstat.us", "/track/open", "/open.gif", "pixel.", "track.", "tracking.", "beacon.",
    ]

    public static func render(html: String, accountID: String, messageID: String, inlineContentIDs: Set<String>) -> RenderedBody {
        guard let document = try? SwiftSoup.parse(html) else {
            return BodyRenderer.render(DecodedMessage(headers: DecodedHeaders([]), plain: html), accountID: accountID, messageID: messageID)
        }
        var trackers = 0
        var remote = false
        do {
            for name in removedElements {
                try document.select(name).remove()
            }
            for element in try document.getAllElements().array() {
                try cleanAttributes(element)
            }
            for image in try document.select("img").array() {
                switch try classifyImage(image, accountID: accountID, messageID: messageID) {
                case .tracker:
                    trackers += 1
                    try image.remove()
                case .remote:
                    remote = true
                case .local:
                    break
                }
            }
            if try !document.select("[background]").isEmpty() {
                remote = true
            }
            let styles = try document.select("style").array().map { $0.data() }.joined(separator: "\n")
            let inlineStyles = try document.select("[style]").array().map { try $0.attr("style") }.joined(separator: "\n")
            if hasRemoteURL(in: styles + inlineStyles) {
                remote = true
            }
            for anchor in try document.select("a").array() {
                try anchor.removeAttr("target")
                try anchor.attr("rel", "noopener noreferrer")
            }
            try QuoteCollapser.collapse(document)
            let usesPaper = try setsOwnColors(document, css: styles + "\n" + inlineStyles)
            let head = try document.head()?.select("style").array().map { try $0.outerHtml() }.joined() ?? ""
            let body = document.body()
            let wrapperStyle = try body.flatMap(bodyStyle)
            let inner = try body?.html() ?? ""
            return RenderedBody(
                html: ReaderDocument.wrap(head: head, body: inner, bodyClass: usesPaper ? "sm-paper" : "sm-simple", wrapperStyle: wrapperStyle),
                hasRemoteContent: remote, trackerCount: trackers, usesPaper: usesPaper
            )
        } catch {
            let text = (try? document.text()) ?? ""
            return BodyRenderer.render(DecodedMessage(headers: DecodedHeaders([]), plain: text), accountID: accountID, messageID: messageID)
        }
    }

    // MARK: Attributes

    static func cleanAttributes(_ element: Element) throws {
        guard let attributes = element.getAttributes() else { return }
        for attribute in attributes.asList() {
            let key = attribute.getKey().lowercased()
            let value = attribute.getValue()
            if key.hasPrefix("on") {
                try element.removeAttr(attribute.getKey())
                continue
            }
            if urlAttributes.contains(key), isDangerousURL(value, attribute: key, tag: element.tagName()) {
                try element.removeAttr(attribute.getKey())
                continue
            }
            if key == "style" {
                try element.attr("style", cleanCSS(value))
            }
        }
        if element.tagName() == "style" {
            let css = element.data()
            let cleaned = cleanCSS(css)
            if cleaned != css {
                try element.html(cleaned)
            }
        }
    }

    /// `javascript:`, `vbscript:` and non-image `data:` URLs, after removing whitespace and
    /// control characters that browsers ignore.
    static func isDangerousURL(_ value: String, attribute: String, tag: String) -> Bool {
        let normalized = String(value.unicodeScalars.filter { $0.value > 0x20 && $0.value != 0x7F }).lowercased()
        if normalized.hasPrefix("javascript:") || normalized.hasPrefix("vbscript:") || normalized.hasPrefix("livescript:") {
            return true
        }
        if normalized.hasPrefix("data:") {
            return !(tag == "img" && attribute == "src" && normalized.hasPrefix("data:image/") && !normalized.hasPrefix("data:image/svg"))
        }
        return false
    }

    static func cleanCSS(_ css: String) -> String {
        var result = css
        for pattern in ["expression(", "javascript:", "vbscript:", "-moz-binding", "behavior:"] {
            result = result.replacingOccurrences(of: pattern, with: "blocked-", options: .caseInsensitive)
        }
        return result
    }

    static func hasRemoteURL(in css: String) -> Bool {
        css.range(of: #"url\(\s*['"]?\s*(https?:)?//"#, options: [.regularExpression, .caseInsensitive]) != nil
            || css.range(of: #"@import"#, options: .caseInsensitive) != nil
    }

    // MARK: Images

    enum ImageKind { case local, remote, tracker }

    static func classifyImage(_ image: Element, accountID: String, messageID: String) throws -> ImageKind {
        let src = try image.attr("src").trimmingCharacters(in: .whitespacesAndNewlines)
        if src.lowercased().hasPrefix("cid:") {
            let contentID = String(src.dropFirst(4)).trimmingCharacters(in: CharacterSet(charactersIn: "<>"))
            try image.attr("src", CIDScheme.url(accountID: accountID, messageID: messageID, contentID: contentID))
            return .local
        }
        let lower = src.lowercased()
        let isRemote = lower.hasPrefix("http://") || lower.hasPrefix("https://") || lower.hasPrefix("//")
        let srcsetRemote = try image.attr("srcset").lowercased().contains("http")
        guard isRemote || srcsetRemote else { return .local }
        if isTrackingPixel(image, src: lower) {
            return .tracker
        }
        return .remote
    }

    static func isTrackingPixel(_ image: Element, src: String) -> Bool {
        func dimension(_ name: String) -> Int? {
            (try? image.attr(name)).flatMap { Int($0.trimmingCharacters(in: CharacterSet(charactersIn: "px "))) }
        }
        if let width = dimension("width"), let height = dimension("height"), width <= 2, height <= 2 {
            return true
        }
        if dimension("width") == 0 || dimension("height") == 0 {
            return true
        }
        let style = ((try? image.attr("style")) ?? "").lowercased().replacingOccurrences(of: " ", with: "")
        let hidden = ["display:none", "visibility:hidden", "opacity:0;", "width:0", "height:0", "width:1px;height:1px", "max-height:0"]
        if hidden.contains(where: style.contains) || style.hasSuffix("opacity:0") {
            return true
        }
        return trackerHosts.contains { src.contains($0) }
    }

    // MARK: Colors

    /// HTML that sets its own colors keeps them on a white "paper" card in dark mode.
    static func setsOwnColors(_ document: Document, css: String) throws -> Bool {
        if try !document.select("[bgcolor], font[color], [text]").isEmpty() {
            return true
        }
        let pattern = #"(background(-color)?|(^|[;{\s])color)\s*:\s*(?!\s*(transparent|inherit|initial|none|currentcolor)\b)"#
        return css.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// Moves `<body bgcolor>` and inline body styles onto the wrapper div.
    static func bodyStyle(_ body: Element) throws -> String? {
        var parts: [String] = []
        let bgcolor = try body.attr("bgcolor")
        if !bgcolor.isEmpty {
            parts.append("background-color:\(bgcolor)")
        }
        let text = try body.attr("text")
        if !text.isEmpty {
            parts.append("color:\(text)")
        }
        let style = try body.attr("style")
        if !style.isEmpty {
            parts.append(style)
        }
        return parts.isEmpty ? nil : parts.joined(separator: ";")
    }
}

/// `swiftmail-cid://<account>/<message>/<content-id>` for inline images.
public enum CIDScheme {
    public static let scheme = "swiftmail-cid"

    public static func url(accountID: String, messageID: String, contentID: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        let encoded = contentID.addingPercentEncoding(withAllowedCharacters: allowed) ?? contentID
        return "\(scheme)://\(accountID)/\(messageID)/\(encoded)"
    }

    /// Parses a scheme URL back into its parts.
    public static func parse(_ url: URL) -> (accountID: String, messageID: String, contentID: String)? {
        guard url.scheme == scheme, let account = url.host() else { return nil }
        let components = url.path(percentEncoded: true).split(separator: "/").map(String.init)
        guard components.count >= 2 else { return nil }
        let contentID = components[1...].joined(separator: "/").removingPercentEncoding ?? components[1]
        return (account, components[0], contentID)
    }
}
