import Foundation

/// A Gmail-syntax query split into what the local index can answer. The raw text always
/// goes to Gmail's server search unchanged.
public struct SearchQuery: Sendable, Equatable {
    public var raw: String
    public var terms: [String] = []
    public var from: [String] = []
    public var to: [String] = []
    public var subject: [String] = []
    public var hasAttachment = false
    public var isUnread = false
    public var isStarred = false
    public var label: String?
    /// Operators the local index can't evaluate (older_than:, larger:, OR, ...).
    public var unsupported: [String] = []

    public init(_ raw: String) {
        self.raw = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        for token in Self.tokenize(self.raw) {
            let lower = token.lowercased()
            if let colon = token.firstIndex(of: ":"), colon != token.startIndex {
                let key = token[..<colon].lowercased()
                let value = Self.unquote(String(token[token.index(after: colon)...]))
                switch key {
                case "from": from.append(value)
                case "to", "cc", "bcc": to.append(value)
                case "subject": subject.append(value)
                case "has" where value.lowercased() == "attachment": hasAttachment = true
                case "is" where value.lowercased() == "unread": isUnread = true
                case "is" where value.lowercased() == "starred": isStarred = true
                case "in", "label": label = value
                default: unsupported.append(token)
                }
            } else if lower == "or" || lower == "and" || token.hasPrefix("-") {
                unsupported.append(token)
            } else {
                terms.append(Self.unquote(token))
            }
        }
    }

    public var isEmpty: Bool {
        raw.isEmpty
    }

    /// Whether the local index can answer the query on its own (exactly).
    public var isFullyLocal: Bool {
        unsupported.isEmpty
    }

    /// Splits on spaces, keeping "quoted phrases" and key:"quoted values" together.
    static func tokenize(_ text: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var inQuotes = false
        for char in text {
            if char == "\"" {
                inQuotes.toggle()
            }
            if char.isWhitespace, !inQuotes {
                if !current.isEmpty {
                    tokens.append(current)
                }
                current = ""
            } else {
                current.append(char)
            }
        }
        if !current.isEmpty {
            tokens.append(current)
        }
        return tokens
    }

    static func unquote(_ value: String) -> String {
        value.count >= 2 && value.hasPrefix("\"") && value.hasSuffix("\"") ? String(value.dropFirst().dropLast()) : value
    }

    /// The FTS5 MATCH expression, every term a quoted prefix so user input can't break it.
    var ftsExpression: String? {
        var parts: [String] = []
        func phrase(_ text: String) -> [String] {
            text.split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "'" })
                .map { "\"" + $0.replacingOccurrences(of: "\"", with: "") + "\"*" }
        }
        for term in terms {
            parts += phrase(term)
        }
        for value in from {
            let words = phrase(value)
            if !words.isEmpty {
                parts.append("from_text : (" + words.joined(separator: " ") + ")")
            }
        }
        for value in to {
            let words = phrase(value)
            if !words.isEmpty {
                parts.append("to_text : (" + words.joined(separator: " ") + ")")
            }
        }
        for value in subject {
            let words = phrase(value)
            if !words.isEmpty {
                parts.append("subject : (" + words.joined(separator: " ") + ")")
            }
        }
        return parts.isEmpty ? nil : parts.joined(separator: " AND ")
    }
}
