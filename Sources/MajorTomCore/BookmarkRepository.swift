import Foundation
import GRDB

/// Row-level bookmark persistence. The repository diffs a collection against SQLite so a
/// title edit, reorder, or favicon refresh updates only the affected rows.
public struct BookmarkRepository: Sendable {
    private struct FolderRow: Equatable {
        let id: UUID
        let name: String
        let position: Int
    }

    private struct BookmarkRow: Equatable {
        let id: UUID
        let folderID: UUID
        let title: String
        let url: URL
        let addedAt: Date
        let position: Int
        let favicon: BookmarkFaviconSnapshot?

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.id == rhs.id
                && lhs.folderID == rhs.folderID
                && lhs.title == rhs.title
                && lhs.url == rhs.url
                && abs(lhs.addedAt.timeIntervalSince(rhs.addedAt)) < 0.001
                && lhs.position == rhs.position
                && lhs.favicon?.emoji == rhs.favicon?.emoji
                && datesEqual(lhs.favicon?.fetchedAt, rhs.favicon?.fetchedAt)
        }

        private static func datesEqual(_ lhs: Date?, _ rhs: Date?) -> Bool {
            switch (lhs, rhs) {
            case (nil, nil): true
            case (.some(let lhs), .some(let rhs)):
                abs(lhs.timeIntervalSince(rhs)) < 0.001
            default: false
            }
        }
    }

    private let database: MajorTomDatabase

    public init(database: MajorTomDatabase) {
        self.database = database
    }

    public func collection() throws -> BookmarkCollection {
        try database.read(Self.fetchCollection)
    }

    public func replace(with collection: BookmarkCollection) throws {
        try database.write { db in try Self.apply(collection, in: db) }
    }

    /// Imports the old JSON document once. The marker is committed in the same SQLite
    /// transaction as the rows, making a crash before JSON removal safe to retry.
    public func importLegacyCollection(_ collection: BookmarkCollection) throws {
        try database.write { db in
            let marker = "legacy-bookmarks-json-v1-imported"
            let imported = try Bool.fetchOne(
                db,
                sql: "SELECT EXISTS(SELECT 1 FROM persistence_metadata WHERE key = ?)",
                arguments: [marker]
            ) ?? false
            guard !imported else { return }

            let existingCount = try Int.fetchOne(
                db,
                sql: """
                    SELECT
                        (SELECT COUNT(*) FROM bookmark_folders) +
                        (SELECT COUNT(*) FROM bookmarks)
                    """
            ) ?? 0
            if existingCount == 0 {
                try Self.apply(collection, in: db)
            }
            try db.execute(
                sql: """
                    INSERT INTO persistence_metadata (key, value, updated_at)
                    VALUES (?, ?, ?)
                    """,
                arguments: [marker, Data(), Date()]
            )
        }
    }

    private static func fetchCollection(_ db: Database) throws -> BookmarkCollection {
        let folders = try folderRows(in: db).sorted { $0.position < $1.position }
        let bookmarks = try bookmarkRows(in: db)
        let byFolder = Dictionary(grouping: bookmarks, by: \BookmarkRow.folderID)
        return BookmarkCollection(folders: folders.map { folder in
            BookmarkFolder(
                id: folder.id,
                name: folder.name,
                bookmarks: (byFolder[folder.id] ?? [])
                    .sorted { $0.position < $1.position }
                    .map {
                        Bookmark(
                            id: $0.id,
                            title: $0.title,
                            url: $0.url,
                            addedAt: $0.addedAt,
                            favicon: $0.favicon
                        )
                    }
            )
        })
    }

    private static func apply(_ collection: BookmarkCollection, in db: Database) throws {
        let oldFolders = Dictionary(uniqueKeysWithValues: try folderRows(in: db).map { ($0.id, $0) })
        let oldBookmarks = Dictionary(uniqueKeysWithValues: try bookmarkRows(in: db).map { ($0.id, $0) })
        let newFolders = collection.folders.enumerated().map {
            FolderRow(id: $0.element.id, name: $0.element.name, position: $0.offset)
        }
        let newBookmarks = collection.folders.flatMap { folder in
            folder.bookmarks.enumerated().map {
                BookmarkRow(
                    id: $0.element.id,
                    folderID: folder.id,
                    title: $0.element.title,
                    url: $0.element.url,
                    addedAt: $0.element.addedAt,
                    position: $0.offset,
                    favicon: $0.element.favicon
                )
            }
        }

        let newBookmarkIDs = Set(newBookmarks.map(\.id))
        for id in oldBookmarks.keys where !newBookmarkIDs.contains(id) {
            try db.execute(sql: "DELETE FROM bookmarks WHERE id = ?", arguments: [id.uuidString])
        }

        for row in newFolders where oldFolders[row.id] != row {
            try db.execute(
                sql: """
                    INSERT INTO bookmark_folders (id, name, position) VALUES (?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET
                        name = excluded.name,
                        position = excluded.position
                    """,
                arguments: [row.id.uuidString, row.name, row.position]
            )
        }

        for row in newBookmarks where oldBookmarks[row.id] != row {
            let state: Int? = row.favicon.map { $0.emoji == nil ? 0 : 1 }
            try db.execute(
                sql: """
                    INSERT INTO bookmarks
                        (id, folder_id, title, url, added_at, position,
                         favicon_state, favicon_emoji, favicon_fetched_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET
                        folder_id = excluded.folder_id,
                        title = excluded.title,
                        url = excluded.url,
                        added_at = excluded.added_at,
                        position = excluded.position,
                        favicon_state = excluded.favicon_state,
                        favicon_emoji = excluded.favicon_emoji,
                        favicon_fetched_at = excluded.favicon_fetched_at
                    """,
                arguments: [
                    row.id.uuidString,
                    row.folderID.uuidString,
                    row.title,
                    row.url.absoluteString,
                    row.addedAt,
                    row.position,
                    state,
                    row.favicon?.emoji,
                    row.favicon?.fetchedAt
                ]
            )
        }

        let newFolderIDs = Set(newFolders.map(\.id))
        for id in oldFolders.keys where !newFolderIDs.contains(id) {
            try db.execute(
                sql: "DELETE FROM bookmark_folders WHERE id = ?",
                arguments: [id.uuidString]
            )
        }
    }

    private static func folderRows(in db: Database) throws -> [FolderRow] {
        try Row.fetchAll(
            db,
            sql: "SELECT id, name, position FROM bookmark_folders"
        ).compactMap { row in
            guard let id = UUID(uuidString: row["id"]) else { return nil }
            return FolderRow(id: id, name: row["name"], position: row["position"])
        }
    }

    private static func bookmarkRows(in db: Database) throws -> [BookmarkRow] {
        try Row.fetchAll(
            db,
            sql: """
                SELECT id, folder_id, title, url, added_at, position,
                       favicon_state, favicon_emoji, favicon_fetched_at
                FROM bookmarks
                """
        ).compactMap { row in
            guard let id = UUID(uuidString: row["id"]),
                  let folderID = UUID(uuidString: row["folder_id"]),
                  let url = URL(string: row["url"]) else { return nil }
            let state: Int? = row["favicon_state"]
            let fetchedAt: Date? = row["favicon_fetched_at"]
            let favicon = state.flatMap { state in
                fetchedAt.map {
                    BookmarkFaviconSnapshot(
                        emoji: state == 1 ? row["favicon_emoji"] : nil,
                        fetchedAt: $0
                    )
                }
            }
            return BookmarkRow(
                id: id,
                folderID: folderID,
                title: row["title"],
                url: url,
                addedAt: row["added_at"],
                position: row["position"],
                favicon: favicon
            )
        }
    }
}
