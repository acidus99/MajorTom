import Foundation
import GRDB

public struct CloudClientCertificateDescriptorPayload: CloudSyncPayload, Equatable, Sendable {
    public static let payloadSchemaVersion = 1
    public static let knownPayloadKeys: Set<String> = [
        "id", "commonName", "emailAddress", "userID", "domain", "organization", "country",
        "notBefore", "notAfter", "certificateSHA256", "publicKeySHA256"
    ]
    public var id: UUID
    public var commonName: String
    public var emailAddress: String
    public var userID: String
    public var domain: String
    public var organization: String
    public var country: String
    public var notBefore: Date
    public var notAfter: Date
    public var certificateSHA256: String
    public var publicKeySHA256: String

    public init(_ descriptor: ClientCertificateDescriptor) {
        id = descriptor.id
        commonName = descriptor.commonName
        emailAddress = descriptor.emailAddress
        userID = descriptor.userID
        domain = descriptor.domain
        organization = descriptor.organization
        country = descriptor.country
        notBefore = descriptor.notBefore
        notAfter = descriptor.notAfter
        certificateSHA256 = descriptor.certificateSHA256
        publicKeySHA256 = descriptor.publicKeySHA256
    }

    public var descriptor: ClientCertificateDescriptor {
        ClientCertificateDescriptor(id: id, commonName: commonName, emailAddress: emailAddress,
            userID: userID, domain: domain, organization: organization, country: country,
            notBefore: notBefore, notAfter: notAfter, certificateSHA256: certificateSHA256,
            publicKeySHA256: publicKeySHA256)
    }
}

public struct CloudClientCertificateAssociationPayload: CloudSyncPayload, Equatable, Sendable {
    public static let payloadSchemaVersion = 1
    public static let knownPayloadKeys: Set<String> = ["association"]
    public var association: ClientCertificateAssociation
    public init(_ association: ClientCertificateAssociation) { self.association = association }
}

public struct ClientCertificateSyncRepository: Sendable {
    private let database: MajorTomDatabase
    private let accountIdentityHash: String?
    private let cloud: CloudSyncRepository

    public init(database: MajorTomDatabase, accountIdentityHash: String? = nil) {
        self.database = database
        self.accountIdentityHash = accountIdentityHash
        cloud = CloudSyncRepository(database: database)
    }

    public func load() throws -> (state: ClientCertificateSyncState, localFlags: [UUID: Bool]) {
        let decoder = JSONDecoder()
        return try database.read { db in
            let certificates = try Data.fetchAll(
                db,
                sql: "SELECT payload FROM client_certificates WHERE account_identity_hash IS ? ORDER BY id",
                arguments: [accountIdentityHash]
            ).compactMap { try? decoder.decode(SyncedClientCertificateDescriptor.self, from: $0) }
            let associations = try Data.fetchAll(
                db,
                sql: "SELECT payload FROM client_certificate_associations WHERE account_identity_hash IS ? ORDER BY id",
                arguments: [accountIdentityHash]
            ).compactMap { try? decoder.decode(SyncedClientCertificateAssociation.self, from: $0) }
            let flags = try Row.fetchAll(
                db,
                sql: "SELECT id, synchronizes_with_icloud FROM client_certificate_local_flags WHERE account_identity_hash IS ?",
                arguments: [accountIdentityHash]
            )
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
                state.certificates.filter { $0.deletedAt == nil },
                table: "client_certificates",
                id: { $0.id.uuidString },
                modifiedAt: { $0.modifiedAt },
                account: accountIdentityHash,
                cloud: cloud,
                recordType: "MTClientCertificateDescriptor",
                enqueueChanges: accountIdentityHash != nil,
                in: db
            )
            try updateRecords(
                state.associations.filter { $0.deletedAt == nil },
                table: "client_certificate_associations",
                id: { $0.id.uuidString },
                modifiedAt: { $0.modifiedAt },
                account: accountIdentityHash,
                cloud: cloud,
                recordType: "MTClientCertificateAssociation",
                enqueueChanges: accountIdentityHash != nil,
                in: db
            )
            try updateLocalFlags(localFlags, account: accountIdentityHash, in: db)
        }
    }

    public func saveFromCloud(
        _ state: ClientCertificateSyncState,
        localFlags: [UUID: Bool]
    ) throws {
        try database.write { db in
            try updateRecords(
                state.certificates.filter { $0.deletedAt == nil },
                table: "client_certificates",
                id: { $0.id.uuidString },
                modifiedAt: { $0.modifiedAt },
                account: accountIdentityHash,
                in: db
            )
            try updateRecords(
                state.associations.filter { $0.deletedAt == nil },
                table: "client_certificate_associations",
                id: { $0.id.uuidString },
                modifiedAt: { $0.modifiedAt },
                account: accountIdentityHash,
                in: db
            )
            try updateLocalFlags(localFlags, account: accountIdentityHash, in: db)
        }
    }

    public func claimUnownedRows() throws {
        guard let accountIdentityHash else { return }
        try database.write { db in
            for table in ["client_certificates", "client_certificate_associations",
                          "client_certificate_local_flags"] {
                try db.execute(
                    sql: "UPDATE \(table) SET account_identity_hash = ? WHERE account_identity_hash IS NULL",
                    arguments: [accountIdentityHash]
                )
            }
        }
    }

    public func certificatePayload(id: UUID) throws -> CloudClientCertificateDescriptorPayload? {
        let loaded = try load().state.certificates.first { $0.id == id && $0.deletedAt == nil }
        return loaded.map { CloudClientCertificateDescriptorPayload($0.descriptor) }
    }

    public func associationPayload(id: UUID) throws -> CloudClientCertificateAssociationPayload? {
        let loaded = try load().state.associations.first { $0.id == id && $0.deletedAt == nil }
        return loaded.map { CloudClientCertificateAssociationPayload($0.association) }
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

private func updateLocalFlags(
    _ localFlags: [UUID: Bool],
    account: String?,
    in db: Database
) throws {
    let existingFlags = try Row.fetchAll(
        db,
        sql: "SELECT id, synchronizes_with_icloud FROM client_certificate_local_flags WHERE account_identity_hash IS ?",
        arguments: [account]
    ).reduce(into: [UUID: Bool]()) { result, row in
        if let id = UUID(uuidString: row["id"]) {
            result[id] = row["synchronizes_with_icloud"]
        }
    }
    for (id, value) in localFlags where existingFlags[id] != value {
        try db.execute(
            sql: """
                INSERT INTO client_certificate_local_flags
                    (id, synchronizes_with_icloud, account_identity_hash) VALUES (?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    synchronizes_with_icloud = excluded.synchronizes_with_icloud,
                    account_identity_hash = excluded.account_identity_hash
                """,
            arguments: [id.uuidString, value, account]
        )
    }
    for id in existingFlags.keys where localFlags[id] == nil {
        try db.execute(
            sql: "DELETE FROM client_certificate_local_flags WHERE id = ? AND account_identity_hash IS ?",
            arguments: [id.uuidString, account]
        )
    }
}

private func updateRecords<Record: Encodable>(
    _ records: [Record],
    table: String,
    id: (Record) -> String,
    modifiedAt: (Record) -> Date,
    account: String? = nil,
    cloud: CloudSyncRepository? = nil,
    recordType: String? = nil,
    enqueueChanges: Bool = false,
    in db: Database
) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let existingRows = try Row.fetchAll(
        db,
        sql: "SELECT id, payload FROM \(table) WHERE account_identity_hash IS ?",
        arguments: [account]
    )
    let existing = Dictionary(uniqueKeysWithValues: existingRows.map { ($0["id"] as String, $0["payload"] as Data) })
    let desiredIDs = Set(records.map(id))
    for record in records {
        let identifier = id(record)
        let payload = try encoder.encode(record)
        guard existing[identifier] != payload else { continue }
        try db.execute(
            sql: """
                INSERT INTO \(table) (id, payload, modified_at, account_identity_hash) VALUES (?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET payload = excluded.payload,
                    modified_at = excluded.modified_at,
                    account_identity_hash = excluded.account_identity_hash
                """,
            arguments: [identifier, payload, modifiedAt(record), account]
        )
        if enqueueChanges, let account, let cloud, let recordType {
            try cloud.enqueue(CloudPendingChange(
                accountIdentityHash: account,
                recordType: recordType,
                recordName: identifier,
                operation: .save
            ), in: db)
        }
    }
    for identifier in existing.keys where !desiredIDs.contains(identifier) {
        try db.execute(
            sql: "DELETE FROM \(table) WHERE id = ? AND account_identity_hash IS ?",
            arguments: [identifier, account]
        )
        if enqueueChanges, let account, let cloud, let recordType {
            try cloud.enqueue(CloudPendingChange(
                accountIdentityHash: account,
                recordType: recordType,
                recordName: identifier,
                operation: .delete
            ), in: db)
        }
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
