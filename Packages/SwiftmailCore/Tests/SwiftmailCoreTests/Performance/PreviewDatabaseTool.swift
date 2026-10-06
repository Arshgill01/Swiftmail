import Foundation
@testable import SwiftmailCore
import Testing

/// Writes a synthetic mailbox to `$SWIFTMAIL_PREVIEW_DB` for UI and launch-time checks.
/// Skipped unless that variable is set: `scripts/preview-db.sh` sets it.
struct PreviewDatabaseTool {
    static let path = ProcessInfo.processInfo.environment["SWIFTMAIL_PREVIEW_DB"]

    @Test(.enabled(if: PreviewDatabaseTool.path != nil))
    func writePreviewDatabase() throws {
        let path = try #require(Self.path)
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: path + suffix)
        }
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: path).deletingLastPathComponent(), withIntermediateDirectories: true
        )
        // Attachment files go next to the database in the app container, never to this
        // (unsandboxed) test process's own Application Support folder.
        AttachmentStorage.setRoot(URL(fileURLWithPath: path).deletingLastPathComponent())
        defer { AttachmentStorage.setRoot(nil) }
        let database = try AppDatabase(GRDBPool.open(path))
        try SyntheticDatabase.populate(database, accountID: "preview", threads: 30000, messages: 100_000)
        try SyntheticDatabase.renderPlainBodies(database)
        try importCorpus(into: database)
    }

    /// The corpus emails as the newest inbox threads, written through the real writer.
    func importCorpus(into database: AppDatabase) throws {
        let now = Date()
        try database.writer.write { db in
            for (index, name) in Corpus.files.enumerated() {
                let data = try Data(contentsOf: Corpus.directory.appendingPathComponent(name))
                let payload = EMLParser.parse(data)
                var labels = ["INBOX", "CATEGORY_PERSONAL"]
                if index % 3 == 0 {
                    labels.append("UNREAD")
                }
                let message = GmailMessage(
                    id: "corpus\(index)", threadId: "corpus-thread-\(index)", labelIds: labels,
                    snippet: MessageDecoder.decode(payload).plain.map { String($0.prefix(100)) } ?? name,
                    historyId: "1", internalDate: String(now.millis + Int64(index) * 1000), sizeEstimate: data.count, payload: payload
                )
                try MailWriter.upsertThread(
                    db, accountID: "preview", thread: GmailThread(id: message.threadId, messages: [message]), format: .full
                )
            }
        }
    }
}
