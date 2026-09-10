import Foundation
import GRDB
import XCTest
@testable import MajorTomCore

final class SecuritySyncRepositoryTests: XCTestCase {
    func testTrustedIdentitiesRoundTripPerEndpointAndDeleteIndependently() throws {
        let database = try MajorTomDatabase(inMemory: ())
        let repository = TrustedIdentityRepository(database: database)
        let first = identity(host: "one.example", fingerprint: "a")
        let second = identity(host: "two.example", fingerprint: "b")
        try repository.save([first, second])
        try repository.save([second])

        XCTAssertEqual(try repository.identities(), [second])
        let count = try database.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM trusted_server_identities") }
        XCTAssertEqual(count, 1)
    }

    func testTrustedIdentityStoreCanUseSQLiteBackend() async throws {
        let database = try MajorTomDatabase(inMemory: ())
        let store = try TrustedIdentityStore(database: database)
        let presented = PresentedServerIdentity(
            endpoint: CapsuleEndpoint(host: "capsule.example", port: 1_965),
            publicKeySHA256: String(repeating: "c", count: 64)
        )
        try await store.trust(presented, source: .user)

        let reopened = try TrustedIdentityStore(database: database)
        let loaded = await reopened.identity(for: presented.endpoint)
        XCTAssertEqual(loaded?.publicKeySHA256, presented.publicKeySHA256)
    }

    func testClientCertificateMetadataAndLocalFlagRoundTrip() throws {
        let database = try MajorTomDatabase(inMemory: ())
        let repository = ClientCertificateSyncRepository(database: database)
        let id = UUID()
        let descriptor = ClientCertificateDescriptor(
            id: id,
            commonName: "Identity",
            notBefore: .distantPast,
            notAfter: .distantFuture,
            certificateSHA256: String(repeating: "a", count: 64),
            publicKeySHA256: String(repeating: "b", count: 64),
            synchronizesWithICloud: false
        )
        let association = ClientCertificateAssociation.entireCapsule(
            certificateID: id,
            endpoint: CapsuleEndpoint(host: "example.com", port: 1_965)
        )
        let state = ClientCertificateSyncState().reconciled(
            certificates: [descriptor],
            associations: [association],
            at: Date(timeIntervalSince1970: 10)
        )

        try repository.save(state, localFlags: [id: false])
        let loaded = try repository.load()

        XCTAssertEqual(loaded.state, state)
        XCTAssertEqual(loaded.localFlags, [id: false])
    }

    func testCertificateRowsAndDeletesShareTheAccountOutbox() throws {
        let database = try MajorTomDatabase(inMemory: ())
        let repository = ClientCertificateSyncRepository(
            database: database,
            accountIdentityHash: "account"
        )
        let id = UUID()
        let descriptor = ClientCertificateDescriptor(
            id: id,
            commonName: "Identity",
            notBefore: .distantPast,
            notAfter: .distantFuture,
            certificateSHA256: String(repeating: "a", count: 64),
            publicKeySHA256: String(repeating: "b", count: 64)
        )
        let state = ClientCertificateSyncState().reconciled(
            certificates: [descriptor], associations: [], at: Date(timeIntervalSince1970: 10)
        )
        try repository.save(state, localFlags: [id: true])

        var pending = try CloudSyncRepository(database: database).pendingChanges(for: "account")
        XCTAssertEqual(pending.map(\.operation), [.save])

        try repository.save(ClientCertificateSyncState(), localFlags: [:])
        pending = try CloudSyncRepository(database: database).pendingChanges(for: "account")
        XCTAssertEqual(pending.map(\.operation), [.delete])
        XCTAssertTrue(try repository.load().state.certificates.isEmpty)
    }

    func testUnchangedLocalFlagsDoNotRewriteEveryRow() throws {
        let database = try MajorTomDatabase(inMemory: ())
        let repository = ClientCertificateSyncRepository(database: database)
        let id = UUID()
        try repository.save(ClientCertificateSyncState(), localFlags: [id: true])
        let before = try database.read { try Int.fetchOne($0, sql: "SELECT total_changes()")! }

        try repository.save(ClientCertificateSyncState(), localFlags: [id: true])

        let after = try database.read { try Int.fetchOne($0, sql: "SELECT total_changes()")! }
        XCTAssertEqual(after, before)
    }

    func testExplicitCertificateDeletionQueuesEveryAliasAndAssociation() throws {
        // Prevents a duplicate metadata UUID on another Mac from surviving a user
        // deletion after local fingerprint reconciliation has hidden that row.
        let database = try MajorTomDatabase(inMemory: ())
        let account = "account"
        let repository = ClientCertificateSyncRepository(
            database: database,
            accountIdentityHash: account
        )
        let descriptorIDs: Set<UUID> = [UUID(), UUID(), UUID()]
        let associationIDs: Set<UUID> = [UUID(), UUID()]

        try repository.enqueueExplicitDeletion(
            descriptorIDs: descriptorIDs,
            associationIDs: associationIDs
        )

        let pending = try CloudSyncRepository(database: database).pendingChanges(for: account)
        XCTAssertEqual(Set(pending.map(\.recordName)), Set(
            descriptorIDs.map(\.uuidString) + associationIDs.map(\.uuidString)
        ))
        XCTAssertTrue(pending.allSatisfy { $0.operation == .delete })
        XCTAssertEqual(
            pending.filter { $0.recordType == "MTClientCertificateDescriptor" }.count,
            descriptorIDs.count
        )
        XCTAssertEqual(
            pending.filter { $0.recordType == "MTClientCertificateAssociation" }.count,
            associationIDs.count
        )
    }

    func testFetchedCertificateMetadataDoesNotEcho() throws {
        let database = try MajorTomDatabase(inMemory: ())
        let repository = ClientCertificateSyncRepository(
            database: database,
            accountIdentityHash: "account"
        )
        try repository.saveFromCloud(ClientCertificateSyncState(), localFlags: [:])
        XCTAssertFalse(try CloudSyncRepository(database: database)
            .hasPendingChanges(for: "account"))
    }

    private func identity(host: String, fingerprint: String) -> TrustedServerIdentity {
        TrustedServerIdentity(
            endpoint: CapsuleEndpoint(host: host, port: 1_965),
            publicKeySHA256: String(repeating: fingerprint, count: 64),
            source: .user,
            firstTrustedAt: Date(timeIntervalSince1970: 1),
            lastSeenAt: Date(timeIntervalSince1970: 2)
        )
    }
}
