import Foundation

public struct CapsuleEndpoint: Hashable, Codable, Sendable {
    public let host: String
    public let port: UInt16

    public init(host: String, port: UInt16 = 1_965) {
        self.host = host.lowercased()
        self.port = port
    }
}

public struct PresentedServerIdentity: Equatable, Sendable {
    public let endpoint: CapsuleEndpoint
    public let publicKeySHA256: String
    public let certificateNotBefore: Date?
    public let certificateNotAfter: Date?
    /// The certificate exactly as the server presented it.
    ///
    /// Carried rather than pre-digested so there is a single source of truth: Page Info
    /// shows the certificate's own digest, the trust record stores an exportable copy,
    /// and both derive from these bytes.
    public let certificateDER: Data?

    public init(
        endpoint: CapsuleEndpoint,
        publicKeySHA256: String,
        certificateNotBefore: Date? = nil,
        certificateNotAfter: Date? = nil,
        certificateDER: Data? = nil
    ) {
        self.endpoint = endpoint
        self.publicKeySHA256 = publicKeySHA256.lowercased()
        self.certificateNotBefore = certificateNotBefore
        self.certificateNotAfter = certificateNotAfter
        self.certificateDER = certificateDER
    }

    /// SHA-256 of the whole certificate, lowercase hex, when the certificate is known.
    public var certificateSHA256: String? {
        certificateDER.map(CertificateDetails.sha256(certificateDER:))
    }

    public var certificatePEM: String? {
        certificateDER.map(CertificateDetails.pem(certificateDER:))
    }

    public func dateIssue(at date: Date) -> CertificateDateIssue? {
        if let certificateNotBefore, date < certificateNotBefore {
            return .notYetValid(validFrom: certificateNotBefore)
        }
        if let certificateNotAfter, date > certificateNotAfter {
            return .expired(expiredAt: certificateNotAfter)
        }
        return nil
    }
}

public struct TrustedServerIdentity: Equatable, Codable, Sendable {
    public enum Source: String, Codable, Sendable {
        case seed
        case user
    }

    public let endpoint: CapsuleEndpoint
    public var publicKeySHA256: String
    public var source: Source
    public var firstTrustedAt: Date
    public var lastSeenAt: Date
    public var timesSeen: Int
    /// SHA-256 of the certificate last seen from this endpoint, lowercase hex.
    public var certificateSHA256: String?
    /// When that certificate expires, so an approaching expiry can be surfaced without
    /// reconnecting.
    public var certificateNotAfter: Date?
    /// That certificate in PEM form, for inspection and export.
    ///
    /// All three describe the certificate *last seen*, not the one first trusted: trust
    /// is pinned to the public key, which survives renewal, so the certificate carrying
    /// it legitimately changes over time.
    public var certificatePEM: String?

    public init(
        endpoint: CapsuleEndpoint,
        publicKeySHA256: String,
        source: Source,
        firstTrustedAt: Date,
        lastSeenAt: Date,
        timesSeen: Int = 1,
        certificateSHA256: String? = nil,
        certificateNotAfter: Date? = nil,
        certificatePEM: String? = nil
    ) {
        self.endpoint = endpoint
        self.publicKeySHA256 = publicKeySHA256.lowercased()
        self.source = source
        self.firstTrustedAt = firstTrustedAt
        self.lastSeenAt = lastSeenAt
        self.timesSeen = timesSeen
        self.certificateSHA256 = certificateSHA256
        self.certificateNotAfter = certificateNotAfter
        self.certificatePEM = certificatePEM
    }
}

public struct SeedServerIdentity: Equatable, Hashable, Sendable {
    public let endpoint: CapsuleEndpoint
    public let publicKeySHA256: String

    public init(endpoint: CapsuleEndpoint, publicKeySHA256: String) {
        self.endpoint = endpoint
        self.publicKeySHA256 = publicKeySHA256.lowercased()
    }
}

public enum CertificateDateIssue: Equatable, Sendable {
    case notYetValid(validFrom: Date)
    case expired(expiredAt: Date)
}

public enum ServerTrustChallenge: Equatable, Sendable {
    case firstUse(presented: PresentedServerIdentity)
    case changed(
        presented: PresentedServerIdentity,
        previouslyTrusted: TrustedServerIdentity
    )
    case seedMismatch(
        presented: PresentedServerIdentity,
        expectedFingerprints: Set<String>
    )
    case invalidCertificateDates(
        presented: PresentedServerIdentity,
        issue: CertificateDateIssue
    )
}

public enum ServerTrustEvaluation: Equatable, Sendable {
    case allowSilently(source: TrustedServerIdentity.Source)
    case requiresApproval(ServerTrustChallenge)
}

public struct ServerTrustPolicy: Sendable {
    public init() {}

    public func evaluate(
        presented: PresentedServerIdentity,
        locallyTrusted: TrustedServerIdentity?,
        seeds: Set<SeedServerIdentity>,
        now: Date = Date()
    ) -> ServerTrustEvaluation {
        if let locallyTrusted {
            if fingerprintsMatch(locallyTrusted.publicKeySHA256, presented.publicKeySHA256) {
                if let issue = presented.dateIssue(at: now) {
                    return .requiresApproval(.invalidCertificateDates(presented: presented, issue: issue))
                }
                return .allowSilently(source: locallyTrusted.source)
            }
            return .requiresApproval(.changed(presented: presented, previouslyTrusted: locallyTrusted))
        }

        let endpointSeeds = seeds.filter { $0.endpoint == presented.endpoint }
        if endpointSeeds.contains(where: {
            fingerprintsMatch($0.publicKeySHA256, presented.publicKeySHA256)
        }) {
            if let issue = presented.dateIssue(at: now) {
                return .requiresApproval(.invalidCertificateDates(presented: presented, issue: issue))
            }
            return .allowSilently(source: .seed)
        }

        if !endpointSeeds.isEmpty {
            return .requiresApproval(.seedMismatch(
                presented: presented,
                expectedFingerprints: Set(endpointSeeds.map(\.publicKeySHA256))
            ))
        }

        return .requiresApproval(.firstUse(presented: presented))
    }

    private func fingerprintsMatch(_ lhs: String, _ rhs: String) -> Bool {
        lhs.caseInsensitiveCompare(rhs) == .orderedSame
    }
}
