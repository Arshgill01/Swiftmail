import Foundation

public struct EmailAddress: Codable, Sendable, Hashable {
    public var name: String?
    public var email: String

    public init(name: String? = nil, email: String) {
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.name = trimmed?.isEmpty == false ? trimmed : nil
        self.email = email.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Name if present, otherwise the address.
    public var displayName: String {
        name ?? email
    }

    /// Parses an address-list header such as `"Doe, Jane" <jane@x.com>, bob@y.com`.
    public static func parseList(_ header: String?) -> [EmailAddress] {
        guard let header, !header.isEmpty else { return [] }
        return splitAddresses(header).compactMap(parse)
    }

    public static func parse(_ raw: String) -> EmailAddress? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if let open = text.lastIndex(of: "<"), let close = text.lastIndex(of: ">"), open < close {
            let email = String(text[text.index(after: open) ..< close])
            var name = String(text[..<open]).trimmingCharacters(in: .whitespaces)
            if name.hasPrefix("\""), name.hasSuffix("\""), name.count >= 2 {
                name = String(name.dropFirst().dropLast()).replacingOccurrences(of: "\\\"", with: "\"")
            }
            guard email.contains("@") else { return nil }
            return EmailAddress(name: HeaderDecoding.decode(name), email: email)
        }
        // `jane@x.com (Jane Doe)`
        if let open = text.firstIndex(of: "("), let close = text.lastIndex(of: ")"), open < close {
            let email = String(text[..<open]).trimmingCharacters(in: .whitespaces)
            let name = String(text[text.index(after: open) ..< close])
            guard email.contains("@") else { return nil }
            return EmailAddress(name: HeaderDecoding.decode(name), email: email)
        }
        guard text.contains("@") else { return nil }
        return EmailAddress(email: text.trimmingCharacters(in: CharacterSet(charactersIn: "\"'")))
    }

    /// Splits on commas that are outside quotes, angle brackets and comments.
    static func splitAddresses(_ header: String) -> [String] {
        var parts: [String] = []
        var current = ""
        var inQuotes = false
        var angle = 0
        var paren = 0
        var escaped = false
        for char in header {
            if escaped {
                current.append(char); escaped = false; continue
            }
            switch char {
            case "\\": escaped = true
            case "\"": inQuotes.toggle()
            case "<" where !inQuotes: angle += 1
            case ">" where !inQuotes: angle = max(0, angle - 1)
            case "(" where !inQuotes: paren += 1
            case ")" where !inQuotes: paren = max(0, paren - 1)
            case ",", ";":
                if !inQuotes, angle == 0, paren == 0 {
                    parts.append(current)
                    current = ""
                    continue
                }
            default: break
            }
            current.append(char)
        }
        parts.append(current)
        return parts
    }

    static func encodeJSON(_ addresses: [EmailAddress]) -> String? {
        guard !addresses.isEmpty, let data = try? JSONEncoder().encode(addresses) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public static func decodeJSON(_ json: String?) -> [EmailAddress] {
        guard let json, let data = json.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([EmailAddress].self, from: data)) ?? []
    }
}
