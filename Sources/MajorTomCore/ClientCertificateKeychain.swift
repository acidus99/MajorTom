import Foundation
import Security

public enum ClientCertificateKeychainError: Error, LocalizedError, Sendable {
    case invalidCommonName
    case invalidCountry
    case invalidExpiration
    case keyGeneration(String)
    case certificateGeneration(String)
    case keychain(OSStatus)
    case identityUnavailable

    public var errorDescription: String? {
        switch self {
        case .invalidCommonName:
            "Enter a common name for the certificate."
        case .invalidCountry:
            "Country must be empty or a two-letter country code."
        case .invalidExpiration:
            "The expiration date must be in the future."
        case .keyGeneration(let message):
            "The private key could not be created: \(message)"
        case .certificateGeneration(let message):
            "The certificate could not be created: \(message)"
        case .keychain(let status):
            SecCopyErrorMessageString(status, nil) as String?
                ?? "Keychain returned error \(status)."
        case .identityUnavailable:
            "The certificate's private key is not available on this Mac yet."
        }
    }
}

/// An ARC-managed client identity safe to carry through the sendable transport API.
public final class ClientTLSIdentity: @unchecked Sendable {
    let securityIdentity: SecIdentity

    public init(_ securityIdentity: SecIdentity) {
        self.securityIdentity = securityIdentity
    }
}

/// Creates and retrieves Major Tom client identities in the data-protection Keychain.
///
/// Both the private key and certificate are synchronizable Keychain items. CloudKit only
/// receives ``ClientCertificateDescriptor`` values and URL associations; it never sees
/// private-key bytes or an exportable credential bundle.
public struct ClientCertificateKeychain: Sendable {
    private static let labelPrefix = "dev.gemi.major-tom.client-cert."
    private static let certificateService = "dev.gemi.major-tom.client-certificates"

    private enum KeyStorage {
        case synchronizedDataProtection
        case localDataProtection
        case legacy

        var synchronizesWithICloud: Bool {
            self == .synchronizedDataProtection
        }

        var usesDataProtection: Bool {
            self != .legacy
        }
    }

    public init() {}

    public func create(
        _ request: ClientCertificateCreationRequest,
        id: UUID = UUID(),
        now: Date = Date()
    ) throws -> ClientCertificateDescriptor {
        let commonName = request.commonName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !commonName.isEmpty else { throw ClientCertificateKeychainError.invalidCommonName }
        let country = request.country.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard country.isEmpty || (country.utf8.count == 2 && country.utf8.allSatisfy(Self.isASCIIAlpha)) else {
            throw ClientCertificateKeychainError.invalidCountry
        }
        guard request.validUntil > now else { throw ClientCertificateKeychainError.invalidExpiration }

        let label = Self.label(for: id)
        let applicationTag = Self.applicationTag(for: id)
        let (privateKey, keyStorage) = try generatePrivateKey(
            label: label,
            applicationTag: applicationTag
        )
        var generationError: Unmanaged<CFError>?

        do {
            guard let publicKey = SecKeyCopyPublicKey(privateKey),
                  let publicKeyBytes = SecKeyCopyExternalRepresentation(publicKey, &generationError) as Data? else {
                let message = generationError?.takeRetainedValue().localizedDescription ?? "Public key unavailable"
                throw ClientCertificateKeychainError.certificateGeneration(message)
            }

            // Start slightly in the past so small clock differences do not make a newly
            // generated identity immediately fail Gemini status 62 validation.
            let notBefore = now.addingTimeInterval(-5 * 60)
            let subject = X509DistinguishedName(
                commonName: commonName,
                emailAddress: request.emailAddress.trimmingCharacters(in: .whitespacesAndNewlines),
                userID: request.userID.trimmingCharacters(in: .whitespacesAndNewlines),
                domain: request.domain.trimmingCharacters(in: .whitespacesAndNewlines),
                organization: request.organization.trimmingCharacters(in: .whitespacesAndNewlines),
                country: country
            )
            let certificateDER = try SelfSignedClientCertificate.make(
                privateKey: privateKey,
                rsaPublicKey: publicKeyBytes,
                subject: subject,
                notBefore: notBefore,
                notAfter: request.validUntil
            )
            guard SecCertificateCreateWithData(nil, certificateDER as CFData) != nil else {
                throw ClientCertificateKeychainError.certificateGeneration("Security.framework rejected the generated X.509 certificate.")
            }

            // Store the DER as an opaque Keychain value instead of a certificate-class
            // item. Certificate-class uniqueness is based on parsed issuer/serial fields
            // and can collide with malformed or stale third-party entries. The UUID
            // account gives Major Tom exact ownership while SecIdentity creation still
            // pairs these bytes with the matching permanent private key.
            var addCertificate: [CFString: Any] = [
                kSecClass: kSecClassGenericPassword,
                kSecAttrService: Self.certificateService,
                kSecAttrAccount: Self.account(for: id),
                kSecAttrLabel: label,
                kSecValueData: certificateDER
            ]
            if keyStorage.usesDataProtection {
                addCertificate[kSecUseDataProtectionKeychain] = true
                addCertificate[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlock
            }
            if keyStorage.synchronizesWithICloud {
                addCertificate[kSecAttrSynchronizable] = true
            }
            let addStatus = SecItemAdd(addCertificate as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw ClientCertificateKeychainError.keychain(addStatus)
            }

            return ClientCertificateDescriptor(
                id: id,
                commonName: commonName,
                emailAddress: subject.emailAddress,
                userID: subject.userID,
                domain: subject.domain,
                organization: subject.organization,
                country: subject.country,
                notBefore: notBefore,
                notAfter: request.validUntil,
                certificateSHA256: CertificateDetails.sha256(certificateDER: certificateDER),
                publicKeySHA256: try SubjectPublicKeyFingerprint.sha256(certificateDER: certificateDER),
                synchronizesWithICloud: keyStorage.synchronizesWithICloud
            )
        } catch {
            try? deleteKey(id: id)
            throw error
        }
    }

    public func identity(for id: UUID) throws -> ClientTLSIdentity {
        let certificateDER = try certificateDER(for: id)
        guard let certificate = SecCertificateCreateWithData(nil, certificateDER as CFData) else {
            throw ClientCertificateKeychainError.identityUnavailable
        }
        do {
            let privateKey = try privateKey(for: id)
            guard let identity = SecIdentityCreate(nil, certificate, privateKey) else {
                throw ClientCertificateKeychainError.identityUnavailable
            }
            return ClientTLSIdentity(identity)
        } catch ClientCertificateKeychainError.keychain(let status)
            where status == errSecMissingEntitlement {
            // Unsigned XCTest bundles cannot query an application-scoped private key
            // directly. Preserve test coverage of the generated identity through the
            // legacy search API; signed Major Tom never takes this branch.
            var identity: SecIdentity?
            let fallbackStatus = SecIdentityCreateWithCertificate(nil, certificate, &identity)
            guard fallbackStatus == errSecSuccess, let identity else {
                throw ClientCertificateKeychainError.keychain(fallbackStatus)
            }
            return ClientTLSIdentity(identity)
        }
    }

    private func privateKey(for id: UUID) throws -> SecKey {
        if let key = try dataProtectionPrivateKey(for: id, synchronized: true) {
            return key
        }
        if let key = try dataProtectionPrivateKey(for: id, synchronized: false) {
            return key
        }

        let query: [CFString: Any] = [
            kSecClass: kSecClassKey,
            kSecAttrApplicationTag: Self.applicationTag(for: id),
            kSecReturnRef: true,
            kSecMatchLimit: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let result else {
            if status == errSecItemNotFound {
                throw ClientCertificateKeychainError.identityUnavailable
            }
            throw ClientCertificateKeychainError.keychain(status)
        }
        return result as! SecKey
    }

    private func dataProtectionPrivateKey(
        for id: UUID,
        synchronized: Bool
    ) throws -> SecKey? {
        var query: [CFString: Any] = [
            kSecClass: kSecClassKey,
            kSecAttrApplicationTag: Self.applicationTag(for: id),
            kSecUseDataProtectionKeychain: true,
            kSecReturnRef: true,
            kSecMatchLimit: kSecMatchLimitOne
        ]
        if synchronized {
            query[kSecAttrSynchronizable] = kSecAttrSynchronizableAny
        }
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecSuccess { return result as! SecKey? }
        if status == errSecItemNotFound || status == errSecMissingEntitlement { return nil }
        throw ClientCertificateKeychainError.keychain(status)
    }

    public func certificateDER(for id: UUID) throws -> Data {
        let synchronizedQuery: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: Self.certificateService,
            kSecAttrAccount: Self.account(for: id),
            kSecAttrSynchronizable: kSecAttrSynchronizableAny,
            kSecUseDataProtectionKeychain: true,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        let synchronizedStatus = SecItemCopyMatching(synchronizedQuery as CFDictionary, &result)
        if synchronizedStatus == errSecSuccess, let data = result as? Data { return data }

        let localDataProtectionQuery: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: Self.certificateService,
            kSecAttrAccount: Self.account(for: id),
            kSecUseDataProtectionKeychain: true,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne
        ]
        result = nil
        let localDataProtectionStatus = SecItemCopyMatching(
            localDataProtectionQuery as CFDictionary,
            &result
        )
        if localDataProtectionStatus == errSecSuccess, let data = result as? Data { return data }

        let localQuery: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: Self.certificateService,
            kSecAttrAccount: Self.account(for: id),
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne
        ]
        result = nil
        let localStatus = SecItemCopyMatching(localQuery as CFDictionary, &result)
        if localStatus == errSecSuccess, let data = result as? Data { return data }

        // Compatibility with identities created by the first client-certificate build.
        let synchronizedLegacyQuery: [CFString: Any] = [
            kSecClass: kSecClassCertificate,
            kSecAttrLabel: Self.label(for: id),
            kSecAttrSynchronizable: kSecAttrSynchronizableAny,
            kSecUseDataProtectionKeychain: true,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne
        ]
        result = nil
        let synchronizedLegacyStatus = SecItemCopyMatching(
            synchronizedLegacyQuery as CFDictionary,
            &result
        )
        if synchronizedLegacyStatus == errSecSuccess, let data = result as? Data { return data }
        let localLegacyQuery: [CFString: Any] = [
            kSecClass: kSecClassCertificate,
            kSecAttrLabel: Self.label(for: id),
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne
        ]
        result = nil
        let localLegacyStatus = SecItemCopyMatching(localLegacyQuery as CFDictionary, &result)
        if localLegacyStatus == errSecSuccess, let data = result as? Data { return data }
        let statuses = [
            localStatus,
            synchronizedStatus,
            localDataProtectionStatus,
            synchronizedLegacyStatus,
            localLegacyStatus
        ]
        if statuses.allSatisfy({
            $0 == errSecItemNotFound || $0 == errSecMissingEntitlement
        }) {
            throw ClientCertificateKeychainError.identityUnavailable
        }
        throw ClientCertificateKeychainError.keychain(
            statuses.first {
                $0 != errSecItemNotFound && $0 != errSecMissingEntitlement
            } ?? localLegacyStatus
        )
    }

    public func delete(id: UUID) throws {
        let synchronizedCertificateStatus = SecItemDelete([
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: Self.certificateService,
            kSecAttrAccount: Self.account(for: id),
            kSecAttrSynchronizable: kSecAttrSynchronizableAny,
            kSecUseDataProtectionKeychain: true
        ] as CFDictionary)
        guard synchronizedCertificateStatus == errSecSuccess
                || synchronizedCertificateStatus == errSecItemNotFound
                || synchronizedCertificateStatus == errSecMissingEntitlement else {
            throw ClientCertificateKeychainError.keychain(synchronizedCertificateStatus)
        }
        let localDataProtectionCertificateStatus = SecItemDelete([
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: Self.certificateService,
            kSecAttrAccount: Self.account(for: id),
            kSecUseDataProtectionKeychain: true
        ] as CFDictionary)
        guard localDataProtectionCertificateStatus == errSecSuccess
                || localDataProtectionCertificateStatus == errSecItemNotFound
                || localDataProtectionCertificateStatus == errSecMissingEntitlement else {
            throw ClientCertificateKeychainError.keychain(localDataProtectionCertificateStatus)
        }
        let localCertificateStatus = SecItemDelete([
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: Self.certificateService,
            kSecAttrAccount: Self.account(for: id)
        ] as CFDictionary)
        guard localCertificateStatus == errSecSuccess || localCertificateStatus == errSecItemNotFound else {
            throw ClientCertificateKeychainError.keychain(localCertificateStatus)
        }
        let synchronizedLegacyCertificateStatus = SecItemDelete([
            kSecClass: kSecClassCertificate,
            kSecAttrLabel: Self.label(for: id),
            kSecAttrSynchronizable: kSecAttrSynchronizableAny,
            kSecUseDataProtectionKeychain: true
        ] as CFDictionary)
        guard synchronizedLegacyCertificateStatus == errSecSuccess
                || synchronizedLegacyCertificateStatus == errSecItemNotFound
                || synchronizedLegacyCertificateStatus == errSecMissingEntitlement else {
            throw ClientCertificateKeychainError.keychain(synchronizedLegacyCertificateStatus)
        }
        let localLegacyCertificateStatus = SecItemDelete([
            kSecClass: kSecClassCertificate,
            kSecAttrLabel: Self.label(for: id)
        ] as CFDictionary)
        guard localLegacyCertificateStatus == errSecSuccess
                || localLegacyCertificateStatus == errSecItemNotFound else {
            throw ClientCertificateKeychainError.keychain(localLegacyCertificateStatus)
        }
        try deleteKey(id: id)
    }

    private func deleteKey(id: UUID) throws {
        let synchronizedStatus = SecItemDelete([
            kSecClass: kSecClassKey,
            kSecAttrApplicationTag: Self.applicationTag(for: id),
            kSecAttrSynchronizable: kSecAttrSynchronizableAny,
            kSecUseDataProtectionKeychain: true
        ] as CFDictionary)
        guard synchronizedStatus == errSecSuccess
                || synchronizedStatus == errSecItemNotFound
                || synchronizedStatus == errSecMissingEntitlement else {
            throw ClientCertificateKeychainError.keychain(synchronizedStatus)
        }
        let localDataProtectionStatus = SecItemDelete([
            kSecClass: kSecClassKey,
            kSecAttrApplicationTag: Self.applicationTag(for: id),
            kSecUseDataProtectionKeychain: true
        ] as CFDictionary)
        guard localDataProtectionStatus == errSecSuccess
                || localDataProtectionStatus == errSecItemNotFound
                || localDataProtectionStatus == errSecMissingEntitlement else {
            throw ClientCertificateKeychainError.keychain(localDataProtectionStatus)
        }
        let localStatus = SecItemDelete([
            kSecClass: kSecClassKey,
            kSecAttrApplicationTag: Self.applicationTag(for: id)
        ] as CFDictionary)
        guard localStatus == errSecSuccess || localStatus == errSecItemNotFound else {
            throw ClientCertificateKeychainError.keychain(localStatus)
        }
    }

    private func generatePrivateKey(
        label: String,
        applicationTag: Data
    ) throws -> (SecKey, KeyStorage) {
        func dataProtectionKeyIsRetrievable(synchronized: Bool) -> Bool {
            var query: [CFString: Any] = [
                kSecClass: kSecClassKey,
                kSecAttrApplicationTag: applicationTag,
                kSecUseDataProtectionKeychain: true,
                kSecReturnRef: true,
                kSecMatchLimit: kSecMatchLimitOne
            ]
            if synchronized {
                query[kSecAttrSynchronizable] = kSecAttrSynchronizableAny
            }
            return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
        }

        func attempt(
            synchronized: Bool,
            dataProtection: Bool
        ) -> (SecKey?, CFError?) {
            var privateAttributes: [CFString: Any] = [
                kSecAttrIsPermanent: true,
                kSecAttrApplicationTag: applicationTag,
                kSecAttrLabel: label,
                kSecAttrCanSign: true
            ]
            if dataProtection {
                privateAttributes[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlock
            } else {
                // The file-based Keychain is only a compatibility path for unsigned
                // development/test builds. Give its private key the system's standard
                // "creating application" ACL so TLS signing does not require a prompt.
                var access: SecAccess?
                if SecAccessCreate(label as CFString, nil, &access) == errSecSuccess,
                   let access {
                    privateAttributes[kSecAttrAccess] = access
                }
            }
            var attributes: [CFString: Any] = [
                kSecAttrKeyType: kSecAttrKeyTypeRSA,
                kSecAttrKeySizeInBits: 2_048,
                kSecPrivateKeyAttrs: privateAttributes
            ]
            if dataProtection {
                attributes[kSecUseDataProtectionKeychain] = true
            }
            if synchronized {
                privateAttributes[kSecAttrSynchronizable] = true
                attributes[kSecPrivateKeyAttrs] = privateAttributes
            }
            var error: Unmanaged<CFError>?
            let key = SecKeyCreateRandomKey(attributes as CFDictionary, &error)
            return (key, error?.takeRetainedValue())
        }

        let synchronized = attempt(synchronized: true, dataProtection: true)
        if let key = synchronized.0, dataProtectionKeyIsRetrievable(synchronized: true) {
            return (key, .synchronizedDataProtection)
        }

        let localDataProtection = attempt(synchronized: false, dataProtection: true)
        if let key = localDataProtection.0, dataProtectionKeyIsRetrievable(synchronized: false) {
            return (key, .localDataProtection)
        }

        if localDataProtection.0 != nil
            || localDataProtection.1.map({
                CFErrorGetCode($0) == Int(errSecMissingEntitlement)
            }) == true {
            // Unsigned command-line tests have no application identifier and therefore
            // cannot use the Data Protection Keychain. Keep this final compatibility
            // fallback out of normal signed application builds.
            let legacy = attempt(synchronized: false, dataProtection: false)
            if let key = legacy.0 { return (key, .legacy) }
            throw ClientCertificateKeychainError.keyGeneration(
                legacy.1?.localizedDescription ?? "Unknown error"
            )
        }
        throw ClientCertificateKeychainError.keyGeneration(
            localDataProtection.1?.localizedDescription
                ?? synchronized.1?.localizedDescription
                ?? "Unknown error"
        )
    }

    private static func label(for id: UUID) -> String {
        labelPrefix + id.uuidString.lowercased()
    }

    private static func applicationTag(for id: UUID) -> Data {
        Data(label(for: id).utf8)
    }

    private static func account(for id: UUID) -> String {
        id.uuidString.lowercased()
    }

    private static func isASCIIAlpha(_ byte: UInt8) -> Bool {
        (65...90).contains(byte) || (97...122).contains(byte)
    }
}

private struct X509DistinguishedName {
    var commonName: String
    var emailAddress: String
    var userID: String
    var domain: String
    var organization: String
    var country: String
}

private enum SelfSignedClientCertificate {
    private static let sha256WithRSAEncryption: [UInt64] = [1, 2, 840, 113549, 1, 1, 11]
    private static let rsaEncryption: [UInt64] = [1, 2, 840, 113549, 1, 1, 1]

    static func make(
        privateKey: SecKey,
        rsaPublicKey: Data,
        subject: X509DistinguishedName,
        notBefore: Date,
        notAfter: Date
    ) throws -> Data {
        let signatureAlgorithm = DERWriter.sequence(
            DERWriter.oid(sha256WithRSAEncryption),
            DERWriter.null
        )
        let encodedName = distinguishedName(subject)
        let subjectPublicKeyInfo = DERWriter.sequence(
            DERWriter.sequence(DERWriter.oid(rsaEncryption), DERWriter.null),
            DERWriter.bitString(rsaPublicKey)
        )
        let extensions = DERWriter.contextSpecific(tag: 3, content: DERWriter.sequence(
            extensionValue(oid: [2, 5, 29, 19], critical: true, value: DERWriter.sequence()),
            extensionValue(
                oid: [2, 5, 29, 15],
                critical: true,
                value: DERWriter.bitString(Data([0x80]), unusedBits: 7)
            ),
            extensionValue(
                oid: [2, 5, 29, 37],
                critical: false,
                value: DERWriter.sequence(DERWriter.oid([1, 3, 6, 1, 5, 5, 7, 3, 2]))
            )
        ))

        var serial = Data(count: 16)
        let randomStatus = serial.withUnsafeMutableBytes { bytes in
            SecRandomCopyBytes(kSecRandomDefault, bytes.count, bytes.baseAddress!)
        }
        guard randomStatus == errSecSuccess else {
            throw ClientCertificateKeychainError.keychain(randomStatus)
        }
        serial[serial.startIndex] &= 0x7f
        if serial.allSatisfy({ $0 == 0 }) { serial[serial.startIndex] = 1 }

        let tbsCertificate = DERWriter.sequence(
            DERWriter.contextSpecific(tag: 0, content: DERWriter.integer(Data([2]))),
            DERWriter.integer(serial),
            signatureAlgorithm,
            encodedName,
            DERWriter.sequence(DERWriter.time(notBefore), DERWriter.time(notAfter)),
            encodedName,
            subjectPublicKeyInfo,
            extensions
        )

        var signatureError: Unmanaged<CFError>?
        guard let signature = SecKeyCreateSignature(
            privateKey,
            .rsaSignatureMessagePKCS1v15SHA256,
            tbsCertificate as CFData,
            &signatureError
        ) as Data? else {
            let message = signatureError?.takeRetainedValue().localizedDescription ?? "Signing failed"
            throw ClientCertificateKeychainError.certificateGeneration(message)
        }
        return DERWriter.sequence(tbsCertificate, signatureAlgorithm, DERWriter.bitString(signature))
    }

    private static func distinguishedName(_ subject: X509DistinguishedName) -> Data {
        var names: [Data] = []
        names.append(attribute(oid: [2, 5, 4, 3], value: DERWriter.utf8String(subject.commonName)))
        if !subject.emailAddress.isEmpty {
            names.append(attribute(
                oid: [1, 2, 840, 113549, 1, 9, 1],
                value: DERWriter.ia5String(subject.emailAddress)
            ))
        }
        if !subject.userID.isEmpty {
            names.append(attribute(
                oid: [0, 9, 2342, 19200300, 100, 1, 1],
                value: DERWriter.utf8String(subject.userID)
            ))
        }
        if !subject.domain.isEmpty {
            names.append(attribute(
                oid: [0, 9, 2342, 19200300, 100, 1, 25],
                value: DERWriter.ia5String(subject.domain)
            ))
        }
        if !subject.organization.isEmpty {
            names.append(attribute(oid: [2, 5, 4, 10], value: DERWriter.utf8String(subject.organization)))
        }
        if !subject.country.isEmpty {
            names.append(attribute(oid: [2, 5, 4, 6], value: DERWriter.printableString(subject.country)))
        }
        return DERWriter.sequence(names)
    }

    private static func attribute(oid: [UInt64], value: Data) -> Data {
        DERWriter.set(DERWriter.sequence(DERWriter.oid(oid), value))
    }

    private static func extensionValue(oid: [UInt64], critical: Bool, value: Data) -> Data {
        var fields = [DERWriter.oid(oid)]
        if critical { fields.append(DERWriter.boolean(true)) }
        fields.append(DERWriter.octetString(value))
        return DERWriter.sequence(fields)
    }
}

private enum DERWriter {
    static let null = Data([0x05, 0x00])

    static func sequence(_ elements: Data...) -> Data { sequence(elements) }
    static func sequence(_ elements: [Data]) -> Data { tlv(tag: 0x30, content: joined(elements)) }
    static func set(_ element: Data) -> Data { tlv(tag: 0x31, content: element) }
    static func integer(_ bytes: Data) -> Data {
        var value = bytes
        while value.count > 1, value.first == 0, value[value.index(after: value.startIndex)] & 0x80 == 0 {
            value.removeFirst()
        }
        if value.first.map({ $0 & 0x80 != 0 }) == true { value.insert(0, at: value.startIndex) }
        return tlv(tag: 0x02, content: value)
    }
    static func boolean(_ value: Bool) -> Data { tlv(tag: 0x01, content: Data([value ? 0xff : 0])) }
    static func octetString(_ value: Data) -> Data { tlv(tag: 0x04, content: value) }
    static func bitString(_ value: Data, unusedBits: UInt8 = 0) -> Data {
        tlv(tag: 0x03, content: Data([unusedBits]) + value)
    }
    static func utf8String(_ value: String) -> Data { tlv(tag: 0x0c, content: Data(value.utf8)) }
    static func printableString(_ value: String) -> Data { tlv(tag: 0x13, content: Data(value.utf8)) }
    static func ia5String(_ value: String) -> Data { tlv(tag: 0x16, content: Data(value.utf8)) }
    static func contextSpecific(tag: UInt8, content: Data) -> Data { tlv(tag: 0xa0 | tag, content: content) }

    static func oid(_ components: [UInt64]) -> Data {
        precondition(components.count >= 2)
        var bytes = Data()
        bytes.append(contentsOf: base128(components[0] * 40 + components[1]))
        for component in components.dropFirst(2) { bytes.append(contentsOf: base128(component)) }
        return tlv(tag: 0x06, content: bytes)
    }

    static func time(_ date: Date) -> Data {
        let calendar = Calendar(identifier: .gregorian)
        let year = calendar.dateComponents(in: TimeZone(secondsFromGMT: 0)!, from: date).year ?? 2000
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        if (1950...2049).contains(year) {
            formatter.dateFormat = "yyMMddHHmmss'Z'"
            return tlv(tag: 0x17, content: Data(formatter.string(from: date).utf8))
        }
        formatter.dateFormat = "yyyyMMddHHmmss'Z'"
        return tlv(tag: 0x18, content: Data(formatter.string(from: date).utf8))
    }

    private static func tlv(tag: UInt8, content: Data) -> Data {
        Data([tag]) + length(content.count) + content
    }

    private static func length(_ count: Int) -> Data {
        if count < 128 { return Data([UInt8(count)]) }
        var value = count
        var bytes: [UInt8] = []
        while value > 0 {
            bytes.insert(UInt8(value & 0xff), at: 0)
            value >>= 8
        }
        return Data([0x80 | UInt8(bytes.count)] + bytes)
    }

    private static func base128(_ value: UInt64) -> [UInt8] {
        var value = value
        var bytes = [UInt8(value & 0x7f)]
        value >>= 7
        while value > 0 {
            bytes.insert(UInt8(value & 0x7f) | 0x80, at: 0)
            value >>= 7
        }
        return bytes
    }

    private static func joined(_ elements: [Data]) -> Data {
        elements.reduce(into: Data()) { $0.append($1) }
    }
}
