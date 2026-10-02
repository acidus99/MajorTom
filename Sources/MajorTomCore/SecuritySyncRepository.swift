import Foundation
import GRDB

public struct CloudClientCertificateDescriptorPayload: CloudSyncPayload, Equatable, Sendable {
    public static let payloadSchemaVersion = 1
    public static let knownPayloadKeys: Set<String> = [
        "id", "commonName", "emailAddress", "userID", "domain", "organization", "country",
        "notBefore", "notAfter", "certificateSHA256", "publicKeySHA256", "keychainIdentifiers"
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
    public var keychainIdentifiers: [UUID]

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
        keychainIdentifiers = descriptor.keychainIdentifiers
    }

    public var descriptor: ClientCertificateDescriptor {
        ClientCertificateDescriptor(id: id, commonName: commonName, emailAddress: emailAddress,
            userID: userID, domain: domain, organization: organization, country: country,
            notBefore: notBefore, notAfter: notAfter, certificateSHA256: certificateSHA256,
            publicKeySHA256: publicKeySHA256, keychainIdentifiers: keychainIdentifiers)
    }

    private enum CodingKeys: String, CodingKey {
        case id, commonName, emailAddress, userID, domain, organization, country
        case notBefore, notAfter, certificateSHA256, publicKeySHA256, keychainIdentifiers
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        commonName = try values.decode(String.self, forKey: .commonName)
        emailAddress = try values.decode(String.self, forKey: .emailAddress)
        userID = try values.decode(String.self, forKey: .userID)
        domain = try values.decode(String.self, forKey: .domain)
        organization = try values.decode(String.self, forKey: .organization)
        country = try values.decode(String.self, forKey: .country)
        notBefore = try values.decode(Date.self, forKey: .notBefore)
        notAfter = try values.decode(Date.self, forKey: .notAfter)
        certificateSHA256 = try values.decode(String.self, forKey: .certificateSHA256)
        publicKeySHA256 = try values.decode(String.self, forKey: .publicKeySHA256)
        keychainIdentifiers = try values.decodeIfPresent(
            [UUID].self, forKey: .keychainIdentifiers
        ) ?? [id]
    }
}

public struct CloudClientCertificateAssociationPayload: CloudSyncPayload, Equatable, Sendable {
    public static let payloadSchemaVersion = 1
    public static let knownPayloadKeys: Set<String> = ["association"]
    public var association: ClientCertificateAssociation
    public init(_ association: ClientCertificateAssociation) { self.association = association }
}

public enum ClientCertificateSyncRepositoryError: Error, Equatable, Sendable {
    case invalidCertificatePayload
    case invalidAssociationPayload
    case invalidLocalFlagID
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
        try database.read { try load(in: $0) }
    }

    func load(in db: Database) throws -> (state: ClientCertificateSyncState, localFlags: [UUID: Bool]) {
        let decoder = JSONDecoder()
            let certificatesData = try Row.fetchAll(
                db,
                sql: "SELECT id, payload FROM client_certificates WHERE account_identity_hash IS ? ORDER BY id",
                arguments: [accountIdentityHash]
            )
            let certificates = try certificatesData.map { row in
                do {
                    let value = try decoder.decode(SyncedClientCertificateDescriptor.self, from: row["payload"])
                    guard UUID(uuidString: row["id"]) == value.id else { throw CloudIncomingError.invalidIdentity }
                    return value
                } catch {
                    throw ClientCertificateSyncRepositoryError.invalidCertificatePayload
                }
            }
            let associationsData = try Row.fetchAll(
                db,
                sql: "SELECT id, payload FROM client_certificate_associations WHERE account_identity_hash IS ? ORDER BY id",
                arguments: [accountIdentityHash]
            )
            let associations = try associationsData.map { row in
                do {
                    let value = try decoder.decode(SyncedClientCertificateAssociation.self, from: row["payload"])
                    guard UUID(uuidString: row["id"]) == value.id else { throw CloudIncomingError.invalidIdentity }
                    return value
                } catch {
                    throw ClientCertificateSyncRepositoryError.invalidAssociationPayload
                }
            }
            let flags = try Row.fetchAll(
                db,
                sql: "SELECT id, synchronizes_with_icloud FROM client_certificate_local_flags WHERE account_identity_hash IS ?",
                arguments: [accountIdentityHash]
            )
                .reduce(into: [UUID: Bool]()) { result, row in
                    guard let id = UUID(uuidString: row["id"]) else {
                        throw ClientCertificateSyncRepositoryError.invalidLocalFlagID
                    }
                    result[id] = row["synchronizes_with_icloud"]
                }
            return (ClientCertificateSyncState(certificates: certificates, associations: associations), flags)
    }

    public func save(_ state: ClientCertificateSyncState, localFlags: [UUID: Bool]) throws {
        try database.write { db in
            try save(state, localFlags: localFlags, enqueueChanges: accountIdentityHash != nil, in: db)
        }
    }

    /// Runs a user operation against the latest rows under the writer lock. The app
    /// can await this work off its main actor without publishing an uncommitted edit.
    public func update(_ operation: @Sendable (inout [ClientCertificateDescriptor], inout [ClientCertificateAssociation], inout [UUID: Bool]) -> Void) throws
        -> (state: ClientCertificateSyncState, localFlags: [UUID: Bool]) {
        try database.write { db in
            let loaded = try load(in: db)
            var certificates = loaded.state.activeCertificates(preservingLocalStorageFrom: [])
            for index in certificates.indices {
                if let flag = loaded.localFlags[certificates[index].id] { certificates[index].synchronizesWithICloud = flag }
            }
            var associations = loaded.state.activeAssociations
            var flags = loaded.localFlags
            operation(&certificates, &associations, &flags)
            let next = loaded.state.reconciled(certificates: certificates, associations: associations, at: Date())
            try save(next, localFlags: flags, enqueueChanges: accountIdentityHash != nil, in: db)
            if let accountIdentityHash {
                let activeIDs = Set(certificates.map(\.id))
                for removed in loaded.state.certificates where removed.deletedAt == nil && !activeIDs.contains(removed.id) {
                    for alias in removed.descriptor.keychainIdentifiers where !activeIDs.contains(alias) {
                        try cloud.enqueue(.init(accountIdentityHash: accountIdentityHash, recordType: "MTClientCertificateDescriptor",
                                                recordName: alias.uuidString, operation: .delete), in: db)
                    }
                }
            }
            return (next, flags)
        }
    }

    public func saveFromCloud(
        _ state: ClientCertificateSyncState,
        localFlags: [UUID: Bool]
    ) throws {
        try database.write { db in try saveFromCloud(state, localFlags: localFlags, in: db) }
    }

    public func saveFromCloud(
        _ state: ClientCertificateSyncState,
        localFlags: [UUID: Bool],
        in db: Database
    ) throws {
        try save(state, localFlags: localFlags, enqueueChanges: false, in: db)
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

    func applyIncoming(_ models: [CloudRecordModel], deletions: [CloudIncomingDeletion], in db: Database) throws {
        for model in models {
            let table: String
            let id: UUID
            let payload: Data
            switch model {
            case .certificate(let value):
                table = "client_certificates"
                id = value.id
                payload = try CloudSyncRepository.encodeModelPayload(
                    SyncedClientCertificateDescriptor(descriptor: value.descriptor, modifiedAt: Date()))
            case .association(let value):
                table = "client_certificate_associations"
                id = value.association.id
                payload = try CloudSyncRepository.encodeModelPayload(
                    SyncedClientCertificateAssociation(association: value.association, modifiedAt: Date()))
            default: continue
            }
            try db.execute(sql: """
                INSERT INTO \(table)(id, payload, modified_at, account_identity_hash) VALUES (?, ?, ?, ?)
                ON CONFLICT(id, account_scope) DO UPDATE SET payload = excluded.payload, modified_at = excluded.modified_at
                """, arguments: [id.uuidString, payload, Date(), accountIdentityHash])
        }
        for deletion in deletions {
            let table: String
            switch deletion.recordType {
            case "MTClientCertificateDescriptor": table = "client_certificates"
            case "MTClientCertificateAssociation": table = "client_certificate_associations"
            default: continue
            }
            try db.execute(sql: "DELETE FROM \(table) WHERE id = ? AND account_identity_hash IS ?",
                           arguments: [deletion.recordName, accountIdentityHash])
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

    func legacyModelPayload(recordType: String, id: UUID, in db: Database) throws -> Data? {
        let table = recordType == "MTClientCertificateDescriptor" ? "client_certificates" : "client_certificate_associations"
        guard let data = try Data.fetchOne(db, sql: "SELECT payload FROM \(table) WHERE id = ? AND account_identity_hash IS ?",
                                           arguments: [id.uuidString, accountIdentityHash]) else { return nil }
        if recordType == "MTClientCertificateDescriptor" {
            let value = try JSONDecoder().decode(SyncedClientCertificateDescriptor.self, from: data)
            guard value.id == id else { throw CloudIncomingError.invalidIdentity }
            return try CloudSyncRepository.encodeModelPayload(CloudClientCertificateDescriptorPayload(value.descriptor))
        }
        let value = try JSONDecoder().decode(SyncedClientCertificateAssociation.self, from: data)
        guard value.id == id else { throw CloudIncomingError.invalidIdentity }
        return try CloudSyncRepository.encodeModelPayload(CloudClientCertificateAssociationPayload(value.association))
    }

    /// Reasserts an explicit deletion for every UUID that has represented an identity.
    /// The aliases may no longer have local metadata rows, so ordinary state diffing
    /// cannot discover these record deletes on its own.
    public func enqueueExplicitDeletion(
        descriptorIDs: Set<UUID>,
        associationIDs: Set<UUID>
    ) throws {
        guard let accountIdentityHash else { return }
        try database.write { db in
            for id in descriptorIDs {
                try cloud.enqueue(CloudPendingChange(
                    accountIdentityHash: accountIdentityHash,
                    recordType: "MTClientCertificateDescriptor",
                    recordName: id.uuidString,
                    operation: .delete
                ), in: db)
            }
            for id in associationIDs {
                try cloud.enqueue(CloudPendingChange(
                    accountIdentityHash: accountIdentityHash,
                    recordType: "MTClientCertificateAssociation",
                    recordName: id.uuidString,
                    operation: .delete
                ), in: db)
            }
        }
    }

    public func importLegacy(
        _ state: ClientCertificateSyncState,
        localFlags: [UUID: Bool]
    ) throws {
        try database.write { db in
            let marker = "legacy-client-certificate-sync-v2-imported"
            let imported = try Bool.fetchOne(
                db,
                sql: "SELECT EXISTS(SELECT 1 FROM persistence_metadata WHERE key = ?)",
                arguments: [marker]
            ) ?? false
            guard !imported else { return }
            try save(state, localFlags: localFlags, enqueueChanges: accountIdentityHash != nil, in: db)
            try db.execute(
                sql: "INSERT INTO persistence_metadata (key, value, updated_at) VALUES (?, ?, ?)",
                arguments: [marker, Data(), Date()]
            )
        }
    }

    func save(
        _ state: ClientCertificateSyncState,
        localFlags: [UUID: Bool],
        enqueueChanges: Bool,
        in db: Database
    ) throws {
        try updateRecords(
            state.certificates.filter { $0.deletedAt == nil },
            table: "client_certificates",
            id: { $0.id.uuidString },
            modifiedAt: { $0.modifiedAt },
            account: accountIdentityHash,
            cloud: cloud,
            recordType: "MTClientCertificateDescriptor",
            cloudPayload: {
                try CloudSyncRepository.encodeModelPayload(
                    CloudClientCertificateDescriptorPayload($0.descriptor)
                )
            },
            enqueueChanges: enqueueChanges,
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
            cloudPayload: {
                try CloudSyncRepository.encodeModelPayload(
                    CloudClientCertificateAssociationPayload($0.association)
                )
            },
            enqueueChanges: enqueueChanges,
            in: db
        )
        try updateLocalFlags(localFlags, account: accountIdentityHash, in: db)
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
        guard let id = UUID(uuidString: row["id"]) else {
            throw ClientCertificateSyncRepositoryError.invalidLocalFlagID
        }
        result[id] = row["synchronizes_with_icloud"]
    }
    for (id, value) in localFlags where existingFlags[id] != value {
        try db.execute(
            sql: """
                INSERT INTO client_certificate_local_flags
                    (id, synchronizes_with_icloud, account_identity_hash) VALUES (?, ?, ?)
                ON CONFLICT(id, account_scope) DO UPDATE SET
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
    cloudPayload: ((Record) throws -> Data)? = nil,
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
                ON CONFLICT(id, account_scope) DO UPDATE SET payload = excluded.payload,
                    modified_at = excluded.modified_at,
                    account_identity_hash = excluded.account_identity_hash
                """,
            arguments: [identifier, payload, modifiedAt(record), account]
        )
        if enqueueChanges, let account, let cloud, let recordType, let cloudPayload {
            let modelPayload = try cloudPayload(record)
            try cloud.enqueue(CloudPendingChange(
                accountIdentityHash: account,
                recordType: recordType,
                recordName: identifier,
                operation: .save,
                modelPayload: modelPayload,
                payloadDigest: CloudSyncRepository.digest(modelPayload)
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
