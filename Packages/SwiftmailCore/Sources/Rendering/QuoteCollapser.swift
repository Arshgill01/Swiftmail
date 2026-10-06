import Foundation
import SwiftSoup

/// Collapses quoted text behind a "•••" toggle (`<details>`, which works with page
/// JavaScript off): Gmail's `div.gmail_quote`, Apple Mail's `blockquote[type=cite]`,
/// Yahoo's `div.yahoo_quoted`, and Outlook's reply header block with what follows it.
/// Forwards and messages that are nothing but a quote stay expanded.
enum QuoteCollapser {
    static func collapse(_ document: Document) throws {
        guard let body = document.body() else { return }
        if let outlook = try body.select("#divRplyFwdMsg, div#appendonsend").first() {
            try collapseOutlook(from: outlook)
            return
        }
        let candidates = try body.select("div.gmail_quote, div.gmail_quote_container, blockquote[type=cite], div.yahoo_quoted").array()
        for element in candidates where try isTopLevel(element) {
            guard try shouldCollapse(element, in: body) else { continue }
            try wrap([element])
        }
    }

    static func isTopLevel(_ element: Element) throws -> Bool {
        var parent = element.parent()
        while let current = parent {
            if current.tagName() == "details" {
                return false
            }
            if current.hasClass("gmail_quote") || current.hasClass("yahoo_quoted") {
                return false
            }
            if current.tagName() == "blockquote", try current.attr("type") == "cite" {
                return false
            }
            parent = current.parent()
        }
        return true
    }

    static func shouldCollapse(_ element: Element, in body: Element) throws -> Bool {
        let text = try element.text()
        if text.contains("Forwarded message") || text.contains("Begin forwarded message") {
            return false
        }
        // Something must come before the quote.
        let full = try body.text().trimmingCharacters(in: .whitespacesAndNewlines)
        return !full.hasPrefix(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    static func collapseOutlook(from start: Element) throws {
        guard let parent = start.parent() else { return }
        var nodes: [Node] = []
        var collecting = false
        // Include an <hr> right before the header block.
        for node in parent.getChildNodes() {
            if node === start {
                collecting = true
            }
            if collecting {
                nodes.append(node)
            }
        }
        if let index = nodes.first.map(\.siblingIndex), index > 0,
           let previous = parent.childNode(index - 1) as? Element, previous.tagName() == "hr" {
            nodes.insert(previous, at: 0)
        }
        let before = try parent.text().replacingOccurrences(of: nodes.compactMap { try? ($0 as? Element)?.text() }.joined(), with: "")
        guard !before.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        try wrap(nodes)
    }

    static func wrap(_ nodes: [Node]) throws {
        guard let first = nodes.first else { return }
        let details = try Element(Tag.valueOf("details"), "")
        try details.addClass("sm-quote")
        let summary = try Element(Tag.valueOf("summary"), "")
        try summary.attr("title", "Show quoted text")
        try summary.text("•••")
        try details.appendChild(summary)
        try first.before(details)
        for node in nodes {
            try details.appendChild(node)
        }
    }
}
