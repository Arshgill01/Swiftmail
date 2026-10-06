import Foundation

/// A parsed `mailto:` URL (RFC 6068).
public struct MailtoLink: Sendable, Equatable {
    public var to: [EmailAddress] = []
    public var cc: [EmailAddress] = []
    public var bcc: [EmailAddress] = []
    public var subject = ""
    public var body = ""

    public init?(_ url: URL) {
        guard url.scheme?.lowercased() == "mailto" else { return nil }
        let raw = url.absoluteString.dropFirst("mailto:".count)
        let parts = raw.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        let decode = { (text: Substring) in String(text).replacingOccurrences(of: "+", with: "%2B").removingPercentEncoding ?? String(text) }
        to = EmailAddress.parseList(decode(parts.first ?? ""))
        guard parts.count > 1 else { return }
        for pair in parts[1].split(separator: "&") {
            let keyValue = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard keyValue.count == 2 else { continue }
            let value = decode(keyValue[1])
            switch keyValue[0].lowercased() {
            case "to": to += EmailAddress.parseList(value)
            case "cc": cc += EmailAddress.parseList(value)
            case "bcc": bcc += EmailAddress.parseList(value)
            case "subject": subject = value
            case "body": body = value.replacingOccurrences(of: "\r\n", with: "\n")
            default: break
            }
        }
    }
}
