import Foundation
import GRDB

/// Per-record local persistence for CloudKit bookmark merge metadata and tombstones.
/// CloudKit still owns transport; this repository prevents one bookmark edit from
/// re-encoding and rewriting the entire synchronized collection in UserDefaults.
public struct BookmarkSyncRepository: Sendable {
    private let database: MajorTomDatabase

    public init(database: MajorTomDatabase) {
        self.database = database
    }

    public func state() throws -> SyncedBookmarks? {
        try database.read { db in
            let folders: [SyncedBookmarkFolder] = try Self.payloads(
                from: "bookmark_sync_folders",
                in: db
            )
            let bookmarks: [SyncedBookmark] = try Self.payloads(
                from: "bookmark_sync_bookmarks",
                in: db
            )
            guard !folders.isEmpty || !bookmarks.isEmpty else { return nil }
            return SyncedBookmarks(folders: folders, bookmarks: bookmarks)
        }
    }

    public func replace(with state: SyncedBookmarks) throws {
        try database.write { db in try Self.apply(state, in: db) }
    }

    public func importLegacyState(_ state: SyncedBookmarks) throws {
        try database.write { db in
            let marker = "legacy-bookmark-cloud-metadata-v1-imported"
            let imported = try Bool.fetchOne(
                db,
                sql: "SELECT EXISTS(SELECT 1 FROM persistence_metadata WHERE key = ?)",
                arguments: [marker]
            ) ?? false
            guard !imported else { return }

            let count = (try Int.fetchOne(
                db,
                sql: """
                    SELECT
                        (SELECT COUNT(*) FROM bookmark_sync_folders) +
                        (SELECT COUNT(*) FROM bookmark_sync_bookmarks)
                    """
            )) ?? 0
            if count == 0 {
                try Self.apply(state, in: db)
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

    private static func apply(_ state: SyncedBookmarks, in db: Database) throws {
        try apply(
            state.folders,
            table: "bookmark_sync_folders",
            id: { $0.id },
            modifiedAt: { $0.modifiedAt },
            in: db
        )
        try apply(
            state.bookmarks,
            table: "bookmark_sync_bookmarks",
            id: { $0.id },
            modifiedAt: { $0.modifiedAt },
            in: db
        )
    }

    private static func apply<Record: Encodable>(
        _ records: [Record],
        table: String,
        id: (Record) -> UUID,
        modifiedAt: (Record) -> Date,
        in db: Database
    ) throws {
        let existing = Dictionary(uniqueKeysWithValues: try Row.fetchAll(
            db,
            sql: "SELECT id, payload FROM \(table)"
        ).map { ($0["id"] as String, $0["payload"] as Data) })
        let ids = Set(records.map { id($0).uuidString })
        for oldID in existing.keys where !ids.contains(oldID) {
            try db.execute(sql: "DELETE FROM \(table) WHERE id = ?", arguments: [oldID])
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        for record in records {
            let recordID = id(record).uuidString
            let payload = try encoder.encode(record)
            guard existing[recordID] != payload else { continue }
            try db.execute(
                sql: """
                    INSERT INTO \(table) (id, payload, modified_at) VALUES (?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET
                        payload = excluded.payload,
                        modified_at = excluded.modified_at
                    """,
                arguments: [recordID, payload, modifiedAt(record)]
            )
        }
    }

    private static func payloads<Record: Decodable>(
        from table: String,
        in db: Database
    ) throws -> [Record] {
        let decoder = JSONDecoder()
        return try Row.fetchAll(db, sql: "SELECT payload FROM \(table)").map { row in
            try decoder.decode(Record.self, from: row["payload"] as Data)
        }
    }
}
