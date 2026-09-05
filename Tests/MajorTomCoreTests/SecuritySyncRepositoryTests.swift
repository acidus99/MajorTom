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

    func testServerTrustSyncTombstoneRoundTrips() throws {
        let database = try MajorTomDatabase(inMemory: ())
        let repository = ServerTrustSyncRepository(database: database)
        let date = Date(timeIntervalSince1970: 50)
        let decision = SyncedServerTrustDecision(
            endpoint: CapsuleEndpoint(host: "example.com", port: 1_965),
            publicKeySHA256: String(repeating: "d", count: 64),
            firstTrustedAt: date,
            modifiedAt: date,
            deletedAt: date
        )

        try repository.save(SyncedServerTrust(decisions: [decision]))

        XCTAssertEqual(try repository.load(), SyncedServerTrust(decisions: [decision]))
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
