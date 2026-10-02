import Foundation
import GRDB
import XCTest
@testable import MajorTomCore

final class CloudSyncRepositoryTests: FileBackedDatabaseTestCase {
    private func manifest(_ major: Int = 3) -> CloudDataModelManifest {
        CloudDataModelManifest(
            formatMajor: major,
            minimumReaderMajor: major,
            minimumWriterMajor: major,
            createdAt: Date(timeIntervalSince1970: Double(major))
        )
    }

    func testLatestChangeReplacesEarlierOperationAndIncrementsGeneration() throws {
        let database = try makeFileBackedDatabase()
        let repository = CloudSyncRepository(database: database)
        try repository.enqueueSave(
            accountIdentityHash: "account", recordType: "MTBookmark", recordName: "bookmark",
            payload: manifest(), enqueuedAt: Date(timeIntervalSince1970: 10)
        )
        try repository.enqueue(CloudPendingChange(
            accountIdentityHash: "account", recordType: "MTBookmark", recordName: "bookmark",
            operation: .delete, enqueuedAt: Date(timeIntervalSince1970: 20)
        ))

        let changes = try repository.pendingChanges(for: "account")
        XCTAssertEqual(changes.count, 1)
        XCTAssertEqual(changes[0].operation, .delete)
        XCTAssertEqual(changes[0].generation, 2)
    }

    func testPendingLocalSaveBlocksStaleFetchedModification() {
        // Prevents a fetch during Sync Now from replacing a newer local edit before
        // the pending save builds its payload from the local row.
        let pending = CloudPendingChangeSet([
            CloudPendingChange(
                accountIdentityHash: "account",
                recordType: "MTBookmark",
                recordName: "edited-bookmark",
                operation: .save
            )
        ])

        XCTAssertFalse(pending.allowsFetchedModification(recordName: "edited-bookmark"))
        XCTAssertTrue(pending.allowsFetchedModification(recordName: "other-bookmark"))
    }

    func testPendingDeleteBlocksFetchedModification() {
        let pending = CloudPendingChangeSet([
            CloudPendingChange(
                accountIdentityHash: "account",
                recordType: "MTBookmark",
                recordName: "deleted-bookmark",
                operation: .delete
            )
        ])

        XCTAssertFalse(pending.allowsFetchedModification(recordName: "deleted-bookmark"))
    }

    func testConflictSetIncludesChangesBeyondOutgoingBatchLimit() throws {
        let repository = CloudSyncRepository(database: try makeFileBackedDatabase())
        for index in 0...200 {
            try repository.enqueueSave(
                accountIdentityHash: "account", recordType: "MTBookmark",
                recordName: "bookmark-\(index)", payload: manifest(),
                enqueuedAt: Date(timeIntervalSince1970: Double(index))
            )
        }

        let pending = try repository.pendingChangeSet(for: "account")

        XCTAssertEqual(pending.saves.count, 201)
        XCTAssertFalse(pending.allowsFetchedModification(recordName: "bookmark-200"))
    }

    func testPendingChangesAreAccountScopedLimitedAndOldestFirst() throws {
        let database = try makeFileBackedDatabase()
        let repository = CloudSyncRepository(database: database)
        for index in (0..<4).reversed() {
            try repository.enqueueSave(
                accountIdentityHash: "account", recordType: "MTBookmark",
                recordName: "record-\(index)", payload: manifest(),
                enqueuedAt: Date(timeIntervalSince1970: Double(index))
            )
        }
        try repository.enqueueSave(
            accountIdentityHash: "other", recordType: "MTBookmark",
            recordName: "other-record", payload: manifest()
        )

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
        try repository.enqueueSave(
            accountIdentityHash: "account", recordType: "MTBookmark", recordName: "bookmark",
            payload: manifest(3)
        )
        try repository.enqueueSave(
            accountIdentityHash: "account", recordType: "MTBookmark", recordName: "bookmark",
            payload: manifest(4)
        )

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
                sql: "INSERT INTO bookmark_folders (id, name, order_key) VALUES (?, ?, ?)",
                arguments: ["folder", "Folder", "a"]
            )
            try repository.enqueueSave(
                accountIdentityHash: "account", recordType: "MTBookmarkFolder", recordName: "folder",
                payload: CloudBookmarkFolderPayload(id: UUID(), name: "Folder", orderKey: "a"), in: db
            )
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

    func testAcknowledgedGenerationIsNeverReused() throws {
        let repository = CloudSyncRepository(database: try makeFileBackedDatabase())
        try repository.enqueueSave(
            accountIdentityHash: "account", recordType: "MTBookmark", recordName: "bookmark",
            payload: manifest(3)
        )
        XCTAssertTrue(try repository.acknowledge(recordName: "bookmark", generation: 1, for: "account"))

        try repository.enqueueSave(
            accountIdentityHash: "account", recordType: "MTBookmark", recordName: "bookmark",
            payload: manifest(4)
        )

        XCTAssertEqual(try repository.pendingChanges(for: "account").first?.generation, 2)
    }

    func testSaveSnapshotIsCanonicalAndDurable() throws {
        let repository = CloudSyncRepository(database: try makeFileBackedDatabase())
        let value = manifest(3)
        try repository.enqueueSave(
            accountIdentityHash: "account", recordType: "MTDataModelManifest",
            recordName: "manifest", payload: value
        )

        let pending = try XCTUnwrap(try repository.pendingChanges(for: "account").first)
        XCTAssertEqual(pending.modelPayload, try CloudSyncRepository.encodeModelPayload(value))
        XCTAssertEqual(pending.payloadDigest, pending.modelPayload.map(CloudSyncRepository.digest))
    }

    func testNewSaveCannotBeEnqueuedWithoutSnapshot() throws {
        let repository = CloudSyncRepository(database: try makeFileBackedDatabase())
        XCTAssertThrowsError(try repository.enqueue(CloudPendingChange(
            accountIdentityHash: "account", recordType: "MTBookmark", recordName: "bookmark",
            operation: .save
        ))) { error in
            XCTAssertEqual(error as? CloudSyncRepositoryError, .saveMissingPayload)
        }
    }

    func testLegacyIdentityOnlySaveUpgradesWithoutReusingGeneration() throws {
        let database = try makeFileBackedDatabase()
        let repository = CloudSyncRepository(database: database)
        try database.write { db in
            try db.execute(
                sql: """
                    INSERT INTO cloud_pending_changes
                        (account_identity_hash, record_type, record_name, operation, generation,
                         model_payload, payload_digest, enqueued_at)
                    VALUES (?, ?, ?, 'save', ?, NULL, NULL, ?)
                    """,
                arguments: ["account", "MTBookmark", "bookmark", 41, Date()]
            )
        }

        try repository.enqueueSave(
            accountIdentityHash: "account", recordType: "MTBookmark", recordName: "bookmark",
            payload: manifest(3)
        )

        let pending = try XCTUnwrap(try repository.pendingChanges(for: "account").first)
        XCTAssertEqual(pending.generation, 42)
        XCTAssertNotNil(pending.modelPayload)
    }

    func testFetchedDeletionClearsOnlyMatchingAccountBookkeeping() throws {
        let repository = CloudSyncRepository(database: try makeFileBackedDatabase())
        try repository.enqueueSave(
            accountIdentityHash: "account-a", recordType: "MTBookmark", recordName: "bookmark",
            payload: manifest()
        )
        try repository.enqueueSave(
            accountIdentityHash: "account-b", recordType: "MTBookmark", recordName: "bookmark",
            payload: manifest()
        )
        try repository.saveRecordState(CloudRecordState(
            accountIdentityHash: "account-a", recordType: "MTBookmark", recordName: "bookmark"
        ))

        try repository.resolveFetchedDeletion(recordName: "bookmark", for: "account-a")

        XCTAssertFalse(try repository.hasPendingChanges(for: "account-a"))
        XCTAssertNil(try repository.recordState(recordName: "bookmark", for: "account-a"))
        XCTAssertTrue(try repository.hasPendingChanges(for: "account-b"))
    }

    func testDiagnosticSnapshotIsAccountScopedAndDoesNotExposeRecordNames() throws {
        let repository = CloudSyncRepository(database: try makeFileBackedDatabase())
        try repository.enqueueSave(
            accountIdentityHash: "account-secret-value", recordType: "MTBookmark",
            recordName: "sensitive-record-name", payload: manifest()
        )
        try repository.enqueue(CloudPendingChange(
            accountIdentityHash: "account-secret-value", recordType: "MTBookmarkFolder",
            recordName: "other-sensitive-record", operation: .delete
        ))

        let snapshot = try repository.diagnosticSnapshot(for: "account-secret-value")

        XCTAssertEqual(snapshot.accountHashPrefix, "account-secr")
        XCTAssertEqual(snapshot.outbox, [
            .init(recordType: "MTBookmark", operation: .save, count: 1),
            .init(recordType: "MTBookmarkFolder", operation: .delete, count: 1),
        ])
        XCTAssertNotNil(snapshot.oldestPendingAt)
    }
}
