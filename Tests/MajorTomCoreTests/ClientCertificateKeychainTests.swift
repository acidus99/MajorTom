import Foundation
import Security
import XCTest
@testable import MajorTomCore

final class ClientCertificateKeychainTests: XCTestCase {
    func testGeneratedCertificateFormsAResolvableKeychainIdentity() throws {
        let keychain = ClientCertificateKeychain()
        let descriptor = try keychain.create(ClientCertificateCreationRequest(
            commonName: "Major Tom Test \(UUID().uuidString)",
            emailAddress: "test@example.com",
            userID: "test-user",
            domain: "example.com",
            organization: "Major Tom Tests",
            country: "US",
            validUntil: Date().addingTimeInterval(24 * 60 * 60)
        ))
        defer { try? keychain.delete(id: descriptor.id) }

        let der = try keychain.certificateDER(for: descriptor.id)
        XCTAssertEqual(CertificateSubject.commonName(certificateDER: der), descriptor.commonName)
        XCTAssertEqual(CertificateDetails.sha256(certificateDER: der), descriptor.certificateSHA256)
        let identity = try keychain.identity(for: descriptor.id)
        XCTAssertNoThrow(try keychain.identity(for: descriptor.id))
        try assertCanSign(identity)

        let exportedPEM = try keychain.exportIdentityPEM(for: descriptor.id)
        XCTAssertTrue(exportedPEM.hasSuffix("-----END RSA PRIVATE KEY-----\n"))
        let exported = try ClientCertificateImport.parse(pem: exportedPEM)
        XCTAssertEqual(exported.certificateDER, der)
    }

    private func assertCanSign(_ identity: ClientTLSIdentity) throws {
        var reloadedPrivateKey: SecKey?
        XCTAssertEqual(
            SecIdentityCopyPrivateKey(identity.securityIdentity, &reloadedPrivateKey),
            errSecSuccess
        )
        let signingKey = try XCTUnwrap(reloadedPrivateKey)
        XCTAssertEqual(
            (SecKeyCopyAttributes(signingKey) as? [CFString: Any])?[kSecAttrCanSign] as? Bool,
            true
        )
        var signingError: Unmanaged<CFError>?
        XCTAssertNotNil(SecKeyCreateSignature(
            signingKey,
            .rsaSignatureMessagePKCS1v15SHA256,
            Data("Major Tom import test".utf8) as CFData,
            &signingError
        ))
        signingError = nil
        XCTAssertNotNil(SecKeyCreateSignature(
            signingKey,
            .rsaSignatureMessagePSSSHA256,
            Data("Major Tom TLS 1.3 import test".utf8) as CFData,
            &signingError
        ))
    }

    func testLagrangeStyleCombinedPKCS8PEMImportsAndResolves() throws {
        let pem = try makeCombinedPEM()
        let imported = try ClientCertificateImport.parse(pem: pem)
        XCTAssertEqual(imported.commonName, "Imported Lagrange Identity")

        let keychain = ClientCertificateKeychain()
        let descriptor = try keychain.importIdentity(imported)
        defer { try? keychain.delete(id: descriptor.id) }

        XCTAssertEqual(descriptor.commonName, "Imported Lagrange Identity")
        XCTAssertEqual(
            try keychain.certificateDER(for: descriptor.id),
            imported.certificateDER
        )
        let identity = try keychain.identity(for: descriptor.id)
        XCTAssertNoThrow(try keychain.identity(for: descriptor.id))
        try assertCanSign(identity)
    }

    func testImportRejectsAPrivateKeyFromAnotherIdentity() throws {
        let first = try makeCombinedPEM()
        let second = try makeCombinedPEM()
        let firstCertificate = try XCTUnwrap(pemBlock(named: "CERTIFICATE", in: first))
        let secondKey = try XCTUnwrap(pemBlock(named: "PRIVATE KEY", in: second))
        let mismatched = pem(named: "CERTIFICATE", data: firstCertificate)
            + "\n"
            + pem(named: "PRIVATE KEY", data: secondKey)

        XCTAssertThrowsError(try ClientCertificateImport.parse(pem: mismatched)) { error in
            XCTAssertEqual(error as? ClientCertificatePEMError, .mismatchedKey)
        }
    }

    func testPEMBlocksMayPutThePrivateKeyBeforeTheCertificate() throws {
        let normal = try makeCombinedPEM()
        let certificate = try XCTUnwrap(pemBlock(named: "CERTIFICATE", in: normal))
        let privateKey = try XCTUnwrap(pemBlock(named: "PRIVATE KEY", in: normal))
        let reversed = pem(named: "PRIVATE KEY", data: privateKey)
            + "\n"
            + pem(named: "CERTIFICATE", data: certificate)

        let imported = try ClientCertificateImport.parse(pem: reversed)
        XCTAssertEqual(imported.commonName, "Imported Lagrange Identity")
    }

    func testSeparateCertificateAndPrivateKeyFilesImportInEitherOrder() throws {
        let combined = try makeCombinedPEM()
        let certificate = pem(
            named: "CERTIFICATE",
            data: try XCTUnwrap(pemBlock(named: "CERTIFICATE", in: combined))
        )
        let privateKey = pem(
            named: "PRIVATE KEY",
            data: try XCTUnwrap(pemBlock(named: "PRIVATE KEY", in: combined))
        )

        XCTAssertNoThrow(try ClientCertificateImport.parse(
            pemFiles: [certificate, privateKey]
        ))
        XCTAssertNoThrow(try ClientCertificateImport.parse(
            pemFiles: [privateKey, certificate]
        ))
    }

    func testTwoFilesMustBeExactlyOneCertificateAndOnePrivateKey() throws {
        let combined = try makeCombinedPEM()
        let certificate = pem(
            named: "CERTIFICATE",
            data: try XCTUnwrap(pemBlock(named: "CERTIFICATE", in: combined))
        )
        let privateKey = pem(
            named: "PRIVATE KEY",
            data: try XCTUnwrap(pemBlock(named: "PRIVATE KEY", in: combined))
        )

        XCTAssertThrowsError(try ClientCertificateImport.parse(
            pemFiles: [certificate, certificate]
        )) { error in
            XCTAssertEqual(error as? ClientCertificatePEMError, .invalidFilePair)
        }
        XCTAssertThrowsError(try ClientCertificateImport.parse(
            pemFiles: [combined, privateKey]
        )) { error in
            XCTAssertEqual(error as? ClientCertificatePEMError, .invalidFilePair)
        }
    }

    func testNoMoreThanTwoPEMFilesMayBeSelected() {
        XCTAssertThrowsError(try ClientCertificateImport.parse(
            pemFiles: ["first", "second", "third"]
        )) { error in
            XCTAssertEqual(error as? ClientCertificatePEMError, .tooManyFiles)
        }
    }

    private func makeCombinedPEM() throws -> String {
        var error: Unmanaged<CFError>?
        let attributes: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits: 2_048
        ]
        let privateKey = try XCTUnwrap(SecKeyCreateRandomKey(attributes as CFDictionary, &error))
        let publicKey = try XCTUnwrap(SecKeyCopyPublicKey(privateKey))
        let publicBytes = try XCTUnwrap(
            SecKeyCopyExternalRepresentation(publicKey, &error) as Data?
        )
        let privateBytes = try XCTUnwrap(
            SecKeyCopyExternalRepresentation(privateKey, &error) as Data?
        )
        let now = Date()
        let certificate = try SelfSignedClientCertificate.make(
            privateKey: privateKey,
            rsaPublicKey: publicBytes,
            subject: X509DistinguishedName(
                commonName: "Imported Lagrange Identity",
                emailAddress: "lagrange@example.com",
                userID: "",
                domain: "",
                organization: "",
                country: ""
            ),
            notBefore: now.addingTimeInterval(-60),
            notAfter: now.addingTimeInterval(86_400)
        )
        let pkcs8 = derSequence(
            Data([0x02, 0x01, 0x00]),
            Data([0x30, 0x0D, 0x06, 0x09, 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x01, 0x05, 0x00]),
            derTLV(tag: 0x04, content: privateBytes)
        )
        return pem(named: "CERTIFICATE", data: certificate)
            + "\n"
            + pem(named: "PRIVATE KEY", data: pkcs8)
    }

    private func pem(named name: String, data: Data) -> String {
        let base64 = data.base64EncodedString()
        let lines = stride(from: 0, to: base64.count, by: 64).map { offset in
            let start = base64.index(base64.startIndex, offsetBy: offset)
            let end = base64.index(start, offsetBy: min(64, base64.distance(from: start, to: base64.endIndex)))
            return String(base64[start..<end])
        }
        return (["-----BEGIN \(name)-----"] + lines + ["-----END \(name)-----"])
            .joined(separator: "\n")
    }

    private func pemBlock(named name: String, in pem: String) -> Data? {
        let beginning = "-----BEGIN \(name)-----"
        let ending = "-----END \(name)-----"
        guard let start = pem.range(of: beginning),
              let end = pem.range(of: ending, range: start.upperBound..<pem.endIndex) else {
            return nil
        }
        let base64 = pem[start.upperBound..<end.lowerBound]
            .components(separatedBy: .whitespacesAndNewlines)
            .joined()
        return Data(base64Encoded: base64)
    }

    private func derSequence(_ elements: Data...) -> Data {
        derTLV(tag: 0x30, content: elements.reduce(into: Data()) { $0.append($1) })
    }

    private func derTLV(tag: UInt8, content: Data) -> Data {
        Data([tag]) + derLength(content.count) + content
    }

    private func derLength(_ count: Int) -> Data {
        if count < 128 { return Data([UInt8(count)]) }
        var count = count
        var bytes: [UInt8] = []
        while count > 0 {
            bytes.insert(UInt8(count & 0xff), at: 0)
            count >>= 8
        }
        return Data([0x80 | UInt8(bytes.count)] + bytes)
    }
}
