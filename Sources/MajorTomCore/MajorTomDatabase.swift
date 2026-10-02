import Foundation
import GRDB

/// Major Tom's local transactional persistence boundary.
///
/// Domain repositories own all SQL used for browser data. This type owns only database
/// creation, connection policy and ordered schema migrations, so SwiftUI views and network
/// services never need to know how the database is configured.
public final class MajorTomDatabase: @unchecked Sendable {
    public static let filename = "MajorTom.db"

    private let writer: any DatabaseWriter
    private let fileURL: URL?

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
        self.fileURL = fileURL
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
        fileURL = nil
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

    /// Folds committed WAL frames into the main database and closes every pooled
    /// connection. Call only after all application-level writes have finished.
    public func checkpointAndClose() throws {
        _ = try writer.writeWithoutTransaction { database in
            try database.checkpoint(.truncate)
        }
        try writer.close()
        guard let fileURL else { return }
        let fileManager = FileManager.default
        for suffix in ["-wal", "-shm"] {
            let companion = URL(fileURLWithPath: fileURL.path + suffix)
            if fileManager.fileExists(atPath: companion.path) {
                try fileManager.removeItem(at: companion)
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
            // These tables were introduced during development and superseded before
            // release by BFCache and the record-level CloudKit outbox.
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
        migrator.registerMigration("v9-history-titles") { database in
            try database.alter(table: "history_entries") { table in
                table.add(column: "title", .text).notNull().defaults(to: "")
            }
        }
        migrator.registerMigration("v10-repair-bookmark-order-columns") { database in
            // Some development databases recorded v8 before its position-column cleanup
            // was added. Migration identifiers are immutable, so repair those databases
            // under a new identifier instead of changing v8 again.
            try database.execute(sql: "DROP INDEX IF EXISTS bookmarks_folder_position")
            if try database.columns(in: "bookmark_folders").contains(where: { $0.name == "position" }) {
                try database.execute(sql: "ALTER TABLE bookmark_folders DROP COLUMN position")
            }
            if try database.columns(in: "bookmarks").contains(where: { $0.name == "position" }) {
                try database.execute(sql: "ALTER TABLE bookmarks DROP COLUMN position")
            }
        }
        migrator.registerMigration("v11-durable-cloud-outbox-payloads") { database in
            // A few development databases recorded v8/v10 while omitting the
            // experimental CloudKit tables altogether. A migration must leave every
            // database it marks as migrated usable, rather than silently recording v11
            // and deferring a missing-table failure until the first sync.
            if try !database.tableExists("cloud_pending_changes") {
                try database.create(table: "cloud_pending_changes") { table in
                    table.column("account_identity_hash", .text).notNull()
                    table.column("record_type", .text).notNull()
                    table.column("record_name", .text).notNull()
                    table.column("operation", .text).notNull()
                        .check { ["save", "delete"].contains($0) }
                    table.column("generation", .integer).notNull()
                    table.column("model_payload", .blob)
                    table.column("payload_digest", .text)
                    table.column("enqueued_at", .datetime).notNull()
                    table.primaryKey(["account_identity_hash", "record_name"])
                }
            } else {
                // A pending save must describe the value that was committed locally,
                // rather than requiring the transport to reread a mutable domain row later.
                try database.alter(table: "cloud_pending_changes") { table in
                    table.add(column: "model_payload", .blob)
                }
            }
            if try !database.tableExists("cloud_sync_state") {
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
            }
            if try !database.tableExists("cloud_record_state") {
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
            }
            // The outbox row is deleted after acknowledgement, so it cannot be the source
            // of the next generation. Keep a small per-record ledger instead.
            try database.create(table: "cloud_record_generations") { table in
                table.column("account_identity_hash", .text).notNull()
                table.column("record_name", .text).notNull()
                table.column("last_generation", .integer).notNull()
                table.primaryKey(["account_identity_hash", "record_name"])
            }
            try database.execute(sql: """
                INSERT INTO cloud_record_generations
                    (account_identity_hash, record_name, last_generation)
                SELECT account_identity_hash, record_name, MAX(generation)
                FROM cloud_pending_changes
                GROUP BY account_identity_hash, record_name
                """)
            try database.create(
                index: "cloud_pending_changes_account_enqueued",
                on: "cloud_pending_changes",
                columns: ["account_identity_hash", "enqueued_at", "record_name"]
            )
        }
        migrator.registerMigration("v12-account-qualified-domain-keys") { db in
            // UUIDs identify cloud records within an account, not across accounts. Keep
            // NULL for pre-account rows; a generated scope gives those rows a real key.
            if try db.tableExists("bookmarks") {
                try db.execute(sql: """
                    CREATE TABLE bookmark_folders_scoped (
                        id TEXT NOT NULL, name TEXT NOT NULL, order_key TEXT,
                        account_identity_hash TEXT,
                        account_scope TEXT GENERATED ALWAYS AS (ifnull(account_identity_hash, '')) STORED,
                        UNIQUE (id, account_scope)
                    );
                    INSERT INTO bookmark_folders_scoped (id, name, order_key, account_identity_hash)
                    SELECT id, name, order_key, account_identity_hash FROM bookmark_folders;
                    CREATE TABLE bookmarks_scoped (
                        id TEXT NOT NULL, folder_id TEXT NOT NULL, title TEXT NOT NULL,
                        url TEXT NOT NULL, added_at DATETIME NOT NULL, order_key TEXT,
                        account_identity_hash TEXT, pending_folder_id TEXT,
                        favicon_state INTEGER, favicon_emoji TEXT, favicon_fetched_at DATETIME,
                        account_scope TEXT GENERATED ALWAYS AS (ifnull(account_identity_hash, '')) STORED,
                        UNIQUE (id, account_scope),
                        FOREIGN KEY (folder_id, account_scope)
                            REFERENCES bookmark_folders(id, account_scope)
                            ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED
                    );
                    INSERT INTO bookmarks_scoped
                        (id, folder_id, title, url, added_at, order_key, account_identity_hash,
                         pending_folder_id, favicon_state, favicon_emoji, favicon_fetched_at)
                    SELECT id, folder_id, title, url, added_at, order_key, account_identity_hash,
                           pending_folder_id, favicon_state, favicon_emoji, favicon_fetched_at FROM bookmarks;
                    DROP TABLE bookmarks;
                    DROP TABLE bookmark_folders;
                    ALTER TABLE bookmark_folders_scoped RENAME TO bookmark_folders;
                    ALTER TABLE bookmarks_scoped RENAME TO bookmarks;
                    CREATE INDEX bookmark_folders_account_order ON bookmark_folders(account_identity_hash, order_key, id);
                    CREATE INDEX bookmarks_account_folder_order ON bookmarks(account_identity_hash, folder_id, order_key, id);
                    """)
            }
            for table in ["client_certificates", "client_certificate_associations", "client_certificate_local_flags"]
            where try db.tableExists(table) {
                let isFlags = table == "client_certificate_local_flags"
                let columns = isFlags ? "id, synchronizes_with_icloud, account_identity_hash"
                    : table == "client_certificate_associations"
                    ? "id, payload, modified_at, account_identity_hash, pending_certificate_id"
                    : "id, payload, modified_at, account_identity_hash"
                let fields = isFlags ? "synchronizes_with_icloud BOOLEAN NOT NULL"
                    : "payload BLOB NOT NULL, modified_at DATETIME NOT NULL"
                let pending = table == "client_certificate_associations" ? ", pending_certificate_id TEXT" : ""
                try db.execute(sql: """
                    CREATE TABLE \(table)_scoped (
                        id TEXT NOT NULL, \(fields), account_identity_hash TEXT\(pending),
                        account_scope TEXT GENERATED ALWAYS AS (ifnull(account_identity_hash, '')) STORED,
                        UNIQUE (id, account_scope)
                    );
                    INSERT INTO \(table)_scoped (\(columns)) SELECT \(columns) FROM \(table);
                    DROP TABLE \(table);
                    ALTER TABLE \(table)_scoped RENAME TO \(table);
                    CREATE INDEX \(table)_account ON \(table)(account_identity_hash, id);
                    """)
            }
        }
        migrator.registerMigration("v13-cloud-incoming-journal") { db in
            try db.execute(sql: """
                CREATE TABLE cloud_incoming_batches (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    account_identity_hash TEXT NOT NULL,
                    payload BLOB NOT NULL
                );
                CREATE INDEX cloud_incoming_batches_account ON cloud_incoming_batches(account_identity_hash, id);
                """)
        }
        migrator.registerMigration("v14-confirmed-deletion-fences") { db in
            try db.execute(sql: """
                CREATE TABLE cloud_confirmed_deletions (
                    account_identity_hash TEXT NOT NULL,
                    record_name TEXT NOT NULL,
                    PRIMARY KEY(account_identity_hash, record_name)
                )
                """)
        }
        return migrator
    }
}

public enum MajorTomDatabaseError: Error, Equatable, Sendable {
    case integrityCheckFailed(String)
    case foreignKeyCheckFailed(Int)
}
