import Foundation
import GRDB

public enum BookmarkRepositoryError: Error, Equatable, Sendable {
    case invalidFolderRow
    case invalidBookmarkRow
}

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

    /// Reads the latest rows and applies a user operation under the same writer lock as
    /// incoming sync. An actor's cached collection is not the database authority.
    public func update(_ change: (inout BookmarkCollection) -> Void) throws -> BookmarkCollection {
        try database.write { db in
            var value = try Self.fetchCollection(db, account: accountIdentityHash)
            change(&value)
            try Self.apply(value, account: accountIdentityHash, cloud: cloud,
                           enqueueChanges: accountIdentityHash != nil, in: db)
            return value
        }
    }

    /// Replaces an account's cache without creating echo uploads for fetched records.
    public func replaceFromCloud(with collection: BookmarkCollection) throws {
        try database.write { db in try replaceFromCloud(with: collection, in: db) }
    }

    /// Transaction-scoped variant used by sync reconciliation so fetched data and its
    /// related bookkeeping can commit together.
    public func replaceFromCloud(with collection: BookmarkCollection, in db: Database) throws {
        try Self.apply(collection, account: accountIdentityHash, cloud: cloud,
                       enqueueChanges: false, in: db)
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

    func legacyModelPayload(recordType: String, id: UUID, in db: Database) throws -> Data? {
        if recordType == Self.folderRecordType {
            return try Self.folderRows(in: db, account: accountIdentityHash).first { $0.id == id }.map {
                try CloudSyncRepository.encodeModelPayload(CloudBookmarkFolderPayload(id: $0.id, name: $0.name, orderKey: $0.orderKey))
            }
        }
        return try Self.bookmarkRows(in: db, account: accountIdentityHash).first { $0.id == id }.map {
            try CloudSyncRepository.encodeModelPayload(CloudBookmarkPayload(id: $0.id, title: $0.title, url: $0.url,
                addedAt: $0.addedAt, folderID: $0.folderID, orderKey: $0.orderKey, favicon: $0.favicon))
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
                guard let id = UUID(uuidString: row["id"]),
                      let folderID = UUID(uuidString: row["pending_folder_id"]) else {
                    throw CloudSyncRepositoryError.invalidRecordIdentity
                }
                result[id] = folderID
            }
        }
    }

    public func savePendingFolderIDs(_ values: [UUID: UUID]) throws {
        try database.write { db in try savePendingFolderIDs(values, in: db) }
    }

    public func savePendingFolderIDs(_ values: [UUID: UUID], in db: Database) throws {
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

    /// Applies partial cloud records without regenerating untouched fractional keys.
    /// The sync repository owns the surrounding transaction and metadata commit.
    func applyIncoming(_ models: [CloudRecordModel], deletions: [CloudIncomingDeletion], in db: Database) throws {
        guard models.contains(where: {
            switch $0 { case .bookmark, .folder: true; default: false }
        }) || deletions.contains(where: { $0.recordType == Self.bookmarkRecordType || $0.recordType == Self.folderRecordType }) else { return }
        let account = accountIdentityHash
        let incomingFolders = models.compactMap { if case .folder(let value) = $0 { value } else { nil } }
        for folder in incomingFolders {
            try db.execute(sql: """
                INSERT INTO bookmark_folders(id, name, order_key, account_identity_hash) VALUES (?, ?, ?, ?)
                ON CONFLICT(id, account_scope) DO UPDATE SET name = excluded.name, order_key = excluded.order_key
                """, arguments: [folder.id.uuidString, folder.name, folder.orderKey, account])
        }
        var favorite = try String.fetchOne(db, sql: """
            SELECT id FROM bookmark_folders WHERE account_identity_hash IS ? AND name = ? ORDER BY order_key, id LIMIT 1
            """, arguments: [account, BookmarkCollection.favoritesName])
        if favorite == nil {
            favorite = Self.recoveryFavoritesID(account: account).uuidString
            try db.execute(sql: "INSERT INTO bookmark_folders(id, name, order_key, account_identity_hash) VALUES (?, ?, ?, ?)",
                           arguments: [favorite, BookmarkCollection.favoritesName, OrderKey.initial(count: 1)[0], account])
        }
        // A provisional empty restore folder must not displace the server Favorites.
        if let serverFavorite = incomingFolders.filter({ $0.name == BookmarkCollection.favoritesName })
            .min(by: { ($0.orderKey, $0.id.uuidString) < ($1.orderKey, $1.id.uuidString) }) {
            let provisional = try String.fetchAll(db, sql: "SELECT id FROM bookmark_folders WHERE account_identity_hash IS ? AND name = ? AND id != ?",
                                                  arguments: [account, BookmarkCollection.favoritesName, serverFavorite.id.uuidString])
            for provisionalID in provisional {
            // Leave established local folders intact; a clean synthesized folder has
            // neither server metadata nor local intent and is safe to fold into it.
            let established = try Bool.fetchOne(db, sql: """
                SELECT EXISTS(SELECT 1 FROM cloud_record_state WHERE account_identity_hash IS ? AND record_name = ?)
                    OR EXISTS(SELECT 1 FROM cloud_pending_changes WHERE account_identity_hash IS ? AND record_name = ?)
                """, arguments: [account, provisionalID, account, provisionalID]) ?? false
            if !established {
                try db.execute(sql: "UPDATE bookmarks SET folder_id = ? WHERE account_identity_hash IS ? AND folder_id = ?",
                               arguments: [serverFavorite.id.uuidString, account, provisionalID])
                try db.execute(sql: "DELETE FROM bookmark_folders WHERE account_identity_hash IS ? AND id = ?",
                               arguments: [account, provisionalID])
                favorite = serverFavorite.id.uuidString
            }
            }
        }
        for folder in incomingFolders {
            try db.execute(sql: "UPDATE bookmarks SET folder_id = ?, pending_folder_id = NULL WHERE account_identity_hash IS ? AND pending_folder_id = ?",
                           arguments: [folder.id.uuidString, account, folder.id.uuidString])
        }
        let localBookmarks = Dictionary(uniqueKeysWithValues: try Self.bookmarkRows(in: db, account: account).map { ($0.id, $0) })
        for case .bookmark(let value) in models {
            let exists = try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM bookmark_folders WHERE account_identity_hash IS ? AND id = ?)",
                                          arguments: [account, value.folderID.uuidString]) ?? false
            let local = localBookmarks[value.id]
            let favicon: BookmarkFaviconSnapshot?
            // SQLite's existing date columns round to milliseconds. Rounding alone
            // must not manufacture a newer observation and an echo upload.
            if let current = local?.favicon, current.fetchedAt.timeIntervalSince(value.favicon?.fetchedAt ?? .distantPast) > 0.001 {
                favicon = current
            } else { favicon = value.favicon }
            try db.execute(sql: """
                INSERT INTO bookmarks(id, folder_id, title, url, added_at, order_key, account_identity_hash,
                                      pending_folder_id, favicon_state, favicon_emoji, favicon_fetched_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id, account_scope) DO UPDATE SET
                    folder_id = excluded.folder_id, title = excluded.title, url = excluded.url,
                    added_at = excluded.added_at, order_key = excluded.order_key,
                    pending_folder_id = excluded.pending_folder_id, favicon_state = excluded.favicon_state,
                    favicon_emoji = excluded.favicon_emoji, favicon_fetched_at = excluded.favicon_fetched_at
                """, arguments: [value.id.uuidString, exists ? value.folderID.uuidString : favorite!,
                                  value.title, value.url.absoluteString, value.addedAt, value.orderKey, account,
                                  exists ? nil : value.folderID.uuidString,
                                  favicon.map { $0.emoji == nil ? 0 : 1 }, favicon?.emoji, favicon?.fetchedAt])
            if favicon != value.favicon, let account {
                var corrected = value
                corrected.favicon = favicon
                try cloud.enqueueSave(accountIdentityHash: account, recordType: Self.bookmarkRecordType,
                                      recordName: value.id.uuidString, payload: corrected, in: db)
            }
        }
        for deletion in deletions where deletion.recordType == Self.bookmarkRecordType {
            try db.execute(sql: "DELETE FROM bookmarks WHERE account_identity_hash IS ? AND id = ?",
                           arguments: [account, deletion.recordName])
        }
        for deletion in deletions where deletion.recordType == Self.folderRecordType {
            if deletion.recordName == favorite {
                favorite = Self.recoveryFavoritesID(account: account, deletedID: deletion.recordName).uuidString
                try db.execute(sql: "INSERT INTO bookmark_folders(id, name, order_key, account_identity_hash) VALUES (?, ?, ?, ?)",
                               arguments: [favorite, BookmarkCollection.favoritesName, OrderKey.initial(count: 1)[0], account])
                if let account {
                    try cloud.enqueueSave(accountIdentityHash: account, recordType: Self.folderRecordType,
                        recordName: favorite!, payload: CloudBookmarkFolderPayload(id: UUID(uuidString: favorite!)!,
                            name: BookmarkCollection.favoritesName, orderKey: OrderKey.initial(count: 1)[0]), in: db)
                }
            }
            try db.execute(sql: "UPDATE bookmarks SET folder_id = ?, pending_folder_id = NULL WHERE account_identity_hash IS ? AND (folder_id = ? OR pending_folder_id = ?)",
                           arguments: [favorite, account, deletion.recordName, deletion.recordName])
            try db.execute(sql: "DELETE FROM bookmark_folders WHERE account_identity_hash IS ? AND id = ?",
                           arguments: [account, deletion.recordName])
            if let account {
                let pending = try Row.fetchAll(db, sql: "SELECT * FROM cloud_pending_changes WHERE account_identity_hash = ? AND record_type = ? AND operation = 'save'",
                                               arguments: [account, Self.bookmarkRecordType]).map(CloudSyncRepository.pendingChange(from:))
                for change in pending {
                    guard let bytes = change.modelPayload else { continue } // materialized before send
                    var payload = try JSONDecoder().decode(CloudBookmarkPayload.self, from: bytes)
                    guard payload.folderID.uuidString == deletion.recordName else { continue }
                    payload.folderID = UUID(uuidString: favorite!)!
                    let parentHasServerState = try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM cloud_record_state WHERE account_identity_hash = ? AND record_name = ?) OR EXISTS(SELECT 1 FROM cloud_pending_changes WHERE account_identity_hash = ? AND record_name = ? AND operation = 'save')",
                                                                arguments: [account, favorite, account, favorite]) ?? false
                    if !parentHasServerState, let parent = try Self.folderRows(in: db, account: account).first(where: { $0.id == payload.folderID }) {
                        try cloud.enqueueSave(accountIdentityHash: account, recordType: Self.folderRecordType,
                            recordName: parent.id.uuidString, payload: CloudBookmarkFolderPayload(id: parent.id, name: parent.name, orderKey: parent.orderKey), in: db)
                    }
                    try cloud.enqueueSave(accountIdentityHash: account, recordType: Self.bookmarkRecordType,
                                          recordName: change.recordName, payload: payload, in: db)
                }
            }
        }
    }

    private static func recoveryFavoritesID(account: String?, deletedID: String = "missing") -> UUID {
        // The same confirmed deletion must not create a different parent on every Mac.
        let hex = CloudSyncRepository.digest(Data("MajorTom.recovery-favorites:\(account ?? "unowned"):\(deletedID)".utf8))
        let chars = Array(hex.prefix(32))
        let name = [String(chars[0..<8]), String(chars[8..<12]), String(chars[12..<16]),
                    String(chars[16..<20]), String(chars[20..<32])].joined(separator: "-")
        return UUID(uuidString: name)!
    }

    static func fetchCollection(_ db: Database, account: String?) throws -> BookmarkCollection {
        let folders = try folderRows(in: db, account: account).sorted { ($0.orderKey, $0.id.uuidString) < ($1.orderKey, $1.id.uuidString) }
        let bookmarks = try bookmarkRows(in: db, account: account)
        let byFolder = Dictionary(grouping: bookmarks, by: \BookmarkRow.folderID)
        return BookmarkCollection(folders: folders.map { folder in
            BookmarkFolder(
                id: folder.id,
                name: folder.name,
                bookmarks: (byFolder[folder.id] ?? []).sorted { ($0.orderKey, $0.id.uuidString) < ($1.orderKey, $1.id.uuidString) }.map {
                    Bookmark(id: $0.id, title: $0.title, url: $0.url,
                             addedAt: $0.addedAt, favicon: $0.favicon)
                }
            )
        })
    }

    static func apply(
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
        let unchangedFolderOrder = oldFolders.values.sorted { ($0.orderKey, $0.id.uuidString) < ($1.orderKey, $1.id.uuidString) }
            .map(\.id) == collection.folders.map(\.id)
        let newFolders = collection.folders.enumerated().map {
            FolderRow(id: $0.element.id, name: $0.element.name,
                      orderKey: unchangedFolderOrder ? oldFolders[$0.element.id]!.orderKey : folderKeys[$0.offset])
        }
        let newBookmarks = collection.folders.flatMap { folder -> [BookmarkRow] in
            let keys = OrderKey.initial(count: folder.bookmarks.count)
            let unchangedOrder = oldBookmarks.values.filter { $0.folderID == folder.id }
                .sorted { ($0.orderKey, $0.id.uuidString) < ($1.orderKey, $1.id.uuidString) }
                .map(\.id) == folder.bookmarks.map(\.id)
            return folder.bookmarks.enumerated().map {
                BookmarkRow(id: $0.element.id, folderID: folder.id, title: $0.element.title,
                            url: $0.element.url, addedAt: $0.element.addedAt,
                            orderKey: unchangedOrder ? oldBookmarks[$0.element.id]!.orderKey : keys[$0.offset],
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
                    ON CONFLICT(id, account_scope) DO UPDATE SET name = excluded.name,
                        order_key = excluded.order_key,
                        account_identity_hash = excluded.account_identity_hash
                    """,
                arguments: [row.id.uuidString, row.name, row.orderKey, account]
            )
            if enqueueChanges, let account {
                try cloud.enqueueSave(
                    accountIdentityHash: account,
                    recordType: folderRecordType,
                    recordName: row.id.uuidString,
                    payload: CloudBookmarkFolderPayload(
                        id: row.id, name: row.name, orderKey: row.orderKey
                    ),
                    in: db
                )
            }
        }

        for row in newBookmarks where oldBookmarks[row.id] != row {
            let state: Int? = row.favicon.map { $0.emoji == nil ? 0 : 1 }
            // A title/favicon edit is not a move out of a not-yet-fetched folder.
            let desiredParent: String? = oldBookmarks[row.id]?.folderID == row.folderID
                ? try String.fetchOne(db, sql: "SELECT pending_folder_id FROM bookmarks WHERE id = ? AND account_identity_hash IS ?",
                                      arguments: [row.id.uuidString, account]) : nil
            try db.execute(
                sql: """
                    INSERT INTO bookmarks
                        (id, folder_id, title, url, added_at, order_key,
                         account_identity_hash, pending_folder_id,
                         favicon_state, favicon_emoji, favicon_fetched_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(id, account_scope) DO UPDATE SET folder_id = excluded.folder_id,
                        title = excluded.title, url = excluded.url, added_at = excluded.added_at,
                        order_key = excluded.order_key,
                        account_identity_hash = excluded.account_identity_hash,
                        pending_folder_id = excluded.pending_folder_id, favicon_state = excluded.favicon_state,
                        favicon_emoji = excluded.favicon_emoji,
                        favicon_fetched_at = excluded.favicon_fetched_at
                    """,
                arguments: [row.id.uuidString, row.folderID.uuidString, row.title,
                            row.url.absoluteString, row.addedAt, row.orderKey,
                            account, desiredParent, state, row.favicon?.emoji, row.favicon?.fetchedAt]
            )
            if enqueueChanges, let account {
                try cloud.enqueueSave(
                    accountIdentityHash: account,
                    recordType: bookmarkRecordType,
                    recordName: row.id.uuidString,
                    payload: CloudBookmarkPayload(
                        id: row.id, title: row.title, url: row.url, addedAt: row.addedAt,
                        folderID: desiredParent.flatMap(UUID.init(uuidString:)) ?? row.folderID,
                        orderKey: row.orderKey, favicon: row.favicon
                    ),
                    in: db
                )
            }
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
            """, arguments: [account]).map { row in
            guard let id = UUID(uuidString: row["id"]) else {
                throw BookmarkRepositoryError.invalidFolderRow
            }
            let key: String? = row["order_key"]
            return FolderRow(id: id, name: row["name"], orderKey: key ?? "")
        }
    }

    private static func bookmarkRows(in db: Database, account: String?) throws -> [BookmarkRow] {
        try Row.fetchAll(db, sql: """
            SELECT id, folder_id, title, url, added_at, order_key,
                   favicon_state, favicon_emoji, favicon_fetched_at
            FROM bookmarks WHERE account_identity_hash IS ?
            """, arguments: [account]).map { row in
            guard let id = UUID(uuidString: row["id"]),
                  let folderID = UUID(uuidString: row["folder_id"]),
                  let url = URL(string: row["url"]) else {
                throw BookmarkRepositoryError.invalidBookmarkRow
            }
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
