import Foundation
import GRDB

/// The standalone SQLite file that owns window, tab, and Back/Forward snapshots.
public final class BackForwardCacheDatabase: @unchecked Sendable {
    public static let filename = "BFCache.db"

    private let writer: any DatabaseWriter
    private let fileURL: URL?

    public init(fileURL: URL) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        var configuration = Configuration()
        configuration.label = "Major Tom Back Forward"
        configuration.busyMode = .timeout(5)
        configuration.prepareDatabase { database in
            try database.execute(sql: "PRAGMA foreign_keys = ON")
            try database.execute(sql: "PRAGMA synchronous = NORMAL")
        }
        let pool = try DatabasePool(path: fileURL.path, configuration: configuration)
        try Self.migrator.migrate(pool)
        writer = pool
        self.fileURL = fileURL
    }

    public init(inMemory: Void) throws {
        var configuration = Configuration()
        configuration.label = "Major Tom Back Forward (in memory)"
        configuration.prepareDatabase { database in
            try database.execute(sql: "PRAGMA foreign_keys = ON")
        }
        let queue = try DatabaseQueue(configuration: configuration)
        try Self.migrator.migrate(queue)
        writer = queue
        fileURL = nil
    }

    public static func defaultFileURL(fileManager: FileManager = .default) throws -> URL {
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

    public func read<Value>(_ body: (Database) throws -> Value) throws -> Value {
        try writer.read(body)
    }

    public func write<Value>(_ body: (Database) throws -> Value) throws -> Value {
        try writer.write(body)
    }

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
        migrator.registerMigration("v1-back-forward") { database in
            try database.create(table: "browser_session") { table in
                table.column("singleton", .integer).primaryKey().check { $0 == 1 }
                table.column("key_window_index", .integer).notNull()
                table.column("updated_at", .datetime).notNull()
            }
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
                table.uniqueKey(["window_id", "position"])
            }
            try database.create(table: "browser_tab_history") { table in
                table.column("id", .text).primaryKey()
                // Entries can be written while a live tab has not yet been included in
                // the coalesced window-session snapshot.
                table.column("tab_id", .text).notNull()
                table.column("position", .integer).notNull()
                table.column("url", .text).notNull()
                table.column("title", .text)
                table.column("favicon", .text)
                table.column("response_status", .integer)
                table.column("response_meta", .text)
                table.column("response_body", .blob)
                table.column("completion", .text)
                table.column("received_at", .datetime)
                table.column("client_certificate_id", .text)
                table.column("presentation_state", .blob).notNull()
                table.uniqueKey(["tab_id", "position"])
            }
            try database.create(
                index: "browser_tab_history_order",
                on: "browser_tab_history",
                columns: ["tab_id", "position"]
            )
        }
        return migrator
    }
}

/// Serializes incremental snapshot reads and writes away from the UI actor.
public actor BackForwardCacheStore {
    private let database: BackForwardCacheDatabase

    public init(database: BackForwardCacheDatabase) {
        self.database = database
    }

    public func save(_ entry: BackForwardEntry, tabID: UUID, position: Int) throws {
        let state = try JSONEncoder().encode(entry.presentation)
        let page = entry.page?.clientCertificateID == nil ? entry.page : nil
        try database.write { db in
            try db.execute(
                sql: "DELETE FROM browser_tab_history WHERE tab_id = ? AND position = ? AND id <> ?",
                arguments: [tabID.uuidString.lowercased(), position, entry.id.uuidString.lowercased()]
            )
            try db.execute(
                sql: """
                    INSERT INTO browser_tab_history (
                        id, tab_id, position, url, title, favicon,
                        response_status, response_meta, response_body, completion,
                        received_at, client_certificate_id, presentation_state
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET
                        tab_id = excluded.tab_id,
                        position = excluded.position,
                        url = excluded.url,
                        title = excluded.title,
                        favicon = excluded.favicon,
                        response_status = COALESCE(excluded.response_status, response_status),
                        response_meta = COALESCE(excluded.response_meta, response_meta),
                        response_body = COALESCE(excluded.response_body, response_body),
                        completion = COALESCE(excluded.completion, completion),
                        received_at = COALESCE(excluded.received_at, received_at),
                        client_certificate_id = COALESCE(excluded.client_certificate_id, client_certificate_id),
                        presentation_state = excluded.presentation_state
                    """,
                arguments: Self.arguments(entry, page: page, tabID: tabID, position: position, state: state)
            )
        }
    }

    public func entry(id: UUID) throws -> BackForwardEntry? {
        try database.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT * FROM browser_tab_history WHERE id = ?",
                arguments: [id.uuidString.lowercased()]
            ) else { return nil }
            return Self.entry(row)
        }
    }

    public func removeResponse(id: UUID) throws {
        try database.write { db in
            try db.execute(
                sql: """
                    UPDATE browser_tab_history
                    SET response_status = NULL, response_meta = NULL, response_body = NULL,
                        completion = NULL, received_at = NULL, client_certificate_id = NULL
                    WHERE id = ?
                    """,
                arguments: [id.uuidString.lowercased()]
            )
        }
    }

    private static func arguments(
        _ entry: BackForwardEntry,
        page: CachedPage?,
        tabID: UUID,
        position: Int,
        state: Data
    ) -> StatementArguments {
        StatementArguments([
            entry.id.uuidString.lowercased(), tabID.uuidString.lowercased(), position,
            entry.url.absoluteString, entry.title, entry.favicon,
            page?.responseStatus, page.map { page in
                page.responseMeta.flatMap { $0.isEmpty ? nil : $0 } ?? page.mimeType
            }, page?.body,
            page?.completion.rawValue, page?.receivedAt,
            page?.clientCertificateID?.uuidString.lowercased(), state
        ])
    }

    static func entry(_ row: Row, includePage: Bool = true) -> BackForwardEntry? {
        guard let id = UUID(uuidString: row["id"]),
              let url = URL(string: row["url"]),
              let stateData: Data = row["presentation_state"],
              let state = try? JSONDecoder().decode(HistoryPresentationState.self, from: stateData) else {
            return nil
        }
        let status: Int? = row["response_status"]
        let meta: String? = row["response_meta"]
        let body: Data? = includePage ? row["response_body"] : nil
        let completionString: String? = row["completion"]
        let receivedAt: Date? = row["received_at"]
        let certificate: UUID? = (row["client_certificate_id"] as String?).flatMap(UUID.init(uuidString:))
        let page: CachedPage?
        if let body, let completionString,
           let completion = PageCompletionState(rawValue: completionString), let receivedAt {
            let mimeType = meta?.split(separator: ";", maxSplits: 1).first
                .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines).lowercased() } ?? ""
            page = CachedPage(
                url: url, mimeType: mimeType, body: body, completion: completion,
                receivedAt: receivedAt, title: row["title"], documentTitle: row["title"],
                responseStatus: status, responseMeta: meta, clientCertificateID: certificate
            )
        } else {
            page = nil
        }
        return BackForwardEntry(
            id: id, url: url, title: row["title"], favicon: row["favicon"],
            page: page, presentation: state
        )
    }
}
