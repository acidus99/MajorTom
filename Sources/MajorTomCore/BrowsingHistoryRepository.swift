import Foundation
import GRDB

public struct BrowsingHistoryEntry: Codable, Equatable, Identifiable, Sendable {
    public var id: String { url.absoluteString }
    public var urlString: String { url.absoluteString }
    public let url: URL
    public let title: String
    public let visitedAt: Date
    public let visitCount: Int

    public init(url: URL, title: String? = nil, visitedAt: Date, visitCount: Int) {
        self.url = url
        self.title = title?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            ?? url.absoluteString
        self.visitedAt = visitedAt
        self.visitCount = visitCount
    }
}

/// Local-only, URL-keyed global browsing history.
///
/// Re-visiting an address moves its one row to the top and increments its count. This is
/// intentionally independent of a tab's Back/Forward list and is never a CloudKit source.
public struct BrowsingHistoryRepository: Sendable {
    public static let retention: TimeInterval = 365 * 24 * 60 * 60

    private let database: MajorTomDatabase

    public init(database: MajorTomDatabase) {
        self.database = database
    }

    public func record(_ url: URL, title: String? = nil, at date: Date = Date()) throws {
        try database.write { db in
            try Self.upsert(url: url, title: title, visitedAt: date, visitCount: 1, in: db)
            try Self.prune(before: date.addingTimeInterval(-Self.retention), in: db)
        }
    }

    public func entries() throws -> [BrowsingHistoryEntry] {
        try database.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT url, title, visited_at, visit_count
                    FROM history_entries
                    ORDER BY visited_at DESC, url ASC
                    """
            ).compactMap(Self.entry)
        }
    }

    /// Imports a legacy append-only history without manufacturing duplicate URL rows.
    public func importLegacyVisits(_ visits: [(url: URL, visitedAt: Date)]) throws {
        guard !visits.isEmpty else { return }
        try database.write { db in
            let marker = "legacy-browsing-history-v1-imported"
            let wasImported = try Bool.fetchOne(
                db,
                sql: "SELECT EXISTS(SELECT 1 FROM persistence_metadata WHERE key = ?)",
                arguments: [marker]
            ) ?? false
            guard !wasImported else { return }

            let grouped = Dictionary(grouping: visits, by: { $0.url.absoluteString })
            for group in grouped.values {
                guard let latest = group.max(by: { $0.visitedAt < $1.visitedAt }) else { continue }
                try Self.upsert(
                    url: latest.url,
                    visitedAt: latest.visitedAt,
                    visitCount: group.count,
                    in: db
                )
            }
            try Self.prune(before: Date().addingTimeInterval(-Self.retention), in: db)
            try db.execute(
                sql: """
                    INSERT INTO persistence_metadata (key, value, updated_at)
                    VALUES (?, ?, ?)
                    """,
                arguments: [marker, Data(), Date()]
            )
        }
    }

    public func clear() throws {
        try database.write { db in
            try db.execute(sql: "DELETE FROM history_entries")
        }
    }

    public func remove(urls: Set<URL>) throws {
        guard !urls.isEmpty else { return }
        try database.write { db in
            for url in urls {
                try db.execute(
                    sql: "DELETE FROM history_entries WHERE url = ?",
                    arguments: [url.absoluteString]
                )
            }
        }
    }

    private static func upsert(
        url: URL,
        title: String? = nil,
        visitedAt: Date,
        visitCount: Int,
        in db: Database
    ) throws {
        try db.execute(
            sql: """
                INSERT INTO history_entries (url, title, visited_at, visit_count)
                VALUES (?, ?, ?, ?)
                ON CONFLICT(url) DO UPDATE SET
                    visited_at = MAX(history_entries.visited_at, excluded.visited_at),
                    visit_count = history_entries.visit_count + excluded.visit_count,
                    title = CASE
                        WHEN excluded.title = '' THEN history_entries.title
                        ELSE excluded.title
                    END
                """,
            arguments: [
                url.absoluteString,
                title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
                visitedAt,
                visitCount
            ]
        )
    }

    private static func prune(before cutoff: Date, in db: Database) throws {
        try db.execute(
            sql: "DELETE FROM history_entries WHERE visited_at < ?",
            arguments: [cutoff]
        )
    }

    private static func entry(_ row: Row) -> BrowsingHistoryEntry? {
        guard let url = URL(string: row["url"]) else { return nil }
        return BrowsingHistoryEntry(
            url: url,
            title: row["title"],
            visitedAt: row["visited_at"],
            visitCount: row["visit_count"]
        )
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
