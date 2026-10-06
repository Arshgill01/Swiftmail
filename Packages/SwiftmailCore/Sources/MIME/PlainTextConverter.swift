import Foundation
import SwiftSoup

/// Makes the `text/plain` alternative from HTML: line breaks and paragraphs kept, list
/// bullets, quotes prefixed with `>`, and links written as "text (url)".
public enum PlainTextConverter {
    static let blockTags: Set<String> = ["p", "div", "section", "article", "header", "footer", "h1", "h2", "h3", "h4", "h5", "h6", "table", "tr", "pre"]

    public static func convert(_ html: String) -> String {
        guard !html.isEmpty, let document = try? SwiftSoup.parseBodyFragment(html), let body = document.body() else { return "" }
        var output = ""
        render(body, into: &output, listStack: [])
        // Collapse runs of blank lines and trim.
        let lines = output.components(separatedBy: "\n").map { $0.replacingOccurrences(of: "\u{00A0}", with: " ").trimmingTrailing() }
        var collapsed: [String] = []
        for line in lines {
            if line.isEmpty, collapsed.last?.isEmpty == true {
                continue
            }
            collapsed.append(line)
        }
        return collapsed.joined(separator: "\n").trimmingCharacters(in: .newlines)
    }

    private static func render(_ node: Node, into output: inout String, listStack: [ListState]) {
        if let text = node as? TextNode {
            let value = text.text().replacingOccurrences(of: "\n", with: " ")
            output += value
            return
        }
        guard let element = node as? Element else { return }
        let tag = element.tagName().lowercased()
        switch tag {
        case "br":
            output += "\n"
            return
        case "style", "script", "head", "title":
            return
        case "blockquote":
            var inner = ""
            for child in element.getChildNodes() {
                render(child, into: &inner, listStack: listStack)
            }
            let quoted = inner.trimmingCharacters(in: .newlines).components(separatedBy: "\n").map { $0.isEmpty ? ">" : "> " + $0 }
            ensureNewline(&output)
            output += quoted.joined(separator: "\n") + "\n"
            return
        case "a":
            renderLink(element, into: &output, listStack: listStack)
            return
        case "img":
            if let alt = try? element.attr("alt"), !alt.isEmpty {
                output += alt
            }
            return
        case "ul", "ol":
            ensureNewline(&output)
            let state = ListState(ordered: tag == "ol")
            for child in element.getChildNodes() {
                render(child, into: &output, listStack: listStack + [state])
            }
            ensureNewline(&output)
            return
        case "li":
            renderListItem(element, into: &output, listStack: listStack)
            return
        case "hr":
            ensureNewline(&output)
            output += "———\n"
            return
        default:
            break
        }
        let isBlock = blockTags.contains(tag)
        if isBlock {
            ensureNewline(&output)
        }
        for child in element.getChildNodes() {
            render(child, into: &output, listStack: listStack)
        }
        if tag == "td" {
            output += " "
        }
        if isBlock {
            ensureNewline(&output)
            if tag == "p" {
                output += "\n"
            }
        }
    }

    private static func renderLink(_ element: Element, into output: inout String, listStack: [ListState]) {
        var inner = ""
        for child in element.getChildNodes() {
            render(child, into: &inner, listStack: listStack)
        }
        let href = (try? element.attr("href")) ?? ""
        let label = inner.trimmingCharacters(in: .whitespaces)
        if href.isEmpty || href == label || href == "mailto:" + label || href.hasPrefix("#") {
            output += inner
        } else {
            output += label.isEmpty ? href : "\(label) (\(href.hasPrefix("mailto:") ? String(href.dropFirst(7)) : href))"
        }
    }

    private static func renderListItem(_ element: Element, into output: inout String, listStack: [ListState]) {
        ensureNewline(&output)
        let indent = String(repeating: "  ", count: max(0, listStack.count - 1))
        if let list = listStack.last, list.ordered {
            list.counter += 1
            output += "\(indent)\(list.counter). "
        } else {
            output += "\(indent)• "
        }
        for child in element.getChildNodes() {
            render(child, into: &output, listStack: listStack)
        }
        ensureNewline(&output)
    }

    final class ListState {
        let ordered: Bool
        var counter = 0
        init(ordered: Bool) {
            self.ordered = ordered
        }
    }

    private static func ensureNewline(_ output: inout String) {
        if !output.isEmpty, !output.hasSuffix("\n") {
            output += "\n"
        }
    }
}

extension String {
    func trimmingTrailing() -> String {
        var copy = self
        while copy.last == " " || copy.last == "\t" {
            copy.removeLast()
        }
        return copy
    }
}
