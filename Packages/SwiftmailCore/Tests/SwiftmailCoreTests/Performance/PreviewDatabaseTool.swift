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
        let database = try AppDatabase(GRDBPool.open(path))
        try SyntheticDatabase.populate(database, accountID: "preview", threads: 30000, messages: 100_000)
    }
}
