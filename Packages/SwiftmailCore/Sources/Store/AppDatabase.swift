import Foundation
import GRDB

/// The single SQLite store shared by all accounts, opened as a WAL `DatabasePool`.
/// The UI only reads from here; sync and actions write through `writer`.
public final class AppDatabase: Sendable {
    public let writer: any DatabaseWriter
    public var reader: any DatabaseReader {
        writer
    }

    public init(_ writer: any DatabaseWriter) throws {
        self.writer = writer
        try Self.migrator.migrate(writer)
    }

    /// Opens `Application Support/Swiftmail/Mail.sqlite`.
    public static func openDefault() throws -> AppDatabase {
        let url = try SwiftmailCore.appSupportDirectory().appendingPathComponent("Mail.sqlite")
        return try AppDatabase(DatabasePool(path: url.path, configuration: makeConfiguration()))
    }

    /// An in-memory database for tests and previews.
    public static func inMemory() throws -> AppDatabase {
        try AppDatabase(DatabaseQueue(configuration: makeConfiguration()))
    }

    /// A temporary on-disk pool, for tests that need WAL and concurrent reads.
    public static func temporary() throws -> AppDatabase {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("swiftmail-\(UUID().uuidString).sqlite")
        return try AppDatabase(DatabasePool(path: url.path, configuration: makeConfiguration()))
    }

    static func makeConfiguration() -> Configuration {
        var config = Configuration()
        config.foreignKeysEnabled = true
        config.label = "Swiftmail"
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA synchronous = NORMAL")
        }
        return config
    }

    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        #if DEBUG
            migrator.eraseDatabaseOnSchemaChange = false
        #endif
        migrator.registerMigration("v1_schema", migrate: Schema.v1)
        return migrator
    }
}
