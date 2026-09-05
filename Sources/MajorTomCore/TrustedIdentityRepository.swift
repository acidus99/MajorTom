import Foundation
import GRDB

/// Per-endpoint local TOFU decisions and observations.
public struct TrustedIdentityRepository: Sendable {
    private let database: MajorTomDatabase

    public init(database: MajorTomDatabase) {
        self.database = database
    }

    public func identities() throws -> [TrustedServerIdentity] {
        let decoder = JSONDecoder.trustedIdentityRepository
        return try database.read { db in
            try Data.fetchAll(db, sql: "SELECT payload FROM trusted_server_identities")
                .map { try decoder.decode(TrustedServerIdentity.self, from: $0) }
                .sorted { ($0.endpoint.host, $0.endpoint.port) < ($1.endpoint.host, $1.endpoint.port) }
        }
    }

    public func save(_ identities: [TrustedServerIdentity]) throws {
        let encoder = JSONEncoder.trustedIdentityRepository
        try database.write { db in
            let desired = Dictionary(uniqueKeysWithValues: identities.map { ($0.endpoint, $0) })
            let existing = try Row.fetchAll(
                db,
                sql: "SELECT endpoint_host, endpoint_port, payload FROM trusted_server_identities"
            )
            var existingPayloads: [CapsuleEndpoint: Data] = [:]
            for row in existing {
                existingPayloads[CapsuleEndpoint(host: row["endpoint_host"], port: row["endpoint_port"])] = row["payload"]
            }
            for (endpoint, identity) in desired {
                let payload = try encoder.encode(identity)
                guard existingPayloads[endpoint] != payload else { continue }
                try db.execute(
                    sql: """
                        INSERT INTO trusted_server_identities (
                            endpoint_host, endpoint_port, payload, updated_at
                        ) VALUES (?, ?, ?, ?)
                        ON CONFLICT(endpoint_host, endpoint_port) DO UPDATE SET
                            payload = excluded.payload,
                            updated_at = excluded.updated_at
                        """,
                    arguments: [endpoint.host, endpoint.port, payload, identity.lastSeenAt]
                )
            }
            for endpoint in existingPayloads.keys where desired[endpoint] == nil {
                try db.execute(
                    sql: "DELETE FROM trusted_server_identities WHERE endpoint_host = ? AND endpoint_port = ?",
                    arguments: [endpoint.host, endpoint.port]
                )
            }
        }
    }

    public func importLegacy(_ identities: [TrustedServerIdentity]) throws {
        try database.write { db in
            let marker = "legacy-trusted-identities-json-imported"
            guard !(try db.tableExists("persistence_metadata") && (try Bool.fetchOne(
                db,
                sql: "SELECT EXISTS(SELECT 1 FROM persistence_metadata WHERE key = ?)",
                arguments: [marker]
            ) ?? false)) else { return }
            let count = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM trusted_server_identities") ?? 0
            if count == 0 {
                let encoder = JSONEncoder.trustedIdentityRepository
                for identity in identities {
                    try db.execute(
                        sql: "INSERT INTO trusted_server_identities (endpoint_host, endpoint_port, payload, updated_at) VALUES (?, ?, ?, ?)",
                        arguments: [identity.endpoint.host, identity.endpoint.port, try encoder.encode(identity), identity.lastSeenAt]
                    )
                }
            }
            try db.execute(
                sql: "INSERT INTO persistence_metadata (key, value, updated_at) VALUES (?, ?, ?)",
                arguments: [marker, Data(), Date()]
            )
        }
    }
}

private extension JSONEncoder {
    static var trustedIdentityRepository: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}

private extension JSONDecoder {
    static var trustedIdentityRepository: JSONDecoder { JSONDecoder() }
}
