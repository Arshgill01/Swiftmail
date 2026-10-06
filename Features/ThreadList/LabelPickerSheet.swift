import SwiftmailCore
import SwiftUI

/// The label picker (`l`), move picker (`v`) and go-to-label picker (`g` `l`).
struct LabelPickerSheet: View {
    enum Mode { case apply, move, navigate }

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let window: MainWindowModel
    let mode: Mode
    @State private var query = ""

    private var accountID: String? {
        window.selectionOrCursor.first?.accountID ?? window.mailbox?.accountID ?? model.accounts.first?.id
    }

    private var labels: [LabelRecord] {
        guard let accountID, let account = model.sidebarAccount(accountID) else { return [] }
        var all = account.userLabels
        if mode != .apply {
            all = [account.allLabels["INBOX"]].compactMap(\.self) + all
        }
        guard !query.isEmpty else { return all }
        return all.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    private var title: String {
        switch mode {
        case .apply: "Label as"
        case .move: "Move to"
        case .navigate: "Go to label"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            TextField("Filter labels", text: $query)
                .textFieldStyle(.roundedBorder)
                .onSubmit {
                    if let first = labels.first {
                        choose(first)
                    }
                }
            List(labels, id: \.id) { label in
                Button {
                    choose(label)
                } label: {
                    HStack {
                        Image(systemName: "tag.fill").foregroundStyle(Color(hex: label.colorBg) ?? .secondary)
                        Text(label.id == "INBOX" ? "Inbox" : label.name)
                        Spacer()
                        if mode == .apply, state(of: label) != .none {
                            Image(systemName: state(of: label) == .all ? "checkmark" : "minus")
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .frame(minHeight: 240)
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding()
        .frame(width: 340, height: 380)
    }

    enum LabelState { case none, some, all }

    private func state(of label: LabelRecord) -> LabelState {
        let threads = window.selectedSummaries
        let count = threads.filter { $0.labelIDs.contains(label.id) }.count
        return count == 0 ? .none : (count == threads.count ? .all : .some)
    }

    private func choose(_ label: LabelRecord) {
        switch mode {
        case .apply:
            window.apply(state(of: label) == .all ? .removeLabels([label.id]) : .addLabels([label.id]))
        case .move:
            window.apply(label.id == "INBOX" ? .moveToInbox : .move(to: label.id, from: window.mailbox?.labelID))
            dismiss()
        case .navigate:
            window.mailbox = Mailbox(accountID: accountID, kind: label.id == "INBOX" ? .inbox : .label(label.id))
            dismiss()
        }
    }
}

struct ShortcutsSheet: View {
    @Environment(\.dismiss) private var dismiss

    static let rows: [(String, String)] = [
        ("c", "New message"), ("r", "Reply"), ("a", "Reply all"), ("f", "Forward"),
        ("e  y", "Archive"), ("#  ⌫", "Move to Trash"), ("!", "Report spam"), ("s", "Star or unstar"),
        ("+  -", "Mark important / not important"), ("⇧I  ⇧U", "Mark read / unread"),
        ("l", "Label"), ("v", "Move to"), ("x", "Select or deselect thread"),
        ("j  k", "Next / previous thread"), ("n  p", "Next / previous message"),
        ("o  ↩", "Open thread / expand message"), (";", "Expand all messages"), ("esc", "Back to the list"),
        ("/", "Search"), ("z  ⌘Z", "Undo"), ("g i", "Go to Inbox"), ("g s", "Go to Starred"), ("g t", "Go to Sent"),
        ("g d", "Go to Drafts"), ("g a", "Go to All Mail"), ("g l", "Go to label"), ("?", "This list"),
        ("⌘↩", "Send (in compose)"), ("⌘+  ⌘-", "Zoom message text"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Keyboard Shortcuts").font(.title3.weight(.semibold))
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 5) {
                ForEach(Self.rows, id: \.1) { keys, action in
                    GridRow {
                        Text(keys).font(.system(.body, design: .monospaced)).foregroundStyle(.secondary)
                        Text(action)
                    }
                }
            }
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}
