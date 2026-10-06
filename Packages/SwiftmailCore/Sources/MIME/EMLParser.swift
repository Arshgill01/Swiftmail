import Foundation

/// Parses a raw RFC 5322 message into the same part tree Gmail's API returns
/// (`format=full`), decoding transfer encodings so bodies are raw bytes in base64url.
/// Used for the test corpus and for saving or viewing originals.
public enum EMLParser {
    public static func parse(_ data: Data) -> GmailMessagePart {
        parsePart(Array(data), partID: "")
    }

    static func parsePart(_ bytes: [UInt8], partID: String) -> GmailMessagePart {
        let (headerBytes, body) = splitHeaderAndBody(bytes)
        let headers = parseHeaders(headerBytes)
        func value(_ name: String) -> String? {
            headers.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
        }
        let contentType = HeaderParameters(value("Content-Type") ?? "text/plain; charset=us-ascii")
        let mimeType = contentType.value.isEmpty ? "text/plain" : contentType.value
        let disposition = value("Content-Disposition").map(HeaderParameters.init)
        let filename = disposition?["filename"] ?? contentType["name"] ?? ""

        if mimeType.hasPrefix("multipart/"), let boundary = contentType["boundary"] {
            let children = splitMultipart(body, boundary: boundary).enumerated().map { index, child in
                parsePart(child, partID: partID.isEmpty ? String(index) : "\(partID).\(index)")
            }
            return GmailMessagePart(
                partId: partID, mimeType: mimeType, filename: filename, headers: headers,
                body: GmailMessagePartBody(size: 0), parts: children
            )
        }
        let decoded = decodeTransferEncoding(body, encoding: value("Content-Transfer-Encoding"))
        return GmailMessagePart(
            partId: partID, mimeType: mimeType, filename: filename, headers: headers,
            body: GmailMessagePartBody(size: decoded.count, data: Base64URL.encode(Data(decoded)))
        )
    }

    static func splitHeaderAndBody(_ bytes: [UInt8]) -> ([UInt8], [UInt8]) {
        var index = 0
        while index < bytes.count {
            if bytes[index] == 0x0A {
                // LF LF or LF CR LF ends the header block.
                if index + 1 < bytes.count, bytes[index + 1] == 0x0A {
                    return (Array(bytes[..<index]), Array(bytes[(index + 2)...]))
                }
                if index + 2 < bytes.count, bytes[index + 1] == 0x0D, bytes[index + 2] == 0x0A {
                    return (Array(bytes[..<index]), Array(bytes[(index + 3)...]))
                }
            }
            index += 1
        }
        return (bytes, [])
    }

    /// Unfolds continuation lines and decodes values as UTF-8 (falling back to Latin-1).
    static func parseHeaders(_ bytes: [UInt8]) -> [GmailHeader] {
        let text = String(bytes: bytes, encoding: .utf8) ?? String(bytes: bytes, encoding: .isoLatin1) ?? ""
        var headers: [GmailHeader] = []
        for rawLine in text.components(separatedBy: "\n") {
            let line = rawLine.hasSuffix("\r") ? String(rawLine.dropLast()) : rawLine
            if line.first == " " || line.first == "\t", let last = headers.popLast() {
                let continuation = line.trimmingCharacters(in: .whitespaces)
                headers.append(GmailHeader(name: last.name, value: last.value.isEmpty ? continuation : last.value + " " + continuation))
            } else if let colon = line.firstIndex(of: ":") {
                let name = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
                let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                if !name.isEmpty {
                    headers.append(GmailHeader(name: name, value: value))
                }
            }
        }
        return headers
    }

    static func splitMultipart(_ body: [UInt8], boundary: String) -> [[UInt8]] {
        let delimiter = Array("--\(boundary)".utf8)
        var parts: [[UInt8]] = []
        var starts: [(start: Int, end: Int)] = []
        var index = 0
        // A delimiter must start a line.
        while index + delimiter.count <= body.count {
            let atLineStart = index == 0 || body[index - 1] == 0x0A
            if atLineStart, body[index] == 0x2D, Array(body[index ..< index + delimiter.count]) == delimiter {
                starts.append((index, index + delimiter.count))
                index += delimiter.count
            } else {
                index += 1
            }
        }
        for (position, marker) in starts.enumerated() {
            let afterMarker = marker.end
            // The closing delimiter ends with "--".
            if afterMarker + 1 < body.count, body[afterMarker] == 0x2D, body[afterMarker + 1] == 0x2D {
                break
            }
            var contentStart = afterMarker
            while contentStart < body.count, body[contentStart] != 0x0A {
                contentStart += 1
            }
            contentStart += 1
            guard position + 1 < starts.count, contentStart <= starts[position + 1].start else { continue }
            var contentEnd = starts[position + 1].start
            // Drop the line break that belongs to the next delimiter.
            if contentEnd > contentStart, body[contentEnd - 1] == 0x0A {
                contentEnd -= 1
            }
            if contentEnd > contentStart, body[contentEnd - 1] == 0x0D {
                contentEnd -= 1
            }
            parts.append(Array(body[contentStart ..< max(contentStart, contentEnd)]))
        }
        return parts
    }

    static func decodeTransferEncoding(_ body: [UInt8], encoding: String?) -> [UInt8] {
        switch encoding?.lowercased().trimmingCharacters(in: .whitespaces) {
        case "base64":
            let text = String(decoding: body, as: UTF8.self).filter { !$0.isWhitespace }
            return Base64URL.decode(text).map { Array($0) } ?? []
        case "quoted-printable":
            return decodeQuotedPrintable(body)
        default:
            return body
        }
    }

    static func decodeQuotedPrintable(_ body: [UInt8]) -> [UInt8] {
        var output: [UInt8] = []
        output.reserveCapacity(body.count)
        var index = 0
        while index < body.count {
            let byte = body[index]
            if byte == UInt8(ascii: "=") {
                // Soft line break.
                if index + 1 < body.count, body[index + 1] == 0x0A {
                    index += 2
                    continue
                }
                if index + 2 < body.count, body[index + 1] == 0x0D, body[index + 2] == 0x0A {
                    index += 3
                    continue
                }
                if index + 2 < body.count, let value = UInt8(String(decoding: body[index + 1 ... index + 2], as: UTF8.self), radix: 16) {
                    output.append(value)
                    index += 3
                    continue
                }
            }
            output.append(byte)
            index += 1
        }
        return output
    }
}
