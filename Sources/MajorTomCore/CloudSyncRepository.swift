import Foundation
import GRDB
import CryptoKit

public enum CloudMigrationPhase: String, Codable, Sendable {
    case notStarted
    case importingV1
    case publishingV2
    case ready
}

public enum CloudZoneState: String, Codable, Sendable {
    case neverEstablished
    case active
    case removed
}

public struct CloudSyncState: Equatable, Sendable {
    public static let currentModelMajor = 3

    public var accountIdentityHash: String
    public var engineState: Data?
    public var modelMajor: Int
    public var migratedFromV1: Bool
    public var migrationPhase: CloudMigrationPhase
    public var zoneState: CloudZoneState
    public var favoritesFolderID: UUID?
    public var lastFetchedAt: Date?
    public var lastSentAt: Date?
    public var updatedAt: Date

    public init(
        accountIdentityHash: String,
        engineState: Data? = nil,
        modelMajor: Int = currentModelMajor,
        migratedFromV1: Bool = false,
        migrationPhase: CloudMigrationPhase = .notStarted,
        zoneState: CloudZoneState = .neverEstablished,
        favoritesFolderID: UUID? = nil,
        lastFetchedAt: Date? = nil,
        lastSentAt: Date? = nil,
        updatedAt: Date = Date()
    ) {
        self.accountIdentityHash = accountIdentityHash
        self.engineState = engineState
        self.modelMajor = modelMajor
        self.migratedFromV1 = migratedFromV1
        self.migrationPhase = migrationPhase
        self.zoneState = zoneState
        self.favoritesFolderID = favoritesFolderID
        self.lastFetchedAt = lastFetchedAt
        self.lastSentAt = lastSentAt
        self.updatedAt = updatedAt
    }
}

public enum CloudPendingOperation: String, Codable, Sendable {
    case save
    case delete
}

public struct CloudPendingChange: Equatable, Sendable {
    public var accountIdentityHash: String
    public var recordType: String
    public var recordName: String
    public var operation: CloudPendingOperation
    public var generation: Int64
    /// Canonical JSON for the typed model the local transaction committed. This is
    /// deliberately not the CloudKit envelope: retries merge this model with the latest
    /// server envelope to preserve fields unknown to this build.
    public var modelPayload: Data?
    public var payloadDigest: String?
    public var enqueuedAt: Date

    public init(
        accountIdentityHash: String,
        recordType: String,
        recordName: String,
        operation: CloudPendingOperation,
        generation: Int64 = 0,
        modelPayload: Data? = nil,
        payloadDigest: String? = nil,
        enqueuedAt: Date = Date()
    ) {
        self.accountIdentityHash = accountIdentityHash
        self.recordType = recordType
        self.recordName = recordName
        self.operation = operation
        self.generation = generation
        self.modelPayload = modelPayload
        self.payloadDigest = payloadDigest
        self.enqueuedAt = enqueuedAt
    }
}

public enum CloudSyncRepositoryError: Error, Equatable, Sendable {
    case saveMissingPayload
    case deleteHasPayload
    case invalidPayloadDigest
    case invalidPendingOperation(String)
    case invalidGeneration(Int64)
    case invalidRecordIdentity
    case generationExhausted
    case invalidSyncState
}

/// The local intent that must win while a CloudKit record change is in flight.
///
/// A fetched modification may carry the server value from immediately before a local
/// edit. Applying it would replace the row that the pending save reads, causing the
/// subsequent upload to send the stale server value back to CloudKit. Deletions are
/// included because a record queued for deletion must not be recreated locally while
/// its delete is pending. Confirmed server deletions are handled separately and still
/// win over local edits.
public struct CloudPendingChangeSet: Equatable, Sendable {
    public let saves: Set<String>
    public let deletes: Set<String>

    public init(_ changes: some Sequence<CloudPendingChange>) {
        saves = Set(changes.filter { $0.operation == .save }.map(\.recordName))
        deletes = Set(changes.filter { $0.operation == .delete }.map(\.recordName))
    }

    public func allowsFetchedModification(recordName: String) -> Bool {
        !saves.contains(recordName) && !deletes.contains(recordName)
    }
}

public struct CloudRecordState: Codable, Equatable, Sendable {
    public var accountIdentityHash: String
    public var recordType: String
    public var recordName: String
    public var systemFields: Data?
    public var serverPayload: Data?
    public var payloadDigest: String?
    public var lastSeenEpoch: Int64?
    public var updatedAt: Date

    public init(
        accountIdentityHash: String,
        recordType: String,
        recordName: String,
        systemFields: Data? = nil,
        serverPayload: Data? = nil,
        payloadDigest: String? = nil,
        lastSeenEpoch: Int64? = nil,
        updatedAt: Date = Date()
    ) {
        self.accountIdentityHash = accountIdentityHash
        self.recordType = recordType
        self.recordName = recordName
        self.systemFields = systemFields
        self.serverPayload = serverPayload
        self.payloadDigest = payloadDigest
        self.lastSeenEpoch = lastSeenEpoch
        self.updatedAt = updatedAt
    }
}

/// Durable account state, record metadata, and transactional sync outbox.
public struct CloudSyncRepository: Sendable {
    private static let activeAccountKey = "cloud-sync-active-account-v2"
    let database: MajorTomDatabase

    public init(database: MajorTomDatabase) {
        self.database = database
    }

    public func activeAccountIdentityHash() throws -> String? {
        try database.read { db in
            guard let data = try Data.fetchOne(
                db,
                sql: "SELECT value FROM persistence_metadata WHERE key = ?",
                arguments: [Self.activeAccountKey]
            ) else { return nil }
            return String(data: data, encoding: .utf8)
        }
    }

    public func saveActiveAccountIdentityHash(_ hash: String?) throws {
        return try database.write { db in
            if let hash {
                try db.execute(
                    sql: """
                        INSERT INTO persistence_metadata (key, value, updated_at) VALUES (?, ?, ?)
                        ON CONFLICT(key) DO UPDATE SET value = excluded.value, updated_at = excluded.updated_at
                        """,
                    arguments: [Self.activeAccountKey, Data(hash.utf8), Date()]
                )
            } else {
                try db.execute(
                    sql: "DELETE FROM persistence_metadata WHERE key = ?",
                    arguments: [Self.activeAccountKey]
                )
            }
        }
    }

    public func state(for accountIdentityHash: String) throws -> CloudSyncState {
        try database.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT * FROM cloud_sync_state WHERE account_identity_hash = ?",
                arguments: [accountIdentityHash]
            ) else { return CloudSyncState(accountIdentityHash: accountIdentityHash) }
            return try Self.state(from: row)
        }
    }

    public func save(_ state: CloudSyncState) throws {
        try database.write { db in try Self.save(state, in: db) }
    }

    public func saveEngineState(_ data: Data?, for accountIdentityHash: String) throws {
        try database.write { db in
            var value = try Row.fetchOne(db, sql: "SELECT * FROM cloud_sync_state WHERE account_identity_hash = ?",
                                         arguments: [accountIdentityHash]).map(Self.state(from:)) ?? CloudSyncState(accountIdentityHash: accountIdentityHash)
            value.engineState = data
            value.updatedAt = Date()
            try Self.save(value, in: db)
        }
    }

    public func markMigratedFromV1(for accountIdentityHash: String) throws {
        var value = try state(for: accountIdentityHash)
        value.migratedFromV1 = true
        value.migrationPhase = .ready
        value.updatedAt = Date()
        try save(value)
    }

    @discardableResult
    public func enqueue(_ change: CloudPendingChange, in db: Database) throws -> Int64 {
        switch change.operation {
        case .save:
            guard let payload = change.modelPayload else {
                // Pre-v11 rows are materialized by the coordinator. New writes must
                // never create another identity-only save.
                throw CloudSyncRepositoryError.saveMissingPayload
            }
            guard change.payloadDigest == Self.digest(payload) else {
                throw CloudSyncRepositoryError.invalidPayloadDigest
            }
            try db.execute(sql: "DELETE FROM cloud_confirmed_deletions WHERE account_identity_hash = ? AND record_name = ?",
                           arguments: [change.accountIdentityHash, change.recordName])
        case .delete:
            guard change.modelPayload == nil, change.payloadDigest == nil else {
                throw CloudSyncRepositoryError.deleteHasPayload
            }
        }

        let ledger = try Int64.fetchOne(
            db,
            sql: "SELECT last_generation FROM cloud_record_generations WHERE account_identity_hash = ? AND record_name = ?",
            arguments: [change.accountIdentityHash, change.recordName]
        ) ?? 0
        let pendingGeneration = try Int64.fetchOne(
            db,
            sql: "SELECT MAX(generation) FROM cloud_pending_changes WHERE account_identity_hash = ? AND record_name = ?",
            arguments: [change.accountIdentityHash, change.recordName]
        ) ?? 0
        guard ledger >= 0, pendingGeneration >= 0 else { throw CloudSyncRepositoryError.invalidGeneration(min(ledger, pendingGeneration)) }
        let prior = max(ledger, pendingGeneration)
        guard prior < Int64.max else { throw CloudSyncRepositoryError.generationExhausted }
        let generation = prior + 1
        try db.execute(
            sql: """
                INSERT INTO cloud_record_generations
                    (account_identity_hash, record_name, last_generation)
                VALUES (?, ?, ?)
                ON CONFLICT(account_identity_hash, record_name) DO UPDATE SET
                    last_generation = excluded.last_generation
                """,
            arguments: [change.accountIdentityHash, change.recordName, generation]
        )
        try db.execute(
            sql: """
                INSERT INTO cloud_pending_changes
                    (account_identity_hash, record_type, record_name, operation, generation, model_payload, payload_digest, enqueued_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(account_identity_hash, record_name) DO UPDATE SET
                    record_type = excluded.record_type,
                    operation = excluded.operation,
                    generation = excluded.generation,
                    model_payload = excluded.model_payload,
                    payload_digest = excluded.payload_digest,
                    enqueued_at = excluded.enqueued_at
                """,
            arguments: [
                change.accountIdentityHash, change.recordType, change.recordName,
                change.operation.rawValue, generation, change.modelPayload,
                change.payloadDigest, change.enqueuedAt
            ]
        )
        return generation
    }

    public func enqueue(_ change: CloudPendingChange) throws {
        _ = try database.write { db in try enqueue(change, in: db) }
    }

    /// Enqueues an immutable typed save snapshot in the caller's transaction.
    @discardableResult
    public func enqueueSave<Value: CloudSyncPayload>(
        accountIdentityHash: String,
        recordType: String,
        recordName: String,
        payload: Value,
        enqueuedAt: Date = Date(),
        in db: Database
    ) throws -> Int64 {
        let data = try Self.encodeModelPayload(payload)
        return try enqueue(CloudPendingChange(
            accountIdentityHash: accountIdentityHash,
            recordType: recordType,
            recordName: recordName,
            operation: .save,
            modelPayload: data,
            payloadDigest: Self.digest(data),
            enqueuedAt: enqueuedAt
        ), in: db)
    }

    /// Enqueues an immutable typed save snapshot in its own transaction.
    @discardableResult
    public func enqueueSave<Value: CloudSyncPayload>(
        accountIdentityHash: String,
        recordType: String,
        recordName: String,
        payload: Value,
        enqueuedAt: Date = Date()
    ) throws -> Int64 {
        try database.write { db in
            try enqueueSave(
                accountIdentityHash: accountIdentityHash,
                recordType: recordType,
                recordName: recordName,
                payload: payload,
                enqueuedAt: enqueuedAt,
                in: db
            )
        }
    }

    public static func encodeModelPayload<Value: Encodable>(_ payload: Value) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(payload)
    }

    public static func digest(_ payload: Data) -> String {
        SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
    }

    public func pendingChanges(for accountIdentityHash: String, limit: Int = 200) throws -> [CloudPendingChange] {
        try database.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT * FROM cloud_pending_changes
                    WHERE account_identity_hash = ?
                    ORDER BY enqueued_at, record_name
                    LIMIT ?
                    """,
                arguments: [accountIdentityHash, max(0, limit)]
            ).map { try Self.pendingChange(from: $0) }
        }
    }

    public func pendingChange(
        recordName: String,
        for accountIdentityHash: String
    ) throws -> CloudPendingChange? {
        try database.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: """
                    SELECT * FROM cloud_pending_changes
                    WHERE account_identity_hash = ? AND record_name = ?
                    """,
                arguments: [accountIdentityHash, recordName]
            ) else { return nil }
            return try Self.pendingChange(from: row)
        }
    }

    public func hasPendingChanges(for accountIdentityHash: String) throws -> Bool {
        try database.read { db in
            try Bool.fetchOne(
                db,
                sql: "SELECT EXISTS(SELECT 1 FROM cloud_pending_changes WHERE account_identity_hash = ?)",
                arguments: [accountIdentityHash]
            ) ?? false
        }
    }

    /// Returns every pending record name for conflict handling. This is deliberately
    /// not limited to the next 200-record send batch: a fetched record must never
    /// overwrite local intent merely because that intent is waiting in a later batch.
    public func pendingChangeSet(for accountIdentityHash: String) throws -> CloudPendingChangeSet {
        CloudPendingChangeSet(try pendingChanges(
            for: accountIdentityHash,
            limit: .max
        ))
    }

    /// Acknowledges only the generation that was actually sent.
    @discardableResult
    public func acknowledge(
        recordName: String,
        generation: Int64,
        for accountIdentityHash: String
    ) throws -> Bool {
        guard generation > 0 else { throw CloudSyncRepositoryError.invalidGeneration(generation) }
        return try database.write { db in
            try db.execute(
                sql: "DELETE FROM cloud_pending_changes WHERE account_identity_hash = ? AND record_name = ? AND generation = ?",
                arguments: [accountIdentityHash, recordName, generation]
            )
            return db.changesCount > 0
        }
    }

    /// Stores server metadata and acknowledges exactly one attempted generation under
    /// one SQLite transaction. A late acknowledgement cannot remove a newer coalesced
    /// user edit.
    @discardableResult
    public func acknowledge(
        recordName: String,
        generation: Int64,
        for accountIdentityHash: String,
        saving state: CloudRecordState?
    ) throws -> Bool {
        guard generation > 0 else { throw CloudSyncRepositoryError.invalidGeneration(generation) }
        if let state, state.accountIdentityHash != accountIdentityHash || state.recordName != recordName {
            throw CloudSyncRepositoryError.invalidRecordIdentity
        }
        return try database.write { db in
            if let state { try Self.saveRecordState(state, in: db) }
            try db.execute(
                sql: "DELETE FROM cloud_pending_changes WHERE account_identity_hash = ? AND record_name = ? AND generation = ?",
                arguments: [accountIdentityHash, recordName, generation]
            )
            let acknowledged = db.changesCount > 0
            try db.execute(sql: "UPDATE cloud_sync_state SET last_sent_at = ?, updated_at = ? WHERE account_identity_hash = ?",
                           arguments: [Date(), Date(), accountIdentityHash])
            return acknowledged
        }
    }

    @discardableResult
    public func acknowledgeDeletion(recordName: String, generation: Int64, for account: String) throws -> Bool {
        guard generation > 0 else { throw CloudSyncRepositoryError.invalidGeneration(generation) }
        return try database.write { db in
            try db.execute(sql: "DELETE FROM cloud_pending_changes WHERE account_identity_hash = ? AND record_name = ? AND generation = ? AND operation = 'delete'",
                           arguments: [account, recordName, generation])
            let acknowledged = db.changesCount > 0
            if acknowledged {
                try db.execute(sql: "DELETE FROM cloud_record_state WHERE account_identity_hash = ? AND record_name = ?",
                               arguments: [account, recordName])
            }
            try db.execute(sql: "UPDATE cloud_sync_state SET last_sent_at = ?, updated_at = ? WHERE account_identity_hash = ?",
                           arguments: [Date(), Date(), account])
            return acknowledged
        }
    }

    public func removeAllPending(for accountIdentityHash: String) throws {
        try database.write { db in
            try db.execute(
                sql: "DELETE FROM cloud_pending_changes WHERE account_identity_hash = ?",
                arguments: [accountIdentityHash]
            )
        }
    }

    /// A fetched deletion is server-confirmed and therefore wins over any local save
    /// or delete intent for this record. Domain-row deletion is performed by the typed
    /// repository; this method atomically clears the matching sync bookkeeping.
    public func resolveFetchedDeletion(
        recordName: String,
        for accountIdentityHash: String
    ) throws {
        try database.write { db in
            try db.execute(
                sql: "DELETE FROM cloud_pending_changes WHERE account_identity_hash = ? AND record_name = ?",
                arguments: [accountIdentityHash, recordName]
            )
            try db.execute(
                sql: "DELETE FROM cloud_record_state WHERE account_identity_hash = ? AND record_name = ?",
                arguments: [accountIdentityHash, recordName]
            )
        }
    }

    public func recordState(
        recordName: String,
        for accountIdentityHash: String
    ) throws -> CloudRecordState? {
        try database.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT * FROM cloud_record_state WHERE account_identity_hash = ? AND record_name = ?",
                arguments: [accountIdentityHash, recordName]
            ) else { return nil }
            return Self.recordState(from: row)
        }
    }

    public func saveRecordState(_ state: CloudRecordState) throws {
        try database.write { db in try Self.saveRecordState(state, in: db) }
    }

    public static func saveRecordState(_ state: CloudRecordState, in db: Database) throws {
        try db.execute(
                sql: """
                    INSERT INTO cloud_record_state
                        (account_identity_hash, record_type, record_name, system_fields, server_payload,
                         payload_digest, last_seen_epoch, updated_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(account_identity_hash, record_name) DO UPDATE SET
                        record_type = excluded.record_type,
                        system_fields = excluded.system_fields,
                        server_payload = excluded.server_payload,
                        payload_digest = excluded.payload_digest,
                        last_seen_epoch = excluded.last_seen_epoch,
                        updated_at = excluded.updated_at
                    """,
                arguments: [
                    state.accountIdentityHash, state.recordType, state.recordName,
                    state.systemFields, state.serverPayload, state.payloadDigest,
                    state.lastSeenEpoch, state.updatedAt
                ]
        )
    }

    static func save(_ state: CloudSyncState, in db: Database) throws {
        try db.execute(
            sql: """
                INSERT INTO cloud_sync_state
                    (account_identity_hash, engine_state, model_major, migrated_from_v1,
                     migration_phase, zone_state, favorites_folder_id, last_fetched_at,
                     last_sent_at, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(account_identity_hash) DO UPDATE SET
                    engine_state = excluded.engine_state,
                    model_major = excluded.model_major,
                    migrated_from_v1 = excluded.migrated_from_v1,
                    migration_phase = excluded.migration_phase,
                    zone_state = excluded.zone_state,
                    favorites_folder_id = excluded.favorites_folder_id,
                    last_fetched_at = excluded.last_fetched_at,
                    last_sent_at = excluded.last_sent_at,
                    updated_at = excluded.updated_at
                """,
            arguments: [
                state.accountIdentityHash, state.engineState, state.modelMajor,
                state.migratedFromV1, state.migrationPhase.rawValue, state.zoneState.rawValue,
                state.favoritesFolderID?.uuidString, state.lastFetchedAt, state.lastSentAt,
                state.updatedAt
            ]
        )
    }

    static func state(from row: Row) throws -> CloudSyncState {
        let migrationRaw: String = row["migration_phase"]
        let zoneRaw: String = row["zone_state"]
        let favorites: String? = row["favorites_folder_id"]
        guard let migration = CloudMigrationPhase(rawValue: migrationRaw),
              let zone = CloudZoneState(rawValue: zoneRaw),
              favorites == nil || favorites.flatMap(UUID.init(uuidString:)) != nil else {
            throw CloudSyncRepositoryError.invalidSyncState
        }
        return CloudSyncState(
            accountIdentityHash: row["account_identity_hash"],
            engineState: row["engine_state"],
            modelMajor: row["model_major"],
            migratedFromV1: row["migrated_from_v1"],
            migrationPhase: migration,
            zoneState: zone,
            favoritesFolderID: favorites.flatMap(UUID.init(uuidString:)),
            lastFetchedAt: row["last_fetched_at"],
            lastSentAt: row["last_sent_at"],
            updatedAt: row["updated_at"]
        )
    }

    static func pendingChange(from row: Row) throws -> CloudPendingChange {
        let generation: Int64 = row["generation"]
        guard generation > 0 else { throw CloudSyncRepositoryError.invalidGeneration(generation) }
        let raw: String = row["operation"]
        guard let operation = CloudPendingOperation(rawValue: raw) else {
            throw CloudSyncRepositoryError.invalidPendingOperation(raw)
        }
        let payload: Data? = row["model_payload"]
        let digest: String? = row["payload_digest"]
        switch operation {
        case .save:
            // v10 rows are intentionally allowed here; the app adapter materializes
            // them before send. New repository writes cannot create them.
            if let payload, digest != Self.digest(payload) {
                throw CloudSyncRepositoryError.invalidPayloadDigest
            }
            if payload == nil, digest != nil { throw CloudSyncRepositoryError.invalidPayloadDigest }
        case .delete:
            guard payload == nil, digest == nil else {
                throw CloudSyncRepositoryError.deleteHasPayload
            }
        }
        return CloudPendingChange(
            accountIdentityHash: row["account_identity_hash"],
            recordType: row["record_type"],
            recordName: row["record_name"],
            operation: operation,
            generation: row["generation"],
            modelPayload: payload,
            payloadDigest: digest,
            enqueuedAt: row["enqueued_at"]
        )
    }

    static func recordState(from row: Row) -> CloudRecordState {
        CloudRecordState(
            accountIdentityHash: row["account_identity_hash"],
            recordType: row["record_type"],
            recordName: row["record_name"],
            systemFields: row["system_fields"],
            serverPayload: row["server_payload"],
            payloadDigest: row["payload_digest"],
            lastSeenEpoch: row["last_seen_epoch"],
            updatedAt: row["updated_at"]
        )
    }
}
