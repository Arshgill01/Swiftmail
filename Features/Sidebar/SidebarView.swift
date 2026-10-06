import SwiftmailCore
import SwiftUI

struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @Bindable var window: MainWindowModel
    @State private var collapsed: Set<String> = []

    var body: some View {
        List(selection: $window.mailbox) {
            if model.accounts.isEmpty {
                Section {
                    Button("Add Gmail Account…") { model.addAccount() }
                        .disabled(model.isSigningIn || !model.isOAuthConfigured)
                    if !model.isOAuthConfigured {
                        Text("Set up Google sign-in first (see README).")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                unifiedSection
                ForEach(model.sidebar.accounts) { item in
                    accountSection(item)
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            SyncFooter()
        }
    }

    private var unifiedSection: some View {
        Section {
            MailboxRow(title: "All Inboxes", systemImage: "tray.2", count: model.sidebar.unifiedInboxUnread)
                .tag(Mailbox.allInboxes)
            MailboxRow(title: "Starred", systemImage: "star")
                .tag(Mailbox(accountID: nil, kind: .starred))
            MailboxRow(title: "Sent", systemImage: "paperplane")
                .tag(Mailbox(accountID: nil, kind: .sent))
            MailboxRow(title: "Drafts", systemImage: "doc", count: model.sidebar.accounts.reduce(0) { $0 + ($1.systemCounts["DRAFT"] ?? 0) })
                .tag(Mailbox(accountID: nil, kind: .drafts))
            if model.sidebar.outboxCount > 0 {
                MailboxRow(title: "Outbox", systemImage: "tray.and.arrow.up", count: model.sidebar.outboxCount)
                    .tag(Mailbox(accountID: nil, kind: .outbox))
            }
        }
    }

    private func accountSection(_ item: SidebarAccount) -> some View {
        let id = item.id
        let mailbox = { (kind: Mailbox.Kind) in Mailbox(accountID: id, kind: kind) }
        return Section(isExpanded: Binding(
            get: { !collapsed.contains(id) },
            set: { expanded in
                if expanded {
                    collapsed.remove(id)
                } else {
                    collapsed.insert(id)
                }
            }
        )) {
            MailboxRow(title: "Inbox", systemImage: "tray", count: item.inboxUnread).tag(mailbox(.inbox))
            MailboxRow(title: "Starred", systemImage: "star").tag(mailbox(.starred))
            MailboxRow(title: "Important", systemImage: "tag").tag(mailbox(.important))
            MailboxRow(title: "Sent", systemImage: "paperplane").tag(mailbox(.sent))
            MailboxRow(title: "Drafts", systemImage: "doc", count: item.systemCounts["DRAFT"] ?? 0).tag(mailbox(.drafts))
            MailboxRow(title: "All Mail", systemImage: "archivebox").tag(mailbox(.allMail))
            MailboxRow(title: "Spam", systemImage: "xmark.octagon", count: item.systemCounts["SPAM"] ?? 0).tag(mailbox(.spam))
            MailboxRow(title: "Trash", systemImage: "trash").tag(mailbox(.trash))
            LabelTreeRows(accountID: id, nodes: LabelNode.build(item.userLabels))
        } header: {
            HStack(spacing: 6) {
                Circle()
                    .fill(AccountColors.color(model.accountColorIndex(id)))
                    .frame(width: 7, height: 7)
                Text(item.account.email)
                    .lineLimit(1)
                if item.account.status == .needsSignIn {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .help("Needs sign-in")
                }
            }
        }
    }
}

/// Quiet sync status at the foot of the sidebar.
struct SyncFooter: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let text = statusText {
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
        }
    }

    private var statusText: String? {
        let statuses = model.syncStatus.values
        if statuses.contains(where: { $0.phase == .offline }) {
            return "Offline"
        }
        if statuses.contains(where: { $0.phase == .firstSync }) {
            return "Downloading your inbox…"
        }
        let backfill = statuses.compactMap { status -> Int? in
            if case let .backfilling(threads) = status.phase {
                return threads
            }
            return nil
        }
        if !backfill.isEmpty {
            return "Downloading older mail · \(backfill.reduce(0, +).formatted()) threads"
        }
        if statuses.contains(where: {
            if case .error = $0.phase {
                true
            } else {
                false
            }
        }) {
            return "Sync error · will retry"
        }
        guard let last = statuses.compactMap(\.lastSuccess).max() else { return nil }
        if Date().timeIntervalSince(last) < 60 {
            return "Updated just now"
        }
        return "Updated \(last.formatted(.relative(presentation: .named)))"
    }
}
