import Foundation
import GRDB

public struct CloudOutgoingIntent: Sendable {
    public var change: CloudPendingChange
    public var server: CloudRecordState?

    public func envelopedPayload() throws -> Data {
        guard let payload = change.modelPayload else { throw CloudSyncRepositoryError.saveMissingPayload }
        let model = try CloudRecordModel(recordType: change.recordType, recordName: change.recordName, payload: payload)
        switch model {
        case .manifest(let value): return try envelope(value)
        case .folder(let value): return try envelope(value)
        case .bookmark(let value): return try envelope(value)
        case .certificate(let value): return try envelope(value)
        case .association(let value): return try envelope(value)
        case .tabs(let value): return try envelope(value)
        }
    }

    private func envelope<T: CloudSyncPayload>(_ value: T) throws -> Data {
        var envelope: CloudRecordPayload<T>
        if let prior = server?.serverPayload { envelope = try CloudRecordPayload<T>(decoding: prior) }
        else { envelope = CloudRecordPayload(model: value) }
        envelope.model = value
        return try envelope.encoded()
    }
}

extension CloudSyncRepository {
    /// One-shot import body and phase marker share a writer transaction. Pending
    /// local intent wins even if legacy timestamps are newer than the local clock.
    public func importLegacyData(bookmarks: SyncedBookmarks?, certificates: ClientCertificateSyncState?, for account: String) throws {
        try database.write { db in
            var state = try Row.fetchOne(db, sql: "SELECT * FROM cloud_sync_state WHERE account_identity_hash = ?",
                                         arguments: [account]).map(Self.state(from:)) ?? CloudSyncState(accountIdentityHash: account)
            guard state.migrationPhase != .publishingV2, state.migrationPhase != .ready else { return }
            let pending = Set(try String.fetchAll(db, sql: "SELECT record_name FROM cloud_pending_changes WHERE account_identity_hash = ?", arguments: [account]))
            if let bookmarks {
                let local = SyncedBookmarks(collection: try BookmarkRepository.fetchCollection(db, account: account), modifiedAt: .distantPast)
                let eligible = SyncedBookmarks(folders: bookmarks.folders.filter { !pending.contains($0.id.uuidString) },
                    bookmarks: bookmarks.bookmarks.filter { !pending.contains($0.id.uuidString) })
                try BookmarkRepository.apply(local.merging(eligible).collection, account: account, cloud: self,
                                             enqueueChanges: true, in: db)
            }
            if let certificates {
                let repo = ClientCertificateSyncRepository(database: database, accountIdentityHash: account)
                let loaded = try repo.load(in: db)
                let eligible = ClientCertificateSyncState(certificates: certificates.certificates.filter { !pending.contains($0.id.uuidString) },
                    associations: certificates.associations.filter { !pending.contains($0.id.uuidString) })
                try repo.save(loaded.state.merging(eligible), localFlags: loaded.localFlags, enqueueChanges: true, in: db)
            }
            state.migrationPhase = .publishingV2
            try Self.save(state, in: db)
        }
    }

    public func currentGenerations(for account: String, recordNames: [String]) throws -> [String: Int64] {
        guard !recordNames.isEmpty else { return [:] }
        return try database.read { db in
            let placeholders = Array(repeating: "?", count: recordNames.count).joined(separator: ",")
            let rows = try Row.fetchAll(db, sql: "SELECT record_name, generation FROM cloud_pending_changes WHERE account_identity_hash = ? AND record_name IN (\(placeholders))",
                                       arguments: StatementArguments([account] + recordNames))
            return Dictionary(uniqueKeysWithValues: rows.map { ($0["record_name"] as String, $0["generation"] as Int64) })
        }
    }

    public func enqueueLocalSnapshot(for account: String, recreatingRemovedZone: Bool = false,
                                     currentTabs: CloudTabDeviceSnapshot? = nil,
                                     completingMigration: Bool = false) throws {
        try database.write { db in
            try enqueueLocalSnapshot(for: account, recreatingRemovedZone: recreatingRemovedZone,
                                     currentTabs: currentTabs, completingMigration: completingMigration, in: db)
        }
    }

    private func enqueueLocalSnapshot(for account: String, recreatingRemovedZone: Bool = false,
                                     currentTabs: CloudTabDeviceSnapshot? = nil,
                                     completingMigration: Bool = false, in db: Database) throws {
            if recreatingRemovedZone {
                try db.execute(sql: "UPDATE cloud_record_state SET system_fields = NULL WHERE account_identity_hash = ?",
                               arguments: [account])
                try db.execute(sql: "UPDATE cloud_sync_state SET engine_state = NULL, zone_state = ? WHERE account_identity_hash = ?",
                               arguments: [CloudZoneState.neverEstablished.rawValue, account])
            }
            try enqueueSave(accountIdentityHash: account, recordType: "MTDataModelManifest", recordName: "data-model-manifest",
                payload: CloudDataModelManifest(formatMajor: CloudSyncState.currentModelMajor,
                    minimumReaderMajor: CloudSyncState.currentModelMajor, minimumWriterMajor: CloudSyncState.currentModelMajor,
                    createdAt: Date(timeIntervalSince1970: 0)), in: db)
            for (table, type) in [("bookmark_folders", "MTBookmarkFolder"), ("bookmarks", "MTBookmark"),
                                  ("client_certificates", "MTClientCertificateDescriptor"),
                                  ("client_certificate_associations", "MTClientCertificateAssociation")] {
                for name in try String.fetchAll(db, sql: "SELECT id FROM \(table) WHERE account_identity_hash = ? ORDER BY id",
                                                arguments: [account]) {
                    guard let id = UUID(uuidString: name) else { throw CloudIncomingError.invalidIdentity }
                    let bytes: Data?
                    if type == "MTBookmark" || type == "MTBookmarkFolder" {
                        bytes = try BookmarkRepository(database: database, accountIdentityHash: account)
                            .legacyModelPayload(recordType: type, id: id, in: db)
                    } else {
                        bytes = try ClientCertificateSyncRepository(database: database, accountIdentityHash: account)
                            .legacyModelPayload(recordType: type, id: id, in: db)
                    }
                    guard let bytes else { throw CloudSyncRepositoryError.saveMissingPayload }
                    try enqueue(.init(accountIdentityHash: account, recordType: type, recordName: name,
                                      operation: .save, modelPayload: bytes, payloadDigest: Self.digest(bytes)), in: db)
                }
            }
            if let currentTabs {
                try enqueueSave(accountIdentityHash: account, recordType: "MTDeviceTabs",
                                recordName: currentTabs.deviceID.uuidString.lowercased(), payload: currentTabs, in: db)
            }
            if completingMigration {
                var state = try Row.fetchOne(db, sql: "SELECT * FROM cloud_sync_state WHERE account_identity_hash = ?",
                                             arguments: [account]).map(Self.state(from:)) ?? CloudSyncState(accountIdentityHash: account)
                state.migrationPhase = .ready
                state.migratedFromV1 = true
                state.modelMajor = CloudSyncState.currentModelMajor
                state.engineState = nil
                try Self.save(state, in: db)
            }
    }

    /// A single durable first-account claim, including the outgoing representation.
    /// A crash cannot claim bookmarks but leave certificates available to another account.
    public func claimUnownedRows(for account: String) throws {
        try database.write { db in
            let key = "cloud-first-account-claim"
            guard try String.fetchOne(db, sql: "SELECT value FROM persistence_metadata WHERE key = ?", arguments: [key]) == nil else { return }
            var claimed = false
            for table in ["bookmark_folders", "bookmarks", "client_certificates", "client_certificate_associations", "client_certificate_local_flags"] {
                try db.execute(sql: "UPDATE \(table) SET account_identity_hash = ? WHERE account_identity_hash IS NULL", arguments: [account])
                claimed = claimed || db.changesCount > 0
            }
            if claimed { try enqueueLocalSnapshot(for: account, in: db) }
            try db.execute(sql: "INSERT INTO persistence_metadata(key, value, updated_at) VALUES (?, ?, ?)", arguments: [key, account, Date()])
        }
    }

    public func materializeLegacy(_ selected: CloudPendingChange, currentTabs: CloudTabDeviceSnapshot?) throws {
        try database.write { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT * FROM cloud_pending_changes WHERE account_identity_hash = ? AND record_name = ?",
                                             arguments: [selected.accountIdentityHash, selected.recordName]) else { return }
            let current = try Self.pendingChange(from: row)
            guard current.generation == selected.generation, current.operation == .save,
                  current.modelPayload == nil else { return }
            let payload: Data?
            switch current.recordType {
            case "MTDataModelManifest":
                payload = try Self.encodeModelPayload(CloudDataModelManifest(formatMajor: CloudSyncState.currentModelMajor,
                    minimumReaderMajor: CloudSyncState.currentModelMajor, minimumWriterMajor: CloudSyncState.currentModelMajor,
                    createdAt: Date(timeIntervalSince1970: 0)))
            case "MTDeviceTabs":
                guard let currentTabs, UUID(uuidString: current.recordName) == currentTabs.deviceID else {
                    throw CloudIncomingError.invalidIdentity
                }
                payload = try Self.encodeModelPayload(currentTabs)
            case "MTBookmark", "MTBookmarkFolder":
                guard let id = UUID(uuidString: current.recordName) else { throw CloudIncomingError.invalidIdentity }
                payload = try BookmarkRepository(database: database, accountIdentityHash: current.accountIdentityHash)
                    .legacyModelPayload(recordType: current.recordType, id: id, in: db)
            case "MTClientCertificateDescriptor", "MTClientCertificateAssociation":
                guard let id = UUID(uuidString: current.recordName) else { throw CloudIncomingError.invalidIdentity }
                payload = try ClientCertificateSyncRepository(database: database, accountIdentityHash: current.accountIdentityHash)
                    .legacyModelPayload(recordType: current.recordType, id: id, in: db)
            default: throw CloudIncomingError.unknownRecordType
            }
            guard let payload else { throw CloudSyncRepositoryError.saveMissingPayload }
            var materialized = current
            materialized.modelPayload = payload
            materialized.payloadDigest = Self.digest(payload)
            try enqueue(materialized, in: db)
        }
    }

    /// Shared by the CloudKit adapter and deterministic server harness.
    @discardableResult
    public func acceptSave(_ state: CloudRecordState, attempted: CloudPendingChange, isConflict: Bool = false) throws -> Bool {
        guard state.accountIdentityHash == attempted.accountIdentityHash,
              state.recordName == attempted.recordName, state.recordType == attempted.recordType,
              let bytes = state.serverPayload else { throw CloudIncomingError.invalidIdentity }
        let model = try CloudRecordModel(recordType: state.recordType, recordName: state.recordName, payload: bytes)
        let canonical = try model.encodedModel()
        var metadata = state
        metadata.payloadDigest = Self.digest(canonical)
        guard isConflict || canonical == attempted.modelPayload else { throw CloudSyncRepositoryError.invalidPayloadDigest }
        // A create already handed to transport can arrive after a fetched deletion.
        // The late success must compensate, not silently resurrect that deleted UUID.
        return try database.write { db in
            try Self.saveRecordState(metadata, in: db)
            let fenced = try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM cloud_confirmed_deletions WHERE account_identity_hash = ? AND record_name = ?)",
                                           arguments: [attempted.accountIdentityHash, attempted.recordName]) == true
            let pending = try Row.fetchOne(db, sql: "SELECT * FROM cloud_pending_changes WHERE account_identity_hash = ? AND record_name = ?",
                                           arguments: [attempted.accountIdentityHash, attempted.recordName]).map(Self.pendingChange(from:))
            if fenced, pending == nil {
                try enqueue(.init(accountIdentityHash: attempted.accountIdentityHash, recordType: attempted.recordType,
                                  recordName: attempted.recordName, operation: .delete), in: db)
            }
            if !fenced, isConflict, let pending, pending.operation == .save,
               case .bookmark(let remote) = model, let bytes = pending.modelPayload {
                var local = try JSONDecoder().decode(CloudBookmarkPayload.self, from: bytes)
                if let icon = remote.favicon, icon.fetchedAt.timeIntervalSince(local.favicon?.fetchedAt ?? .distantPast) > 0.001 {
                    local.favicon = icon
                    try enqueueSave(accountIdentityHash: pending.accountIdentityHash, recordType: pending.recordType,
                                    recordName: pending.recordName, payload: local, in: db)
                    try BookmarkRepository(database: database, accountIdentityHash: pending.accountIdentityHash)
                        .applyIncoming([.bookmark(local)], deletions: [], in: db)
                    return false
                }
            }
            guard !fenced, canonical == attempted.modelPayload else { return false }
            try db.execute(sql: "DELETE FROM cloud_pending_changes WHERE account_identity_hash = ? AND record_name = ? AND generation = ? AND operation = 'save'",
                           arguments: [attempted.accountIdentityHash, attempted.recordName, attempted.generation])
            let acknowledged = db.changesCount > 0
            try db.execute(sql: "UPDATE cloud_sync_state SET last_sent_at = ?, updated_at = ? WHERE account_identity_hash = ?",
                           arguments: [Date(), Date(), attempted.accountIdentityHash])
            return acknowledged
        }
    }

    /// Two bounded queries in one consistent read, rather than multiple metadata reads
    /// for each record. A snapshot never mixes payload and change tag from different reads.
    public func preparedChanges(for account: String, limit: Int = 200) throws -> [CloudOutgoingIntent] {
        try database.read { db in
            let pending = try Row.fetchAll(db, sql: """
                SELECT * FROM cloud_pending_changes WHERE account_identity_hash = ?
                ORDER BY enqueued_at, record_name LIMIT ?
                """, arguments: [account, max(0, min(limit, 200))]).map(Self.pendingChange(from:))
            guard !pending.isEmpty else { return [] }
            let placeholders = Array(repeating: "?", count: pending.count).joined(separator: ",")
            let metadata = try Row.fetchAll(db, sql: """
                SELECT * FROM cloud_record_state WHERE account_identity_hash = ? AND record_name IN (\(placeholders))
                """, arguments: StatementArguments([account] + pending.map(\.recordName))).map(Self.recordState(from:))
            let byName = Dictionary(uniqueKeysWithValues: metadata.map { ($0.recordName, $0) })
            return pending.map { CloudOutgoingIntent(change: $0, server: byName[$0.recordName]) }
        }
    }
}
