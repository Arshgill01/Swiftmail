import Foundation

/// Builds and parses `multipart/mixed` batch requests for
/// `POST https://gmail.googleapis.com/batch/gmail/v1`.
enum GmailBatch {
    static let maxItems = 50

    struct Item: Sendable {
        let id: String
        let path: String
    }

    struct Response: Sendable {
        let status: Int
        let body: Data
    }

    static func body(for items: [Item], boundary: String) -> Data {
        var text = ""
        for (index, item) in items.enumerated() {
            text += "--\(boundary)\r\n"
            text += "Content-Type: application/http\r\n"
            text += "Content-ID: <item\(index)>\r\n\r\n"
            text += "GET \(item.path)\r\n\r\n"
        }
        text += "--\(boundary)--\r\n"
        return Data(text.utf8)
    }

    /// Reads the boundary from a `multipart/mixed; boundary=...` content type.
    static func boundary(fromContentType contentType: String) -> String? {
        for parameter in contentType.split(separator: ";").dropFirst() {
            let pair = parameter.split(separator: "=", maxSplits: 1)
            guard pair.count == 2, pair[0].trimmingCharacters(in: .whitespaces).lowercased() == "boundary" else { continue }
            return pair[1].trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        }
        return nil
    }

    /// Parses a batch response into per-item responses keyed by item index.
    static func parse(_ data: Data, boundary: String) -> [Int: Response] {
        let text = String(decoding: data, as: UTF8.self)
        var results: [Int: Response] = [:]
        for rawPart in text.components(separatedBy: "--\(boundary)") {
            let part = rawPart.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !part.isEmpty, part != "--" else { continue }
            guard let (outerHeaders, httpMessage) = splitHeaders(part) else { continue }
            guard let contentID = header("Content-ID", in: outerHeaders),
                  let index = itemIndex(fromContentID: contentID)
            else { continue }
            guard let (innerHead, body) = splitHeaders(httpMessage) else { continue }
            let statusLine = innerHead.components(separatedBy: .newlines).first ?? ""
            let statusParts = statusLine.split(separator: " ")
            guard statusParts.count >= 2, let status = Int(statusParts[1]) else { continue }
            results[index] = Response(status: status, body: Data(body.utf8))
        }
        return results
    }

    private static func splitHeaders(_ text: String) -> (String, String)? {
        for separator in ["\r\n\r\n", "\n\n"] {
            if let range = text.range(of: separator) {
                return (String(text[..<range.lowerBound]), String(text[range.upperBound...]))
            }
        }
        return (text, "")
    }

    private static func header(_ name: String, in headers: String) -> String? {
        for line in headers.components(separatedBy: .newlines) {
            let pair = line.split(separator: ":", maxSplits: 1)
            if pair.count == 2, pair[0].trimmingCharacters(in: .whitespaces).caseInsensitiveCompare(name) == .orderedSame {
                return pair[1].trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    /// `<response-item12>` → 12.
    private static func itemIndex(fromContentID contentID: String) -> Int? {
        let trimmed = contentID.trimmingCharacters(in: CharacterSet(charactersIn: "<> "))
        guard let range = trimmed.range(of: "item", options: .backwards) else { return nil }
        return Int(trimmed[range.upperBound...])
    }
}
