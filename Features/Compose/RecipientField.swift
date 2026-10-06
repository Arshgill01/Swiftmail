import AppKit
import GRDB
import SwiftmailCore
import SwiftUI

/// To, Cc and Bcc as an `NSTokenField`, completing from addresses seen in local mail.
struct RecipientField: NSViewRepresentable {
    @Binding var addresses: [EmailAddress]
    let database: AppDatabase
    var placeholder = ""

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSTokenField {
        let field = NSTokenField()
        field.delegate = context.coordinator
        field.tokenStyle = .rounded
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.placeholderString = placeholder
        field.completionDelay = 0.05
        field.tokenizingCharacterSet = CharacterSet(charactersIn: ",;")
        field.font = .systemFont(ofSize: 13)
        field.lineBreakMode = .byWordWrapping
        field.cell?.wraps = true
        field.cell?.isScrollable = false
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.objectValue = addresses.map(\.tokenString)
        return field
    }

    func updateNSView(_ field: NSTokenField, context: Context) {
        context.coordinator.parent = self
        let current = (field.objectValue as? [String]) ?? []
        let wanted = addresses.map(\.tokenString)
        if current != wanted, field.currentEditor() == nil {
            field.objectValue = wanted
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTokenFieldDelegate {
        var parent: RecipientField

        init(parent: RecipientField) {
            self.parent = parent
        }

        func controlTextDidChange(_ notification: Notification) {
            commit(notification.object as? NSTokenField)
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            commit(notification.object as? NSTokenField)
        }

        private func commit(_ field: NSTokenField?) {
            guard let tokens = field?.objectValue as? [String] else { return }
            let parsed = tokens.compactMap { EmailAddress.parse($0) ?? (ComposeState.isValidAddress($0) ? EmailAddress(email: $0) : nil) }
            if parsed != parent.addresses {
                parent.addresses = parsed
            }
        }

        func tokenField(
            _ tokenField: NSTokenField, completionsForSubstring substring: String, indexOfToken tokenIndex: Int,
            indexOfSelectedItem selectedIndex: UnsafeMutablePointer<Int>?
        ) -> [Any]? {
            let suggestions = (try? parent.database.reader.read { db in try ContactQueries.suggest(db, prefix: substring) }) ?? []
            selectedIndex?.pointee = suggestions.isEmpty ? -1 : 0
            return suggestions.map(\.display)
        }

        func tokenField(_ tokenField: NSTokenField, displayStringForRepresentedObject representedObject: Any) -> String? {
            guard let token = representedObject as? String, let address = EmailAddress.parse(token) else { return representedObject as? String }
            return address.name ?? address.email
        }

        func tokenField(_ tokenField: NSTokenField, editingStringForRepresentedObject representedObject: Any) -> String? {
            representedObject as? String
        }
    }
}

extension EmailAddress {
    var tokenString: String {
        name.map { "\($0) <\(email)>" } ?? email
    }
}
