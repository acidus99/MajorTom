import Foundation
import GRDB
import XCTest
@testable import MajorTomCore

final class MajorTomDatabaseTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        if let directory {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    func testFoundationMigrationIsApplied() throws {
        let database = try MajorTomDatabase(inMemory: ())

        let tableExists = try database.read { db in
            try db.tableExists("persistence_metadata")
        }

        XCTAssertTrue(tableExists)
        XCTAssertTrue(try database.read { try $0.tableExists("history_entries") })
        XCTAssertTrue(try database.read {
            try $0.columns(in: "history_entries").contains { $0.name == "title" }
        })
        XCTAssertTrue(try database.read { try $0.tableExists("gemini_input_drafts") })
        XCTAssertTrue(try database.read { try $0.tableExists("bookmark_folders") })
        XCTAssertTrue(try database.read { try $0.tableExists("bookmarks") })
        XCTAssertTrue(try database.read { try $0.tableExists("trusted_server_identities") })
        XCTAssertTrue(try database.read { try $0.tableExists("client_certificates") })
        XCTAssertTrue(try database.read { try $0.tableExists("client_certificate_associations") })
        XCTAssertTrue(try database.read { try $0.tableExists("client_certificate_local_flags") })
        XCTAssertTrue(try database.read { try $0.tableExists("cloud_sync_state") })
        XCTAssertTrue(try database.read { try $0.tableExists("cloud_pending_changes") })
        XCTAssertTrue(try database.read { try $0.tableExists("cloud_record_state") })
        XCTAssertFalse(try database.read { try $0.tableExists("page_cache") })
        XCTAssertFalse(try database.read { try $0.tableExists("browser_session") })
        XCTAssertFalse(try database.read { try $0.tableExists("bookmark_sync_folders") })
        XCTAssertFalse(try database.read { try $0.tableExists("server_trust_sync") })
        XCTAssertFalse(try database.read {
            try $0.columns(in: "bookmark_folders").contains { $0.name == "position" }
        })
        XCTAssertFalse(try database.read {
            try $0.columns(in: "bookmarks").contains { $0.name == "position" }
        })
        try database.validate()
    }

    func testDurableDatabaseReopensWithCommittedData() throws {
        let fileURL = directory.appendingPathComponent(MajorTomDatabase.filename)
        do {
            let database = try MajorTomDatabase(fileURL: fileURL)
            try database.write { db in
                try db.execute(
                    sql: """
                        INSERT INTO persistence_metadata (key, value, updated_at)
                        VALUES (?, ?, ?)
                        """,
                    arguments: ["migration-test", Data("saved".utf8), Date()]
                )
            }
        }

        let reopened = try MajorTomDatabase(fileURL: fileURL)
        let value = try reopened.read { db in
            try Data.fetchOne(
                db,
                sql: "SELECT value FROM persistence_metadata WHERE key = ?",
                arguments: ["migration-test"]
            )
        }

        XCTAssertEqual(value, Data("saved".utf8))
        try reopened.validate()
    }

    func testV10RepairsDatabaseThatRecordedV8BeforePositionCleanup() throws {
        // Pins the development-upgrade bug where v8 was already recorded while the
        // obsolete NOT NULL position columns remained, blocking order-key-only inserts.
        let fileURL = directory.appendingPathComponent(MajorTomDatabase.filename)
        let oldDatabase = try DatabaseQueue(path: fileURL.path)
        try oldDatabase.write { db in
            try db.execute(sql: "CREATE TABLE grdb_migrations (identifier TEXT NOT NULL PRIMARY KEY)")
            for identifier in [
                "v1-foundation", "v2-history-and-input-drafts", "v3-bookmarks",
                "v4-sessions-cache-and-search", "v5-security-and-sync-metadata",
                "v6-cloud-sync-refactor", "v7-cloud-certificate-metadata",
                "v8-remove-unused-local-storage", "v9-history-titles",
            ] {
                try db.execute(
                    sql: "INSERT INTO grdb_migrations (identifier) VALUES (?)",
                    arguments: [identifier]
                )
            }
            try db.execute(sql: """
                CREATE TABLE bookmark_folders (
                    id TEXT PRIMARY KEY,
                    name TEXT NOT NULL,
                    position INTEGER NOT NULL,
                    order_key TEXT,
                    account_identity_hash TEXT
                )
                """)
            try db.execute(sql: """
                CREATE TABLE bookmarks (
                    id TEXT PRIMARY KEY,
                    folder_id TEXT NOT NULL REFERENCES bookmark_folders(id) ON DELETE CASCADE,
                    title TEXT NOT NULL,
                    url TEXT NOT NULL,
                    added_at DATETIME NOT NULL,
                    position INTEGER NOT NULL,
                    order_key TEXT,
                    account_identity_hash TEXT,
                    pending_folder_id TEXT,
                    favicon_state INTEGER,
                    favicon_emoji TEXT,
                    favicon_fetched_at DATETIME
                )
                """)
            try db.execute(
                sql: "INSERT INTO bookmark_folders (id, name, position, order_key) VALUES (?, ?, ?, ?)",
                arguments: ["folder", "Favorites", 0, "a"]
            )
            try db.execute(
                sql: """
                    INSERT INTO bookmarks
                        (id, folder_id, title, url, added_at, position, order_key)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: ["bookmark", "folder", "Title", "gemini://example/", Date(), 0, "a"]
            )
        }

        let repaired = try MajorTomDatabase(fileURL: fileURL)

        XCTAssertFalse(try repaired.read {
            try $0.columns(in: "bookmark_folders").contains { $0.name == "position" }
        })
        XCTAssertFalse(try repaired.read {
            try $0.columns(in: "bookmarks").contains { $0.name == "position" }
        })
        XCTAssertEqual(try repaired.read {
            try String.fetchOne($0, sql: "SELECT title FROM bookmarks WHERE id = 'bookmark'")
        }, "Title")
        try repaired.validate()
    }

    func testThrowingWriteRollsBackTransaction() throws {
        enum Expected: Error { case failure }
        let database = try MajorTomDatabase(inMemory: ())

        XCTAssertThrowsError(try database.write { db in
            try db.execute(
                sql: """
                    INSERT INTO persistence_metadata (key, value, updated_at)
                    VALUES (?, ?, ?)
                    """,
                arguments: ["rolled-back", Data(), Date()]
            )
            throw Expected.failure
        })

        let count = try database.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM persistence_metadata WHERE key = ?",
                arguments: ["rolled-back"]
            )
        }
        XCTAssertEqual(count, 0)
    }

    func testForeignKeysAreEnabled() throws {
        let database = try MajorTomDatabase(inMemory: ())
        let enabled = try database.read { db in
            try Bool.fetchOne(db, sql: "PRAGMA foreign_keys")
        }
        XCTAssertEqual(enabled, true)
    }
}
