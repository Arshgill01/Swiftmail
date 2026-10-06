import Foundation
import GRDB
import Synchronization

/// Files under `Application Support/Swiftmail/Attachments/<account>/<message>/`.
/// `attachments.local_path` stores paths relative to the storage root.
public enum AttachmentStorage {
    private static let overrideRoot = Mutex<URL?>(nil)

    /// Tests point this at a temporary directory.
    public static func setRoot(_ url: URL?) {
        overrideRoot.withLock { $0 = url }
    }

    public static func root() throws -> URL {
        if let url = overrideRoot.withLock({ $0 }) {
            return url
        }
        return try SwiftmailCore.appSupportDirectory()
    }

    public static func relativePath(accountID: String, messageID: String, partID: String, filename: String) -> String {
        let safeName = filename.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: "_")
        let safePart = partID.replacingOccurrences(of: "/", with: "_")
        return "Attachments/\(accountID)/\(messageID)/\(safePart)-\(safeName)"
    }

    public static func url(forRelativePath path: String) throws -> URL {
        try root().appendingPathComponent(path)
    }

    /// Writes data and returns the relative path to store.
    public static func write(_ data: Data, accountID: String, messageID: String, partID: String, filename: String) throws -> String {
        let relative = relativePath(accountID: accountID, messageID: messageID, partID: partID, filename: filename)
        let url = try url(forRelativePath: relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        return relative
    }
}

/// Small attachments arrive inline in `body.data`; save them so they never need a fetch.
enum InlineDataCache {
    static func store(_ db: Database, accountID: String, messageID: String, attachments: [DecodedAttachment]) throws {
        for attachment in attachments {
            guard let data = attachment.data, !data.isEmpty else { continue }
            let path = try AttachmentStorage.write(
                data, accountID: accountID, messageID: messageID, partID: attachment.partID, filename: attachment.filename
            )
            try db.execute(
                sql: "UPDATE attachments SET local_path = ? WHERE account_id = ? AND message_id = ? AND part_id = ?",
                arguments: [path, accountID, messageID, attachment.partID]
            )
        }
    }
}
