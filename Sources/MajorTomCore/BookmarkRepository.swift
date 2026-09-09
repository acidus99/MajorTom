import Foundation
import GRDB

public struct CloudBookmarkFolderPayload: CloudSyncPayload, Equatable, Sendable {
    public static let payloadSchemaVersion = 1
    public static let knownPayloadKeys: Set<String> = ["id", "name", "orderKey"]
    public var id: UUID
    public var name: String
    public var orderKey: String
}

public struct CloudBookmarkPayload: CloudSyncPayload, Equatable, Sendable {
    public static let payloadSchemaVersion = 1
    public static let knownPayloadKeys: Set<String> = [
        "id", "title", "url", "addedAt", "folderID", "orderKey", "favicon"
    ]
    public var id: UUID
    public var title: String
    public var url: URL
    public var addedAt: Date
    public var folderID: UUID
    public var orderKey: String
    public var favicon: BookmarkFaviconSnapshot?
}

/// Row-level bookmark persistence with account isolation and an atomic CloudKit outbox.
public struct BookmarkRepository: Sendable {
    public static let folderRecordType = "MTBookmarkFolder"
    public static let bookmarkRecordType = "MTBookmark"

    private struct FolderRow: Equatable {
        let id: UUID
        let name: String
        let orderKey: String
    }

    private struct BookmarkRow: Equatable {
        let id: UUID
        let folderID: UUID
        let title: String
        let url: URL
        let addedAt: Date
        let orderKey: String
        let favicon: BookmarkFaviconSnapshot?

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.id == rhs.id
                && lhs.folderID == rhs.folderID
                && lhs.title == rhs.title
                && lhs.url == rhs.url
                && abs(lhs.addedAt.timeIntervalSince(rhs.addedAt)) < 0.001
                && lhs.orderKey == rhs.orderKey
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
    private let accountIdentityHash: String?
    private let cloud: CloudSyncRepository

    public init(database: MajorTomDatabase, accountIdentityHash: String? = nil) {
        self.database = database
        self.accountIdentityHash = accountIdentityHash
        cloud = CloudSyncRepository(database: database)
    }

    public func collection() throws -> BookmarkCollection {
        try database.read { db in try Self.fetchCollection(db, account: accountIdentityHash) }
    }

    public func replace(with collection: BookmarkCollection) throws {
        try database.write { db in
            try Self.apply(collection, account: accountIdentityHash, cloud: cloud,
                           enqueueChanges: accountIdentityHash != nil, in: db)
        }
    }

    /// Replaces an account's cache without creating echo uploads for fetched records.
    public func replaceFromCloud(with collection: BookmarkCollection) throws {
        try database.write { db in
            try Self.apply(collection, account: accountIdentityHash, cloud: cloud,
                           enqueueChanges: false, in: db)
        }
    }

    /// Claims pre-account rows for the first signed-in account without copying them.
    public func claimUnownedRows() throws {
        guard let accountIdentityHash else { return }
        try database.write { db in
            try db.execute(
                sql: "UPDATE bookmark_folders SET account_identity_hash = ? WHERE account_identity_hash IS NULL",
                arguments: [accountIdentityHash]
            )
            try db.execute(
                sql: "UPDATE bookmarks SET account_identity_hash = ? WHERE account_identity_hash IS NULL",
                arguments: [accountIdentityHash]
            )
        }
    }

    /// Imports the old JSON document once. The marker and rows share one transaction.
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
                        (SELECT COUNT(*) FROM bookmark_folders WHERE account_identity_hash IS ?) +
                        (SELECT COUNT(*) FROM bookmarks WHERE account_identity_hash IS ?)
                    """,
                arguments: [accountIdentityHash, accountIdentityHash]
            ) ?? 0
            if existingCount == 0 {
                try Self.apply(collection, account: accountIdentityHash, cloud: cloud,
                               enqueueChanges: false, in: db)
            }
            try db.execute(
                sql: "INSERT INTO persistence_metadata (key, value, updated_at) VALUES (?, ?, ?)",
                arguments: [marker, Data(), Date()]
            )
        }
    }

    public func folderPayload(id: UUID) throws -> CloudBookmarkFolderPayload? {
        try database.read { db in
            try Self.folderRows(in: db, account: accountIdentityHash).first { $0.id == id }.map {
                CloudBookmarkFolderPayload(id: $0.id, name: $0.name, orderKey: $0.orderKey)
            }
        }
    }

    public func bookmarkPayload(id: UUID) throws -> CloudBookmarkPayload? {
        try database.read { db in
            try Self.bookmarkRows(in: db, account: accountIdentityHash).first { $0.id == id }.map {
                CloudBookmarkPayload(id: $0.id, title: $0.title, url: $0.url,
                                     addedAt: $0.addedAt, folderID: $0.folderID,
                                     orderKey: $0.orderKey, favicon: $0.favicon)
            }
        }
    }

    /// The persisted fractional keys are required when applying a partial CloudKit batch.
    /// Reconstructing them from visible indices would mix a different key alphabet with
    /// incoming keys and could reorder untouched siblings.
    public func folderOrderKeys() throws -> [UUID: String] {
        try database.read { db in
            Dictionary(uniqueKeysWithValues: try Self.folderRows(in: db, account: accountIdentityHash)
                .map { ($0.id, $0.orderKey) })
        }
    }

    public func bookmarkOrderKeys() throws -> [UUID: String] {
        try database.read { db in
            Dictionary(uniqueKeysWithValues: try Self.bookmarkRows(in: db, account: accountIdentityHash)
                .map { ($0.id, $0.orderKey) })
        }
    }

    public func pendingFolderIDs() throws -> [UUID: UUID] {
        try database.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT id, pending_folder_id FROM bookmarks
                    WHERE account_identity_hash IS ? AND pending_folder_id IS NOT NULL
                    """,
                arguments: [accountIdentityHash]
            ).reduce(into: [UUID: UUID]()) { result, row in
                if let id = UUID(uuidString: row["id"]),
                   let folderID = UUID(uuidString: row["pending_folder_id"]) {
                    result[id] = folderID
                }
            }
        }
    }

    public func savePendingFolderIDs(_ values: [UUID: UUID]) throws {
        try database.write { db in
            try db.execute(
                sql: "UPDATE bookmarks SET pending_folder_id = NULL WHERE account_identity_hash IS ?",
                arguments: [accountIdentityHash]
            )
            for (bookmarkID, folderID) in values {
                try db.execute(
                    sql: """
                        UPDATE bookmarks SET pending_folder_id = ?
                        WHERE id = ? AND account_identity_hash IS ?
                        """,
                    arguments: [folderID.uuidString, bookmarkID.uuidString, accountIdentityHash]
                )
            }
        }
    }

    private static func fetchCollection(_ db: Database, account: String?) throws -> BookmarkCollection {
        let folders = try folderRows(in: db, account: account).sorted { $0.orderKey < $1.orderKey }
        let bookmarks = try bookmarkRows(in: db, account: account)
        let byFolder = Dictionary(grouping: bookmarks, by: \BookmarkRow.folderID)
        return BookmarkCollection(folders: folders.map { folder in
            BookmarkFolder(
                id: folder.id,
                name: folder.name,
                bookmarks: (byFolder[folder.id] ?? []).sorted { $0.orderKey < $1.orderKey }.map {
                    Bookmark(id: $0.id, title: $0.title, url: $0.url,
                             addedAt: $0.addedAt, favicon: $0.favicon)
                }
            )
        })
    }

    private static func apply(
        _ collection: BookmarkCollection,
        account: String?,
        cloud: CloudSyncRepository,
        enqueueChanges: Bool,
        in db: Database
    ) throws {
        let oldFolders = Dictionary(uniqueKeysWithValues:
            try folderRows(in: db, account: account).map { ($0.id, $0) })
        let oldBookmarks = Dictionary(uniqueKeysWithValues:
            try bookmarkRows(in: db, account: account).map { ($0.id, $0) })
        let folderKeys = OrderKey.initial(count: collection.folders.count)
        let newFolders = collection.folders.enumerated().map {
            FolderRow(id: $0.element.id, name: $0.element.name, orderKey: folderKeys[$0.offset])
        }
        let newBookmarks = collection.folders.flatMap { folder -> [BookmarkRow] in
            let keys = OrderKey.initial(count: folder.bookmarks.count)
            return folder.bookmarks.enumerated().map {
                BookmarkRow(id: $0.element.id, folderID: folder.id, title: $0.element.title,
                            url: $0.element.url, addedAt: $0.element.addedAt,
                            orderKey: keys[$0.offset],
                            favicon: $0.element.favicon)
            }
        }

        let newBookmarkIDs = Set(newBookmarks.map(\.id))
        for id in oldBookmarks.keys where !newBookmarkIDs.contains(id) {
            try db.execute(sql: "DELETE FROM bookmarks WHERE id = ? AND account_identity_hash IS ?",
                           arguments: [id.uuidString, account])
            try enqueue(.delete, type: bookmarkRecordType, id: id, account: account,
                        cloud: cloud, enabled: enqueueChanges, in: db)
        }

        for row in newFolders where oldFolders[row.id] != row {
            try db.execute(
                sql: """
                    INSERT INTO bookmark_folders (id, name, order_key, account_identity_hash)
                    VALUES (?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET name = excluded.name,
                        order_key = excluded.order_key,
                        account_identity_hash = excluded.account_identity_hash
                    """,
                arguments: [row.id.uuidString, row.name, row.orderKey, account]
            )
            try enqueue(.save, type: folderRecordType, id: row.id, account: account,
                        cloud: cloud, enabled: enqueueChanges, in: db)
        }

        for row in newBookmarks where oldBookmarks[row.id] != row {
            let state: Int? = row.favicon.map { $0.emoji == nil ? 0 : 1 }
            try db.execute(
                sql: """
                    INSERT INTO bookmarks
                        (id, folder_id, title, url, added_at, order_key,
                         account_identity_hash, pending_folder_id,
                         favicon_state, favicon_emoji, favicon_fetched_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, NULL, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET folder_id = excluded.folder_id,
                        title = excluded.title, url = excluded.url, added_at = excluded.added_at,
                        order_key = excluded.order_key,
                        account_identity_hash = excluded.account_identity_hash,
                        pending_folder_id = NULL, favicon_state = excluded.favicon_state,
                        favicon_emoji = excluded.favicon_emoji,
                        favicon_fetched_at = excluded.favicon_fetched_at
                    """,
                arguments: [row.id.uuidString, row.folderID.uuidString, row.title,
                            row.url.absoluteString, row.addedAt, row.orderKey,
                            account, state, row.favicon?.emoji, row.favicon?.fetchedAt]
            )
            try enqueue(.save, type: bookmarkRecordType, id: row.id, account: account,
                        cloud: cloud, enabled: enqueueChanges, in: db)
        }

        let newFolderIDs = Set(newFolders.map(\.id))
        for id in oldFolders.keys where !newFolderIDs.contains(id) {
            try db.execute(sql: "DELETE FROM bookmark_folders WHERE id = ? AND account_identity_hash IS ?",
                           arguments: [id.uuidString, account])
            try enqueue(.delete, type: folderRecordType, id: id, account: account,
                        cloud: cloud, enabled: enqueueChanges, in: db)
        }
    }

    private static func enqueue(
        _ operation: CloudPendingOperation, type: String, id: UUID, account: String?,
        cloud: CloudSyncRepository, enabled: Bool, in db: Database
    ) throws {
        guard enabled, let account else { return }
        try cloud.enqueue(CloudPendingChange(accountIdentityHash: account, recordType: type,
                                             recordName: id.uuidString, operation: operation), in: db)
    }

    private static func folderRows(in db: Database, account: String?) throws -> [FolderRow] {
        try Row.fetchAll(db, sql: """
            SELECT id, name, order_key FROM bookmark_folders
            WHERE account_identity_hash IS ?
            """, arguments: [account]).compactMap { row in
            guard let id = UUID(uuidString: row["id"]) else { return nil }
            let key: String? = row["order_key"]
            return FolderRow(id: id, name: row["name"], orderKey: key ?? "")
        }
    }

    private static func bookmarkRows(in db: Database, account: String?) throws -> [BookmarkRow] {
        try Row.fetchAll(db, sql: """
            SELECT id, folder_id, title, url, added_at, order_key,
                   favicon_state, favicon_emoji, favicon_fetched_at
            FROM bookmarks WHERE account_identity_hash IS ?
            """, arguments: [account]).compactMap { row in
            guard let id = UUID(uuidString: row["id"]),
                  let folderID = UUID(uuidString: row["folder_id"]),
                  let url = URL(string: row["url"]) else { return nil }
            let state: Int? = row["favicon_state"]
            let fetchedAt: Date? = row["favicon_fetched_at"]
            let key: String? = row["order_key"]
            let favicon = state.flatMap { value in fetchedAt.map {
                BookmarkFaviconSnapshot(emoji: value == 1 ? row["favicon_emoji"] : nil,
                                        fetchedAt: $0)
            } }
            return BookmarkRow(id: id, folderID: folderID, title: row["title"], url: url,
                               addedAt: row["added_at"], orderKey: key ?? "", favicon: favicon)
        }
    }
}
