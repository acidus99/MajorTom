import Foundation

public actor TrustedIdentityStore {
    /// How long a sighting-only update may sit in memory before it reaches disk.
    public static let sightingFlushInterval: Duration = .seconds(5)

    private let fileURL: URL
    private var records: [CapsuleEndpoint: TrustedServerIdentity]
    private var changeHandler: (@Sendable ([TrustedServerIdentity]) -> Void)?
    private var pendingSightingFlush: Task<Void, Never>?

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

    public func setChangeHandler(
        _ handler: (@Sendable ([TrustedServerIdentity]) -> Void)?
    ) {
        changeHandler = handler
        handler?(sortedIdentities())
    }

    public func trust(
        _ presented: PresentedServerIdentity,
        source: TrustedServerIdentity.Source,
        at date: Date = Date()
    ) throws {
        let decisionChanged: Bool
        if var existing = records[presented.endpoint],
           existing.publicKeySHA256.caseInsensitiveCompare(presented.publicKeySHA256) == .orderedSame {
            decisionChanged = false
            existing.lastSeenAt = date
            existing.timesSeen += 1
            // Refreshed on every sighting, but only when a certificate was actually
            // presented: a capsule that renewed while keeping its key serves a new
            // certificate with a later expiry, and a stale stored copy would describe
            // one the server no longer offers. Absent bytes must not erase what is
            // already recorded.
            if presented.certificateDER != nil {
                existing.certificateSHA256 = presented.certificateSHA256
                existing.certificateNotAfter = presented.certificateNotAfter
                existing.certificatePEM = presented.certificatePEM
            }
            records[presented.endpoint] = existing
        } else {
            decisionChanged = true
            records[presented.endpoint] = TrustedServerIdentity(
                endpoint: presented.endpoint,
                publicKeySHA256: presented.publicKeySHA256,
                source: source,
                firstTrustedAt: date,
                lastSeenAt: date,
                certificateSHA256: presented.certificateSHA256,
                certificateNotAfter: presented.certificateNotAfter,
                certificatePEM: presented.certificatePEM
            )
        }
        // Persisting is all-or-nothing: the file holds every record, each with its own
        // certificate PEM, so one write rewrites the entire trust database. A decision is
        // worth that; a sighting is not. Bumping lastSeenAt and timesSeen on a capsule
        // already trusted used to rewrite the whole file on every single page view.
        if decisionChanged {
            pendingSightingFlush?.cancel()
            pendingSightingFlush = nil
            try persist()
            changeHandler?(sortedIdentities())
        } else {
            scheduleSightingFlush()
        }
    }

    /// Adds trust decisions from a local client export in one atomic write.
    ///
    /// Existing decisions are deliberately left alone: importing must never replace a
    /// decision the person has already made in Major Tom. In particular, this avoids
    /// silently accepting a different identity for an endpoint that has changed since
    /// the export was created.
    @discardableResult
    public func importTrustedIdentities(
        _ presentedIdentities: [PresentedServerIdentity],
        source: TrustedServerIdentity.Source = .user,
        at date: Date = Date()
    ) throws -> Int {
        var additions = 0
        for presented in presentedIdentities where records[presented.endpoint] == nil {
            records[presented.endpoint] = TrustedServerIdentity(
                endpoint: presented.endpoint,
                publicKeySHA256: presented.publicKeySHA256,
                source: source,
                firstTrustedAt: date,
                lastSeenAt: date,
                certificateSHA256: presented.certificateSHA256,
                certificateNotAfter: presented.certificateNotAfter,
                certificatePEM: presented.certificatePEM
            )
            additions += 1
        }
        guard additions > 0 else { return 0 }
        pendingSightingFlush?.cancel()
        pendingSightingFlush = nil
        try persist()
        changeHandler?(sortedIdentities())
        return additions
    }

    /// Coalesces sighting counters into one write.
    ///
    /// The counters are advisory, so losing a few seconds of them to an abrupt quit is
    /// acceptable in a way that losing a trust decision would not be. Any later decision
    /// writes the whole file anyway, which carries the coalesced counters with it.
    private func scheduleSightingFlush() {
        guard pendingSightingFlush == nil else { return }
        pendingSightingFlush = Task { [weak self] in
            try? await Task.sleep(for: Self.sightingFlushInterval)
            guard !Task.isCancelled else { return }
            await self?.flushSightings()
        }
    }

    private func flushSightings() {
        pendingSightingFlush = nil
        try? persist()
    }

    /// Writes any coalesced sighting counters immediately. Call before quitting.
    public func flushPendingWrites() throws {
        guard pendingSightingFlush != nil else { return }
        pendingSightingFlush?.cancel()
        pendingSightingFlush = nil
        try persist()
    }

    public func removeTrust(for endpoint: CapsuleEndpoint) throws {
        records.removeValue(forKey: endpoint)
        pendingSightingFlush?.cancel()
        pendingSightingFlush = nil
        try persist()
        changeHandler?(sortedIdentities())
    }

    /// Removes every user-created trust decision in one durable update while retaining
    /// bundled seed policy. This is used when a person explicitly deletes local user data.
    public func removeAllUserTrust() throws {
        let retained = records.filter { $0.value.source == .seed }
        guard retained.count != records.count else { return }
        pendingSightingFlush?.cancel()
        pendingSightingFlush = nil
        records = retained
        try persist()
        changeHandler?(sortedIdentities())
    }

    /// Applies unambiguous user trust decisions received from CloudKit. Seed policy and
    /// locally observed certificate details remain local. Callers must exclude endpoints
    /// with more than one active fingerprint so a conflict can never become silent trust.
    public func applySyncedUserTrust(_ decisions: [SyncedServerTrustDecision]) throws {
        pendingSightingFlush?.cancel()
        pendingSightingFlush = nil
        var updated = records.filter { $0.value.source == .seed }
        for decision in decisions where decision.deletedAt == nil {
            // A bundled/local seed is machine policy and remains authoritative over a
            // cloud decision. A mismatch will continue through the normal warning flow.
            guard updated[decision.endpoint]?.source != .seed else { continue }
            if let existing = records[decision.endpoint],
               existing.publicKeySHA256.caseInsensitiveCompare(
                    decision.publicKeySHA256
               ) == .orderedSame {
                updated[decision.endpoint] = existing
            } else {
                updated[decision.endpoint] = TrustedServerIdentity(
                    endpoint: decision.endpoint,
                    publicKeySHA256: decision.publicKeySHA256,
                    source: .user,
                    firstTrustedAt: decision.firstTrustedAt,
                    lastSeenAt: decision.firstTrustedAt,
                    timesSeen: 0
                )
            }
        }
        records = updated
        try persist()
    }

    private func persist() throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try JSONEncoder.majorTom.encode(sortedIdentities())
        try data.write(to: fileURL, options: [.atomic])
    }

    private func sortedIdentities() -> [TrustedServerIdentity] {
        records.values.sorted {
            ($0.endpoint.host, $0.endpoint.port) < ($1.endpoint.host, $1.endpoint.port)
        }
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
