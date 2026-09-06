import Foundation
import GRDB

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
    public var payloadDigest: String?
    public var enqueuedAt: Date

    public init(
        accountIdentityHash: String,
        recordType: String,
        recordName: String,
        operation: CloudPendingOperation,
        generation: Int64 = 0,
        payloadDigest: String? = nil,
        enqueuedAt: Date = Date()
    ) {
        self.accountIdentityHash = accountIdentityHash
        self.recordType = recordType
        self.recordName = recordName
        self.operation = operation
        self.generation = generation
        self.payloadDigest = payloadDigest
        self.enqueuedAt = enqueuedAt
    }
}

public struct CloudRecordState: Equatable, Sendable {
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
    private let database: MajorTomDatabase

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
        try database.write { db in
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
            return Self.state(from: row)
        }
    }

    public func save(_ state: CloudSyncState) throws {
        try database.write { db in try Self.save(state, in: db) }
    }

    public func saveEngineState(_ data: Data?, for accountIdentityHash: String) throws {
        var value = try state(for: accountIdentityHash)
        value.engineState = data
        value.updatedAt = Date()
        try save(value)
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
        let prior = try Int64.fetchOne(
            db,
            sql: "SELECT generation FROM cloud_pending_changes WHERE account_identity_hash = ? AND record_name = ?",
            arguments: [change.accountIdentityHash, change.recordName]
        ) ?? 0
        let generation = prior + 1
        try db.execute(
            sql: """
                INSERT INTO cloud_pending_changes
                    (account_identity_hash, record_type, record_name, operation, generation, payload_digest, enqueued_at)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(account_identity_hash, record_name) DO UPDATE SET
                    record_type = excluded.record_type,
                    operation = excluded.operation,
                    generation = excluded.generation,
                    payload_digest = excluded.payload_digest,
                    enqueued_at = excluded.enqueued_at
                """,
            arguments: [
                change.accountIdentityHash, change.recordType, change.recordName,
                change.operation.rawValue, generation, change.payloadDigest, change.enqueuedAt
            ]
        )
        return generation
    }

    public func enqueue(_ change: CloudPendingChange) throws {
        _ = try database.write { db in try enqueue(change, in: db) }
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
            ).compactMap(Self.pendingChange(from:))
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

    /// Acknowledges only the generation that was actually sent.
    @discardableResult
    public func acknowledge(
        recordName: String,
        generation: Int64,
        for accountIdentityHash: String
    ) throws -> Bool {
        try database.write { db in
            try db.execute(
                sql: "DELETE FROM cloud_pending_changes WHERE account_identity_hash = ? AND record_name = ? AND generation = ?",
                arguments: [accountIdentityHash, recordName, generation]
            )
            return db.changesCount > 0
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
        try database.write { db in
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
    }

    private static func save(_ state: CloudSyncState, in db: Database) throws {
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

    private static func state(from row: Row) -> CloudSyncState {
        let migrationRaw: String = row["migration_phase"]
        let zoneRaw: String = row["zone_state"]
        let favorites: String? = row["favorites_folder_id"]
        return CloudSyncState(
            accountIdentityHash: row["account_identity_hash"],
            engineState: row["engine_state"],
            modelMajor: row["model_major"],
            migratedFromV1: row["migrated_from_v1"],
            migrationPhase: CloudMigrationPhase(rawValue: migrationRaw) ?? .notStarted,
            zoneState: CloudZoneState(rawValue: zoneRaw) ?? .neverEstablished,
            favoritesFolderID: favorites.flatMap(UUID.init(uuidString:)),
            lastFetchedAt: row["last_fetched_at"],
            lastSentAt: row["last_sent_at"],
            updatedAt: row["updated_at"]
        )
    }

    private static func pendingChange(from row: Row) -> CloudPendingChange? {
        let raw: String = row["operation"]
        guard let operation = CloudPendingOperation(rawValue: raw) else { return nil }
        return CloudPendingChange(
            accountIdentityHash: row["account_identity_hash"],
            recordType: row["record_type"],
            recordName: row["record_name"],
            operation: operation,
            generation: row["generation"],
            payloadDigest: row["payload_digest"],
            enqueuedAt: row["enqueued_at"]
        )
    }

    private static func recordState(from row: Row) -> CloudRecordState {
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
