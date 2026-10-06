#if DEBUG
    import AppKit
    import SwiftmailCore
    import WebKit

    /// Debug builds only: `--snapshot <name.png in the container tmp folder> [--select <n>] [--appearance dark|light]` renders
    /// the main window (webviews included) to a PNG and quits. Needs no screen recording.
    @MainActor
    enum DebugSnapshot {
        static let selectNotification = Notification.Name("SwiftmailDebugSelect")

        static func argument(_ name: String) -> String? {
            let arguments = CommandLine.arguments
            guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
            return arguments[index + 1]
        }

        static func runIfRequested() {
            if let appearance = argument("--appearance") {
                NSApp.appearance = NSAppearance(named: appearance == "dark" ? .darkAqua : .aqua)
            }
            guard let path = argument("--snapshot") else { return }
            Task {
                try? await Task.sleep(for: .seconds(2))
                if let index = argument("--select").flatMap(Int.init) {
                    NotificationCenter.default.post(name: selectNotification, object: index)
                    try? await Task.sleep(for: .seconds(3))
                }
                if let text = argument("--search"), let window = NSApp.windows.first(where: \.isVisible),
                   let model = WindowRegistry.model(for: window) {
                    model.search.text = text
                    try? await Task.sleep(for: .seconds(2))
                }
                // `--commands archive,nextThread` runs commands on the window, as shortcuts would.
                if let commands = argument("--commands"), let window = NSApp.windows.first(where: \.isVisible),
                   let model = WindowRegistry.model(for: window) {
                    for name in commands.split(separator: ",") {
                        if let command = MailCommand(rawValue: String(name)) {
                            model.perform(command)
                        }
                        try? await Task.sleep(for: .milliseconds(400))
                    }
                    try? await Task.sleep(for: .seconds(1))
                }
                // `--snapshot-window compose` captures a compose window instead of the main one.
                let wanted = argument("--snapshot-window")
                let candidates = NSApp.windows.filter { $0.isVisible && $0.contentView != nil }
                let target = wanted.flatMap { name in candidates.first { $0.identifier?.rawValue.hasPrefix(name) == true } } ?? candidates.first
                if let window = target {
                    if wanted == nil {
                        window.setContentSize(NSSize(width: 1400, height: 900))
                    }
                    try? await Task.sleep(for: .milliseconds(800))
                    await write(window, to: path)
                }
                NSApp.terminate(nil)
            }
        }

        private static func write(_ window: NSWindow, to path: String) async {
            guard let view = window.contentView?.superview ?? window.contentView,
                  let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
            view.cacheDisplay(in: view.bounds, to: rep)
            guard let context = NSGraphicsContext(bitmapImageRep: rep) else { return }
            // Webviews draw out of process; paint their snapshots over the cached image.
            for webView in allWebViews(in: view) where !webView.isHiddenOrHasHiddenAncestor {
                let frame = webView.convert(webView.bounds, to: view)
                guard let image = try? await webView.takeSnapshot(configuration: nil) else { continue }
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = context
                let flipped = NSRect(x: frame.minX, y: view.isFlipped ? view.bounds.height - frame.maxY : frame.minY, width: frame.width, height: frame.height)
                image.draw(in: flipped)
                NSGraphicsContext.restoreGraphicsState()
            }
            if let data = rep.representation(using: .png, properties: [:]) {
                try? data.write(to: FileManager.default.temporaryDirectory.appendingPathComponent(path))
            }
        }

        private static func allWebViews(in view: NSView) -> [WKWebView] {
            var result: [WKWebView] = []
            for subview in view.subviews {
                if let webView = subview as? WKWebView {
                    result.append(webView)
                }
                result += allWebViews(in: subview)
            }
            return result
        }
    }
#endif
