import Foundation

/// Decodes the HTML entities Gmail uses in snippets (`&#39;`, `&amp;`, `&quot;` ...).
public enum HTMLEntities {
    static let named: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": "\u{00A0}",
        "ndash": "–", "mdash": "—", "hellip": "…", "rsquo": "’", "lsquo": "‘", "rdquo": "”",
        "ldquo": "“", "copy": "©", "reg": "®", "trade": "™", "euro": "€", "zwnj": "\u{200C}",
    ]

    public static func decode(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var result = ""
        var index = text.startIndex
        while index < text.endIndex {
            let char = text[index]
            if char == "&", let semicolon = text[index...].prefix(12).firstIndex(of: ";") {
                let entity = text[text.index(after: index) ..< semicolon]
                if let replacement = resolve(entity) {
                    result += replacement
                    index = text.index(after: semicolon)
                    continue
                }
            }
            result.append(char)
            index = text.index(after: index)
        }
        return result
    }

    private static func resolve(_ entity: Substring) -> String? {
        if entity.hasPrefix("#x") || entity.hasPrefix("#X") {
            return UInt32(entity.dropFirst(2), radix: 16).flatMap(Unicode.Scalar.init).map { String(Character($0)) }
        }
        if entity.hasPrefix("#") {
            return UInt32(entity.dropFirst()).flatMap(Unicode.Scalar.init).map { String(Character($0)) }
        }
        return named[String(entity)]
    }
}
