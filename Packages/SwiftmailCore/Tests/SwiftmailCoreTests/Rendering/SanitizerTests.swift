import Foundation
@testable import SwiftmailCore
import SwiftSoup
import Testing

func sanitize(_ html: String, inline: Set<String> = []) -> RenderedBody {
    HTMLSanitizer.render(html: html, accountID: "acc", messageID: "msg", inlineContentIDs: inline)
}

struct SanitizerTests {
    @Test(arguments: ["script", "iframe", "frame", "object", "embed", "applet", "form", "input", "button", "base"])
    func removesDangerousElements(_ tag: String) throws {
        let rendered = sanitize("<p>ok</p><\(tag) src=\"https://evil.example.com\"></\(tag)>")
        let document = try SwiftSoup.parse(rendered.html)
        #expect(try document.select(tag).isEmpty())
        #expect(rendered.html.contains("ok"))
    }

    @Test func removesMetaRefreshAndLinkImport() {
        let rendered = sanitize(#"<head><meta http-equiv="refresh" content="0;url=https://x"><link rel="import" href="https://x"></head><p>hi</p>"#)
        #expect(!rendered.html.lowercased().contains("refresh"))
        #expect(!rendered.html.contains("rel=\"import\""))
    }

    @Test func removesEventHandlersAndScriptURLs() throws {
        let rendered = sanitize("""
        <p onclick="x()" ONMOUSEOVER="x()">a</p><a href="javascript:x()">j</a><a href=" java\tscript:x()">t</a>
        <a href="&#106;avascript:x()">e</a><a href="vbscript:x">v</a><a href="data:text/html,<b>">d</a><a href="https://ok.example.com">ok</a>
        """)
        let document = try SwiftSoup.parse(rendered.html)
        for element in try document.getAllElements().array() {
            for attribute in element.getAttributes()?.asList() ?? [] {
                #expect(!attribute.getKey().lowercased().hasPrefix("on"))
                let value = attribute.getValue().lowercased().filter { !$0.isWhitespace }
                #expect(!value.hasPrefix("javascript:") && !value.hasPrefix("vbscript:") && !value.hasPrefix("data:text"))
            }
        }
        #expect(try document.select("a[href=https://ok.example.com]").size() == 1)
    }

    @Test func keepsStylesAndInsertsCSP() {
        let rendered = sanitize("<html><head><style>.x{color:red}</style></head><body><p style=\"font-weight:bold\">s</p></body></html>")
        #expect(rendered.html.contains(".x{color:red}"))
        #expect(rendered.html.contains("font-weight:bold"))
        #expect(rendered.html.contains(ReaderCSP.metaTag(ReaderCSP.blocked)))
        #expect(!rendered.html.contains("https:;"))
        let allowed = ReaderCSP.allowingRemoteContent(rendered.html)
        #expect(allowed.contains("img-src swiftmail-cid: data: https: http:"))
    }

    @Test func rewritesCIDImages() {
        let rendered = sanitize(#"<img src="cid:logo@x.com"><img src="CID:<a b>">"#)
        #expect(rendered.html.contains("swiftmail-cid://acc/msg/logo%40x.com"))
        #expect(rendered.html.contains("swiftmail-cid://acc/msg/a%20b"))
        #expect(!rendered.hasRemoteContent)
        let parsed = CIDScheme.parse(URL(string: "swiftmail-cid://acc/msg/logo%40x.com")!)
        #expect(parsed?.contentID == "logo@x.com")
        #expect(parsed?.messageID == "msg")
    }

    @Test func detectsTrackersAndRemoteImages() {
        let rendered = sanitize("""
        <img src="https://shop.example.com/a.jpg" width="200">
        <img src="https://x.example.com/p.gif" width="1" height="1">
        <img src="https://x.example.com/q.gif" style="display: none">
        <img src="https://www.google-analytics.com/collect">
        """)
        #expect(rendered.trackerCount == 3)
        #expect(rendered.hasRemoteContent)
        #expect(rendered.html.contains("shop.example.com/a.jpg"))
        #expect(!rendered.html.contains("p.gif"))
        let cssOnly = sanitize("<div style=\"background:url('https://x.example.com/bg.png')\">x</div>")
        #expect(cssOnly.hasRemoteContent)
        #expect(!sanitize("<p>plain</p>").hasRemoteContent)
    }

    @Test func paperForColoredMailOnly() {
        #expect(sanitize("<div dir=ltr>Hello <b>there</b></div>").usesPaper == false)
        #expect(sanitize("<table bgcolor=#fff><tr><td>x</td></tr></table>").usesPaper)
        #expect(sanitize("<p style=\"color:#333\">x</p>").usesPaper)
        #expect(sanitize("<p style=\"background: transparent\">x</p>").usesPaper == false)
        #expect(sanitize("<body bgcolor=\"#f4f4f4\"><p>x</p></body>").html.contains("background-color:#f4f4f4"))
    }
}

struct QuoteTests {
    func collapsedCount(_ html: String) throws -> Int {
        try SwiftSoup.parse(sanitize(html).html).select("details.sm-quote").size()
    }

    @Test func gmailQuoteCollapsesOnceAtTopLevel() throws {
        let html = """
        <div>Reply</div><div class="gmail_quote">On Mon wrote:<blockquote class="gmail_quote">old
        <div class="gmail_quote">older<blockquote class="gmail_quote">oldest</blockquote></div></blockquote></div>
        """
        #expect(try collapsedCount(html) == 1)
    }

    @Test func appleMailAndOutlook() throws {
        #expect(try collapsedCount(#"<div>Thanks</div><blockquote type="cite">On Oct 5 wrote: hi</blockquote>"#) == 1)
        let outlook = #"<div>Approved.</div><hr><div id="divRplyFwdMsg"><b>From:</b> J</div><div>Please approve.</div>"#
        let document = try SwiftSoup.parse(sanitize(outlook).html)
        let details = try #require(try document.select("details.sm-quote").first())
        #expect(try details.text().contains("Please approve."))
        #expect(try !details.text().contains("Approved."))
        #expect(try details.select("hr").size() == 1)
    }

    @Test func forwardsAndQuoteOnlyMessagesStayOpen() throws {
        #expect(try collapsedCount(#"<div>FYI</div><div class="gmail_quote">---------- Forwarded message ---------<br>From: x</div>"#) == 0)
        #expect(try collapsedCount(#"<div class="gmail_quote">On Mon wrote:<blockquote>only quote</blockquote></div>"#) == 0)
    }

    @Test func plainTextQuotesLinksAndFlowed() {
        let text = "Sounds good, see https://example.org/x.\n\nOn Tue, 6 Oct 2026, Mina <m@example.com> wrote:\n> Noon?\n> > Earlier\n"
        let html = PlainTextRenderer.html(text)
        #expect(html.contains("<a href=\"https://example.org/x\">https://example.org/x</a>"))
        #expect(html.contains("<details class=\"sm-quote\">"))
        #expect(html.contains("<blockquote>Noon?\n<blockquote>Earlier"))
        #expect(html.contains("mailto:m@example.com"))
        let flowed = PlainTextRenderer.html("This is \nflowed text.\n\nNew para", flowed: true)
        #expect(flowed.hasPrefix("This is flowed text.\n\nNew para"))
        #expect(PlainTextRenderer.html("<b>&").contains("&lt;b&gt;&amp;"))
    }
}
