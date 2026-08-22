import Foundation
import Security

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

public enum ClientCertificatePEMError: Error, LocalizedError, Equatable, Sendable {
    case certificateMissing
    case privateKeyMissing
    case encryptedPrivateKey
    case invalidCertificate
    case invalidPrivateKey
    case unsupportedPrivateKey
    case mismatchedKey
    case invalidFilePair
    case tooManyFiles

    public var errorDescription: String? {
        switch self {
        case .certificateMissing:
            "No PEM certificate was found. Copy the complete client identity."
        case .privateKeyMissing:
            "No PEM private key was found. Copy the complete client identity."
        case .encryptedPrivateKey:
            "Encrypted private keys are not supported yet."
        case .invalidCertificate:
            "The PEM certificate is not a valid X.509 certificate."
        case .invalidPrivateKey:
            "The PEM private key is not valid."
        case .unsupportedPrivateKey:
            "This private-key format is not supported. Major Tom currently imports RSA client identities."
        case .mismatchedKey:
            "The private key does not belong to this certificate."
        case .invalidFilePair:
            "Choose one combined PEM file, or one certificate PEM file and one private-key PEM file."
        case .tooManyFiles:
            "Choose no more than two PEM files."
        }
    }
}

/// A validated certificate/private-key pair awaiting storage in Keychain.
///
/// The private key remains in memory only while the import sheet is open. It is never
/// placed in preferences or CloudKit.
public struct ClientCertificateImport: Sendable {
    public let certificateDER: Data
    let rsaPrivateKeyDER: Data

    public var commonName: String {
        CertificateSubject.commonName(certificateDER: certificateDER) ?? "Imported Identity"
    }

    public var notBefore: Date? {
        CertificateDetails.validityDates(certificateDER: certificateDER).notBefore
    }

    public var notAfter: Date? {
        CertificateDetails.validityDates(certificateDER: certificateDER).notAfter
    }

    public static func parse(pem: String) throws -> ClientCertificateImport {
        guard let certificateDER = pemBlock(named: "CERTIFICATE", in: pem) else {
            throw ClientCertificatePEMError.certificateMissing
        }
        guard SecCertificateCreateWithData(nil, certificateDER as CFData) != nil else {
            throw ClientCertificatePEMError.invalidCertificate
        }

        if pem.contains("-----BEGIN ENCRYPTED PRIVATE KEY-----") {
            throw ClientCertificatePEMError.encryptedPrivateKey
        }

        let rsaPrivateKeyDER: Data
        if let pkcs1 = pemBlock(named: "RSA PRIVATE KEY", in: pem) {
            rsaPrivateKeyDER = pkcs1
        } else if let pkcs8 = pemBlock(named: "PRIVATE KEY", in: pem) {
            rsaPrivateKeyDER = try unwrapRSAPKCS8(pkcs8)
        } else if pem.contains("-----BEGIN EC PRIVATE KEY-----") {
            throw ClientCertificatePEMError.unsupportedPrivateKey
        } else {
            throw ClientCertificatePEMError.privateKeyMissing
        }

        let privateKey = try makePrivateKey(rsaPrivateKeyDER)
        guard let privatePublicKey = SecKeyCopyPublicKey(privateKey),
              let certificate = SecCertificateCreateWithData(nil, certificateDER as CFData),
              let certificatePublicKey = SecCertificateCopyKey(certificate) else {
            throw ClientCertificatePEMError.invalidPrivateKey
        }
        var privateError: Unmanaged<CFError>?
        var certificateError: Unmanaged<CFError>?
        guard let privatePublicBytes = SecKeyCopyExternalRepresentation(
            privatePublicKey,
            &privateError
        ) as Data?,
              let certificatePublicBytes = SecKeyCopyExternalRepresentation(
                certificatePublicKey,
                &certificateError
              ) as Data?,
              privatePublicBytes == certificatePublicBytes else {
            throw ClientCertificatePEMError.mismatchedKey
        }

        return ClientCertificateImport(
            certificateDER: certificateDER,
            rsaPrivateKeyDER: rsaPrivateKeyDER
        )
    }

    /// Parses either one combined PEM document or a pair containing exactly one
    /// certificate-only document and one private-key-only document.
    public static func parse(pemFiles: [String]) throws -> ClientCertificateImport {
        guard pemFiles.count <= 2 else { throw ClientCertificatePEMError.tooManyFiles }
        guard pemFiles.count == 2 else {
            guard let pem = pemFiles.first else {
                throw ClientCertificatePEMError.certificateMissing
            }
            return try parse(pem: pem)
        }

        let roles = pemFiles.map { pem -> (certificate: Bool, privateKey: Bool) in
            (
                pem.contains("-----BEGIN CERTIFICATE-----"),
                pem.contains("-----BEGIN RSA PRIVATE KEY-----")
                    || pem.contains("-----BEGIN PRIVATE KEY-----")
                    || pem.contains("-----BEGIN ENCRYPTED PRIVATE KEY-----")
                    || pem.contains("-----BEGIN EC PRIVATE KEY-----")
            )
        }
        guard roles.filter({ $0.certificate }).count == 1,
              roles.filter({ $0.privateKey }).count == 1,
              roles.allSatisfy({ $0.certificate != $0.privateKey }) else {
            throw ClientCertificatePEMError.invalidFilePair
        }
        return try parse(pem: pemFiles.joined(separator: "\n"))
    }

    func makePrivateKey() throws -> SecKey {
        try Self.makePrivateKey(rsaPrivateKeyDER)
    }

    private static func makePrivateKey(_ der: Data) throws -> SecKey {
        var error: Unmanaged<CFError>?
        let attributes: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass: kSecAttrKeyClassPrivate
        ]
        guard let key = SecKeyCreateWithData(
            der as CFData,
            attributes as CFDictionary,
            &error
        ) else {
            throw ClientCertificatePEMError.invalidPrivateKey
        }
        return key
    }

    private static func pemBlock(named name: String, in pem: String) -> Data? {
        let beginning = "-----BEGIN \(name)-----"
        let ending = "-----END \(name)-----"
        guard let beginRange = pem.range(of: beginning),
              let endRange = pem.range(of: ending, range: beginRange.upperBound..<pem.endIndex) else {
            return nil
        }
        let base64 = pem[beginRange.upperBound..<endRange.lowerBound]
            .components(separatedBy: .whitespacesAndNewlines)
            .joined()
        return Data(base64Encoded: base64)
    }

    /// PKCS #8 wraps the PKCS #1 RSA private key in an OCTET STRING after an RSA
    /// algorithm identifier. Security.framework imports the inner PKCS #1 value.
    private static func unwrapRSAPKCS8(_ der: Data) throws -> Data {
        let rsaEncryptionOID = Data([0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x01])
        guard let root = try? DERElement.parse(in: der, at: der.startIndex),
              root.tag == 0x30,
              root.fullRange == der.startIndex..<der.endIndex,
              let fields = try? root.children(in: der),
              fields.count >= 3,
              fields[0].tag == 0x02,
              fields[1].tag == 0x30,
              fields[2].tag == 0x04,
              let algorithm = try? fields[1].children(in: der),
              let oid = algorithm.first,
              oid.tag == 0x06 else {
            throw ClientCertificatePEMError.invalidPrivateKey
        }
        guard der[oid.contentRange].elementsEqual(rsaEncryptionOID) else {
            throw ClientCertificatePEMError.unsupportedPrivateKey
        }
        return Data(der[fields[2].contentRange])
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

    /// Removes every approval for the identity used at `url` on that capsule. This
    /// prevents a broader rule from becoming active when a narrower rule is removed.
    public static func removingCapsuleApproval(
        matching url: URL,
        from associations: [ClientCertificateAssociation]
    ) -> [ClientCertificateAssociation] {
        guard let used = mostSpecific(matching: url, in: associations) else {
            return associations
        }
        return associations.filter {
            $0.certificateID != used.certificateID || $0.endpoint != used.endpoint
        }
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
