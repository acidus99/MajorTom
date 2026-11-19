import Foundation
import XCTest
@testable import MajorTomCore

final class ClientCertificateStoreTests: XCTestCase {
    @MainActor
    func testDeleteAllDrainsAcceptedCreationBeforeSnapshotAndRejectsNewMaterialWork() async throws {
        let fixture = try CertificateStoreFixture()
        defer { fixture.finish() }
        let entered = expectation(description: "Material creation accepted")
        fixture.material.blockCreation(entered)
        let creating = Task { try await fixture.store.create(request()) }
        let ready = await XCTWaiter.fulfillment(of: [entered], timeout: 2)
        XCTAssertEqual(ready, .completed)
        let deletionStarted = expectation(description: "Deletion entered")
        let deleting = Task { deletionStarted.fulfill(); try await fixture.store.deleteAll() }
        _ = await XCTWaiter.fulfillment(of: [deletionStarted], timeout: 2)
        do { _ = try await fixture.store.create(request()); XCTFail("New material work must be rejected") }
        catch is CancellationError {}
        XCTAssertTrue(fixture.material.deletedIDs.isEmpty)
        fixture.material.releaseCreation()
        let created = try await creating.value
        try await deleting.value
        XCTAssertEqual(fixture.material.deletedIDs, [created.id])
        XCTAssertTrue(fixture.store.certificates.isEmpty)
        XCTAssertTrue(try fixture.repository.load().state.activeCertificates(preservingLocalStorageFrom: []).isEmpty)
    }

    @MainActor
    func testAccountChangeDuringCreationRollsBackOnlyItsNewMaterial() async throws {
        let fixture = try CertificateStoreFixture()
        defer { fixture.finish() }
        let entered = expectation(description: "Material created before account replacement")
        fixture.material.blockCreation(entered)
        let creating = Task { try await fixture.store.create(request()) }
        let ready = await XCTWaiter.fulfillment(of: [entered], timeout: 2)
        XCTAssertEqual(ready, .completed)
        let next = ClientCertificateSyncRepository(database: fixture.database, accountIdentityHash: "synthetic-next")
        fixture.store.replaceRepository(next)
        fixture.material.releaseCreation()
        do { _ = try await creating.value; XCTFail("Old-account creation must not publish") }
        catch is CancellationError {}
        XCTAssertEqual(fixture.material.deletedIDs, fixture.material.createdIDs)
        XCTAssertEqual(fixture.material.createdIDs.count, 1)
        XCTAssertTrue(try next.load().state.activeCertificates(preservingLocalStorageFrom: []).isEmpty)
    }

    @MainActor
    func testFailedMetadataCommitCleansNewMaterialAndDoesNotPublishDescriptor() async throws {
        let fixture = try CertificateStoreFixture()
        defer { fixture.finish() }
        let entered = expectation(description: "New material awaiting metadata")
        fixture.material.blockCreation(entered)
        let creating = Task { try await fixture.store.create(request()) }
        let ready = await XCTWaiter.fulfillment(of: [entered], timeout: 2)
        XCTAssertEqual(ready, .completed)
        try fixture.database.checkpointAndClose()
        fixture.material.releaseCreation()
        do { _ = try await creating.value; XCTFail("Closed storage must refuse metadata") }
        catch { XCTAssertFalse(error is CancellationError) }
        XCTAssertEqual(fixture.material.deletedIDs, fixture.material.createdIDs)
        XCTAssertEqual(fixture.material.createdIDs.count, 1)
        XCTAssertTrue(fixture.store.certificates.isEmpty)
        XCTAssertNotNil(fixture.activity.failure)
    }

    @MainActor
    func testCommittedMetadataReloadDoesNotEchoOrDeleteMissingKeyMaterial() async throws {
        let fixture = try CertificateStoreFixture()
        defer { fixture.finish() }
        let descriptor = MaterialProbe.descriptor(id: UUID(), now: Date())
        _ = try fixture.repository.update { values, _, _ in values.append(descriptor) }
        await fixture.store.reloadCommittedCatalogue()
        XCTAssertEqual(fixture.store.certificates.map(\.id), [descriptor.id])
        let cloud = CloudSyncRepository(database: fixture.database)
        _ = try fixture.repository.update { values, associations, flags in
            values = []; associations = []; flags = [:]
        }
        let pendingBeforeReload = try cloud.pendingChanges(for: "synthetic-original")
        await fixture.store.reloadCommittedCatalogue()
        XCTAssertEqual(try cloud.pendingChanges(for: "synthetic-original"), pendingBeforeReload)
        XCTAssertTrue(fixture.store.certificates.isEmpty)
        XCTAssertTrue(fixture.material.deletedIDs.isEmpty, "Metadata absence never authorizes Keychain deletion")
    }

    private func request() -> ClientCertificateCreationRequest {
        ClientCertificateCreationRequest(commonName: "Synthetic fixture", validUntil: Date().addingTimeInterval(86_400))
    }
}

@MainActor
private final class CertificateStoreFixture {
    let database: MajorTomDatabase
    let repository: ClientCertificateSyncRepository
    let activity = LocalPersistenceActivity()
    let material = MaterialProbe()
    let defaults: UserDefaults
    let suite = "MajorTomTests-\(UUID().uuidString)"
    let store: ClientCertificateStore

    init() throws {
        database = try MajorTomDatabase(inMemory: ())
        repository = ClientCertificateSyncRepository(database: database, accountIdentityHash: "synthetic-original")
        defaults = UserDefaults(suiteName: suite)!
        store = ClientCertificateStore(defaults: defaults, keychain: material, repository: repository, activity: activity)
    }
    func finish() { material.releaseCreation(); defaults.removePersistentDomain(forName: suite) }
}

private final class MaterialProbe: ClientIdentityMaterialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var entered: XCTestExpectation?
    private let gate = DispatchSemaphore(value: 0)
    private var created: [UUID] = []
    private var deleted: [UUID] = []
    var createdIDs: [UUID] { lock.withLock { created } }
    var deletedIDs: [UUID] { lock.withLock { deleted } }
    func blockCreation(_ entered: XCTestExpectation) { lock.withLock { self.entered = entered } }
    func releaseCreation() { gate.signal() }
    func create(_ request: ClientCertificateCreationRequest, id: UUID, now: Date) throws -> ClientCertificateDescriptor {
        let entered = lock.withLock { created.append(id); return self.entered }
        if let entered {
            entered.fulfill()
            guard gate.wait(timeout: .now() + 3) == .success else { throw ProbeFailure.timedOut }
        }
        return Self.descriptor(id: id, now: now)
    }
    static func descriptor(id: UUID, now: Date) -> ClientCertificateDescriptor {
        ClientCertificateDescriptor(id: id, commonName: "Synthetic fixture", notBefore: now,
            notAfter: now.addingTimeInterval(86_400), certificateSHA256: String(repeating: "c", count: 64),
            publicKeySHA256: String(repeating: "d", count: 64))
    }
    func importIdentity(_ imported: ClientCertificateImport, id: UUID) throws -> ClientCertificateDescriptor { throw ProbeFailure.unavailable }
    func delete(_ descriptor: ClientCertificateDescriptor) throws { try delete(id: descriptor.id) }
    func delete(id: UUID) throws { lock.withLock { deleted.append(id) } }
    func certificateDER(for descriptor: ClientCertificateDescriptor) throws -> Data { throw ProbeFailure.unavailable }
    func validateIdentityCanSign(for descriptor: ClientCertificateDescriptor) throws { throw ProbeFailure.unavailable }
    func identity(for descriptor: ClientCertificateDescriptor) throws -> ClientTLSIdentity { throw ProbeFailure.unavailable }
    func exportIdentityPEM(for descriptor: ClientCertificateDescriptor) throws -> String { throw ProbeFailure.unavailable }
    private enum ProbeFailure: Error { case timedOut, unavailable }
}
