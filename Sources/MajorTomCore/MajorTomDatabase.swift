import Foundation
import GRDB

/// Major Tom's local transactional persistence boundary.
///
/// Domain repositories own all SQL used for browser data. This type owns only database
/// creation, connection policy and ordered schema migrations, so SwiftUI views and network
/// services never need to know how the database is configured.
public final class MajorTomDatabase: @unchecked Sendable {
    public static let filename = "MajorTom.sqlite"

    private let writer: any DatabaseWriter

    /// Opens (or creates) the durable database and applies every pending migration.
    public init(fileURL: URL) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        var configuration = Configuration()
        configuration.label = "Major Tom"
        configuration.busyMode = .timeout(5)
        configuration.prepareDatabase { database in
            try database.execute(sql: "PRAGMA foreign_keys = ON")
        }

        let pool = try DatabasePool(path: fileURL.path, configuration: configuration)
        try Self.migrator.migrate(pool)
        writer = pool
    }

    /// Creates an isolated database for tests and previews.
    public init(inMemory: Void) throws {
        var configuration = Configuration()
        configuration.label = "Major Tom (in memory)"
        configuration.prepareDatabase { database in
            try database.execute(sql: "PRAGMA foreign_keys = ON")
        }

        let queue = try DatabaseQueue(configuration: configuration)
        try Self.migrator.migrate(queue)
        writer = queue
    }

    /// The normal database location in the user's Application Support directory.
    public static func defaultFileURL(
        fileManager: FileManager = .default
    ) throws -> URL {
        guard let root = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw CocoaError(.fileNoSuchFile)
        }
        return root
            .appendingPathComponent("Major Tom", isDirectory: true)
            .appendingPathComponent(filename)
    }

    /// Runs a consistent read without exposing the connection pool itself.
    public func read<Value>(
        _ body: (Database) throws -> Value
    ) throws -> Value {
        try writer.read(body)
    }

    /// Runs a transaction. Throwing from `body` rolls every change back.
    public func write<Value>(
        _ body: (Database) throws -> Value
    ) throws -> Value {
        try writer.write(body)
    }

    /// Verifies SQLite structure and every declared foreign-key relationship.
    public func validate() throws {
        try read { database in
            let result = try String.fetchOne(database, sql: "PRAGMA quick_check")
            guard result == "ok" else {
                throw MajorTomDatabaseError.integrityCheckFailed(result ?? "no result")
            }
            let violations = try Row.fetchAll(database, sql: "PRAGMA foreign_key_check")
            guard violations.isEmpty else {
                throw MajorTomDatabaseError.foreignKeyCheckFailed(violations.count)
            }
        }
    }

    private static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1-foundation") { database in
            try database.create(table: "persistence_metadata") { table in
                table.column("key", .text).primaryKey()
                table.column("value", .blob).notNull()
                table.column("updated_at", .datetime).notNull()
            }
        }
        migrator.registerMigration("v2-history-and-input-drafts") { database in
            try database.create(table: "history_entries") { table in
                table.column("url", .text).primaryKey()
                table.column("visited_at", .datetime).notNull().indexed()
                table.column("visit_count", .integer).notNull()
                    .defaults(to: 1)
                    .check { $0 > 0 }
            }
            try database.create(table: "gemini_input_drafts") { table in
                table.column("prompt_url", .text).primaryKey()
                table.column("text", .text).notNull()
                table.column("updated_at", .datetime).notNull()
                table.column("expires_at", .datetime).notNull().indexed()
            }
        }
        migrator.registerMigration("v3-bookmarks") { database in
            try database.create(table: "bookmark_folders") { table in
                table.column("id", .text).primaryKey()
                table.column("name", .text).notNull()
                table.column("position", .integer).notNull()
            }
            try database.create(table: "bookmarks") { table in
                table.column("id", .text).primaryKey()
                table.column("folder_id", .text).notNull()
                    .references("bookmark_folders", onDelete: .cascade)
                table.column("title", .text).notNull()
                table.column("url", .text).notNull()
                table.column("added_at", .datetime).notNull()
                table.column("position", .integer).notNull()
                // NULL means no capsule favicon has ever been observed for this bookmark.
                // 0 is a confirmed absence and 1 is a confirmed emoji value.
                table.column("favicon_state", .integer)
                table.column("favicon_emoji", .text)
                table.column("favicon_fetched_at", .datetime)
            }
        }
        migrator.registerMigration("v5-security-and-sync-metadata") { database in
            try database.create(table: "trusted_server_identities") { table in
                table.column("endpoint_host", .text).notNull()
                table.column("endpoint_port", .integer).notNull()
                table.column("payload", .blob).notNull()
                table.column("updated_at", .datetime).notNull()
                table.primaryKey(["endpoint_host", "endpoint_port"])
            }
            try database.create(table: "client_certificate_sync_descriptors") { table in
                table.column("id", .text).primaryKey()
                table.column("payload", .blob).notNull()
                table.column("modified_at", .datetime).notNull().indexed()
            }
            try database.create(table: "client_certificate_sync_associations") { table in
                table.column("id", .text).primaryKey()
                table.column("payload", .blob).notNull()
                table.column("modified_at", .datetime).notNull().indexed()
            }
            try database.create(table: "client_certificate_local_flags") { table in
                table.column("id", .text).primaryKey()
                table.column("synchronizes_with_icloud", .boolean).notNull()
            }
        }
        migrator.registerMigration("v6-cloud-sync-refactor") { database in
            try database.create(table: "cloud_sync_state") { table in
                table.column("account_identity_hash", .text).primaryKey()
                table.column("engine_state", .blob)
                table.column("model_major", .integer).notNull()
                table.column("migrated_from_v1", .boolean).notNull().defaults(to: false)
                table.column("migration_phase", .text).notNull()
                table.column("zone_state", .text).notNull()
                table.column("favorites_folder_id", .text)
                table.column("last_fetched_at", .datetime)
                table.column("last_sent_at", .datetime)
                table.column("updated_at", .datetime).notNull()
            }
            try database.create(table: "cloud_pending_changes") { table in
                table.column("account_identity_hash", .text).notNull()
                table.column("record_type", .text).notNull()
                table.column("record_name", .text).notNull()
                table.column("operation", .text).notNull()
                    .check { ["save", "delete"].contains($0) }
                table.column("generation", .integer).notNull()
                table.column("payload_digest", .text)
                table.column("enqueued_at", .datetime).notNull()
                table.primaryKey(["account_identity_hash", "record_name"])
            }
            try database.create(table: "cloud_record_state") { table in
                table.column("account_identity_hash", .text).notNull()
                table.column("record_type", .text).notNull()
                table.column("record_name", .text).notNull()
                table.column("system_fields", .blob)
                table.column("server_payload", .blob)
                table.column("payload_digest", .text)
                table.column("last_seen_epoch", .integer)
                table.column("updated_at", .datetime).notNull()
                table.primaryKey(["account_identity_hash", "record_name"])
            }

            try database.alter(table: "bookmark_folders") { table in
                table.add(column: "order_key", .text)
                table.add(column: "account_identity_hash", .text)
            }
            try database.alter(table: "bookmarks") { table in
                table.add(column: "order_key", .text)
                table.add(column: "account_identity_hash", .text)
                table.add(column: "pending_folder_id", .text)
            }

            let folderIDs = try String.fetchAll(
                database,
                sql: "SELECT id FROM bookmark_folders ORDER BY position, id"
            )
            for (id, orderKey) in zip(folderIDs, OrderKey.initial(count: folderIDs.count)) {
                try database.execute(
                    sql: "UPDATE bookmark_folders SET order_key = ? WHERE id = ?",
                    arguments: [orderKey, id]
                )
            }
            for folderID in folderIDs {
                let bookmarkIDs = try String.fetchAll(
                    database,
                    sql: "SELECT id FROM bookmarks WHERE folder_id = ? ORDER BY position, id",
                    arguments: [folderID]
                )
                for (id, orderKey) in zip(bookmarkIDs, OrderKey.initial(count: bookmarkIDs.count)) {
                    try database.execute(
                        sql: "UPDATE bookmarks SET order_key = ? WHERE id = ?",
                        arguments: [orderKey, id]
                    )
                }
            }
            try database.create(
                index: "bookmark_folders_account_order",
                on: "bookmark_folders",
                columns: ["account_identity_hash", "order_key"]
            )
            try database.create(
                index: "bookmarks_account_folder_order",
                on: "bookmarks",
                columns: ["account_identity_hash", "folder_id", "order_key"]
            )
        }
        migrator.registerMigration("v7-cloud-certificate-metadata") { database in
            try database.rename(
                table: "client_certificate_sync_descriptors",
                to: "client_certificates"
            )
            try database.rename(
                table: "client_certificate_sync_associations",
                to: "client_certificate_associations"
            )
            try database.alter(table: "client_certificates") { table in
                table.add(column: "account_identity_hash", .text)
            }
            try database.alter(table: "client_certificate_associations") { table in
                table.add(column: "account_identity_hash", .text)
                table.add(column: "pending_certificate_id", .text)
            }
            try database.alter(table: "client_certificate_local_flags") { table in
                table.add(column: "account_identity_hash", .text)
            }
            // A development build may have applied v5 before this cleanup landed.
            // Preserve that upgrade path; fresh databases never create this old table.
            if try database.tableExists("server_trust_sync") {
                try database.alter(table: "server_trust_sync") { table in
                    table.add(column: "account_identity_hash", .text)
                }
            }
            try database.create(
                index: "client_certificates_account",
                on: "client_certificates",
                columns: ["account_identity_hash"]
            )
            try database.create(
                index: "client_certificate_associations_account",
                on: "client_certificate_associations",
                columns: ["account_identity_hash"]
            )
        }
        migrator.registerMigration("v8-remove-unused-local-storage") { database in
            // No released Major Tom build ever used MajorTom.sqlite. These tables were
            // introduced during development and superseded before release by BFCache
            // and the record-level CloudKit outbox.
            for table in [
                "page_cache_fts",
                "page_cache",
                "browser_tab_history",
                "browser_tabs",
                "browser_windows",
                "browser_session",
                "bookmark_sync_folders",
                "bookmark_sync_bookmarks",
                "server_trust_sync"
            ] where try database.tableExists(table) {
                try database.execute(sql: "DROP TABLE \(table)")
            }
            // Order keys became authoritative in v6. These ordinal copies were only a
            // migration aid, so remove both their index and the redundant values.
            try database.execute(sql: "DROP INDEX IF EXISTS bookmarks_folder_position")
            if try database.columns(in: "bookmark_folders").contains(where: { $0.name == "position" }) {
                try database.execute(sql: "ALTER TABLE bookmark_folders DROP COLUMN position")
            }
            if try database.columns(in: "bookmarks").contains(where: { $0.name == "position" }) {
                try database.execute(sql: "ALTER TABLE bookmarks DROP COLUMN position")
            }
        }
        return migrator
    }
}

public enum MajorTomDatabaseError: Error, Equatable, Sendable {
    case integrityCheckFailed(String)
    case foreignKeyCheckFailed(Int)
}
