import SwiftmailCore
import SwiftUI

/// User labels nested by `/`, as Gmail shows them.
struct LabelNode: Identifiable, Hashable {
    let id: String
    let title: String
    let label: LabelRecord?
    var children: [LabelNode]?

    static func build(_ labels: [LabelRecord]) -> [LabelNode] {
        final class Builder {
            var title: String
            var label: LabelRecord?
            var path: String
            var children: [String: Builder] = [:]
            var order: [String] = []

            init(title: String, path: String) {
                self.title = title
                self.path = path
            }

            func child(_ name: String) -> Builder {
                if let existing = children[name] {
                    return existing
                }
                let node = Builder(title: name, path: path.isEmpty ? name : path + "/" + name)
                children[name] = node
                order.append(name)
                return node
            }

            func node() -> LabelNode {
                let kids = order.compactMap { children[$0]?.node() }
                return LabelNode(id: label?.id ?? "path:" + path, title: title, label: label, children: kids.isEmpty ? nil : kids)
            }
        }
        let root = Builder(title: "", path: "")
        for label in labels {
            var node = root
            for component in label.name.split(separator: "/") {
                node = node.child(String(component))
            }
            node.label = label
        }
        return root.order.compactMap { root.children[$0]?.node() }
    }
}

struct LabelTreeRows: View {
    let accountID: String
    let nodes: [LabelNode]

    var body: some View {
        ForEach(nodes) { node in
            if let children = node.children {
                DisclosureGroup {
                    LabelTreeRows(accountID: accountID, nodes: children)
                } label: {
                    row(node)
                }
            } else {
                row(node)
            }
        }
    }

    @ViewBuilder
    private func row(_ node: LabelNode) -> some View {
        if let label = node.label {
            MailboxRow(
                title: node.title,
                systemImage: "tag",
                tint: Color(hex: label.colorBg),
                count: label.threadsUnread
            )
            .tag(Mailbox(accountID: accountID, kind: .label(label.id)))
        } else {
            Label(node.title, systemImage: "folder")
        }
    }
}
