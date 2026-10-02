import Foundation
import GRDB

public struct CloudIncomingDeletion: Codable, Sendable {
    public var recordType: String
    public var recordName: String
    public init(recordType: String, recordName: String) {
        self.recordType = recordType
        self.recordName = recordName
    }
}

/// Transport data is journaled before decoding. Even malformed records remain durable
/// when CKSyncEngine advances its token after delivering an event.
public struct CloudIncomingBatch: Codable, Sendable {
    public var modifications: [CloudRecordState]
    public var deletions: [CloudIncomingDeletion]
    public init(modifications: [CloudRecordState], deletions: [CloudIncomingDeletion]) {
        self.modifications = modifications
        self.deletions = deletions
    }
}

public enum CloudIncomingError: Error, Equatable {
    case unknownRecordType
    case invalidIdentity
    case missingPayload
    case payloadTooLarge
    case requiresNewerApp
    case invalidURL
}

/// One validation path for incoming records, equality checks, and outgoing snapshots.
public enum CloudRecordModel: Sendable {
    case manifest(CloudDataModelManifest)
    case folder(CloudBookmarkFolderPayload)
    case bookmark(CloudBookmarkPayload)
    case certificate(CloudClientCertificateDescriptorPayload)
    case association(CloudClientCertificateAssociationPayload)
    case tabs(CloudTabDeviceSnapshot)

    public init(recordType: String, recordName: String, payload: Data) throws {
        guard payload.count <= 1_000_000 else { throw CloudIncomingError.payloadTooLarge }
        switch recordType {
        case "MTDataModelManifest":
            guard recordName == "data-model-manifest" else { throw CloudIncomingError.invalidIdentity }
            let value = try CloudRecordPayload<CloudDataModelManifest>(decoding: payload).model
            guard value.minimumReaderMajor > 0, value.minimumWriterMajor > 0 else { throw CloudIncomingError.requiresNewerApp }
            guard value.compatibility(readerMajor: CloudSyncState.currentModelMajor,
                                      writerMajor: CloudSyncState.currentModelMajor) == .compatible else {
                throw CloudIncomingError.requiresNewerApp
            }
            self = .manifest(value)
        case "MTBookmarkFolder":
            let value = try CloudRecordPayload<CloudBookmarkFolderPayload>(decoding: payload).model
            try Self.validate(value.id, recordName)
            try OrderKey.validate(value.orderKey)
            self = .folder(value)
        case "MTBookmark":
            let value = try CloudRecordPayload<CloudBookmarkPayload>(decoding: payload).model
            try Self.validate(value.id, recordName)
            try OrderKey.validate(value.orderKey)
            guard value.url.scheme != nil else { throw CloudIncomingError.invalidURL }
            self = .bookmark(value)
        case "MTClientCertificateDescriptor":
            let value = try CloudRecordPayload<CloudClientCertificateDescriptorPayload>(decoding: payload).model
            try Self.validate(value.id, recordName)
            self = .certificate(value)
        case "MTClientCertificateAssociation":
            let value = try CloudRecordPayload<CloudClientCertificateAssociationPayload>(decoding: payload).model
            try Self.validate(value.association.id, recordName)
            self = .association(value)
        case "MTDeviceTabs":
            let value = try CloudRecordPayload<CloudTabDeviceSnapshot>(decoding: payload).model
            try Self.validate(value.deviceID, recordName)
            guard value.tabs.count <= 200, value.tabs.allSatisfy({ CloudTabURL.normalized($0.url) != nil }) else { throw CloudIncomingError.invalidURL }
            self = .tabs(value)
        default: throw CloudIncomingError.unknownRecordType
        }
    }

    public func encodedModel() throws -> Data {
        switch self {
        case .manifest(let value): try CloudSyncRepository.encodeModelPayload(value)
        case .folder(let value): try CloudSyncRepository.encodeModelPayload(value)
        case .bookmark(let value): try CloudSyncRepository.encodeModelPayload(value)
        case .certificate(let value): try CloudSyncRepository.encodeModelPayload(value)
        case .association(let value): try CloudSyncRepository.encodeModelPayload(value)
        case .tabs(let value): try CloudSyncRepository.encodeModelPayload(value)
        }
    }

    private static func validate(_ id: UUID, _ name: String) throws {
        guard UUID(uuidString: name) == id else { throw CloudIncomingError.invalidIdentity }
    }
}

extension CloudSyncRepository {
    /// This commit must precede any acceptance of subsequent engine state.
    @discardableResult
    public func journal(_ batch: CloudIncomingBatch, for account: String) throws -> Int64 {
        let payload = try JSONEncoder().encode(batch)
        return try database.write { db in
            try db.execute(sql: "INSERT INTO cloud_incoming_batches(account_identity_hash, payload) VALUES (?, ?)",
                           arguments: [account, payload])
            return db.lastInsertedRowID
        }
    }

    public func hasUnappliedBatches(for account: String) throws -> Bool {
        try database.read { db in
            try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM cloud_incoming_batches WHERE account_identity_hash = ?)",
                              arguments: [account]) ?? false
        }
    }

    public func replayIncoming(for account: String) throws {
        try replayIncoming(for: account, beforeApplying: nil)
    }

    /// Internal scheduling seam: tests can pause after decode but before acquiring
    /// the writer, exactly where competing replay workers can overtake one another.
    func replayIncoming(for account: String, beforeApplying: (@Sendable () -> Void)?) throws {
        while let item = try database.read({ db in
            try Row.fetchOne(db, sql: "SELECT id, payload FROM cloud_incoming_batches WHERE account_identity_hash = ? ORDER BY id LIMIT 1",
                             arguments: [account])
        }) {
            let id: Int64 = item["id"]
            let batch = try JSONDecoder().decode(CloudIncomingBatch.self, from: item["payload"])
            // Validate every record before any domain row can change.
            let decoded = try batch.modifications.map { state -> (CloudRecordState, CloudRecordModel, Data) in
                guard state.accountIdentityHash == account else { throw CloudIncomingError.invalidIdentity }
                guard let payload = state.serverPayload else { throw CloudIncomingError.missingPayload }
                let model = try CloudRecordModel(recordType: state.recordType, recordName: state.recordName, payload: payload)
                return (state, model, try model.encodedModel())
            }
            for deletion in batch.deletions {
                guard ["MTBookmarkFolder", "MTBookmark", "MTClientCertificateDescriptor",
                       "MTClientCertificateAssociation", "MTDeviceTabs"].contains(deletion.recordType),
                      UUID(uuidString: deletion.recordName) != nil else { throw CloudIncomingError.invalidIdentity }
            }
            beforeApplying?()
            try database.write { db in
                // Another replay worker may have consumed this batch and later ones
                // while we decoded it. Replaying it now would roll clean rows backward.
                guard try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM cloud_incoming_batches WHERE id = ? AND account_identity_hash = ?)",
                                        arguments: [id, account]) == true else { return }
                // All repositories here receive this same SQLite transaction.
                var applicable: [CloudRecordModel] = []
                for (var state, model, modelData) in decoded {
                    let row = try Row.fetchOne(db, sql: "SELECT * FROM cloud_pending_changes WHERE account_identity_hash = ? AND record_name = ?",
                                               arguments: [account, state.recordName])
                    let pending = try row.map(Self.pendingChange(from:))
                    let fenced = try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM cloud_confirmed_deletions WHERE account_identity_hash = ? AND record_name = ?)",
                                                   arguments: [account, state.recordName]) == true
                    if fenced {
                        // Also recover when the server accepted an in-flight create but
                        // this process crashed before its save callback. The fetched echo
                        // is no more permission to resurrect it than that callback was.
                        if pending == nil {
                            try enqueue(.init(accountIdentityHash: account, recordType: state.recordType,
                                              recordName: state.recordName, operation: .delete), in: db)
                        }
                        state.payloadDigest = Self.digest(modelData)
                        try Self.saveRecordState(state, in: db)
                        continue
                    }
                    switch CloudSyncReconciliation.fetchedModification(pending: pending, serverModelPayload: modelData) {
                    case .applyRemote: applicable.append(model)
                    case .retainPendingSave:
                        guard let pending else { throw CloudSyncRepositoryError.invalidSyncState }
                        let previous = try Row.fetchOne(db, sql: "SELECT * FROM cloud_record_state WHERE account_identity_hash = ? AND record_name = ?",
                                                       arguments: [account, state.recordName]).map(Self.recordState(from:))
                        var rebased = false
                        // Favicon observations are independent of title intent. Rebase
                        // just this field while retaining the locally committed title.
                        if case .bookmark(let remote) = model,
                           let bytes = pending.modelPayload {
                            var local = try JSONDecoder().decode(CloudBookmarkPayload.self, from: bytes)
                            if let icon = remote.favicon,
                               icon.fetchedAt.timeIntervalSince(local.favicon?.fetchedAt ?? .distantPast) > 0.001 {
                                local.favicon = icon
                                try enqueueSave(accountIdentityHash: account, recordType: pending.recordType,
                                                recordName: pending.recordName, payload: local, in: db)
                                applicable.append(.bookmark(local))
                                rebased = true
                            }
                        }
                        if !rebased, pending.modelPayload != modelData,
                           previous?.systemFields != state.systemFields || previous?.serverPayload != state.serverPayload {
                            // This observation can be newer than a success callback
                            // still in flight. Reassert intent with a fresh generation
                            // so that callback cannot erase the required retry. Exact
                            // duplicate observations do not allocate another generation.
                            try enqueue(pending, in: db)
                        }
                    case .retainPendingDelete: break
                    }
                    state.payloadDigest = Self.digest(modelData)
                    try Self.saveRecordState(state, in: db)
                }
                try BookmarkRepository(database: database, accountIdentityHash: account)
                    .applyIncoming(applicable, deletions: batch.deletions, in: db)
                try ClientCertificateSyncRepository(database: database, accountIdentityHash: account)
                    .applyIncoming(applicable, deletions: batch.deletions, in: db)
                for deletion in batch.deletions {
                    // A fence is needed only where this Mac has local/in-flight intent.
                    // An uninvolved observer must accept a later genuine recreation
                    // (notably a device's self-replacing Cloud Tabs record).
                    try db.execute(sql: "INSERT OR IGNORE INTO cloud_confirmed_deletions(account_identity_hash, record_name) SELECT ?, ? WHERE EXISTS(SELECT 1 FROM cloud_pending_changes WHERE account_identity_hash = ? AND record_name = ?)",
                                   arguments: [account, deletion.recordName, account, deletion.recordName])
                    try db.execute(sql: "DELETE FROM cloud_pending_changes WHERE account_identity_hash = ? AND record_name = ?",
                                   arguments: [account, deletion.recordName])
                    try db.execute(sql: "DELETE FROM cloud_record_state WHERE account_identity_hash = ? AND record_name = ?",
                                   arguments: [account, deletion.recordName])
                }
                try db.execute(sql: "UPDATE cloud_sync_state SET last_fetched_at = ?, updated_at = ? WHERE account_identity_hash = ?",
                               arguments: [Date(), Date(), account])
                try db.execute(sql: "DELETE FROM cloud_incoming_batches WHERE id = ? AND account_identity_hash = ?",
                               arguments: [id, account])
            }
        }
    }

    public func tabSnapshots(for account: String) throws -> [CloudTabDeviceSnapshot] {
        try database.read { db in
            try Data.fetchAll(db, sql: "SELECT server_payload FROM cloud_record_state WHERE account_identity_hash = ? AND record_type = 'MTDeviceTabs'",
                              arguments: [account]).map { try CloudRecordPayload<CloudTabDeviceSnapshot>(decoding: $0).model }
        }
    }
}
