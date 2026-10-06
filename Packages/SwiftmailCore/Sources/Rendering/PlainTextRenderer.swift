import Foundation

/// Plain-text bodies: system font, line breaks kept, URLs and addresses linked,
/// `format=flowed` unwrapped, and quoted lines after an "On … wrote:" line collapsed.
public enum PlainTextRenderer {
    public static func html(_ text: String, flowed: Bool = false, delSp: Bool = false) -> String {
        var lines = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
        if flowed {
            lines = unflow(lines, delSp: delSp)
        }
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        return render(lines, detector: detector, topLevel: true)
    }

    /// RFC 3676: a line ending in a space continues on the next line of the same quote depth.
    static func unflow(_ lines: [String], delSp: Bool) -> [String] {
        var output: [String] = []
        var current: String?
        var currentDepth = 0
        for raw in lines {
            let depth = raw.prefix { $0 == ">" }.count
            var content = String(raw.dropFirst(depth))
            if content.hasPrefix(" ") {
                content.removeFirst()
            } // space-stuffing
            let soft = content.hasSuffix(" ") && content != "-- "
            if delSp, soft {
                content.removeLast()
            }
            if let existing = current, depth == currentDepth {
                current = existing + content
            } else {
                if let existing = current {
                    output.append(quotePrefix(currentDepth) + existing)
                }
                current = content
                currentDepth = depth
            }
            if !soft {
                output.append(quotePrefix(depth) + (current ?? ""))
                current = nil
            }
        }
        if let current {
            output.append(quotePrefix(currentDepth) + current)
        }
        return output
    }

    private static func quotePrefix(_ depth: Int) -> String {
        depth == 0 ? "" : String(repeating: ">", count: depth) + " "
    }

    static func render(_ lines: [String], detector: NSDataDetector?, topLevel: Bool) -> String {
        var html = ""
        var index = 0
        var hasContent = false
        while index < lines.count {
            let line = lines[index]
            if line.hasPrefix(">") {
                var block: [String] = []
                while index < lines.count, lines[index].hasPrefix(">") {
                    var inner = String(lines[index].dropFirst())
                    if inner.hasPrefix(" ") {
                        inner.removeFirst()
                    }
                    block.append(inner)
                    index += 1
                }
                let quote = "<blockquote>" + render(block, detector: detector, topLevel: false) + "</blockquote>"
                html += topLevel && hasContent ? collapsed(quote) : quote
                continue
            }
            if topLevel, hasContent, isAttribution(line), index + 1 < lines.count,
               lines[index + 1].hasPrefix(">") || (index + 2 < lines.count && lines[index + 1].isEmpty && lines[index + 2].hasPrefix(">")) {
                // The attribution line and the quote below it collapse together.
                var block: [String] = []
                index += 1
                while index < lines.count, lines[index].hasPrefix(">") || (lines[index].isEmpty && block.isEmpty) {
                    var inner = String(lines[index].dropFirst())
                    if inner.hasPrefix(" ") {
                        inner.removeFirst()
                    }
                    if !lines[index].isEmpty {
                        block.append(inner)
                    }
                    index += 1
                }
                let quote = linkify(line, detector: detector) + "\n<blockquote>" + render(block, detector: detector, topLevel: false) + "</blockquote>"
                html += collapsed(quote)
                continue
            }
            if !line.trimmingCharacters(in: .whitespaces).isEmpty {
                hasContent = true
            }
            html += linkify(line, detector: detector) + (index < lines.count - 1 ? "\n" : "")
            index += 1
        }
        return html
    }

    static func isAttribution(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return (trimmed.hasPrefix("On ") && trimmed.hasSuffix("wrote:")) || trimmed.hasSuffix("wrote:")
    }

    static func collapsed(_ html: String) -> String {
        "<details class=\"sm-quote\"><summary title=\"Show quoted text\">•••</summary>\(html)</details>"
    }

    /// Escapes a line and turns URLs and email addresses into links.
    static func linkify(_ line: String, detector: NSDataDetector?) -> String {
        guard let detector, !line.isEmpty else { return ReaderDocument.escapeText(line) }
        let ns = line as NSString
        var output = ""
        var cursor = 0
        for match in detector.matches(in: line, range: NSRange(location: 0, length: ns.length)) {
            guard let url = match.url, ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "") else { continue }
            output += ReaderDocument.escapeText(ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor)))
            let label = ns.substring(with: match.range)
            output += "<a href=\"\(ReaderDocument.escapeAttribute(url.absoluteString))\">\(ReaderDocument.escapeText(label))</a>"
            cursor = match.range.location + match.range.length
        }
        output += ReaderDocument.escapeText(ns.substring(from: cursor))
        return output
    }
}
