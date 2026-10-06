import SwiftmailCore
import SwiftUI

struct ReaderView: View {
    @Environment(AppModel.self) private var model
    let window: MainWindowModel
    private var reader: ReaderModel {
        window.reader
    }

    var body: some View {
        Group {
            if window.selectedThreads.count > 1 {
                ContentUnavailableView("\(window.selectedThreads.count) conversations selected", systemImage: "envelope.badge")
            } else if let conversation = reader.conversation {
                conversationView(conversation)
            } else if window.focusedThread != nil, reader.snapshot != nil {
                ContentUnavailableView("Conversation not found", systemImage: "questionmark.folder")
            } else if window.focusedThread == nil {
                ContentUnavailableView("No Conversation Selected", systemImage: "envelope")
            } else {
                Color.clear
            }
        }
        .onAppear { reader.show(window.focusedThread, model: model) }
        .onChange(of: window.focusedThread) { reader.show(window.focusedThread, model: model) }
        .environment(reader)
    }

    private func conversationView(_ conversation: Conversation) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ConversationHeader(conversation: conversation)
                    if let error = reader.bodyError {
                        HStack {
                            Label(error, systemImage: "wifi.exclamationmark").foregroundStyle(.secondary)
                            Button("Try Again") { reader.retry(model: model) }
                        }
                        .font(.callout)
                    }
                    ForEach(conversation.messages) { message in
                        MessageCard(message: message, accountID: conversation.thread.accountId)
                            .id(message.id)
                            .overlay {
                                if reader.focusedMessage == message.id {
                                    RoundedRectangle(cornerRadius: 10).strokeBorder(Color.accentColor.opacity(0.6), lineWidth: 1.5)
                                }
                            }
                    }
                    ConversationFooter(window: window)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
                .frame(maxWidth: 880)
                .frame(maxWidth: .infinity)
            }
            .onChange(of: reader.focusedMessage) {
                if let id = reader.focusedMessage {
                    withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(id, anchor: .top) }
                }
            }
        }
        .overlay(alignment: .bottomLeading) {
            if let link = reader.hoveredLink {
                Text(link)
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
                    .padding(8)
                    .frame(maxWidth: 520, alignment: .leading)
                    .allowsHitTesting(false)
            }
        }
    }
}

struct ConversationHeader: View {
    @Environment(AppModel.self) private var model
    let conversation: Conversation

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 6) {
                Text(subject)
                    .font(.title2.weight(.semibold))
                    .textSelection(.enabled)
                let labels = conversation.labelIDs.compactMap { model.sidebarAccount(conversation.thread.accountId)?.allLabels[$0] }
                    .filter { $0.type == "user" }
                    .sorted { $0.name < $1.name }
                if !labels.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(labels, id: \.id) { LabelChip(label: $0) }
                    }
                }
            }
            Spacer()
            Image(systemName: conversation.thread.isStarred ? "star.fill" : "star")
                .foregroundStyle(conversation.thread.isStarred ? .yellow : .secondary)
                .accessibilityLabel(conversation.thread.isStarred ? "Starred" : "Not starred")
        }
        .padding(.bottom, 4)
    }

    private var subject: String {
        let text = conversation.thread.subject?.trimmingCharacters(in: .whitespaces) ?? ""
        return text.isEmpty ? "(no subject)" : text
    }
}

struct ConversationFooter: View {
    let window: MainWindowModel

    var body: some View {
        HStack {
            Button("Reply", systemImage: "arrowshape.turn.up.left") { window.perform(.reply) }
            Button("Reply All", systemImage: "arrowshape.turn.up.left.2") { window.perform(.replyAll) }
            Button("Forward", systemImage: "arrowshape.turn.up.right") { window.perform(.forward) }
        }
        .padding(.top, 6)
    }
}
