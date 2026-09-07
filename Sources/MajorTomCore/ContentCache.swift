import Foundation
import GRDB

/// A complete protocol response suitable for replay through a protocol's normal
/// response-handling pipeline.
public struct ContentResponse: Equatable, Sendable {
    public var url: URL
    public var status: Int?
    public var meta: Data
    public var mimeType: String?
    public var body: Data
    public var receivedAt: Date

    public init(
        url: URL,
        status: Int?,
        meta: Data,
        mimeType: String?,
        body: Data,
        receivedAt: Date
    ) {
        self.url = url
        self.status = status
        self.meta = meta
        self.mimeType = mimeType
        self.body = body
        self.receivedAt = receivedAt
    }
}

/// Why Major Tom retained a response. This is management metadata rather than
/// part of the cache key: one URL always identifies at most one response.
public enum ResourceType: String, Equatable, Sendable {
    case favicon
    case image
}

public enum ContentCacheStoreResult: Equatable, Sendable {
    case stored
    case tooLarge
}

/// The standalone SQLite file containing reusable network responses.
public final class ContentCacheDatabase: @unchecked Sendable {
    public static let filename = "ContentCache.db"

    private let writer: any DatabaseWriter
    private let fileURL: URL?

    public init(fileURL: URL) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        var configuration = Configuration()
        configuration.label = "Major Tom Content Cache"
        configuration.busyMode = .timeout(5)
        configuration.prepareDatabase { database in
            try database.execute(sql: "PRAGMA synchronous = NORMAL")
        }
        let pool = try DatabasePool(path: fileURL.path, configuration: configuration)
        try Self.migrator.migrate(pool)
        writer = pool
        self.fileURL = fileURL
    }

    public init(inMemory: Void) throws {
        var configuration = Configuration()
        configuration.label = "Major Tom Content Cache (in memory)"
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
        }
    }

    /// Call after the content-cache actor has finished all queued operations.
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
        migrator.registerMigration("v1-content-cache") { database in
            try database.create(table: "content_cache") { table in
                table.column("url", .text).primaryKey()
                table.column("resource_type", .text).notNull()
                table.column("status", .integer)
                table.column("meta", .blob).notNull()
                table.column("mime_type", .text)
                table.column("body", .blob).notNull()
                table.column("received_at", .datetime).notNull()
                table.column("stored_at", .datetime).notNull()
                table.column("expires_at", .datetime).notNull()
                table.column("last_accessed_at", .datetime).notNull()
            }
            try database.create(
                index: "content_cache_resource_type",
                on: "content_cache",
                columns: ["resource_type"]
            )
            try database.create(
                index: "content_cache_expiration",
                on: "content_cache",
                columns: ["expires_at"]
            )
            try database.create(
                index: "content_cache_last_accessed",
                on: "content_cache",
                columns: ["last_accessed_at"]
            )
        }
        return migrator
    }
}

/// A passive, URL-addressed store. It never performs retrieval or decides what
/// should be cached.
public actor ContentCache {
    public static let maximumEntryBytes = 16 * 1_024 * 1_024
    public static let maximumTotalBytes = 256 * 1_024 * 1_024

    private let database: ContentCacheDatabase
    private let maximumEntryBytes: Int
    private let maximumTotalBytes: Int

    public init(
        database: ContentCacheDatabase,
        maximumEntryBytes: Int = ContentCache.maximumEntryBytes,
        maximumTotalBytes: Int = ContentCache.maximumTotalBytes
    ) {
        self.database = database
        self.maximumEntryBytes = maximumEntryBytes
        self.maximumTotalBytes = maximumTotalBytes
    }

    /// Returns and touches a response only while its fixed lifetime remains fresh.
    /// An expired response is deleted rather than exposed to callers.
    public func freshResponse(for url: URL, now: Date = Date()) throws -> ContentResponse? {
        let key = Self.key(for: url)
        return try database.write { db in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT * FROM content_cache WHERE url = ?",
                arguments: [key]
            ) else { return nil }
            let expiresAt: Date = row["expires_at"]
            guard expiresAt > now else {
                try db.execute(sql: "DELETE FROM content_cache WHERE url = ?", arguments: [key])
                return nil
            }
            guard let response = Self.response(from: row) else {
                try db.execute(sql: "DELETE FROM content_cache WHERE url = ?", arguments: [key])
                return nil
            }
            try db.execute(
                sql: "UPDATE content_cache SET last_accessed_at = ? WHERE url = ?",
                arguments: [now, key]
            )
            return response
        }
    }

    @discardableResult
    public func store(
        _ response: ContentResponse,
        resourceType: ResourceType,
        lifetime: TimeInterval,
        now: Date = Date()
    ) throws -> ContentCacheStoreResult {
        let key = Self.key(for: response.url)
        guard response.body.count <= maximumEntryBytes else {
            try database.write {
                try $0.execute(sql: "DELETE FROM content_cache WHERE url = ?", arguments: [key])
            }
            return .tooLarge
        }
        let expiresAt = response.receivedAt.addingTimeInterval(max(0, lifetime))
        try database.write { db in
            try db.execute(
                sql: """
                    INSERT INTO content_cache (
                        url, resource_type, status, meta, mime_type, body,
                        received_at, stored_at, expires_at, last_accessed_at
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(url) DO UPDATE SET
                        resource_type = excluded.resource_type,
                        status = excluded.status,
                        meta = excluded.meta,
                        mime_type = excluded.mime_type,
                        body = excluded.body,
                        received_at = excluded.received_at,
                        stored_at = excluded.stored_at,
                        expires_at = excluded.expires_at,
                        last_accessed_at = excluded.last_accessed_at
                    """,
                arguments: [
                    key, resourceType.rawValue, response.status, response.meta,
                    response.mimeType, response.body, response.receivedAt, now, expiresAt, now
                ]
            )
            try Self.prune(
                db,
                now: now,
                maximumTotalBytes: maximumTotalBytes
            )
        }
        return .stored
    }

    public func removeResponse(for url: URL) throws {
        try database.write {
            try $0.execute(
                sql: "DELETE FROM content_cache WHERE url = ?",
                arguments: [Self.key(for: url)]
            )
        }
    }

    public func removeAll(ofType resourceType: ResourceType) throws {
        try database.write {
            try $0.execute(
                sql: "DELETE FROM content_cache WHERE resource_type = ?",
                arguments: [resourceType.rawValue]
            )
        }
    }

    /// Used by non-fetching surfaces such as Favorites to display only favicon
    /// responses that browsing has already discovered.
    public func freshResponses(
        ofType resourceType: ResourceType,
        now: Date = Date()
    ) throws -> [ContentResponse] {
        try database.write { db in
            try db.execute(
                sql: "DELETE FROM content_cache WHERE expires_at <= ?",
                arguments: [now]
            )
            return try Row.fetchAll(
                db,
                sql: "SELECT * FROM content_cache WHERE resource_type = ? ORDER BY url",
                arguments: [resourceType.rawValue]
            ).compactMap(Self.response(from:))
        }
    }

    public func performMaintenance(now: Date = Date()) throws {
        try database.write {
            try Self.prune($0, now: now, maximumTotalBytes: maximumTotalBytes)
        }
    }

    private static func response(from row: Row) -> ContentResponse? {
        guard let url = URL(string: row["url"]),
              let meta: Data = row["meta"],
              let body: Data = row["body"],
              let receivedAt: Date = row["received_at"] else { return nil }
        return ContentResponse(
            url: url,
            status: row["status"],
            meta: meta,
            mimeType: row["mime_type"],
            body: body,
            receivedAt: receivedAt
        )
    }

    private static func prune(
        _ db: Database,
        now: Date,
        maximumTotalBytes: Int
    ) throws {
        try db.execute(sql: "DELETE FROM content_cache WHERE expires_at <= ?", arguments: [now])
        var total = try Int.fetchOne(
            db,
            sql: "SELECT COALESCE(SUM(length(body)), 0) FROM content_cache"
        ) ?? 0
        guard total > maximumTotalBytes else { return }
        let rows = try Row.fetchAll(
            db,
            sql: "SELECT url, length(body) AS body_size FROM content_cache ORDER BY last_accessed_at, url"
        )
        for row in rows where total > maximumTotalBytes {
            let url: String = row["url"]
            let size: Int = row["body_size"]
            try db.execute(sql: "DELETE FROM content_cache WHERE url = ?", arguments: [url])
            total -= size
        }
    }

    private static func key(for url: URL) -> String {
        guard var components = URLComponents(
            url: url.absoluteURL,
            resolvingAgainstBaseURL: true
        ) else { return url.absoluteURL.absoluteString }
        components.fragment = nil
        return components.url?.absoluteString ?? url.absoluteURL.absoluteString
    }
}
