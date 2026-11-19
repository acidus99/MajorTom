import Foundation

/// Store opening belongs to application composition. These handles are supplied to
/// their owners, never passed wholesale to browser workflows.
public struct ApplicationStorage: Sendable {
    public enum Store: Sendable { case durable, session, content, trust }
    public struct OpeningFailure: Sendable {
        public let store: Store
        public let underlying: any Error
    }
    public let durable: MajorTomDatabase?
    public let session: BackForwardCacheDatabase?
    public let content: ContentCacheDatabase?
    public let trust: TrustedIdentityStore?
    public let failures: [OpeningFailure]

    public init(directory: URL?) {
        var failures: [OpeningFailure] = []
        func open<T>(_ store: Store, _ operation: (URL) throws -> T) -> T? {
            do {
                guard let directory else { throw CocoaError(.fileNoSuchFile) }
                return try operation(directory)
            } catch {
                failures.append(OpeningFailure(store: store, underlying: error))
                return nil
            }
        }
        let durable = open(.durable) { try MajorTomDatabase(fileURL: $0.appendingPathComponent(MajorTomDatabase.filename)) }
        self.durable = durable
        session = open(.session) { try BackForwardCacheDatabase(fileURL: $0.appendingPathComponent(BackForwardCacheDatabase.filename)) }
        content = open(.content) { try ContentCacheDatabase(fileURL: $0.appendingPathComponent(ContentCacheDatabase.filename)) }
        trust = open(.trust) { directory in
            let legacy = directory.appendingPathComponent("trusted-identities.json")
            if let durable { return try TrustedIdentityStore(database: durable, legacyFileURL: legacy) }
            // Once migrated, never replace unavailable durable trust with an empty
            // JSON catalogue: that would silently turn a changed key into first use.
            guard FileManager.default.fileExists(atPath: legacy.path) else {
                throw CocoaError(.fileReadUnknown)
            }
            return try TrustedIdentityStore(fileURL: legacy)
        }
        if content != nil, let directory {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent("favicons.json"))
        }
        self.failures = failures
    }
}
