import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WebKit

/// Drives the bundled editor page. Page JavaScript stays off; `editor.js` runs as an app
/// script in its own content world, so nothing pasted or quoted can ever execute.
@MainActor
@Observable
final class ComposeEditorController: NSObject, WKScriptMessageHandler {
    static let world = WKContentWorld.world(name: "swiftmail-editor")
    var isBold = false
    var isItalic = false
    var isUnderline = false
    var linkRequest: String?
    @ObservationIgnored var onChange: (String) -> Void = { _ in }
    @ObservationIgnored var onFiles: ([URL]) -> Void = { _ in }
    @ObservationIgnored private var pendingContent: String?
    @ObservationIgnored private var isReady = false
    @ObservationIgnored private(set) lazy var webView: ComposeWebView = makeWebView()

    private func makeWebView() -> ComposeWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        let controller = configuration.userContentController
        if let script = Self.resource("editor", "js") {
            controller.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: Self.world))
        }
        for name in ["changed", "selection", "link", "ready"] {
            controller.add(self, contentWorld: Self.world, name: name)
        }
        let view = ComposeWebView(frame: .zero, configuration: configuration)
        view.setValue(false, forKey: "drawsBackground")
        view.onFiles = { [weak self] urls in self?.onFiles(urls) }
        let css = Self.resource("editor", "css") ?? ""
        let html = (Self.resource("editor", "html") ?? "<div id=editor contenteditable></div>").replacingOccurrences(of: "/*EDITOR_CSS*/", with: css)
        view.loadHTMLString(html, baseURL: nil)
        return view
    }

    static func resource(_ name: String, _ ext: String) -> String? {
        let url = Bundle.main.url(forResource: name, withExtension: ext, subdirectory: "ComposeEditor")
            ?? Bundle.main.url(forResource: name, withExtension: ext)
        return url.flatMap { try? String(contentsOf: $0, encoding: .utf8) }
    }

    func setContent(_ html: String) {
        guard isReady else {
            pendingContent = html
            return
        }
        call("SM.setContent(\(Self.jsString(html)))")
    }

    func content() async -> String? {
        guard isReady else { return pendingContent }
        return try? await webView.evaluateJavaScript("SM.getContent()", in: nil, contentWorld: Self.world) as? String
    }

    func exec(_ command: String, value: String? = nil) {
        call("SM.exec(\(Self.jsString(command)), \(value.map(Self.jsString) ?? "null"))")
    }

    func setSignature(_ html: String?) {
        call("SM.setSignature(\(Self.jsString(html ?? "")))")
    }

    func insertImage(dataURL: String, name: String) {
        call("SM.insertImage(\(Self.jsString(dataURL)), \(Self.jsString(name)))")
    }

    func focus(atStart: Bool = false) {
        webView.window?.makeFirstResponder(webView)
        call("SM.focus(\(atStart))")
    }

    private func call(_ script: String) {
        webView.evaluateJavaScript(script, in: nil, in: Self.world, completionHandler: nil)
    }

    static func jsString(_ value: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: [value])) ?? Data("[\"\"]".utf8)
        let array = String(decoding: data, as: UTF8.self)
        return String(array.dropFirst().dropLast())
    }

    nonisolated func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        let box = UncheckedSendable(message)
        MainActor.assumeIsolated {
            let name = box.value.name
            let body = UncheckedSendable(box.value.body)
            switch name {
            case "ready":
                isReady = true
                if let pendingContent {
                    self.pendingContent = nil
                    setContent(pendingContent)
                }
            case "changed":
                if let html = body.value as? String {
                    onChange(html)
                }
            case "selection":
                let state = body.value as? [String: Bool] ?? [:]
                isBold = state["bold"] ?? false
                isItalic = state["italic"] ?? false
                isUnderline = state["underline"] ?? false
            case "link":
                linkRequest = body.value as? String ?? ""
            default:
                break
            }
        }
    }
}

/// The editor's webview; file drops become attachments or inline images instead of
/// navigating, and links never open inside it.
final class ComposeWebView: WKWebView, WKNavigationDelegate {
    var onFiles: ([URL]) -> Void = { _ in }

    override init(frame: CGRect, configuration: WKWebViewConfiguration) {
        super.init(frame: frame, configuration: configuration)
        navigationDelegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        guard !urls.isEmpty else { return super.performDragOperation(sender) }
        onFiles(urls)
        return true
    }

    func webView(
        _ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
    ) {
        decisionHandler(action.request.url?.absoluteString == "about:blank" ? .allow : .cancel)
    }
}

struct ComposeEditorView: NSViewRepresentable {
    let controller: ComposeEditorController

    func makeNSView(context: Context) -> ComposeWebView {
        controller.webView
    }

    func updateNSView(_ view: ComposeWebView, context: Context) {}
}
