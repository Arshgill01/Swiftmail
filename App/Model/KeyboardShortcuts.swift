import AppKit
import SwiftmailCore

/// Feeds key presses in main windows through the `CommandRouter`. Never handles keys
/// while a text field or text view has focus.
@MainActor
final class KeyboardShortcuts {
    private var monitor: Any?
    private var router = CommandRouter()

    func install() {
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // Local monitors run on the main thread.
            let box = UncheckedSendable(event)
            let handled = MainActor.assumeIsolated { self?.handle(box.value) ?? false }
            return handled ? nil : event
        }
    }

    private func handle(_ event: NSEvent) -> Bool {
        guard let window = event.window, let model = WindowRegistry.model(for: window), window.attachedSheet == nil else { return false }
        let responder = window.firstResponder
        let isTextInput = responder is NSText || (responder as? NSTextField)?.isEditable == true
            || (responder as? NSView)?.isKind(of: NSClassFromString("NSTokenField") ?? NSView.self) == true
        var modifiers: CommandRouter.Modifiers = []
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.shift) {
            modifiers.insert(.shift)
        }
        if flags.contains(.command) {
            modifiers.insert(.command)
        }
        if flags.contains(.control) {
            modifiers.insert(.control)
        }
        if flags.contains(.option) {
            modifiers.insert(.option)
        }
        let key: CommandRouter.Key = switch event.keyCode {
        case 36, 76: .returnKey
        case 53: .escape
        case 51: .delete
        case 117: .forwardDelete
        case 125: .down
        case 126: .up
        default: .character(event.charactersIgnoringModifiers.map { flags.contains(.shift) ? (event.characters ?? $0) : $0 } ?? "")
        }
        guard let command = router.route(key, modifiers: modifiers, isTextInput: isTextInput) else {
            // Swallow the "g" that starts a go sequence; let everything else through.
            return router.isAwaitingGo
        }
        model.perform(command)
        return true
    }
}
