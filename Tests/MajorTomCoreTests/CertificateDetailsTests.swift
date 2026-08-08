import Foundation
import XCTest
@testable import MajorTomCore

final class CertificateDetailsTests: XCTestCase {
    /// The same self-signed fixture used for the SPKI fingerprint test.
    private static let certificateBase64 = """
    MIIDFTCCAf2gAwIBAgIURUz3VTTlE0H71h8YCaczUq7YfbwwDQYJKoZIhvcNAQELBQAwGjEYMBYGA1UEAwwPZml4dHVyZS5leGFtcGxlMB4XDTI2MDgwMTE4NDAxMloXDTM2MDcyOTE4NDAxMlowGjEYMBYGA1UEAwwPZml4dHVyZS5leGFtcGxlMIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAlp5UR+pMVreAVSq4tCFmbb5efx78DXHrmTwKuT1Cs2+J+8ZS3NNST0R1t7mRfc4oDH3xngETOaEUMHuwKVNB9A1LVbeM17BDiyaWReJC6DADGEhBREg0Uv2tcn1rG5eD/dY7I8x8WWLKg2Mg3nwThNN6SZNqCKr0BCjcyAE0ixBCtkQmA5bv0ecCAYHP4o7Z/0zHPwFL1XaTWdjkEiFBe2H5ePNj54GQgcpanfurwfCRUMgrHbGs0OX1bTvVwVDyuWscHaLdKm9s7NobdyelH1pLUyaXhvX2uYCyLKuNKPYnr91QMGY9iHo06ffnF2Kijxc+Kn65sM4mQvbrK6c/8wIDAQABo1MwUTAdBgNVHQ4EFgQU29M5ahjpHtnb9s2xPYU2IdPQCuswHwYDVR0jBBgwFoAU29M5ahjpHtnb9s2xPYU2IdPQCuswDwYDVR0TAQH/BAUwAwEB/zANBgkqhkiG9w0BAQsFAAOCAQEARpJOwlGKmmfqiXkWp6iAmb+GueFm93ZKP8fs9NAqCpIErTOtQHdvTB1h0OK6M5oQNQ3vXA4xdUjFFos2zOYDlYb6udS7efnDx5+aK+RaPcVQxAW9oxranHHMIYd0QewbUl7tJa/SZrYec8be3SD+SNS7Jza5ODndxENQoq+J5XBFyjD+Tf7I3Ic60u9xgmo+cytLjeL2xroTRmsu89kuLcO3ILDbEU7kgzBh9Scz2fde73NLK0JJ90gtBnHOgzrKX+LOnkZ94REcut9LvrhZt9c7HaZz8ofhoL0tZ0FjUs/uTPb46cwwa8QRc3QKrVmAyMl1Znxsn+DpWBCl6ED2VQ==
    """

    private func fixture() throws -> Data {
        try XCTUnwrap(Data(base64Encoded: Self.certificateBase64))
    }

    /// Verified against `openssl x509 -fingerprint -sha256`, which is also what
    /// `openssl dgst -sha256` of the DER reports.
    func testCertificateSHA256MatchesOpenSSL() throws {
        XCTAssertEqual(
            CertificateDetails.sha256(certificateDER: try fixture()),
            "3898761ee12633f9d8b264db987204c1b0da017483a6afdbbe92fb8203419ca8"
        )
    }

    /// The certificate digest and the pinned key digest must not be confused for each
    /// other; they describe different things and differ for the same certificate.
    func testCertificateDigestDiffersFromTheKeyFingerprint() throws {
        let der = try fixture()
        XCTAssertNotEqual(
            CertificateDetails.sha256(certificateDER: der),
            try SubjectPublicKeyFingerprint.sha256(certificateDER: der)
        )
    }

    func testCertificateValidityDatesAreReadFromSecurityAbsoluteTimes() throws {
        let dates = CertificateDetails.validityDates(certificateDER: try fixture())
        let formatter = ISO8601DateFormatter()

        XCTAssertEqual(dates.notBefore, formatter.date(from: "2026-08-01T18:40:12Z"))
        XCTAssertEqual(dates.notAfter, formatter.date(from: "2036-07-29T18:40:12Z"))
    }

    func testCertificateValidityDatesCanBeRecoveredFromStoredPEM() throws {
        let pem = CertificateDetails.pem(certificateDER: try fixture())
        let dates = CertificateDetails.validityDates(certificatePEM: pem)
        let formatter = ISO8601DateFormatter()

        XCTAssertEqual(dates.notBefore, formatter.date(from: "2026-08-01T18:40:12Z"))
        XCTAssertEqual(dates.notAfter, formatter.date(from: "2036-07-29T18:40:12Z"))
    }

    func testPEMIsWrappedAndDelimited() throws {
        let pem = CertificateDetails.pem(certificateDER: try fixture())
        let lines = pem.split(separator: "\n", omittingEmptySubsequences: false)
        XCTAssertEqual(lines.first, "-----BEGIN CERTIFICATE-----")
        XCTAssertEqual(lines.last, "-----END CERTIFICATE-----")
        for line in lines.dropFirst().dropLast() {
            XCTAssertLessThanOrEqual(line.count, 64, "body lines wrap at 64 per RFC 7468")
        }
        XCTAssertGreaterThan(lines.count, 3, "a real certificate spans several lines")
    }

    func testPEMBodyDecodesBackToTheOriginalCertificate() throws {
        let der = try fixture()
        let pem = CertificateDetails.pem(certificateDER: der)
        let body = pem
            .split(separator: "\n")
            .dropFirst()
            .dropLast()
            .joined()
        XCTAssertEqual(Data(base64Encoded: body), der)
    }

    // MARK: - Trust record

    private func makeStore() throws -> (TrustedIdentityStore, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MajorTomCertTests-\(UUID().uuidString)", isDirectory: true)
        let file = directory.appendingPathComponent("trusted-identities.json")
        return (try TrustedIdentityStore(fileURL: file), directory)
    }

    func testTrustRecordsAndReloadsCertificateDetails() async throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        let der = try fixture()
        let endpoint = CapsuleEndpoint(host: "example.com", port: 1_965)
        let expiry = Date(timeIntervalSince1970: 2_100_000_000)
        let presented = PresentedServerIdentity(
            endpoint: endpoint,
            publicKeySHA256: try SubjectPublicKeyFingerprint.sha256(certificateDER: der),
            certificateNotAfter: expiry,
            certificateDER: der
        )
        try await store.trust(presented, source: .user)

        let reopened = try TrustedIdentityStore(fileURL: directory.appendingPathComponent("trusted-identities.json"))
        let record = await reopened.identity(for: endpoint)
        XCTAssertEqual(record?.certificateSHA256, CertificateDetails.sha256(certificateDER: der))
        XCTAssertEqual(record?.certificatePEM, CertificateDetails.pem(certificateDER: der))
        let storedExpiry = try XCTUnwrap(record?.certificateNotAfter)
        XCTAssertEqual(
            storedExpiry.timeIntervalSince1970,
            expiry.timeIntervalSince1970,
            accuracy: 1
        )
    }

    /// A record written before these fields existed must still decode.
    func testRecordWithoutCertificateFieldsStillDecodes() throws {
        let json = Data("""
        [{
          "endpoint": { "host": "example.com", "port": 1965 },
          "publicKeySHA256": "\(String(repeating: "ab", count: 32))",
          "source": "user",
          "firstTrustedAt": "2026-01-01T00:00:00Z",
          "lastSeenAt": "2026-01-02T00:00:00Z",
          "timesSeen": 3
        }]
        """.utf8)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let records = try decoder.decode([TrustedServerIdentity].self, from: json)
        XCTAssertEqual(records.count, 1)
        XCTAssertNil(records.first?.certificatePEM)
        XCTAssertNil(records.first?.certificateSHA256)
        XCTAssertEqual(records.first?.timesSeen, 3)
    }

    /// Seeing the same key again without certificate bytes must not wipe what is stored.
    func testSightingWithoutCertificateBytesKeepsStoredDetails() async throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        let der = try fixture()
        let endpoint = CapsuleEndpoint(host: "example.com", port: 1_965)
        let key = try SubjectPublicKeyFingerprint.sha256(certificateDER: der)
        try await store.trust(
            PresentedServerIdentity(endpoint: endpoint, publicKeySHA256: key, certificateDER: der),
            source: .user
        )
        try await store.trust(
            PresentedServerIdentity(endpoint: endpoint, publicKeySHA256: key),
            source: .user
        )

        let record = await store.identity(for: endpoint)
        XCTAssertEqual(record?.certificateSHA256, CertificateDetails.sha256(certificateDER: der))
        XCTAssertEqual(record?.timesSeen, 2)
    }
}
