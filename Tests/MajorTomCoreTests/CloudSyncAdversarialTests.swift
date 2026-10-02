import Foundation
import GRDB
import XCTest
@testable import MajorTomCore

final class CloudSyncAdversarialTests: FileBackedDatabaseTestCase {
    func testOvertakenJournalReplayCannotRollBackNewerCommittedBatches() async throws {
        // Two workers decode batch N. The fast worker commits N and N+1 before
        // the slow worker obtains the writer. N must not be applied a second time.
        let db = try makeFileBackedDatabase()
        let cloud = CloudSyncRepository(database: db)
        let id = UUID()
        func batch(_ name: String) throws -> CloudIncomingBatch {
            .init(modifications: [.init(accountIdentityHash: "a", recordType: "MTBookmarkFolder",
                recordName: id.uuidString, serverPayload: try CloudRecordPayload(model:
                    CloudBookmarkFolderPayload(id: id, name: name, orderKey: "k")).encoded())], deletions: [])
        }
        try cloud.journal(batch("Old"), for: "a")
        let decoded = DispatchSemaphore(value: 0)
        let resume = DispatchSemaphore(value: 0)
        let slow = Task.detached {
            try cloud.replayIncoming(for: "a", beforeApplying: {
                decoded.signal()
                _ = resume.wait(timeout: .now() + 10)
            })
        }
        defer { resume.signal() }
        XCTAssertEqual(decoded.wait(timeout: .now() + 5), .success)
        try cloud.journal(batch("New"), for: "a")
        try cloud.replayIncoming(for: "a")
        resume.signal()
        try await slow.value
        XCTAssertEqual(try BookmarkRepository(database: db, accountIdentityHash: "a")
            .collection().folders.first(where: { $0.id == id })?.name, "New")
        XCTAssertFalse(try cloud.hasUnappliedBatches(for: "a"))
        try db.validate()
    }

    func testEngineCheckpointWriteFailureRetainsPreviousDurableState() throws {
        let db = try makeFileBackedDatabase()
        let cloud = CloudSyncRepository(database: db)
        try cloud.saveEngineState(Data("before".utf8), for: "a")
        try db.write { try $0.execute(sql: """
            CREATE TRIGGER reject_checkpoint BEFORE UPDATE OF engine_state ON cloud_sync_state
            BEGIN SELECT RAISE(ABORT, 'injected checkpoint failure'); END
            """) }
        XCTAssertThrowsError(try cloud.saveEngineState(Data("after".utf8), for: "a"))
        XCTAssertEqual(try cloud.state(for: "a").engineState, Data("before".utf8))
    }

    func testGenerationNeverFallsBelowExistingPendingHighWaterMark() throws {
        let db = try makeFileBackedDatabase()
        let cloud = CloudSyncRepository(database: db)
        let change = CloudPendingChange(accountIdentityHash: "a", recordType: "MTBookmark", recordName: "high-water", operation: .delete)
        try cloud.enqueue(change)
        try db.write { try $0.execute(sql: "UPDATE cloud_pending_changes SET generation = 100") }
        try cloud.enqueue(change)
        XCTAssertEqual(try cloud.pendingChange(recordName: change.recordName, for: "a")?.generation, 101)
    }

    func testConflictResponseRetainsPendingTitleButAdoptsNewerFavicon() throws {
        let db = try makeFileBackedDatabase()
        let cloud = CloudSyncRepository(database: db)
        let repo = BookmarkRepository(database: db, accountIdentityHash: "a")
        var local = BookmarkCollection()
        let id = local.add(title: "Pending title", url: URL(string: "gemini://favicon/")!).id
        try repo.replace(with: local)
        let attempt = try XCTUnwrap(try cloud.preparedChanges(for: "a").first { $0.change.recordName == id.uuidString })
        var remote = try JSONDecoder().decode(CloudBookmarkPayload.self, from: XCTUnwrap(attempt.change.modelPayload))
        remote.title = "Old title"
        remote.favicon = BookmarkFaviconSnapshot(emoji: "🚀", fetchedAt: Date())
        try cloud.acceptSave(.init(accountIdentityHash: "a", recordType: "MTBookmark", recordName: id.uuidString,
            serverPayload: try CloudRecordPayload(model: remote).encoded()), attempted: attempt.change, isConflict: true)
        let next = try XCTUnwrap(cloud.pendingChange(recordName: id.uuidString, for: "a"))
        let actual = try JSONDecoder().decode(CloudBookmarkPayload.self, from: XCTUnwrap(next.modelPayload))
        XCTAssertEqual(actual.title, "Pending title")
        XCTAssertEqual(actual.favicon, remote.favicon)
        let stored = try XCTUnwrap(repo.collection().bookmark(with: id)?.favicon)
        XCTAssertEqual(stored.emoji, remote.favicon?.emoji)
        XCTAssertEqual(stored.fetchedAt.timeIntervalSince1970, try XCTUnwrap(remote.favicon).fetchedAt.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertGreaterThan(next.generation, attempt.change.generation)
    }

    func testLegacyImportBodyAndMarkerRollbackAndNeverOverwriteNewLocalIntent() throws {
        let db = try makeFileBackedDatabase()
        let cloud = CloudSyncRepository(database: db)
        let repo = BookmarkRepository(database: db, accountIdentityHash: "a")
        var legacy = BookmarkCollection()
        let id = legacy.add(title: "Legacy", url: URL(string: "gemini://legacy/")!).id
        let incoming = SyncedBookmarks(collection: legacy, modifiedAt: Date())
        try db.write { try $0.execute(sql: """
            CREATE TRIGGER reject_import_marker BEFORE INSERT ON cloud_sync_state
            BEGIN SELECT RAISE(ABORT, 'injected import failure'); END
            """) }
        XCTAssertThrowsError(try cloud.importLegacyData(bookmarks: incoming, certificates: nil, for: "a"))
        XCTAssertNil(try repo.collection().bookmark(with: id))
        XCTAssertFalse(try cloud.hasPendingChanges(for: "a"))
        try db.write { try $0.execute(sql: "DROP TRIGGER reject_import_marker") }
        try cloud.importLegacyData(bookmarks: incoming, certificates: nil, for: "a")
        _ = try repo.update { $0.rename(bookmarkWith: id, to: "After import") }
        try cloud.importLegacyData(bookmarks: incoming, certificates: nil, for: "a")
        XCTAssertEqual(try repo.collection().bookmark(with: id)?.title, "After import")
        XCTAssertEqual(try cloud.state(for: "a").migrationPhase, .publishingV2)
        try db.validate()
    }

    func testCertificateEditUsesLatestRowsAndCannotResurrectADeletedStaleObject() throws {
        // Publication can lag the database. Whole-catalogue replacement erased unrelated
        // incoming certificates and resurrected deleted ones from the stale UI snapshot.
        let db = try makeFileBackedDatabase()
        let repo = ClientCertificateSyncRepository(database: db, accountIdentityHash: "a")
        let cloud = CloudSyncRepository(database: db)
        let descriptor = ClientCertificateDescriptor(id: UUID(), commonName: "Initial", notBefore: .distantPast,
            notAfter: .distantFuture, certificateSHA256: String(repeating: "a", count: 64),
            publicKeySHA256: String(repeating: "b", count: 64))
        let base = ClientCertificateSyncState().reconciled(certificates: [descriptor], associations: [], at: Date())
        try repo.save(base, localFlags: [:])
        var remote = descriptor
        remote.id = UUID()
        try cloud.journal(.init(modifications: [.init(accountIdentityHash: "a", recordType: "MTClientCertificateDescriptor",
            recordName: remote.id.uuidString, serverPayload: try CloudRecordPayload(model: CloudClientCertificateDescriptorPayload(remote)).encoded())], deletions: []), for: "a")
        try cloud.replayIncoming(for: "a")
        let edit: @Sendable (inout [ClientCertificateDescriptor], inout [ClientCertificateAssociation], inout [UUID: Bool]) -> Void = { certificates, _, _ in
            guard let index = certificates.firstIndex(where: { $0.id == descriptor.id }) else { return }
            certificates[index].commonName = "Edited"
        }
        let committed = try repo.update(edit)
        XCTAssertEqual(Set(committed.state.certificates.map(\.id)), [descriptor.id, remote.id])
        try cloud.journal(.init(modifications: [], deletions: [.init(recordType: "MTClientCertificateDescriptor", recordName: descriptor.id.uuidString)]), for: "a")
        try cloud.replayIncoming(for: "a")
        _ = try repo.update(edit)
        XCTAssertFalse(try repo.load().state.certificates.contains { $0.id == descriptor.id })
        try db.validate()
    }

    func testCertificateMutationFailureRollsBackCatalogueFlagsAndOutbox() throws {
        // Moving catalogue writes off the UI actor must not separate the approval or
        // local Keychain flag from its immutable outgoing intent.
        let db = try makeFileBackedDatabase()
        let repo = ClientCertificateSyncRepository(database: db, accountIdentityHash: "a")
        let cloud = CloudSyncRepository(database: db)
        let descriptor = ClientCertificateDescriptor(id: UUID(), commonName: "Atomic", notBefore: .distantPast,
            notAfter: .distantFuture, certificateSHA256: String(repeating: "a", count: 64),
            publicKeySHA256: String(repeating: "b", count: 64))
        try db.write { try $0.execute(sql: """
            CREATE TRIGGER reject_certificate_intent BEFORE INSERT ON cloud_pending_changes
            BEGIN SELECT RAISE(ABORT, 'injected intent failure'); END
            """) }
        XCTAssertThrowsError(try repo.update { certificates, _, flags in
            certificates.append(descriptor)
            flags[descriptor.id] = true
        })
        XCTAssertTrue(try repo.load().state.certificates.isEmpty)
        XCTAssertTrue(try repo.load().localFlags.isEmpty)
        XCTAssertFalse(try cloud.hasPendingChanges(for: "a"))
        try db.validate()
    }

    func testFirstAccountClaimAndPayloadsRollBackTogether() throws {
        // A crash between independent bookmark/certificate claims could split ownership.
        let db = try makeFileBackedDatabase()
        var local = BookmarkCollection()
        let id = local.add(title: "Offline", url: URL(string: "gemini://offline/")!).id
        try BookmarkRepository(database: db).replace(with: local)
        let cloud = CloudSyncRepository(database: db)
        try db.write { try $0.execute(sql: """
            CREATE TRIGGER reject_claim BEFORE INSERT ON cloud_pending_changes
            BEGIN SELECT RAISE(ABORT, 'injected claim failure'); END
            """) }
        XCTAssertThrowsError(try cloud.claimUnownedRows(for: "a"))
        XCTAssertNotNil(try BookmarkRepository(database: db).collection().bookmark(with: id))
        try db.write { try $0.execute(sql: "DROP TRIGGER reject_claim") }
        try cloud.claimUnownedRows(for: "a")
        XCTAssertNotNil(try cloud.pendingChange(recordName: id.uuidString, for: "a")?.modelPayload)
        try cloud.claimUnownedRows(for: "b")
        XCTAssertNil(try BookmarkRepository(database: db, accountIdentityHash: "b").collection().bookmark(with: id))
        try db.validate()
    }

    func testRecoverySnapshotAndReadyMarkerAreAtomicAndGenerationsAdvance() throws {
        let db = try makeFileBackedDatabase()
        let cloud = CloudSyncRepository(database: db)
        var local = BookmarkCollection()
        let id = local.add(title: "Retained", url: URL(string: "gemini://retained/")!).id
        try BookmarkRepository(database: db, accountIdentityHash: "a").replace(with: local)
        let prior = try XCTUnwrap(try cloud.pendingChange(recordName: id.uuidString, for: "a"))
        try db.write { try $0.execute(sql: """
            CREATE TRIGGER reject_ready BEFORE INSERT ON cloud_sync_state
            BEGIN SELECT RAISE(ABORT, 'injected marker failure'); END
            """) }
        XCTAssertThrowsError(try cloud.enqueueLocalSnapshot(for: "a", completingMigration: true))
        XCTAssertEqual(try cloud.pendingChange(recordName: id.uuidString, for: "a"), prior)
        try db.write { try $0.execute(sql: "DROP TRIGGER reject_ready") }
        try cloud.enqueueLocalSnapshot(for: "a", completingMigration: true)
        XCTAssertEqual(try cloud.state(for: "a").migrationPhase, .ready)
        try cloud.saveRecordState(.init(accountIdentityHash: "a", recordType: "MTBookmark",
                                        recordName: id.uuidString, systemFields: Data([1])))
        try cloud.enqueueLocalSnapshot(for: "a", recreatingRemovedZone: true)
        XCTAssertNil(try cloud.recordState(recordName: id.uuidString, for: "a")?.systemFields)
        XCTAssertGreaterThan(try XCTUnwrap(cloud.pendingChange(recordName: id.uuidString, for: "a")).generation, prior.generation)
        XCTAssertNotNil(try cloud.pendingChange(recordName: "data-model-manifest", for: "a")?.modelPayload)
        try db.validate()
    }

    func testTitleEditPreservesUnresolvedParentAndFolderDeleteRebasesSnapshot() throws {
        let db = try makeFileBackedDatabase()
        let cloud = CloudSyncRepository(database: db)
        let repo = BookmarkRepository(database: db, accountIdentityHash: "a")
        let parent = UUID()
        let child = CloudBookmarkPayload(id: UUID(), title: "Original", url: URL(string: "gemini://child/")!,
                                        addedAt: .distantPast, folderID: parent, orderKey: "k", favicon: nil)
        try cloud.journal(.init(modifications: [.init(accountIdentityHash: "a", recordType: "MTBookmark",
            recordName: child.id.uuidString, serverPayload: try CloudRecordPayload(model: child).encoded())], deletions: []), for: "a")
        try cloud.replayIncoming(for: "a")
        _ = try repo.update { $0.rename(bookmarkWith: child.id, to: "Edited") }
        var pending = try XCTUnwrap(cloud.pendingChange(recordName: child.id.uuidString, for: "a"))
        XCTAssertEqual(try JSONDecoder().decode(CloudBookmarkPayload.self, from: XCTUnwrap(pending.modelPayload)).folderID, parent)
        try cloud.journal(.init(modifications: [], deletions: [.init(recordType: "MTBookmarkFolder", recordName: parent.uuidString)]), for: "a")
        try cloud.replayIncoming(for: "a")
        pending = try XCTUnwrap(cloud.pendingChange(recordName: child.id.uuidString, for: "a"))
        let rebased = try JSONDecoder().decode(CloudBookmarkPayload.self, from: XCTUnwrap(pending.modelPayload))
        XCTAssertEqual(rebased.title, "Edited")
        XCTAssertEqual(rebased.folderID, try repo.collection().favoritesID)
        XCTAssertNotNil(try cloud.pendingChange(recordName: rebased.folderID.uuidString, for: "a")?.modelPayload)
        XCTAssertNil(try repo.pendingFolderIDs()[child.id])
        try db.validate()
    }

    func testBoundedPreparationAndLargeIncomingBatchCharacterization() throws {
        let db = try makeFileBackedDatabase()
        let cloud = CloudSyncRepository(database: db)
        var value = BookmarkCollection()
        for n in 0..<450 { value.add(title: "Item \(n)", url: URL(string: "gemini://example/\(n)")!) }
        try BookmarkRepository(database: db, accountIdentityHash: "a").replace(with: value)
        let start = Date()
        let intents = try cloud.preparedChanges(for: "a", limit: 1000)
        XCTAssertEqual(intents.count, 200)
        let states = try intents.map { intent in
            CloudRecordState(accountIdentityHash: "b", recordType: intent.change.recordType,
                             recordName: intent.change.recordName, serverPayload: try intent.envelopedPayload())
        }
        try cloud.journal(.init(modifications: states, deletions: []), for: "b")
        try cloud.replayIncoming(for: "b")
        XCTAssertLessThan(Date().timeIntervalSince(start), 10, "Generous ceiling detects whole-library work per record")
        try db.validate()
    }

    func testIdenticalCertificateUUIDsAndFlagsStayInTheirAccount() throws {
        let db = try makeFileBackedDatabase()
        let a = ClientCertificateSyncRepository(database: db, accountIdentityHash: "a")
        let b = ClientCertificateSyncRepository(database: db, accountIdentityHash: "b")
        let id = UUID()
        var descriptor = ClientCertificateDescriptor(id: id, commonName: "A", notBefore: .distantPast,
            notAfter: .distantFuture, certificateSHA256: String(repeating: "a", count: 64),
            publicKeySHA256: String(repeating: "b", count: 64))
        try a.save(ClientCertificateSyncState().reconciled(certificates: [descriptor], associations: [], at: Date()), localFlags: [id: true])
        descriptor.commonName = "B"
        try b.save(ClientCertificateSyncState().reconciled(certificates: [descriptor], associations: [], at: Date()), localFlags: [id: false])
        XCTAssertEqual(try a.load().state.certificates.first?.commonName, "A")
        XCTAssertEqual(try b.load().state.certificates.first?.commonName, "B")
        XCTAssertEqual(try a.load().localFlags[id], true)
        XCTAssertEqual(try b.load().localFlags[id], false)
        try db.validate()
    }

    func testIdenticalBookmarkUUIDsCannotMoveRowsBetweenAccounts() throws {
        // Review finding: ON CONFLICT(id) reassigned A's UUID to B despite scoped reads.
        let db = try makeFileBackedDatabase()
        let a = BookmarkRepository(database: db, accountIdentityHash: "a")
        let b = BookmarkRepository(database: db, accountIdentityHash: "b")
        var original = BookmarkCollection()
        let bookmark = original.add(title: "A", url: URL(string: "gemini://example/")!)
        try a.replace(with: original)
        var other = original
        other.rename(bookmarkWith: bookmark.id, to: "B")
        try b.replace(with: other)
        XCTAssertEqual(try a.collection().bookmark(with: bookmark.id)?.title, "A")
        XCTAssertEqual(try b.collection().bookmark(with: bookmark.id)?.title, "B")
        other.remove(bookmarkWith: bookmark.id)
        try b.replace(with: other)
        XCTAssertEqual(try a.collection().bookmark(with: bookmark.id)?.title, "A")
        try db.validate()
    }

    func testForeignKeyRejectsParentFromDifferentAccount() throws {
        let db = try makeFileBackedDatabase()
        var value = BookmarkCollection()
        value.add(title: "A", url: URL(string: "gemini://example/")!)
        try BookmarkRepository(database: db, accountIdentityHash: "a").replace(with: value)
        XCTAssertThrowsError(try db.write { sql in
            try sql.execute(sql: """
                INSERT INTO bookmarks(id, folder_id, title, url, added_at, account_identity_hash)
                VALUES (?, ?, 'B', 'gemini://example/', ?, 'b')
                """, arguments: [UUID().uuidString, value.favoritesID.uuidString, Date()])
        })
        try db.validate()
    }

    func testGenerationExhaustionThrowsWithoutChangingOutbox() throws {
        // Review finding: Int64.max + 1 trapped instead of retaining durable intent.
        let db = try makeFileBackedDatabase()
        let repository = CloudSyncRepository(database: db)
        try repository.enqueue(.init(accountIdentityHash: "a", recordType: "MTBookmark",
                                     recordName: "x", operation: .delete))
        try db.write { sql in
            try sql.execute(sql: "UPDATE cloud_record_generations SET last_generation = ?",
                            arguments: [Int64.max])
        }
        XCTAssertThrowsError(try repository.enqueue(.init(accountIdentityHash: "a", recordType: "MTBookmark",
                                                         recordName: "x", operation: .delete))) {
            XCTAssertEqual($0 as? CloudSyncRepositoryError, .generationExhausted)
        }
        XCTAssertEqual(try repository.pendingChange(recordName: "x", for: "a")?.generation, 1)
    }

    func testCorruptGenerationCannotBeReadAsSendableIntent() throws {
        let db = try makeFileBackedDatabase()
        let repository = CloudSyncRepository(database: db)
        try repository.enqueue(.init(accountIdentityHash: "a", recordType: "MTBookmark",
                                     recordName: "x", operation: .delete))
        try db.write { try $0.execute(sql: "UPDATE cloud_pending_changes SET generation = 0") }
        XCTAssertThrowsError(try repository.pendingChanges(for: "a"))
    }

    func testIncomingFailureRollsBackDomainMetadataAndAcknowledgementAndReplays() throws {
        // Review finding: old apply committed domain rows and advanced tokens separately.
        let db = try makeFileBackedDatabase()
        let repository = CloudSyncRepository(database: db)
        let folders = BookmarkRepository(database: db, accountIdentityHash: "a")
        var collection = BookmarkCollection()
        let bookmark = collection.add(title: "Station", url: URL(string: "gemini://example/")!)
        try folders.replace(with: collection)
        let intent = try XCTUnwrap(try repository.preparedChanges(for: "a").first { $0.change.recordName == bookmark.id.uuidString })
        let state = CloudRecordState(accountIdentityHash: "a", recordType: "MTBookmark",
                                     recordName: bookmark.id.uuidString, serverPayload: try intent.envelopedPayload())
        try repository.saveRecordState(state)
        try repository.journal(.init(modifications: [], deletions: [.init(recordType: "MTBookmark", recordName: bookmark.id.uuidString)]), for: "a")
        try db.write { try $0.execute(sql: """
            CREATE TRIGGER fail_incoming_commit BEFORE DELETE ON cloud_incoming_batches
            BEGIN SELECT RAISE(ABORT, 'injected failure'); END
            """) }
        XCTAssertThrowsError(try repository.replayIncoming(for: "a"))
        XCTAssertNotNil(try repository.pendingChange(recordName: bookmark.id.uuidString, for: "a"))
        XCTAssertNotNil(try repository.recordState(recordName: bookmark.id.uuidString, for: "a"))
        XCTAssertNotNil(try folders.collection().bookmark(with: bookmark.id))
        XCTAssertTrue(try repository.hasUnappliedBatches(for: "a"))
        try db.write { try $0.execute(sql: "DROP TRIGGER fail_incoming_commit") }
        try repository.replayIncoming(for: "a")
        XCTAssertNil(try repository.pendingChange(recordName: bookmark.id.uuidString, for: "a"))
        XCTAssertNil(try repository.recordState(recordName: bookmark.id.uuidString, for: "a"))
        XCTAssertNil(try folders.collection().bookmark(with: bookmark.id))
        XCTAssertFalse(try repository.hasUnappliedBatches(for: "a"))
        try db.validate()
    }

    func testMalformedBatchRemainsJournaledWithoutPartialDomainApply() throws {
        let db = try makeFileBackedDatabase()
        let repository = CloudSyncRepository(database: db)
        let folder = CloudBookmarkFolderPayload(id: UUID(), name: "Reading", orderKey: "k")
        try repository.journal(.init(modifications: [
            .init(accountIdentityHash: "a", recordType: "MTBookmarkFolder", recordName: folder.id.uuidString,
                  serverPayload: try CloudRecordPayload(model: folder).encoded()),
            .init(accountIdentityHash: "a", recordType: "MTClientCertificateDescriptor", recordName: UUID().uuidString,
                  serverPayload: Data("malformed".utf8))
        ], deletions: []), for: "a")
        XCTAssertThrowsError(try repository.replayIncoming(for: "a"))
        XCTAssertNil(try BookmarkRepository(database: db, accountIdentityHash: "a").folderPayload(id: folder.id))
        XCTAssertTrue(try repository.hasUnappliedBatches(for: "a"))
    }

    func testPartialFetchPreservesServerOrderKeysAndChildBeforeParent() throws {
        // Review finding: replaceFromCloud regenerated all keys after every partial batch.
        let db = try makeFileBackedDatabase()
        let repository = CloudSyncRepository(database: db)
        let bookmarks = BookmarkRepository(database: db, accountIdentityHash: "a")
        let parent = CloudBookmarkFolderPayload(id: UUID(), name: "Reading", orderKey: "t")
        let child = CloudBookmarkPayload(id: UUID(), title: "Child", url: URL(string: "gemini://example/")!,
                                        addedAt: .distantPast, folderID: parent.id, orderKey: "abcdef", favicon: nil)
        try repository.journal(.init(modifications: [
            .init(accountIdentityHash: "a", recordType: "MTBookmark", recordName: child.id.uuidString,
                  serverPayload: try CloudRecordPayload(model: child).encoded())
        ], deletions: []), for: "a")
        try repository.replayIncoming(for: "a")
        XCTAssertEqual(try bookmarks.pendingFolderIDs()[child.id], parent.id)
        try repository.journal(.init(modifications: [
            .init(accountIdentityHash: "a", recordType: "MTBookmarkFolder", recordName: parent.id.uuidString,
                  serverPayload: try CloudRecordPayload(model: parent).encoded())
        ], deletions: []), for: "a")
        try repository.replayIncoming(for: "a")
        XCTAssertEqual(try bookmarks.collection().folder(containing: child.id)?.id, parent.id)
        XCTAssertEqual(try bookmarks.bookmarkOrderKeys()[child.id], child.orderKey)
        XCTAssertNil(try bookmarks.pendingFolderIDs()[child.id])
        try db.validate()
    }

    func testBookmarkStoreMutationStartsFromLatestCommittedCloudRows() async throws {
        // A long-lived actor cache previously erased remote changes on the next local edit.
        let db = try makeFileBackedDatabase()
        let store = try BookmarkStore(database: db, accountIdentityHash: "a")
        var remote = BookmarkCollection()
        let first = remote.add(title: "Remote", url: URL(string: "gemini://remote/")!)
        try BookmarkRepository(database: db, accountIdentityHash: "a").replaceFromCloud(with: remote)
        let updated = try await store.update { value in
            value.add(title: "Local", url: URL(string: "gemini://local/")!)
        }
        XCTAssertEqual(updated.bookmark(with: first.id)?.title, "Remote")
        XCTAssertEqual(updated.allBookmarks.count, 2)
    }
}
