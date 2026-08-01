import Foundation

public actor TrustedIdentityStore {
    private let fileURL: URL
    private var records: [CapsuleEndpoint: TrustedServerIdentity]

    public init(fileURL: URL) throws {
        self.fileURL = fileURL
        if FileManager.default.fileExists(atPath: fileURL.path) {
            let data = try Data(contentsOf: fileURL)
            let decoded = try JSONDecoder.majorTom.decode([TrustedServerIdentity].self, from: data)
            self.records = Dictionary(uniqueKeysWithValues: decoded.map { ($0.endpoint, $0) })
        } else {
            self.records = [:]
        }
    }

    public func identity(for endpoint: CapsuleEndpoint) -> TrustedServerIdentity? {
        records[endpoint]
    }

    public func allIdentities() -> [TrustedServerIdentity] {
        records.values.sorted {
            ($0.endpoint.host, $0.endpoint.port) < ($1.endpoint.host, $1.endpoint.port)
        }
    }

    public func trust(
        _ presented: PresentedServerIdentity,
        source: TrustedServerIdentity.Source,
        at date: Date = Date()
    ) throws {
        if var existing = records[presented.endpoint],
           existing.publicKeySHA256.caseInsensitiveCompare(presented.publicKeySHA256) == .orderedSame {
            existing.lastSeenAt = date
            existing.timesSeen += 1
            records[presented.endpoint] = existing
        } else {
            records[presented.endpoint] = TrustedServerIdentity(
                endpoint: presented.endpoint,
                publicKeySHA256: presented.publicKeySHA256,
                source: source,
                firstTrustedAt: date,
                lastSeenAt: date
            )
        }
        try persist()
    }

    public func removeTrust(for endpoint: CapsuleEndpoint) throws {
        records.removeValue(forKey: endpoint)
        try persist()
    }

    private func persist() throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try JSONEncoder.majorTom.encode(allIdentities())
        try data.write(to: fileURL, options: [.atomic])
    }
}

private extension JSONEncoder {
    static var majorTom: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}

private extension JSONDecoder {
    static var majorTom: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
