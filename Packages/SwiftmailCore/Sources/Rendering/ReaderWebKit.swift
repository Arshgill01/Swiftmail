import Foundation
import WebKit

/// WebKit setup for showing email: page JavaScript off, a non-persistent data store,
/// remote loads blocked by a content rule list, inline images through `swiftmail-cid`,
/// and the app's own measuring script in a separate content world.
@MainActor
public enum ReaderWebKit {
    public static let contentWorld = WKContentWorld.world(name: "swiftmail-reader")
    public static let heightMessage = "height"
    public static let linkMessage = "link"

    /// Reports the document height and the link under the pointer to the app.
    static let measuringScript = """
    (function () {
      const post = (name, value) => { try { window.webkit.messageHandlers[name].postMessage(value); } catch (e) {} };
      let last = 0;
      // Scale content wider than the card (fixed-width newsletters) down to fit.
      let scale = 1;
      const fit = () => {
        const content = document.querySelector('.sm-content');
        if (!content) { return; }
        content.style.transform = '';
        content.style.width = '';
        document.documentElement.style.overflowX = 'hidden';
        const available = document.documentElement.clientWidth;
        const needed = content.scrollWidth;
        scale = needed > available + 2 ? available / needed : 1;
        if (scale < 1) {
          content.style.width = needed + 'px';
          content.style.transformOrigin = '0 0';
          content.style.transform = 'scale(' + scale.toFixed(4) + ')';
        }
      };
      const report = () => {
        // The content box, not the document: the document never gets shorter than the frame.
        const content = document.querySelector('.sm-content') || document.body;
        if (!content) { return; }
        const height = Math.ceil(content.offsetTop + content.offsetHeight * scale);
        if (height !== last) { last = height; post('height', height); }
      };
      new ResizeObserver(report).observe(document.documentElement);
      if (document.body) { new ResizeObserver(report).observe(document.body); }
      const box = document.querySelector('.sm-content');
      if (box) { new ResizeObserver(report).observe(box); }
      document.addEventListener('toggle', report, true);
      window.addEventListener('load', () => { fit(); report(); });
      let width = document.documentElement.clientWidth;
      window.addEventListener('resize', () => {
        if (document.documentElement.clientWidth !== width) { width = document.documentElement.clientWidth; fit(); report(); }
      });
      document.addEventListener('mouseover', (event) => {
        const link = event.target.closest && event.target.closest('a[href]');
        post('link', link ? link.href : '');
      });
      document.addEventListener('mouseleave', () => post('link', ''));
      fit();
      report();
    })();
    """

    static let blockRemoteRules = """
    [{"trigger":{"url-filter":"^https?://"},"action":{"type":"block"}},
     {"trigger":{"url-filter":"^//"},"action":{"type":"block"}}]
    """

    private static var compiledRules: WKContentRuleList?

    /// The rule list that blocks every http and https resource, compiled once.
    public static func blockRemoteRuleList() async throws -> WKContentRuleList {
        if let compiledRules {
            return compiledRules
        }
        guard let store = WKContentRuleListStore.default() else { throw URLError(.cannotLoadFromNetwork) }
        let list = try await store.compileContentRuleList(forIdentifier: "swiftmail-block-remote", encodedContentRuleList: blockRemoteRules)
        guard let list else { throw URLError(.cannotLoadFromNetwork) }
        compiledRules = list
        return list
    }

    public static func makeConfiguration(schemeHandler: WKURLSchemeHandler, messageHandler: WKScriptMessageHandler) -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.preferences.isElementFullscreenEnabled = false
        configuration.suppressesIncrementalRendering = false
        configuration.setURLSchemeHandler(schemeHandler, forURLScheme: CIDScheme.scheme)
        let controller = configuration.userContentController
        controller.addUserScript(WKUserScript(
            source: measuringScript, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: contentWorld
        ))
        controller.add(messageHandler, contentWorld: contentWorld, name: heightMessage)
        controller.add(messageHandler, contentWorld: contentWorld, name: linkMessage)
        return configuration
    }
}

/// Serves `swiftmail-cid://<account>/<message>/<content-id>` from stored attachments,
/// downloading them first when needed.
@MainActor
public final class CIDSchemeHandler: NSObject, WKURLSchemeHandler {
    public typealias Loader = @Sendable (_ accountID: String, _ messageID: String, _ contentID: String) async throws -> (Data, String)

    private let loader: Loader
    private var active: Set<ObjectIdentifier> = []

    public init(loader: @escaping Loader) {
        self.loader = loader
    }

    public func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        let id = ObjectIdentifier(task)
        active.insert(id)
        guard let url = task.request.url, let parts = CIDScheme.parse(url) else {
            task.didFailWithError(URLError(.badURL))
            active.remove(id)
            return
        }
        let loader = loader
        Task {
            let result: Result<(Data, String), Error>
            do {
                result = try await .success(loader(parts.accountID, parts.messageID, parts.contentID))
            } catch {
                result = .failure(error)
            }
            // A task WebKit already stopped must not be answered.
            guard active.remove(id) != nil else { return }
            switch result {
            case let .success((data, mimeType)):
                task.didReceive(URLResponse(url: url, mimeType: mimeType, expectedContentLength: data.count, textEncodingName: nil))
                task.didReceive(data)
                task.didFinish()
            case let .failure(error):
                task.didFailWithError(error)
            }
        }
    }

    public func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {
        active.remove(ObjectIdentifier(task))
    }
}
