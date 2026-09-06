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
            try database.create(
                index: "bookmarks_folder_position",
                on: "bookmarks",
                columns: ["folder_id", "position"]
            )
            try database.create(table: "bookmark_sync_folders") { table in
                table.column("id", .text).primaryKey()
                table.column("payload", .blob).notNull()
                table.column("modified_at", .datetime).notNull().indexed()
            }
            try database.create(table: "bookmark_sync_bookmarks") { table in
                table.column("id", .text).primaryKey()
                table.column("payload", .blob).notNull()
                table.column("modified_at", .datetime).notNull().indexed()
            }
        }
        migrator.registerMigration("v4-sessions-cache-and-search") { database in
            try database.create(table: "browser_windows") { table in
                table.column("id", .text).primaryKey()
                table.column("position", .integer).notNull().unique()
                table.column("frame_x", .double)
                table.column("frame_y", .double)
                table.column("frame_width", .double)
                table.column("frame_height", .double)
                table.column("selected_tab_index", .integer).notNull()
            }
            try database.create(table: "browser_tabs") { table in
                table.column("id", .text).primaryKey()
                table.column("window_id", .text).notNull()
                    .references("browser_windows", onDelete: .cascade)
                table.column("position", .integer).notNull()
                table.column("history_index", .integer).notNull()
                table.column("zoom", .double).notNull()
                table.column("title", .text)
                table.column("document_title", .text)
                table.uniqueKey(["window_id", "position"])
            }
            try database.create(table: "browser_tab_history") { table in
                table.column("tab_id", .text).notNull()
                    .references("browser_tabs", onDelete: .cascade)
                table.column("position", .integer).notNull()
                table.column("url", .text).notNull()
                table.column("scroll_offset", .double).notNull().defaults(to: 0)
                table.primaryKey(["tab_id", "position"])
            }
            try database.create(table: "browser_session") { table in
                table.column("singleton", .integer).primaryKey()
                    .check { $0 == 1 }
                table.column("key_window_index", .integer).notNull()
                table.column("updated_at", .datetime).notNull()
            }
            try database.create(table: "page_cache") { table in
                table.column("url", .text).primaryKey()
                table.column("mime_type", .text).notNull()
                table.column("body", .blob).notNull()
                table.column("body_size", .integer).notNull()
                    .check { $0 >= 0 }
                table.column("completion", .text).notNull()
                table.column("received_at", .datetime).notNull().indexed()
                table.column("last_accessed_at", .datetime).notNull().indexed()
                table.column("title", .text)
                table.column("document_title", .text)
                table.column("response_status", .integer)
                table.column("response_meta", .text)
                table.column("client_certificate_id", .text)
            }
            try database.execute(sql: """
                CREATE VIRTUAL TABLE page_cache_fts USING fts5(
                    url UNINDEXED,
                    title,
                    content,
                    tokenize = 'unicode61'
                )
                """)
        }
        migrator.registerMigration("v5-security-and-sync-metadata") { database in
            try database.create(table: "trusted_server_identities") { table in
                table.column("endpoint_host", .text).notNull()
                table.column("endpoint_port", .integer).notNull()
                table.column("payload", .blob).notNull()
                table.column("updated_at", .datetime).notNull()
                table.primaryKey(["endpoint_host", "endpoint_port"])
            }
            try database.create(table: "server_trust_sync") { table in
                table.column("id", .text).primaryKey()
                table.column("payload", .blob).notNull()
                table.column("modified_at", .datetime).notNull().indexed()
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
            // Retained only as a v1 migration source. The column lets the compatibility
            // repository continue to read old rows without participating in v2 sync.
            try database.alter(table: "server_trust_sync") { table in
                table.add(column: "account_identity_hash", .text)
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
        return migrator
    }
}

public enum MajorTomDatabaseError: Error, Equatable, Sendable {
    case integrityCheckFailed(String)
    case foreignKeyCheckFailed(Int)
}
