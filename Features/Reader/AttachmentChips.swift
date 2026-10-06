import AppKit
import QuickLook
import SwiftmailCore
import SwiftUI
import UniformTypeIdentifiers

struct AttachmentChips: View {
    @Environment(AppModel.self) private var model
    let attachments: [AttachmentRecord]
    @State private var previewURL: URL?
    @State private var loading: Set<String> = []
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            FlowLayout(spacing: 6) {
                ForEach(attachments, id: \.partId) { attachment in
                    chip(attachment)
                }
            }
            if let error {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
        .quickLookPreview($previewURL)
    }

    private func chip(_ attachment: AttachmentRecord) -> some View {
        Button {
            open(attachment) { previewURL = $0 }
        } label: {
            HStack(spacing: 6) {
                Image(nsImage: icon(for: attachment))
                    .resizable()
                    .frame(width: 20, height: 20)
                VStack(alignment: .leading, spacing: 0) {
                    Text(attachment.filename ?? "attachment")
                        .font(.system(size: 12))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(ByteCountFormatter.string(fromByteCount: Int64(attachment.size ?? 0), countStyle: .file))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                if loading.contains(attachment.partId) {
                    ProgressView().controlSize(.mini)
                }
            }
            .frame(maxWidth: 220, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .help("Quick Look")
        .accessibilityLabel(
            "Attachment \(attachment.filename ?? ""), \(ByteCountFormatter.string(fromByteCount: Int64(attachment.size ?? 0), countStyle: .file))"
        )
        .contextMenu {
            Button("Quick Look") { open(attachment) { previewURL = $0 } }
            Button("Open") { open(attachment) { NSWorkspace.shared.open($0) } }
            Button("Save…") { save(attachment) }
        }
        .onDrag { dragProvider(attachment) }
    }

    private func icon(for attachment: AttachmentRecord) -> NSImage {
        let type = attachment.mimeType.flatMap { UTType(mimeType: $0) }
            ?? UTType(filenameExtension: (attachment.filename as NSString?)?.pathExtension ?? "")
            ?? .data
        return NSWorkspace.shared.icon(for: type)
    }

    private func loader(_ accountID: String) async -> AttachmentLoader? {
        guard let session = await model.session(for: accountID) else { return nil }
        return AttachmentLoader(database: model.database, client: session.client)
    }

    private func open(_ attachment: AttachmentRecord, then: @escaping @MainActor (URL) -> Void) {
        loading.insert(attachment.partId)
        error = nil
        Task {
            defer { loading.remove(attachment.partId) }
            do {
                guard let loader = await loader(attachment.accountId) else { return }
                try await then(loader.localURL(for: attachment))
            } catch {
                self.error = "Couldn't download \(attachment.filename ?? "the attachment")."
            }
        }
    }

    private func save(_ attachment: AttachmentRecord) {
        open(attachment) { url in
            let panel = NSSavePanel()
            panel.nameFieldStringValue = attachment.filename ?? url.lastPathComponent
            panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            guard panel.runModal() == .OK, let destination = panel.url else { return }
            try? FileManager.default.removeItem(at: destination)
            do {
                try FileManager.default.copyItem(at: url, to: destination)
            } catch {
                self.error = "Couldn't save the file."
            }
        }
    }

    /// Drags a file to Finder, downloading it first if needed.
    private func dragProvider(_ attachment: AttachmentRecord) -> NSItemProvider {
        Self.makeDragProvider(attachment, database: model.database, manager: model.accountManager)
    }

    private nonisolated static func makeDragProvider(
        _ attachment: AttachmentRecord, database: AppDatabase, manager: AccountManager
    ) -> NSItemProvider {
        let provider = NSItemProvider()
        provider.suggestedName = attachment.filename
        let type = attachment.mimeType.flatMap { UTType(mimeType: $0) } ?? .data
        provider.registerFileRepresentation(for: type, visibility: .all) { handler in
            let completion = UncheckedSendable(handler)
            Task.detached {
                do {
                    guard let session = await manager.session(for: attachment.accountId) else { throw GmailError.notFound }
                    let url = try await AttachmentLoader(database: database, client: session.client).localURL(for: attachment)
                    completion.value(url, false, nil)
                } catch {
                    completion.value(nil, false, error)
                }
            }
            return nil
        }
        return provider
    }
}

/// Wraps children onto new lines, like attachment chips under a message.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var maxX: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            maxX = max(maxX, x - spacing)
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: maxX, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

/// Wraps a value that is safe to send but not marked `Sendable`, such as a completion
/// handler AppKit calls exactly once from any thread.
struct UncheckedSendable<Value>: @unchecked Sendable {
    let value: Value

    init(_ value: Value) {
        self.value = value
    }
}
