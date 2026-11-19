import Foundation
import XCTest
@testable import MajorTomCore

final class ICloudSynchronizationTests: XCTestCase {
    @MainActor
    func testShutdownDrainsAcceptedBootstrapTransactionAndRejectsLateNetworkResultWork() async throws {
        let suite = "MajorTomTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let database = try MajorTomDatabase(inMemory: ())
        let sync = ICloudSynchronization(defaults: defaults, database: database, activity: LocalPersistenceActivity())
        // start() is intentionally not called: no account, CloudKit, KVS or network work.
        let gate = DispatchSemaphore(value: 0)
        defer { gate.signal() }
        let entered = expectation(description: "Local transaction accepted")
        let repository = BookmarkRepository(database: database)
        let url = URL(string: "gemini://example.invalid/accepted")!
        let writing = Task {
            try await sync.executeLocal {
                entered.fulfill()
                guard gate.wait(timeout: .now() + 3) == .success else { throw FixtureError.timedOut }
                var collection = BookmarkCollection()
                collection.add(title: "Accepted fixture", url: url)
                try repository.replace(with: collection)
            }
        }
        let ready = await XCTWaiter.fulfillment(of: [entered], timeout: 2)
        XCTAssertEqual(ready, .completed)
        var closed = false
        let stopping = expectation(description: "Shutdown requested")
        let terminating = Task {
            stopping.fulfill()
            await sync.prepareForTermination()
            closed = true
        }
        _ = await XCTWaiter.fulfillment(of: [stopping], timeout: 2)
        XCTAssertFalse(closed)
        do {
            try await sync.executeLocal { XCTFail("Late bootstrap/network results must not start a transaction") }
            XCTFail("Expected shutdown fence")
        } catch is CancellationError {}
        gate.signal()
        try await writing.value
        await terminating.value
        XCTAssertTrue(closed)
        XCTAssertTrue(try repository.collection().contains(url: url))
        try database.checkpointAndClose()
    }

    @MainActor
    func testActivationCannotStartSynchronizationBeforeCompositionIsReady() async throws {
        let suite = "MajorTomTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let sync = ICloudSynchronization(defaults: defaults, database: try MajorTomDatabase(inMemory: ()),
            activity: LocalPersistenceActivity())
        let initial = sync.status
        sync.refresh(trigger: .activation)
        sync.refresh(trigger: .reconnection)
        XCTAssertEqual(sync.status, initial)
        await sync.prepareForTermination()
    }

    private enum FixtureError: Error { case timedOut }
}
