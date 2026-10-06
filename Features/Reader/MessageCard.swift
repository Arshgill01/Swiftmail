import SwiftmailCore
import SwiftUI

struct MessageCard: View {
    @Environment(AppModel.self) private var model
    @Environment(ReaderModel.self) private var reader
    let message: ConversationMessage
    let accountID: String
    @State private var height: CGFloat = 40
    @AppStorage(Preferences.loadRemoteImages) private var loadRemoteGlobally = false
    @AppStorage(Preferences.readerFontSize) private var fontSize = 14.0

    var body: some View {
        let isExpanded = reader.expanded.contains(message.id)
        VStack(alignment: .leading, spacing: 8) {
            header(expanded: isExpanded)
                .contentShape(Rectangle())
                .onTapGesture { withAnimation(.easeOut(duration: 0.15)) { reader.toggle(message.id) } }
            if isExpanded {
                expandedBody
            }
        }
        .padding(12)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator.opacity(0.5)))
    }

    private var own: Set<String> {
        model.sidebarAccount(accountID)?.ownAddresses ?? []
    }

    @ViewBuilder
    private func header(expanded: Bool) -> some View {
        HStack(alignment: expanded ? .top : .center, spacing: 10) {
            AvatarView(name: message.from.displayName, email: message.from.email, size: expanded ? 32 : 24)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(own.contains(message.from.email.lowercased()) ? "me" : message.from.displayName)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                        .help(message.from.email)
                    if message.message.isDraft {
                        Text("Draft").font(.caption).foregroundStyle(.red)
                    }
                    if !expanded {
                        Text(message.message.snippet ?? "")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                if expanded {
                    Text(recipientsLine)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .help(fullRecipients)
                }
            }
            Spacer(minLength: 8)
            let date = Date(millis: message.message.internalDate)
            Text(date, format: .relative(presentation: .named))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .help(date.formatted(date: .complete, time: .standard))
            if expanded {
                if message.message.isDraft {
                    Button("Edit") { model.editDraft(message, threadID: message.message.threadId) }
                        .controlSize(.small)
                }
                Menu {
                    Button("Reply") { model.reply(.reply, to: message, threadID: message.message.threadId) }
                    Button("Reply All") { model.reply(.replyAll, to: message, threadID: message.message.threadId) }
                    Button("Forward") { model.reply(.forward, to: message, threadID: message.message.threadId) }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityLabel("Message actions")
            }
        }
    }

    @ViewBuilder
    private var expandedBody: some View {
        let allowRemote = reader.allowsRemote(message, globally: loadRemoteGlobally)
        if message.body?.hasRemoteContent == true, !allowRemote {
            RemoteImagesBanner(
                loadOnce: { reader.allowedThisSession.insert(message.id) },
                alwaysAllow: { sender in
                    Task {
                        try? await model.database.writer.write { db in
                            try ConversationQueries.allowRemoteContent(db, accountID: accountID, sender: sender)
                        }
                    }
                },
                sender: message.from.email
            )
        }
        if let html = message.body?.displayHtml {
            MessageWebView(
                services: model.readerServices,
                html: html,
                allowRemote: allowRemote,
                zoom: fontSize,
                height: $height,
                onLinkHover: { reader.hoveredLink = $0 },
                onFinish: { reader.bodyFinished() }
            )
            .frame(height: max(height, 20))
            .accessibilityLabel("Message body")
        } else {
            HStack {
                ProgressView().controlSize(.small)
                Text("Downloading…").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 60)
        }
        if !message.visibleAttachments.isEmpty {
            AttachmentChips(attachments: message.visibleAttachments)
        }
    }

    private var recipientsLine: String {
        let recipients = message.to + message.cc
        guard let first = recipients.first else { return "" }
        let name = own.contains(first.email.lowercased()) ? "me" : (first.name?.split(separator: " ").first.map(String.init) ?? first.email)
        return recipients.count > 1 ? "to \(name) +\(recipients.count - 1)" : "to \(name)"
    }

    private var fullRecipients: String {
        var lines = ["To: " + message.to.map(\.email).joined(separator: ", ")]
        if !message.cc.isEmpty {
            lines.append("Cc: " + message.cc.map(\.email).joined(separator: ", "))
        }
        if !message.bcc.isEmpty {
            lines.append("Bcc: " + message.bcc.map(\.email).joined(separator: ", "))
        }
        return lines.joined(separator: "\n")
    }
}

struct RemoteImagesBanner: View {
    let loadOnce: () -> Void
    let alwaysAllow: (String) -> Void
    let sender: String

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                message
                Spacer(minLength: 4)
                buttons
            }
            VStack(alignment: .leading, spacing: 4) {
                message
                buttons
            }
        }
        .font(.callout)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 7))
    }

    private var message: some View {
        Label("Images are hidden to protect your privacy.", systemImage: "photo.badge.exclamationmark")
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .fixedSize()
    }

    private var buttons: some View {
        HStack(spacing: 10) {
            Button("Load images", action: loadOnce)
                .buttonStyle(.link)
            Menu("Always load from this sender") {
                Button("Always load from \(sender)") { alwaysAllow(sender) }
                if let domain = sender.split(separator: "@").last {
                    Button("Always load from @\(domain)") { alwaysAllow("@\(domain)") }
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
    }
}
