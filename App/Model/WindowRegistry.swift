import AppKit
import SwiftUI

/// Maps each main window to its model so key events and menus reach the right window.
@MainActor
enum WindowRegistry {
    private static var models: [ObjectIdentifier: WeakModel] = [:]

    struct WeakModel {
        weak var value: MainWindowModel?
    }

    static func register(_ window: NSWindow, model: MainWindowModel) {
        models[ObjectIdentifier(window)] = WeakModel(value: model)
        models = models.filter { $0.value.value != nil }
    }

    static func model(for window: NSWindow?) -> MainWindowModel? {
        window.flatMap { models[ObjectIdentifier($0)]?.value }
    }
}

/// Hands the hosting NSWindow to SwiftUI.
struct WindowAccessor: NSViewRepresentable {
    let onWindow: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { [weak view] in
            if let window = view?.window {
                onWindow(window)
            }
        }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {}
}

struct MainWindowKey: FocusedValueKey {
    typealias Value = MainWindowModel
}

extension FocusedValues {
    var mainWindow: MainWindowModel? {
        get { self[MainWindowKey.self] }
        set { self[MainWindowKey.self] = newValue }
    }
}
