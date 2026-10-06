import GRDB
import SwiftmailCore
import SwiftUI

/// Messages waiting to send: held for undo, offline, or failed. Never dropped.
struct OutboxListView: View {
    @Environment(AppModel.self) private var model
    @State private var items: [Outbox.Item] = []

    var body: some View {
        List(items) { item in
            HStack {
                Image(systemName: item.state == .failed ? "exclamationmark.triangle.fill" : "paperplane")
                    .foregroundStyle(item.state == .failed ? .orange : .secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.summary).lineLimit(1)
                    Text(status(item))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if item.state == .failed {
                    Button("Retry") {
                        Task {
                            try? await Outbox.retry(item.id, database: model.database)
                            await model.session(for: item.accountID)?.drainActions()
                        }
                    }
                }
                if item.state != .inFlight {
                    Button("Edit") { model.undoSend(item.id) }
                }
            }
            .padding(.vertical, 4)
        }
        .overlay {
            if items.isEmpty {
                ContentUnavailableView("Outbox is empty", systemImage: "tray.and.arrow.up")
            }
        }
        .task {
            let observation = ValueObservation.tracking(Outbox.items)
            do {
                for try await value in observation.values(in: model.database.reader) {
                    items = value
                }
            } catch {}
        }
    }

    private func status(_ item: Outbox.Item) -> String {
        switch item.state {
        case .held: "Sending soon"
        case .inFlight: "Sending…"
        case .failed: "Not sent" + (item.lastError.map { " — \($0)" } ?? "")
        default: "Waiting for a connection"
        }
    }
}
