import Foundation
import GRDB

/// Downloads attachments on demand into `Attachments/<account>/<message>/` and records
/// the path in `attachments.local_path`.
public struct AttachmentLoader: Sendable {
    let database: AppDatabase
    let client: any GmailClient

    public init(database: AppDatabase, client: any GmailClient) {
        self.database = database
        self.client = client
    }

    /// The local file for an attachment, downloading it if needed (user priority).
    public func localURL(for attachment: AttachmentRecord) async throws -> URL {
        if let path = attachment.localPath {
            let url = try AttachmentStorage.url(forRelativePath: path)
            if FileManager.default.fileExists(atPath: url.path) {
                return url
            }
        }
        guard let attachmentID = attachment.attachmentId else { throw GmailError.notFound }
        let data = try await client.getAttachment(messageID: attachment.messageId, attachmentID: attachmentID)
        let path = try AttachmentStorage.write(
            data, accountID: attachment.accountId, messageID: attachment.messageId,
            partID: attachment.partId, filename: attachment.filename ?? "attachment"
        )
        try await database.writer.write { db in
            try db.execute(
                sql: "UPDATE attachments SET local_path = ? WHERE account_id = ? AND message_id = ? AND part_id = ?",
                arguments: [path, attachment.accountId, attachment.messageId, attachment.partId]
            )
        }
        return try AttachmentStorage.url(forRelativePath: path)
    }

    /// Data and MIME type for an inline image referenced by Content-ID.
    public func inlineImage(accountID: String, messageID: String, contentID: String) async throws -> (Data, String) {
        let attachment = try await database.reader.read { db in
            try AttachmentRecord.fetchOne(db, sql: """
            SELECT * FROM attachments WHERE account_id = ? AND message_id = ? AND lower(content_id) = lower(?)
            """, arguments: [accountID, messageID, contentID])
        }
        guard let attachment else { throw GmailError.notFound }
        let url = try await localURL(for: attachment)
        return try (Data(contentsOf: url), attachment.mimeType ?? "application/octet-stream")
    }
}
