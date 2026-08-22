import Foundation
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
        XCTAssertNoThrow(try keychain.identity(for: descriptor.id))
        XCTAssertNoThrow(try keychain.identity(for: descriptor.id))
    }
}
