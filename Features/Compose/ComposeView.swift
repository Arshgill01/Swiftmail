import SwiftmailCore
import SwiftUI

/// The contents of a compose window, loaded from its local draft.
struct ComposeWindow: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let id: UUID?
    @State private var model: ComposeModel?
    @State private var missing = false

    var body: some View {
        Group {
            if let model {
                ComposeView(model: model, close: { dismiss() })
                    .navigationTitle(model.title)
            } else if missing {
                ContentUnavailableView("This draft is no longer available", systemImage: "doc.badge.ellipsis")
            } else {
                ProgressView()
            }
        }
        .frame(minWidth: 560, minHeight: 420)
        .task {
            guard model == nil, let id else { missing = id == nil; return }
            if let state = try? await app.database.localDraft(id) {
                model = ComposeModel(state: state, app: app)
                try? await app.database.setLocalDraftOpen(id, true)
            } else {
                missing = true
            }
        }
        .onDisappear {
            guard let model else { return }
            Task { await model.windowClosed() }
        }
    }
}

struct ComposeView: View {
    @Environment(AppModel.self) private var app
    @Bindable var model: ComposeModel
    let close: () -> Void
    @State private var linkURL = ""

    var body: some View {
        VStack(spacing: 0) {
            if model.aliases.count > 1 {
                row("From") {
                    Picker("From", selection: Binding(get: { model.state.from }, set: { model.selectFrom($0) })) {
                        ForEach(model.aliases, id: \.email) { alias in
                            Text(alias.displayName.map { "\($0) <\(alias.email)>" } ?? alias.email).tag(alias.email)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                    Spacer()
                }
            }
            row("To") {
                RecipientField(addresses: $model.state.to, database: app.database)
                if !model.state.showCcBcc {
                    Button("Cc Bcc") { model.state.showCcBcc = true }
                        .buttonStyle(.link)
                        .font(.caption)
                }
            }
            if model.state.showCcBcc {
                row("Cc") { RecipientField(addresses: $model.state.cc, database: app.database) }
                row("Bcc") { RecipientField(addresses: $model.state.bcc, database: app.database) }
            }
            row("Subject") {
                TextField("Subject", text: $model.state.subject)
                    .textFieldStyle(.plain)
                    .labelsHidden()
            }
            FormattingBar(editor: model.editor)
            Divider()
            ComposeEditorView(controller: model.editor)
                .frame(minHeight: 200)
            if !model.state.attachments.isEmpty {
                ComposeAttachments(model: model)
            }
            if let error = model.error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .font(.callout)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
            }
            Divider()
            bottomBar
        }
        .sheet(isPresented: Binding(get: { model.editor.linkRequest != nil }, set: {
            if !$0 {
                model.editor.linkRequest = nil
            }
        })) {
            linkSheet
        }
    }

    private func row(_ label: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(label)
                    .foregroundStyle(.secondary)
                    .frame(width: 58, alignment: .trailing)
                content()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            Divider().padding(.leading, 78)
        }
    }

    private var bottomBar: some View {
        HStack {
            Button("Attach", systemImage: "paperclip") { model.chooseFiles() }
                .help("Attach files")
            Text(ByteCountFormatter.string(fromByteCount: Int64(model.state.attachmentBytes), countStyle: .file))
                .font(.caption)
                .foregroundStyle(.secondary)
                .opacity(model.state.attachments.isEmpty ? 0 : 1)
            Spacer()
            Button("Discard", systemImage: "trash", role: .destructive) {
                Task {
                    await model.discard()
                    close()
                }
            }
            .help("Discard draft")
            Button {
                Task {
                    if await model.send() {
                        close()
                    }
                }
            } label: {
                Label("Send", systemImage: "paperplane.fill")
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(model.isSending)
            .help("Send (⌘↩)")
        }
        .padding(10)
    }

    private var linkSheet: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Add Link").font(.headline)
            TextField("https://", text: $linkURL)
                .textFieldStyle(.roundedBorder)
                .frame(width: 320)
            HStack {
                Spacer()
                Button("Cancel") { model.editor.linkRequest = nil }.keyboardShortcut(.cancelAction)
                Button("Add") {
                    var url = linkURL.trimmingCharacters(in: .whitespaces)
                    if !url.contains(":") {
                        url = (url.contains("@") ? "mailto:" : "https://") + url
                    }
                    model.editor.exec("createLink", value: url)
                    model.editor.linkRequest = nil
                    linkURL = ""
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
    }
}

struct FormattingBar: View {
    let editor: ComposeEditorController

    var body: some View {
        HStack(spacing: 2) {
            toggle("bold", "bold", editor.isBold, "Bold (⌘B)")
            toggle("italic", "italic", editor.isItalic, "Italic (⌘I)")
            toggle("underline", "underline", editor.isUnderline, "Underline (⌘U)")
            Divider().frame(height: 16)
            button("link", "Link (⌘K)") { editor.linkRequest = "" }
            button("list.bullet", "Bulleted list") { editor.exec("insertUnorderedList") }
            button("list.number", "Numbered list") { editor.exec("insertOrderedList") }
            button("text.quote", "Quote") { editor.exec("blockquote") }
            button("textformat", "Clear formatting") { editor.exec("removeFormat") }
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
    }

    private func toggle(_ symbol: String, _ command: String, _ isOn: Bool, _ help: String) -> some View {
        button(symbol, help) { editor.exec(command) }
            .background(isOn ? Color.accentColor.opacity(0.18) : .clear, in: RoundedRectangle(cornerRadius: 5))
    }

    private func button(_ symbol: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).frame(width: 24, height: 20)
        }
        .buttonStyle(.borderless)
        .help(help)
        .accessibilityLabel(help)
    }
}

struct ComposeAttachments: View {
    let model: ComposeModel

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 6) {
                ForEach(model.state.attachments) { attachment in
                    HStack(spacing: 4) {
                        Image(systemName: "doc")
                        Text(attachment.filename).lineLimit(1).truncationMode(.middle)
                        Text(ByteCountFormatter.string(fromByteCount: Int64(attachment.size), countStyle: .file))
                            .foregroundStyle(.secondary)
                        Button {
                            model.removeAttachment(attachment.id)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Remove \(attachment.filename)")
                    }
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.quaternary.opacity(0.6), in: Capsule())
                    .frame(maxWidth: 240)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
    }
}
