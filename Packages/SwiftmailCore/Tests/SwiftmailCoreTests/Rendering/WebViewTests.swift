import Foundation
@testable import SwiftmailCore
import Testing
import WebKit

@MainActor
final class ReaderProbe: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    var heights: [Int] = []
    var finished = false

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        if message.name == ReaderWebKit.heightMessage, let height = message.body as? Int {
            heights.append(height)
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        finished = true
    }

    func load(_ html: String, blockRemote: Bool) async throws -> WKWebView {
        let handler = CIDSchemeHandler { _, _, _ in (Data(), "image/png") }
        let configuration = ReaderWebKit.makeConfiguration(schemeHandler: handler, messageHandler: self)
        if blockRemote {
            try await configuration.userContentController.add(ReaderWebKit.blockRemoteRuleList())
        }
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 700, height: 400), configuration: configuration)
        webView.navigationDelegate = self
        finished = false
        webView.loadHTMLString(html, baseURL: nil)
        for _ in 0 ..< 200 where !finished {
            try await Task.sleep(for: .milliseconds(25))
        }
        // Let late image loads and resize observers run.
        try await Task.sleep(for: .milliseconds(300))
        return webView
    }
}

@MainActor
struct WebViewTests {
    /// Points every remote URL at the local counting server.
    func localize(_ html: String, port: UInt16) -> String {
        html.replacingOccurrences(of: #"https?://[A-Za-z0-9.\-]+"#, with: "http://127.0.0.1:\(port)", options: .regularExpression)
    }

    @Test func corpusMakesNoRemoteLoadsUnlessAllowed() async throws {
        let server = try CountingHTTPServer()
        try await server.start()
        defer { server.stop() }
        let probe = ReaderProbe()
        for name in [
            "01-newsletter-table.eml",
            "21-css-background-remote.eml",
            "22-tracker-pixels.eml",
            "26-iframe-object-embed.eml",
            "12-scripts-forms-events.eml",
        ] {
            let html = try localize(Corpus.render(name).html, port: server.port)
            _ = try await probe.load(html, blockRemote: true)
        }
        #expect(server.requests == 0)
        // Control: with remote content allowed, the same mail does load images.
        let allowed = try ReaderCSP.allowingRemoteContent(localize(Corpus.render("01-newsletter-table.eml").html, port: server.port))
        _ = try await probe.load(allowed, blockRemote: false)
        #expect(server.requests > 0)
    }

    @Test func pageScriptsDoNotRunButTheMeasuringScriptDoes() async throws {
        let probe = ReaderProbe()
        // Deliberately unsanitized: the configuration alone must stop page JavaScript.
        let html = "<html><body><p style='height:900px'>tall</p><script>document.body.setAttribute('data-pwned','1')</script></body></html>"
        let webView = try await probe.load(html, blockRemote: true)
        let pwned = try await webView.evaluateJavaScript(
            "document.body.getAttribute('data-pwned')", in: nil, contentWorld: ReaderWebKit.contentWorld
        )
        #expect(pwned == nil || pwned is NSNull)
        #expect((probe.heights.last ?? 0) >= 900)
    }
}
