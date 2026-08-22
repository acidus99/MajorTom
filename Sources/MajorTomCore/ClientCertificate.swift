import Foundation

/// The public, syncable description of a TLS client identity.
///
/// The certificate and private key deliberately do not appear here. They live in Keychain;
/// this value is safe to encode into local preferences and private CloudKit records.
public struct ClientCertificateDescriptor: Codable, Equatable, Identifiable, Sendable {
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
    public var synchronizesWithICloud: Bool

    public init(
        id: UUID,
        commonName: String,
        emailAddress: String = "",
        userID: String = "",
        domain: String = "",
        organization: String = "",
        country: String = "",
        notBefore: Date,
        notAfter: Date,
        certificateSHA256: String,
        publicKeySHA256: String,
        synchronizesWithICloud: Bool = true
    ) {
        self.id = id
        self.commonName = commonName
        self.emailAddress = emailAddress
        self.userID = userID
        self.domain = domain
        self.organization = organization
        self.country = country
        self.notBefore = notBefore
        self.notAfter = notAfter
        self.certificateSHA256 = certificateSHA256.lowercased()
        self.publicKeySHA256 = publicKeySHA256.lowercased()
        self.synchronizesWithICloud = synchronizesWithICloud
    }

    public func isValid(at date: Date = Date()) -> Bool {
        notBefore <= date && date <= notAfter
    }
}

/// Values entered when Major Tom creates a self-signed client certificate.
public struct ClientCertificateCreationRequest: Equatable, Sendable {
    public var commonName: String
    public var emailAddress: String
    public var userID: String
    public var domain: String
    public var organization: String
    public var country: String
    public var validUntil: Date

    public init(
        commonName: String,
        emailAddress: String = "",
        userID: String = "",
        domain: String = "",
        organization: String = "",
        country: String = "",
        validUntil: Date
    ) {
        self.commonName = commonName
        self.emailAddress = emailAddress
        self.userID = userID
        self.domain = domain
        self.organization = organization
        self.country = country
        self.validUntil = validUntil
    }
}

public enum ClientCertificateScopeChoice: String, CaseIterable, Codable, Sendable {
    case entireCapsule
    case pathAndDescendants

    /// Gemini applications commonly authenticate a session across several sibling
    /// paths after enrollment. Keep the narrower option available, but make the normal
    /// sign-in behavior work without requiring the user to anticipate those routes.
    public static let authenticationDefault: ClientCertificateScopeChoice = .entireCapsule
}

/// User consent to offer one identity to one capsule path tree.
///
/// Queries and fragments never participate in matching. The endpoint contains the
/// effective port, so an identity approved for example.com:1965 is not exposed to a
/// different service on example.com:1966.
public struct ClientCertificateAssociation: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var certificateID: UUID
    public var endpoint: CapsuleEndpoint
    public var scope: ClientCertificateScopeChoice
    /// The URL at which approval was granted. Whole-capsule rules retain this path so
    /// changing the rule back to path scope restores the user's original boundary.
    public var pathPrefix: String

    public init(
        id: UUID = UUID(),
        certificateID: UUID,
        endpoint: CapsuleEndpoint,
        scope: ClientCertificateScopeChoice,
        pathPrefix: String
    ) {
        self.id = id
        self.certificateID = certificateID
        self.endpoint = endpoint
        self.scope = scope
        self.pathPrefix = Self.normalizedPath(pathPrefix)
    }

    public static func entireCapsule(
        certificateID: UUID,
        endpoint: CapsuleEndpoint,
        approvedPath: String = "/"
    ) -> ClientCertificateAssociation {
        ClientCertificateAssociation(
            certificateID: certificateID,
            endpoint: endpoint,
            scope: .entireCapsule,
            pathPrefix: approvedPath
        )
    }

    public static func pathAndDescendants(
        certificateID: UUID,
        url: URL
    ) -> ClientCertificateAssociation? {
        guard let endpoint = CapsuleEndpoint(url: url) else { return nil }
        return ClientCertificateAssociation(
            certificateID: certificateID,
            endpoint: endpoint,
            scope: .pathAndDescendants,
            pathPrefix: Self.requestPath(for: url)
        )
    }

    public func matches(_ url: URL) -> Bool {
        guard CapsuleEndpoint(url: url) == endpoint else { return false }
        if scope == .entireCapsule { return true }
        let candidate = Self.requestPath(for: url)
        if pathPrefix == "/" { return true }
        if candidate == pathPrefix { return true }
        if pathPrefix.hasSuffix("/") { return candidate.hasPrefix(pathPrefix) }
        return candidate.hasPrefix(pathPrefix + "/")
    }

    public static func mostSpecific(
        matching url: URL,
        in associations: some Sequence<ClientCertificateAssociation>
    ) -> ClientCertificateAssociation? {
        associations
            .filter { $0.matches(url) }
            .max { lhs, rhs in lhs.specificity < rhs.specificity }
    }

    public static func requestPath(for url: URL) -> String {
        let path = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath
            ?? url.path(percentEncoded: true)
        return normalizedPath(path)
    }

    private static func normalizedPath(_ path: String) -> String {
        guard !path.isEmpty else { return "/" }
        return path.hasPrefix("/") ? path : "/" + path
    }

    private var specificity: Int {
        scope == .entireCapsule ? 0 : pathPrefix.utf8.count
    }

    private enum CodingKeys: String, CodingKey {
        case id, certificateID, endpoint, scope, pathPrefix
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        certificateID = try values.decode(UUID.self, forKey: .certificateID)
        endpoint = try values.decode(CapsuleEndpoint.self, forKey: .endpoint)
        pathPrefix = Self.normalizedPath(try values.decode(String.self, forKey: .pathPrefix))
        scope = try values.decodeIfPresent(ClientCertificateScopeChoice.self, forKey: .scope)
            ?? (pathPrefix == "/" ? .entireCapsule : .pathAndDescendants)
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(certificateID, forKey: .certificateID)
        try values.encode(endpoint, forKey: .endpoint)
        try values.encode(scope, forKey: .scope)
        try values.encode(pathPrefix, forKey: .pathPrefix)
    }
}

/// One conflict-resolvable client-certificate metadata snapshot in private CloudKit.
public struct SyncedClientCertificates: Codable, Equatable, Sendable {
    public var certificates: [ClientCertificateDescriptor]
    public var associations: [ClientCertificateAssociation]
    public var modifiedAt: Date

    public init(
        certificates: [ClientCertificateDescriptor] = [],
        associations: [ClientCertificateAssociation] = [],
        modifiedAt: Date
    ) {
        self.certificates = certificates
        self.associations = associations
        self.modifiedAt = modifiedAt
    }

    public func shouldReplace(_ local: SyncedClientCertificates?) -> Bool {
        guard let local else { return true }
        return modifiedAt > local.modifiedAt
    }
}
