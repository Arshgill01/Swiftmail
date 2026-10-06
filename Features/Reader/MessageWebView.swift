import AppKit
import os
import SwiftmailCore
import SwiftUI
import WebKit

/// One message body in a pooled webview, sized to its content.
struct MessageWebView: NSViewRepresentable {
    let services: ReaderServices
    let html: String
    let allowRemote: Bool
    let zoom: Double
    @Binding var height: CGFloat
    var onLinkHover: (String?) -> Void = { _ in }
    var onOpenLink: (URL) -> Void = { NSWorkspace.shared.open($0) }
    var onFinish: () -> Void = {}

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> ReaderWebView {
        let view = services.dequeue(owner: context.coordinator)
        view.navigationDelegate = context.coordinator
        view.uiDelegate = context.coordinator
        return view
    }

    func updateNSView(_ view: ReaderWebView, context: Context) {
        context.coordinator.parent = self
        view.pageZoom = zoom / 14
        let key = "\(allowRemote ? 1 : 0):\(html.hashValue)"
        guard view.loadedKey != key else { return }
        view.loadedKey = key
        let rules = view.configuration.userContentController
        rules.removeAllContentRuleLists()
        if allowRemote {
            view.loadHTMLString(ReaderCSP.allowingRemoteContent(html), baseURL: nil)
        } else if let list = services.blockList {
            rules.add(list)
            view.loadHTMLString(html, baseURL: nil)
        } else {
            // The rule list is still compiling: wait for it rather than load unblocked.
            let html = html
            Task { @MainActor in
                if let list = try? await ReaderWebKit.blockRemoteRuleList() {
                    rules.add(list)
                    view.loadHTMLString(html, baseURL: nil)
                }
            }
        }
    }

    static func dismantleNSView(_ view: ReaderWebView, coordinator: Coordinator) {
        coordinator.parent.services.recycle(view)
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        var parent: MessageWebView

        init(parent: MessageWebView) {
            self.parent = parent
        }

        func received(name: String, body: Any) {
            switch name {
            case ReaderWebKit.heightMessage:
                if let value = body as? Int, CGFloat(value) != parent.height {
                    parent.height = CGFloat(value)
                }
            case ReaderWebKit.linkMessage:
                let link = body as? String
                parent.onLinkHover(link?.isEmpty == false ? link : nil)
            default:
                break
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            parent.onFinish()
        }

        /// The webview never navigates: links open in the browser or a compose window.
        func webView(
            _ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
            decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
        ) {
            guard let url = action.request.url else { return decisionHandler(.cancel) }
            if action.navigationType == .other, url.absoluteString == "about:blank" {
                return decisionHandler(.allow)
            }
            decisionHandler(.cancel)
            if action.navigationType == .linkActivated, ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "") {
                parent.onOpenLink(url)
            }
        }

        func webView(
            _ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
            for action: WKNavigationAction, windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            if let url = action.request.url, ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "") {
                parent.onOpenLink(url)
            }
            return nil
        }
    }
}
