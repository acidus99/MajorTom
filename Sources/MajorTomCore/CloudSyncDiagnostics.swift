import Foundation
import GRDB

public enum CloudSyncFailureCategory: String, Equatable, Sendable {
    case account
    case zone
    case transport
    case persistence
    case payload
    case conflict
    case engineState
    case unknown
}

/// A privacy-safe, testable summary of durable CloudKit sync state. Identifiers and
/// payloads deliberately never leave the database through this value.
public struct CloudSyncDiagnosticSnapshot: Equatable, Sendable {
    public struct OutboxCount: Equatable, Sendable {
        public var recordType: String
        public var operation: CloudPendingOperation
        public var count: Int

        public init(recordType: String, operation: CloudPendingOperation, count: Int) {
            self.recordType = recordType
            self.operation = operation
            self.count = count
        }
    }

    public var accountHashPrefix: String
    public var zoneState: CloudZoneState
    public var migrationPhase: CloudMigrationPhase
    public var engineStatePresent: Bool
    public var lastFetchedAt: Date?
    public var lastSentAt: Date?
    public var outbox: [OutboxCount]
    public var oldestPendingAt: Date?

    public init(
        accountHashPrefix: String,
        zoneState: CloudZoneState,
        migrationPhase: CloudMigrationPhase,
        engineStatePresent: Bool,
        lastFetchedAt: Date?,
        lastSentAt: Date?,
        outbox: [OutboxCount],
        oldestPendingAt: Date?
    ) {
        self.accountHashPrefix = accountHashPrefix
        self.zoneState = zoneState
        self.migrationPhase = migrationPhase
        self.engineStatePresent = engineStatePresent
        self.lastFetchedAt = lastFetchedAt
        self.lastSentAt = lastSentAt
        self.outbox = outbox
        self.oldestPendingAt = oldestPendingAt
    }
}

/// Supplements the durable database snapshot with coordinator state that exists only
/// while the process is alive. It is suitable for a support report, never for sync
/// decisions.
public struct CloudSyncRuntimeDiagnosticSnapshot: Equatable, Sendable {
    public var durable: CloudSyncDiagnosticSnapshot
    public var cycleIsActive: Bool
    public var lastFailureCategory: CloudSyncFailureCategory?
    public var engineInitialized: Bool
    public var phase: String
    public var retryAt: Date?
    public var unappliedBatchCount: Int

    public init(
        durable: CloudSyncDiagnosticSnapshot,
        cycleIsActive: Bool,
        lastFailureCategory: CloudSyncFailureCategory?,
        engineInitialized: Bool = false,
        phase: String = "idle",
        retryAt: Date? = nil,
        unappliedBatchCount: Int = 0
    ) {
        self.durable = durable
        self.cycleIsActive = cycleIsActive
        self.lastFailureCategory = lastFailureCategory
        self.engineInitialized = engineInitialized
        self.phase = phase
        self.retryAt = retryAt
        self.unappliedBatchCount = unappliedBatchCount
    }
}

extension CloudSyncRepository {
    public func unappliedBatchCount(for account: String) throws -> Int {
        try database.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM cloud_incoming_batches WHERE account_identity_hash = ?",
                                            arguments: [account]) ?? 0 }
    }
    public func diagnosticSnapshot(for accountIdentityHash: String) throws -> CloudSyncDiagnosticSnapshot {
        try database.read { db in
            let state: CloudSyncState
            if let row = try Row.fetchOne(
                db,
                sql: "SELECT * FROM cloud_sync_state WHERE account_identity_hash = ?",
                arguments: [accountIdentityHash]
            ) {
                state = try CloudSyncRepository.state(from: row)
            } else {
                state = CloudSyncState(accountIdentityHash: accountIdentityHash)
            }
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT record_type, operation, COUNT(*) AS count
                    FROM cloud_pending_changes
                    WHERE account_identity_hash = ?
                    GROUP BY record_type, operation
                    ORDER BY record_type, operation
                    """,
                arguments: [accountIdentityHash]
            )
            let outbox = try rows.map { row -> CloudSyncDiagnosticSnapshot.OutboxCount in
                guard let operation = CloudPendingOperation(rawValue: row["operation"]) else {
                    throw CloudSyncRepositoryError.invalidPendingOperation(row["operation"])
                }
                return .init(recordType: row["record_type"], operation: operation, count: row["count"])
            }
            let oldest = try Date.fetchOne(
                db,
                sql: "SELECT MIN(enqueued_at) FROM cloud_pending_changes WHERE account_identity_hash = ?",
                arguments: [accountIdentityHash]
            )
            return CloudSyncDiagnosticSnapshot(
                accountHashPrefix: String(accountIdentityHash.prefix(12)),
                zoneState: state.zoneState,
                migrationPhase: state.migrationPhase,
                engineStatePresent: state.engineState != nil,
                lastFetchedAt: state.lastFetchedAt,
                lastSentAt: state.lastSentAt,
                outbox: outbox,
                oldestPendingAt: oldest
            )
        }
    }
}
