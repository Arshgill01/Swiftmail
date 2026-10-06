import Foundation
import SwiftSoup

/// Plain text used for full-text search.
public enum BodyText {
    static let maxLength = 64 * 1024

    public static func extract(html: String?, plain: String?) -> String? {
        if let plain, !plain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return String(plain.prefix(maxLength))
        }
        guard let html, !html.isEmpty else { return nil }
        guard let document = try? SwiftSoup.parse(html) else { return nil }
        _ = try? document.select("style, script, head, title").remove()
        let text = (try? document.text()) ?? ""
        return String(text.prefix(maxLength))
    }
}
