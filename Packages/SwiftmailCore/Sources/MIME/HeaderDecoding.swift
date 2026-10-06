import Foundation

/// RFC 2047 encoded words (`=?charset?B|Q?text?=`) in header values.
public enum HeaderDecoding {
    public static func decode(_ value: String) -> String {
        guard value.contains("=?") else { return value }
        var result = ""
        var rest = Substring(value)
        var lastWasEncoded = false
        let encodedWord = /=\?([^?\s]+)\?([BbQq])\?([^?\s]*)\?=/
        while let match = rest.firstMatch(of: encodedWord) {
            let between = rest[rest.startIndex ..< match.range.lowerBound]
            // Whitespace between two adjacent encoded words is dropped (RFC 2047 §6.2).
            if !(lastWasEncoded && between.allSatisfy(\.isWhitespace)) {
                result += between
            }
            let charset = String(match.1).split(separator: "*").first.map(String.init)
            if let decoded = decodeWord(charset: charset, encoding: String(match.2), text: String(match.3)) {
                result += decoded
            } else {
                result += rest[match.range]
            }
            lastWasEncoded = true
            rest = rest[match.range.upperBound...]
        }
        result += rest
        return result
    }

    static func decodeWord(charset: String?, encoding: String, text: String) -> String? {
        let data: Data? = if encoding.uppercased() == "B" {
            Data(base64Encoded: padded(text))
        } else {
            decodeQ(text)
        }
        guard let data else { return nil }
        return Charset.decode(data, charset: charset)
    }

    private static func padded(_ text: String) -> String {
        let remainder = text.count % 4
        return remainder == 0 ? text : text + String(repeating: "=", count: 4 - remainder)
    }

    static func decodeQ(_ text: String) -> Data {
        var bytes: [UInt8] = []
        let chars = Array(text.utf8)
        var index = 0
        while index < chars.count {
            let char = chars[index]
            if char == UInt8(ascii: "_") {
                bytes.append(0x20)
            } else if char == UInt8(ascii: "="), index + 2 < chars.count,
                      let byte = UInt8(String(decoding: chars[index + 1 ... index + 2], as: UTF8.self), radix: 16) {
                bytes.append(byte)
                index += 2
            } else {
                bytes.append(char)
            }
            index += 1
        }
        return Data(bytes)
    }
}

/// A parsed `type/subtype; key=value` header such as Content-Type or Content-Disposition.
public struct HeaderParameters: Sendable, Equatable {
    public let value: String
    public let parameters: [String: String]

    public init(_ header: String) {
        let pieces = Self.splitRespectingQuotes(header, separator: ";")
        value = (pieces.first ?? "").trimmingCharacters(in: .whitespaces).lowercased()
        var params: [String: String] = [:]
        var continuations: [String: [Int: String]] = [:]
        for piece in pieces.dropFirst() {
            let pair = piece.split(separator: "=", maxSplits: 1)
            guard pair.count == 2 else { continue }
            var key = pair[0].trimmingCharacters(in: .whitespaces).lowercased()
            var raw = pair[1].trimmingCharacters(in: .whitespaces)
            if raw.hasPrefix("\""), raw.hasSuffix("\""), raw.count >= 2 {
                raw = String(raw.dropFirst().dropLast()).replacingOccurrences(of: "\\\"", with: "\"")
            }
            // RFC 2231: name*=charset'lang'value and name*0*=... continuations.
            var extended = false
            if key.hasSuffix("*") {
                key.removeLast()
                extended = true
            }
            if let star = key.firstIndex(of: "*"), let section = Int(key[key.index(after: star)...]) {
                let base = String(key[..<star])
                continuations[base, default: [:]][section] = extended ? raw : raw
                continue
            }
            params[key] = extended ? Self.decodeRFC2231(raw) : HeaderDecoding.decode(raw)
        }
        for (key, sections) in continuations {
            let joined = sections.keys.sorted().compactMap { sections[$0] }.joined()
            params[key] = Self.decodeRFC2231(joined)
        }
        parameters = params
    }

    public subscript(_ key: String) -> String? {
        parameters[key.lowercased()]
    }

    static func decodeRFC2231(_ value: String) -> String {
        let parts = value.split(separator: "'", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3 else { return value.removingPercentEncoding ?? value }
        let charset = String(parts[0])
        var bytes: [UInt8] = []
        let chars = Array(parts[2].utf8)
        var index = 0
        while index < chars.count {
            if chars[index] == UInt8(ascii: "%"), index + 2 < chars.count,
               let byte = UInt8(String(decoding: chars[index + 1 ... index + 2], as: UTF8.self), radix: 16) {
                bytes.append(byte)
                index += 3
            } else {
                bytes.append(chars[index])
                index += 1
            }
        }
        return Charset.decode(Data(bytes), charset: charset.isEmpty ? "utf-8" : charset)
    }

    static func splitRespectingQuotes(_ text: String, separator: Character) -> [String] {
        var result: [String] = []
        var current = ""
        var inQuotes = false
        var escaped = false
        for char in text {
            if escaped {
                current.append(char)
                escaped = false
                continue
            }
            if char == "\\" {
                escaped = true; current.append(char); continue
            }
            if char == "\"" {
                inQuotes.toggle()
            }
            if char == separator, !inQuotes {
                result.append(current)
                current = ""
            } else {
                current.append(char)
            }
        }
        result.append(current)
        return result
    }
}
