import Foundation
import GRDB

public struct ServerTrustSyncRepository: Sendable {
    private let database: MajorTomDatabase

    public init(database: MajorTomDatabase) { self.database = database }

    public func load() throws -> SyncedServerTrust {
        let decoder = JSONDecoder()
        return try database.read { db in
            SyncedServerTrust(decisions: try Data.fetchAll(
                db,
                sql: "SELECT payload FROM server_trust_sync ORDER BY id"
            ).compactMap { try? decoder.decode(SyncedServerTrustDecision.self, from: $0) })
        }
    }

    public func save(_ state: SyncedServerTrust) throws {
        try saveRecords(
            state.decisions,
            table: "server_trust_sync",
            id: { $0.id },
            modifiedAt: { $0.modifiedAt },
            database: database
        )
    }

    public func importLegacy(_ state: SyncedServerTrust) throws {
        try importOnce(marker: "legacy-server-trust-sync-v1-imported", database: database) {
            try save(state)
        }
    }
}

public struct ClientCertificateSyncRepository: Sendable {
    private let database: MajorTomDatabase

    public init(database: MajorTomDatabase) { self.database = database }

    public func load() throws -> (state: ClientCertificateSyncState, localFlags: [UUID: Bool]) {
        let decoder = JSONDecoder()
        return try database.read { db in
            let certificates = try Data.fetchAll(
                db,
                sql: "SELECT payload FROM client_certificate_sync_descriptors ORDER BY id"
            ).compactMap { try? decoder.decode(SyncedClientCertificateDescriptor.self, from: $0) }
            let associations = try Data.fetchAll(
                db,
                sql: "SELECT payload FROM client_certificate_sync_associations ORDER BY id"
            ).compactMap { try? decoder.decode(SyncedClientCertificateAssociation.self, from: $0) }
            let flags = try Row.fetchAll(db, sql: "SELECT id, synchronizes_with_icloud FROM client_certificate_local_flags")
                .reduce(into: [UUID: Bool]()) { result, row in
                    if let id = UUID(uuidString: row["id"]) {
                        result[id] = row["synchronizes_with_icloud"]
                    }
                }
            return (ClientCertificateSyncState(certificates: certificates, associations: associations), flags)
        }
    }

    public func save(_ state: ClientCertificateSyncState, localFlags: [UUID: Bool]) throws {
        try database.write { db in
            try updateRecords(
                state.certificates,
                table: "client_certificate_sync_descriptors",
                id: { $0.id.uuidString },
                modifiedAt: { $0.modifiedAt },
                in: db
            )
            try updateRecords(
                state.associations,
                table: "client_certificate_sync_associations",
                id: { $0.id.uuidString },
                modifiedAt: { $0.modifiedAt },
                in: db
            )
            try db.execute(sql: "DELETE FROM client_certificate_local_flags")
            for (id, value) in localFlags {
                try db.execute(
                    sql: "INSERT INTO client_certificate_local_flags (id, synchronizes_with_icloud) VALUES (?, ?)",
                    arguments: [id.uuidString, value]
                )
            }
        }
    }

    public func importLegacy(
        _ state: ClientCertificateSyncState,
        localFlags: [UUID: Bool]
    ) throws {
        try importOnce(marker: "legacy-client-certificate-sync-v2-imported", database: database) {
            try save(state, localFlags: localFlags)
        }
    }
}

private func saveRecords<Record: Encodable>(
    _ records: [Record],
    table: String,
    id: (Record) -> String,
    modifiedAt: (Record) -> Date,
    database: MajorTomDatabase
) throws {
    try database.write { db in
        try updateRecords(records, table: table, id: id, modifiedAt: modifiedAt, in: db)
    }
}

private func updateRecords<Record: Encodable>(
    _ records: [Record],
    table: String,
    id: (Record) -> String,
    modifiedAt: (Record) -> Date,
    in db: Database
) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let existingRows = try Row.fetchAll(db, sql: "SELECT id, payload FROM \(table)")
    let existing = Dictionary(uniqueKeysWithValues: existingRows.map { ($0["id"] as String, $0["payload"] as Data) })
    let desiredIDs = Set(records.map(id))
    for record in records {
        let identifier = id(record)
        let payload = try encoder.encode(record)
        guard existing[identifier] != payload else { continue }
        try db.execute(
            sql: """
                INSERT INTO \(table) (id, payload, modified_at) VALUES (?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET payload = excluded.payload, modified_at = excluded.modified_at
                """,
            arguments: [identifier, payload, modifiedAt(record)]
        )
    }
    for identifier in existing.keys where !desiredIDs.contains(identifier) {
        try db.execute(sql: "DELETE FROM \(table) WHERE id = ?", arguments: [identifier])
    }
}

private func importOnce(
    marker: String,
    database: MajorTomDatabase,
    body: () throws -> Void
) throws {
    let imported = try database.read { db in
        try Bool.fetchOne(
            db,
            sql: "SELECT EXISTS(SELECT 1 FROM persistence_metadata WHERE key = ?)",
            arguments: [marker]
        ) ?? false
    }
    guard !imported else { return }
    try body()
    try database.write { db in
        try db.execute(
            sql: "INSERT OR IGNORE INTO persistence_metadata (key, value, updated_at) VALUES (?, ?, ?)",
            arguments: [marker, Data(), Date()]
        )
    }
}
