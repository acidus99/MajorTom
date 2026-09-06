import Foundation
import GRDB
import XCTest
@testable import MajorTomCore

final class CloudSyncRepositoryTests: FileBackedDatabaseTestCase {
    func testLatestChangeReplacesEarlierOperationAndIncrementsGeneration() throws {
        let database = try makeFileBackedDatabase()
        let repository = CloudSyncRepository(database: database)
        let first = CloudPendingChange(
            accountIdentityHash: "account",
            recordType: "MTBookmark",
            recordName: "bookmark",
            operation: .save,
            enqueuedAt: Date(timeIntervalSince1970: 10)
        )
        try repository.enqueue(first)
        var deletion = first
        deletion.operation = .delete
        deletion.enqueuedAt = Date(timeIntervalSince1970: 20)
        try repository.enqueue(deletion)

        let changes = try repository.pendingChanges(for: "account")
        XCTAssertEqual(changes.count, 1)
        XCTAssertEqual(changes[0].operation, .delete)
        XCTAssertEqual(changes[0].generation, 2)
    }

    func testPendingChangesAreAccountScopedLimitedAndOldestFirst() throws {
        let database = try makeFileBackedDatabase()
        let repository = CloudSyncRepository(database: database)
        for index in (0..<4).reversed() {
            try repository.enqueue(CloudPendingChange(
                accountIdentityHash: "account",
                recordType: "MTBookmark",
                recordName: "record-\(index)",
                operation: .save,
                enqueuedAt: Date(timeIntervalSince1970: Double(index))
            ))
        }
        try repository.enqueue(CloudPendingChange(
            accountIdentityHash: "other",
            recordType: "MTBookmark",
            recordName: "other-record",
            operation: .save
        ))

        XCTAssertEqual(
            try repository.pendingChanges(for: "account", limit: 2).map(\.recordName),
            ["record-0", "record-1"]
        )
    }

    func testEngineAndAccountStateRoundTripIncludingNil() throws {
        let database = try makeFileBackedDatabase()
        let repository = CloudSyncRepository(database: database)
        XCTAssertNil(try repository.activeAccountIdentityHash())
        try repository.saveActiveAccountIdentityHash("account")
        try repository.saveEngineState(Data([1, 2, 3]), for: "account")
        XCTAssertEqual(try repository.state(for: "account").engineState, Data([1, 2, 3]))

        try repository.saveEngineState(nil, for: "account")
        XCTAssertNil(try repository.state(for: "account").engineState)
        try repository.saveActiveAccountIdentityHash(nil)
        XCTAssertNil(try repository.activeAccountIdentityHash())
    }

    func testStaleAcknowledgementCannotRemoveNewerEdit() throws {
        let database = try makeFileBackedDatabase()
        let repository = CloudSyncRepository(database: database)
        let change = CloudPendingChange(
            accountIdentityHash: "account",
            recordType: "MTBookmark",
            recordName: "bookmark",
            operation: .save
        )
        try repository.enqueue(change)
        try repository.enqueue(change)

        XCTAssertFalse(try repository.acknowledge(
            recordName: "bookmark", generation: 1, for: "account"
        ))
        XCTAssertTrue(try repository.hasPendingChanges(for: "account"))
        XCTAssertTrue(try repository.acknowledge(
            recordName: "bookmark", generation: 2, for: "account"
        ))
        XCTAssertFalse(try repository.hasPendingChanges(for: "account"))
    }

    func testThrowingDomainWriteRollsBackOutboxEntry() throws {
        enum Expected: Error { case failure }
        let database = try makeFileBackedDatabase()
        let repository = CloudSyncRepository(database: database)

        XCTAssertThrowsError(try database.write { db in
            try db.execute(
                sql: "INSERT INTO bookmark_folders (id, name, position) VALUES (?, ?, ?)",
                arguments: ["folder", "Folder", 0]
            )
            try repository.enqueue(CloudPendingChange(
                accountIdentityHash: "account",
                recordType: "MTBookmarkFolder",
                recordName: "folder",
                operation: .save
            ), in: db)
            throw Expected.failure
        })

        XCTAssertFalse(try repository.hasPendingChanges(for: "account"))
        let folderCount = try database.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM bookmark_folders")
        }
        XCTAssertEqual(folderCount, 0)
    }

    func testRecordMetadataRoundTrips() throws {
        let repository = CloudSyncRepository(database: try makeFileBackedDatabase())
        let state = CloudRecordState(
            accountIdentityHash: "account",
            recordType: "MTBookmark",
            recordName: "bookmark",
            systemFields: Data([1]),
            serverPayload: Data([2]),
            payloadDigest: "digest",
            lastSeenEpoch: 4,
            updatedAt: Date(timeIntervalSince1970: 50)
        )
        try repository.saveRecordState(state)
        XCTAssertEqual(try repository.recordState(recordName: "bookmark", for: "account"), state)
    }
}
