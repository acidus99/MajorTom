import Foundation
import XCTest
@testable import MajorTomCore

/// Uses the production journal, partial-record reconciler, outgoing preparation and
/// acknowledgement APIs. Only CloudKit's transport contract is simulated.
final class CloudSyncReliabilitySimulationTests: XCTestCase {
    private var directories: [URL] = []

    private func device(_ account: String = "account") throws -> SimulatedDevice {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        directories.append(directory)
        return try SimulatedDevice(account: account, url: directory.appendingPathComponent("MajorTom.db"))
    }

    override func tearDownWithError() throws {
        for directory in directories { try FileManager.default.removeItem(at: directory) }
    }

    func testProductionPrefixSurvivesStaleFetchAndEmptyMacRestore() throws {
        // Pins the exact production incident against the actual production reconciler.
        let server = FakeCloudServer()
        let a = try device()
        let id = try a.create("Station")
        try a.send(server)
        try a.rename(id, "PRODUCTION - Station")
        try a.fetch(server) // old server data arrives between local commit and send
        XCTAssertEqual(try a.title(id), "PRODUCTION - Station")
        try a.send(server)
        let b = try device() // completely empty local database
        try b.fetch(server)
        try a.fetch(server)
        XCTAssertEqual(try a.title(id), "PRODUCTION - Station")
        XCTAssertEqual(try b.title(id), "PRODUCTION - Station")
    }

    func testCrashBeforeSendAndAfterServerAcceptance() throws {
        let server = FakeCloudServer()
        let a = try device()
        let id = try a.create("Committed before crash")
        let before = try a.cloud.pendingChanges(for: a.account)
        try a.reopen()
        XCTAssertEqual(try a.cloud.pendingChanges(for: a.account), before)
        try a.send(server, acknowledge: false)
        try a.reopen()
        try a.fetch(server)
        try a.send(server) // equality is confirmed by this generation's conditional send
        XCTAssertFalse(try a.cloud.hasPendingChanges(for: a.account))
        XCTAssertEqual(try a.title(id), "Committed before crash")
    }

    func testLateSaveAcknowledgementCannotRemoveNextGeneration() throws {
        let server = FakeCloudServer()
        let a = try device()
        let id = try a.create("N")
        let intent = try XCTUnwrap(try a.cloud.preparedChanges(for: a.account).first {
            $0.change.recordName == id.uuidString
        })
        let result = try server.save(intent, account: a.account)
        try a.rename(id, "N+1")
        try a.cloud.acceptSave(result.record, attempted: intent.change)
        let next = try XCTUnwrap(try a.cloud.pendingChange(recordName: id.uuidString, for: a.account))
        XCTAssertGreaterThan(next.generation, intent.change.generation)
        XCTAssertEqual(try JSONDecoder().decode(CloudBookmarkPayload.self, from: XCTUnwrap(next.modelPayload)).title, "N+1")
    }

    func testFetchedNewerServerValueBeforeOldSuccessRetainsRequiredRetry() throws {
        // Save N succeeds, another Mac writes R, fetch R, then receive N's delayed
        // success. Exact local generation alone used to falsely acknowledge N here.
        let server = FakeCloudServer()
        let a = try device()
        let id = try a.create("Initial")
        try a.send(server)
        try a.rename(id, "Local intent")
        let attempt = try XCTUnwrap(try a.cloud.preparedChanges(for: a.account).first { $0.change.recordName == id.uuidString })
        let accepted = try server.save(attempt, account: a.account)
        let b = try device()
        try b.fetch(server)
        try b.rename(id, "Remote after acceptance")
        try b.send(server)
        try a.fetch(server)
        try a.cloud.acceptSave(accepted.record, attempted: attempt.change)
        XCTAssertNotNil(try a.cloud.pendingChange(recordName: id.uuidString, for: a.account))
        try a.send(server) // stale success metadata encounters the newer server tag
        try a.send(server) // rebased conditional retry
        try b.fetch(server)
        XCTAssertEqual(try b.title(id), "Local intent")
    }

    func testFetchedEqualityCannotAcknowledgeWhileOlderDifferentSaveIsInFlight() throws {
        // Server already contains X. Prepare N, then locally revert to X and fetch X.
        // The prepared N can still be accepted with X's change tag after that fetch.
        let server = FakeCloudServer()
        let a = try device()
        let id = try a.create("X")
        try a.send(server)
        try a.rename(id, "N")
        let attempt = try XCTUnwrap(try a.cloud.preparedChanges(for: a.account).first { $0.change.recordName == id.uuidString })
        try a.rename(id, "X")
        a.token = 0
        try a.fetch(server)
        let accepted = try server.save(attempt, account: a.account)
        try a.cloud.acceptSave(accepted.record, attempted: attempt.change)
        XCTAssertNotNil(try a.cloud.pendingChange(recordName: id.uuidString, for: a.account))
        try a.send(server)
        let b = try device()
        try b.fetch(server)
        XCTAssertEqual(try b.title(id), "X")
    }

    func testCreateAlreadyInFlightAfterConfirmedDeletionIsCompensated() throws {
        // A new CKRecord has no change tag: an in-flight create can land after delete.
        let server = FakeCloudServer()
        let a = try device()
        let id = try a.create("In flight")
        let intent = try XCTUnwrap(try a.cloud.preparedChanges(for: a.account).first { $0.change.recordName == id.uuidString })
        try a.cloud.journal(.init(modifications: [], deletions: [.init(recordType: "MTBookmark", recordName: id.uuidString)]), for: a.account)
        try a.cloud.replayIncoming(for: a.account)
        try a.reopen() // deletion fence is durable, not an in-memory timing flag
        let late = try server.save(intent, account: a.account)
        try a.cloud.acceptSave(late.record, attempted: intent.change)
        XCTAssertEqual(try a.cloud.pendingChange(recordName: id.uuidString, for: a.account)?.operation, .delete)
        XCTAssertNil(try a.title(id))
        try a.send(server)
        XCTAssertNil(server.records[a.account]?[id.uuidString])
    }

    func testFetchedEchoAfterLostCreateCallbackAlsoHonorsDeletionFence() throws {
        let server = FakeCloudServer()
        let a = try device()
        let id = try a.create("Create whose callback will be lost")
        let intent = try XCTUnwrap(try a.cloud.preparedChanges(for: a.account).first { $0.change.recordName == id.uuidString })
        try a.cloud.journal(.init(modifications: [], deletions: [.init(recordType: "MTBookmark", recordName: id.uuidString)]), for: a.account)
        try a.cloud.replayIncoming(for: a.account)
        _ = try server.save(intent, account: a.account)
        try a.reopen()
        try a.fetch(server)
        XCTAssertNil(try a.title(id))
        XCTAssertEqual(try a.cloud.pendingChange(recordName: id.uuidString, for: a.account)?.operation, .delete)
        try a.send(server)
        XCTAssertNil(server.records[a.account]?[id.uuidString])
    }

    func testConflictsRebasePendingTitleAndPreserveUnknownField() throws {
        let server = FakeCloudServer()
        let a = try device()
        let id = try a.create("Station")
        try a.send(server)
        let b = try device()
        try b.fetch(server)
        try server.addFutureField(id.uuidString, account: a.account)
        try a.rename(id, "A")
        try b.rename(id, "B")
        try a.send(server) // conditional conflict records new metadata, retains intent
        try a.send(server)
        try b.send(server) // B rebases on A's newer server record
        try b.send(server)
        try a.fetch(server)
        XCTAssertEqual(try a.title(id), "B")
        let state = try XCTUnwrap(server.records[a.account]?[id.uuidString])
        let json = try JSONDecoder().decode([String: JSONValue].self, from: XCTUnwrap(state.serverPayload))
        XCTAssertEqual(json["futureField"], .string("survives"))
    }

    func testRemoteDeleteWinsOverPendingEditAndDuplicateDeliveryIsIdempotent() throws {
        let server = FakeCloudServer()
        let a = try device()
        let id = try a.create("Station")
        try a.send(server)
        let b = try device()
        try b.fetch(server)
        try b.rename(id, "offline edit")
        try a.remove(id)
        try a.send(server)
        try b.fetch(server)
        b.token = 0
        try b.fetch(server)
        XCTAssertNil(try b.title(id))
        XCTAssertFalse(try b.cloud.hasPendingChanges(for: b.account))
    }

    func testLocalDeleteCannotBeResurrectedByRemoteModification() throws {
        let server = FakeCloudServer()
        let a = try device()
        let id = try a.create("Station")
        try a.send(server)
        let b = try device()
        try b.fetch(server)
        try a.remove(id)
        try b.rename(id, "Remote edit")
        try b.send(server)
        try a.fetch(server)
        XCTAssertNil(try a.title(id))
        try a.send(server)
        try b.fetch(server)
        XCTAssertNil(try b.title(id))
    }

    func testSeededDeliverySchedulesConverge() throws {
        let count = Int(ProcessInfo.processInfo.environment["MAJOR_TOM_SYNC_SEEDS"] ?? "") ?? 24
        for seed in 0..<count {
            let server = FakeCloudServer()
            let a = try device()
            let b = try device()
            var id = try a.create("Station")
            try a.send(server)
            try b.fetch(server)
            var random = UInt64(seed + 1)
            for step in 0..<30 {
                random = random &* 6364136223846793005 &+ 1442695040888963407
                let device = random & 1 == 0 ? a : b
                switch (random >> 16) % 7 {
                case 0: try device.rename(id, "seed-\(seed)-step-\(step)")
                case 1: try device.send(server)
                case 2: try device.fetch(server)
                case 3: try device.reopen()
                case 4: try device.remove(id)
                case 5: id = try device.create("recreated-\(seed)-\(step)")
                default: device.token = 0; try device.fetch(server)
                }
            }
            for _ in 0..<8 {
                try a.send(server); try b.send(server)
                try a.fetch(server); try b.fetch(server)
            }
            let aValues = try a.bookmarks.collection().allBookmarks.sorted { $0.id.uuidString < $1.id.uuidString }
            let bValues = try b.bookmarks.collection().allBookmarks.sorted { $0.id.uuidString < $1.id.uuidString }
            XCTAssertEqual(aValues, bValues, "seed=\(seed)")
            XCTAssertFalse(try a.cloud.hasPendingChanges(for: a.account), "seed=\(seed)")
            XCTAssertFalse(try b.cloud.hasPendingChanges(for: b.account), "seed=\(seed)")
            try a.database.validate()
            try b.database.validate()
        }
    }
}

private final class FakeCloudServer {
    enum Failure: Error { case unknownItem }
    struct Result { var record: CloudRecordState; var conflict: Bool }
    var records: [String: [String: CloudRecordState]] = [:]
    private var logs: [String: [CloudIncomingBatch]] = [:]
    private var version: Int64 = 0

    func save(_ intent: CloudOutgoingIntent, account: String) throws -> Result {
        let name = intent.change.recordName
        if records[account]?[name] == nil, intent.server != nil { throw Failure.unknownItem }
        if let existing = records[account]?[name], existing.lastSeenEpoch != intent.server?.lastSeenEpoch {
            return Result(record: existing, conflict: true)
        }
        version += 1
        let state = CloudRecordState(accountIdentityHash: account, recordType: intent.change.recordType,
                                     recordName: name, serverPayload: try intent.envelopedPayload(), lastSeenEpoch: version)
        records[account, default: [:]][name] = state
        logs[account, default: []].append(.init(modifications: [state], deletions: []))
        return Result(record: state, conflict: false)
    }

    func delete(_ change: CloudPendingChange, account: String) {
        records[account, default: [:]][change.recordName] = nil
        logs[account, default: []].append(.init(modifications: [], deletions: [
            .init(recordType: change.recordType, recordName: change.recordName)
        ]))
    }

    func changes(account: String, after token: Int) -> ([CloudIncomingBatch], Int) {
        let log = logs[account] ?? []
        return (Array(log.dropFirst(token)), log.count)
    }

    func addFutureField(_ name: String, account: String) throws {
        var state = try XCTUnwrap(records[account]?[name])
        var json = try JSONDecoder().decode([String: JSONValue].self, from: XCTUnwrap(state.serverPayload))
        json["futureField"] = .string("survives")
        state.serverPayload = try JSONEncoder().encode(json)
        version += 1
        state.lastSeenEpoch = version
        records[account]?[name] = state
        logs[account, default: []].append(.init(modifications: [state], deletions: []))
    }
}

private final class SimulatedDevice {
    let account: String
    let url: URL
    var database: MajorTomDatabase
    var token = 0
    var cloud: CloudSyncRepository { CloudSyncRepository(database: database) }
    var bookmarks: BookmarkRepository { BookmarkRepository(database: database, accountIdentityHash: account) }

    init(account: String, url: URL) throws {
        self.account = account
        self.url = url
        database = try MajorTomDatabase(fileURL: url)
    }

    func reopen() throws {
        try database.checkpointAndClose()
        database = try MajorTomDatabase(fileURL: url)
        try cloud.replayIncoming(for: account)
    }

    func create(_ title: String) throws -> UUID {
        var value = try bookmarks.collection()
        let bookmark = value.add(title: title, url: URL(string: "gemini://station.example/")!,
                                 at: Date(timeIntervalSince1970: 1))
        try bookmarks.replace(with: value)
        return bookmark.id
    }

    func rename(_ id: UUID, _ title: String) throws {
        _ = try bookmarks.update { $0.rename(bookmarkWith: id, to: title) }
    }

    func remove(_ id: UUID) throws {
        _ = try bookmarks.update { $0.remove(bookmarkWith: id) }
    }

    func title(_ id: UUID) throws -> String? { try bookmarks.collection().bookmark(with: id)?.title }

    func send(_ server: FakeCloudServer, acknowledge: Bool = true) throws {
        for intent in try cloud.preparedChanges(for: account) {
            if intent.change.operation == .delete {
                server.delete(intent.change, account: account)
                if acknowledge {
                    try cloud.acknowledgeDeletion(recordName: intent.change.recordName,
                                                  generation: intent.change.generation, for: account)
                }
            } else {
                let result: FakeCloudServer.Result
                do { result = try server.save(intent, account: account) }
                catch FakeCloudServer.Failure.unknownItem { continue } // no deletion is inferred; await its event
                if acknowledge {
                    try cloud.acceptSave(result.record, attempted: intent.change, isConflict: result.conflict)
                }
            }
        }
    }

    func fetch(_ server: FakeCloudServer) throws {
        let (batches, next) = server.changes(account: account, after: token)
        for batch in batches {
            try cloud.journal(batch, for: account)
            try cloud.replayIncoming(for: account)
        }
        token = next
    }
}
