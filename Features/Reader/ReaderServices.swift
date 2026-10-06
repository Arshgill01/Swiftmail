import AppKit
import SwiftmailCore
import WebKit

/// Shared by every window: the webview pool, the `swiftmail-cid` handler and the
/// message router that hands script messages to the view that owns each webview.
@MainActor
final class ReaderServices: NSObject, WKScriptMessageHandler {
    private let schemeHandler: CIDSchemeHandler
    private var pool: [ReaderWebView] = []
    private var owners: [ObjectIdentifier: WeakCoordinator] = [:]
    private(set) var blockList: WKContentRuleList?
    static let maxPooled = 6

    struct WeakCoordinator {
        weak var value: MessageWebView.Coordinator?
    }

    init(loader: @escaping CIDSchemeHandler.Loader) {
        schemeHandler = CIDSchemeHandler(loader: loader)
        super.init()
    }

    /// Compiles the rule list and pre-warms one webview so the first open is fast.
    func prewarm() {
        Task {
            blockList = try? await ReaderWebKit.blockRemoteRuleList()
            let view = makeWebView()
            view.loadHTMLString("<html><body></body></html>", baseURL: nil)
            pool.append(view)
        }
    }

    func dequeue(owner: MessageWebView.Coordinator) -> ReaderWebView {
        let view = pool.popLast() ?? makeWebView()
        owners[ObjectIdentifier(view)] = WeakCoordinator(value: owner)
        return view
    }

    func recycle(_ view: ReaderWebView) {
        owners[ObjectIdentifier(view)] = nil
        view.navigationDelegate = nil
        view.uiDelegate = nil
        view.stopLoading()
        view.loadedKey = nil
        guard pool.count < Self.maxPooled else { return }
        view.loadHTMLString("<html><body></body></html>", baseURL: nil)
        pool.append(view)
    }

    private func makeWebView() -> ReaderWebView {
        let configuration = ReaderWebKit.makeConfiguration(schemeHandler: schemeHandler, messageHandler: self)
        let view = ReaderWebView(frame: NSRect(x: 0, y: 0, width: 600, height: 40), configuration: configuration)
        view.setValue(false, forKey: "drawsBackground")
        view.allowsMagnification = false
        view.allowsBackForwardNavigationGestures = false
        return view
    }

    nonisolated func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        MainActor.assumeIsolated {
            guard let webView = message.webView, let owner = owners[ObjectIdentifier(webView)]?.value else { return }
            owner.received(name: message.name, body: message.body)
        }
    }
}

/// Lets vertical scrolling pass through to the conversation's scroll view, since each
/// webview is sized to its content and must not scroll on its own.
final class ReaderWebView: WKWebView {
    var loadedKey: String?

    override func scrollWheel(with event: NSEvent) {
        if abs(event.scrollingDeltaY) >= abs(event.scrollingDeltaX) {
            nextResponder?.scrollWheel(with: event)
        } else {
            super.scrollWheel(with: event)
        }
    }
}
