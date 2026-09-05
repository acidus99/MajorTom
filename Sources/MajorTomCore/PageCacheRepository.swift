import Foundation
import GRDB

public enum PageCacheStoreResult: Equatable, Sendable {
    case stored
    case tooLarge
}

public struct PageCacheSearchResult: Equatable, Sendable {
    public let url: URL
    public let title: String?

    public init(url: URL, title: String?) {
        self.url = url
        self.title = title
    }
}

/// The local, cross-tab response cache. Cached source bytes never leave this database.
public struct PageCacheRepository: Sendable {
    public static let maximumAge: TimeInterval = 120 * 24 * 60 * 60
    public static let maximumTotalBytes = 1_024 * 1_024 * 1_024
    public static let maximumEntryBytes = 32 * 1_024 * 1_024

    private let database: MajorTomDatabase
    private let maximumAge: TimeInterval
    private let maximumTotalBytes: Int
    private let maximumEntryBytes: Int

    public init(
        database: MajorTomDatabase,
        maximumAge: TimeInterval = PageCacheRepository.maximumAge,
        maximumTotalBytes: Int = PageCacheRepository.maximumTotalBytes,
        maximumEntryBytes: Int = PageCacheRepository.maximumEntryBytes
    ) {
        self.database = database
        self.maximumAge = maximumAge
        self.maximumTotalBytes = maximumTotalBytes
        self.maximumEntryBytes = maximumEntryBytes
    }

    @discardableResult
    public func store(_ page: CachedPage, accessedAt: Date = Date()) throws -> PageCacheStoreResult {
        guard page.body.count <= maximumEntryBytes else {
            try remove(page.url)
            return .tooLarge
        }

        try database.write { db in
            try db.execute(
                sql: """
                    INSERT INTO page_cache (
                        url, mime_type, body, body_size, completion, received_at,
                        last_accessed_at, title, document_title, response_status,
                        response_meta, client_certificate_id
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(url) DO UPDATE SET
                        mime_type = excluded.mime_type,
                        body = excluded.body,
                        body_size = excluded.body_size,
                        completion = excluded.completion,
                        received_at = excluded.received_at,
                        last_accessed_at = excluded.last_accessed_at,
                        title = excluded.title,
                        document_title = excluded.document_title,
                        response_status = excluded.response_status,
                        response_meta = excluded.response_meta,
                        client_certificate_id = excluded.client_certificate_id
                    """,
                arguments: [
                    page.url.absoluteString,
                    page.mimeType,
                    page.body,
                    page.body.count,
                    page.completion.rawValue,
                    page.receivedAt,
                    accessedAt,
                    page.title,
                    page.documentTitle,
                    page.responseStatus,
                    page.responseMeta,
                    page.clientCertificateID?.uuidString
                ]
            )
            try Self.replaceSearchDocument(for: page, in: db)
            try prune(in: db, now: accessedAt)
        }
        return .stored
    }

    /// Fetches and touches one cached representation, making reads participate in LRU.
    public func page(for url: URL, accessedAt: Date = Date()) throws -> CachedPage? {
        try database.write { db in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT * FROM page_cache WHERE url = ?",
                arguments: [url.absoluteString]
            ), let page = Self.page(row) else { return nil }
            try db.execute(
                sql: "UPDATE page_cache SET last_accessed_at = ? WHERE url = ?",
                arguments: [accessedAt, url.absoluteString]
            )
            return page
        }
    }

    public func touch(_ url: URL, accessedAt: Date = Date()) throws {
        try database.write { db in
            try db.execute(
                sql: "UPDATE page_cache SET last_accessed_at = ? WHERE url = ?",
                arguments: [accessedAt, url.absoluteString]
            )
        }
    }

    /// Hydrates session Back/Forward lists in one database operation.
    public func pages(for urls: Set<URL>, accessedAt: Date = Date()) throws -> [URL: CachedPage] {
        guard !urls.isEmpty else { return [:] }
        return try database.write { db in
            let strings = urls.map(\.absoluteString)
            let placeholders = databaseQuestionMarks(count: strings.count)
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT * FROM page_cache WHERE url IN (\(placeholders))",
                arguments: StatementArguments(strings)
            )
            try db.execute(
                sql: "UPDATE page_cache SET last_accessed_at = ? WHERE url IN (\(placeholders))",
                arguments: StatementArguments([accessedAt] + strings)
            )
            return Dictionary(
                rows.compactMap { row in Self.page(row).map { ($0.url, $0) } },
                uniquingKeysWith: { first, _ in first }
            )
        }
    }

    public func search(_ query: String, limit: Int = 20) throws -> [PageCacheSearchResult] {
        let terms = query.split(whereSeparator: \.isWhitespace)
        guard !terms.isEmpty, limit > 0 else { return [] }
        let expression = terms.map {
            "\"\($0.replacingOccurrences(of: "\"", with: "\"\""))\"*"
        }.joined(separator: " ")
        return try database.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT url, title
                    FROM page_cache_fts
                    WHERE page_cache_fts MATCH ?
                    ORDER BY rank
                    LIMIT ?
                    """,
                arguments: [expression, limit]
            ).compactMap { row in
                guard let url = URL(string: row["url"]) else { return nil }
                return PageCacheSearchResult(url: url, title: row["title"])
            }
        }
    }

    public func performMaintenance(now: Date = Date()) throws {
        try database.write { try prune(in: $0, now: now) }
    }

    public func remove(_ url: URL) throws {
        try database.write { db in
            try Self.remove(url.absoluteString, in: db)
        }
    }

    public func clear() throws {
        try database.write { db in
            try db.execute(sql: "DELETE FROM page_cache")
            try db.execute(sql: "DELETE FROM page_cache_fts")
        }
    }

    private func prune(in db: Database, now: Date) throws {
        let expired = try String.fetchAll(
            db,
            sql: "SELECT url FROM page_cache WHERE received_at < ?",
            arguments: [now.addingTimeInterval(-maximumAge)]
        )
        for url in expired { try Self.remove(url, in: db) }

        var total = try Int.fetchOne(db, sql: "SELECT COALESCE(SUM(body_size), 0) FROM page_cache") ?? 0
        guard total > maximumTotalBytes else { return }
        let candidates = try Row.fetchAll(
            db,
            sql: "SELECT url, body_size FROM page_cache ORDER BY last_accessed_at ASC, url ASC"
        )
        for row in candidates where total > maximumTotalBytes {
            let url: String = row["url"]
            let size: Int = row["body_size"]
            try Self.remove(url, in: db)
            total -= size
        }
    }

    private static func replaceSearchDocument(for page: CachedPage, in db: Database) throws {
        try db.execute(sql: "DELETE FROM page_cache_fts WHERE url = ?", arguments: [page.url.absoluteString])
        guard page.mimeType.hasPrefix("text/"),
              let content = String(data: page.body, encoding: .utf8) else { return }
        try db.execute(
            sql: "INSERT INTO page_cache_fts (url, title, content) VALUES (?, ?, ?)",
            arguments: [page.url.absoluteString, page.documentTitle ?? page.title, content]
        )
    }

    private static func remove(_ url: String, in db: Database) throws {
        try db.execute(sql: "DELETE FROM page_cache WHERE url = ?", arguments: [url])
        try db.execute(sql: "DELETE FROM page_cache_fts WHERE url = ?", arguments: [url])
    }

    private static func page(_ row: Row) -> CachedPage? {
        guard let url = URL(string: row["url"]),
              let completion = PageCompletionState(rawValue: row["completion"]) else { return nil }
        let certificate: UUID? = (row["client_certificate_id"] as String?).flatMap(UUID.init(uuidString:))
        return CachedPage(
            url: url,
            mimeType: row["mime_type"],
            body: row["body"],
            completion: completion,
            receivedAt: row["received_at"],
            title: row["title"],
            documentTitle: row["document_title"],
            responseStatus: row["response_status"],
            responseMeta: row["response_meta"],
            clientCertificateID: certificate
        )
    }
}

private func databaseQuestionMarks(count: Int) -> String {
    Array(repeating: "?", count: count).joined(separator: ",")
}
