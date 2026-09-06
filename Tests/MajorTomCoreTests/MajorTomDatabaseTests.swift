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
        XCTAssertTrue(try database.read { try $0.tableExists("gemini_input_drafts") })
        XCTAssertTrue(try database.read { try $0.tableExists("bookmark_folders") })
        XCTAssertTrue(try database.read { try $0.tableExists("bookmarks") })
        XCTAssertTrue(try database.read { try $0.tableExists("bookmark_sync_folders") })
        XCTAssertTrue(try database.read { try $0.tableExists("bookmark_sync_bookmarks") })
        XCTAssertTrue(try database.read { try $0.tableExists("browser_windows") })
        XCTAssertTrue(try database.read { try $0.tableExists("browser_tabs") })
        XCTAssertTrue(try database.read { try $0.tableExists("browser_tab_history") })
        XCTAssertTrue(try database.read { try $0.tableExists("browser_session") })
        XCTAssertTrue(try database.read { try $0.tableExists("page_cache") })
        XCTAssertTrue(try database.read { try $0.tableExists("page_cache_fts") })
        XCTAssertTrue(try database.read { try $0.tableExists("trusted_server_identities") })
        XCTAssertTrue(try database.read { try $0.tableExists("server_trust_sync") })
        XCTAssertTrue(try database.read { try $0.tableExists("client_certificate_sync_descriptors") })
        XCTAssertTrue(try database.read { try $0.tableExists("client_certificate_sync_associations") })
        XCTAssertTrue(try database.read { try $0.tableExists("client_certificate_local_flags") })
        XCTAssertTrue(try database.read { try $0.tableExists("cloud_sync_state") })
        XCTAssertTrue(try database.read { try $0.tableExists("cloud_pending_changes") })
        XCTAssertTrue(try database.read { try $0.tableExists("cloud_record_state") })
        try database.validate()
    }

    func testCloudMigrationAddsTransitionalBookmarkColumns() throws {
        let database = try MajorTomDatabase(inMemory: ())
        try database.write { db in
            try db.execute(
                sql: "INSERT INTO bookmark_folders (id, name, position) VALUES ('folder', 'Folder', 0)"
            )
            try db.execute(
                sql: """
                    INSERT INTO bookmarks (id, folder_id, title, url, added_at, position)
                    VALUES ('first', 'folder', 'First', 'gemini://one', ?, 0),
                           ('second', 'folder', 'Second', 'gemini://two', ?, 1)
                    """,
                arguments: [Date(), Date()]
            )
        }

        let keys: [String?] = try database.read { db in
            try Optional<String>.fetchAll(db, sql: "SELECT order_key FROM bookmarks ORDER BY position")
        }

        // New databases migrate before these rows are inserted. The nullable columns keep
        // pre-refactor repository writes valid until the bookmark cutover stage.
        XCTAssertEqual(keys, [nil, nil])
        XCTAssertTrue(try database.read { db in
            try db.columns(in: "bookmarks").contains { $0.name == "order_key" }
        })
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
