import Foundation
import XCTest
@testable import MajorTomCore

final class CertificateSubjectTests: XCTestCase {
    /// Self-signed, CN=primary.example, with
    /// subjectAltName = DNS:primary.example, DNS:*.wild.example, DNS:second.example
    /// as reported by `openssl x509 -ext subjectAltName`.
    private static let sanCertificateBase64 = """
    MIIDUzCCAjugAwIBAgIUS7XSJ8IO2JZWOkpH5paViwivFk8wDQYJKoZIhvcNAQELBQAwGjEYMBYGA1UEAwwPcHJpbWFyeS5leGFtcGxlMB4XDTI2MDgwNDA1MTEwMloXDTM2MDgwMTA1MTEwMlowGjEYMBYGA1UEAwwPcHJpbWFyeS5leGFtcGxlMIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAmpN5V3cJdnrRd3z/np7wIN+wRAX//jP3kQJTJv8XawfuTPuyomzsOTdm1zKzBLSgJEoTgDuEUDpMb4UfgemiFY4r0X7Bij7TXXiw/Oa/9Zqs0ymDnmCW8wp2UV4lpYaTPw4bn2DRPH4Q+qNPVhWADEYeiex95g/DPhWveMkygxSOkTU7vQe8KMtcw2Cauekstk+U1sh8tRwCghHVa+1+h7kDLmeCycHk86S5GZ7CK139eApo6l5PKanZ1WnoY5YYC7LYJfqb/GA2ciG7nXTdFjugdD3kAVI8LikOpMxttS5L4w+ssBY108pid55Cgu5WmHkRo07nbBKSjIoWEjrxbwIDAQABo4GQMIGNMB0GA1UdDgQWBBRY9reLlUmcWXlsEK3W3EpdKXKxUTAfBgNVHSMEGDAWgBRY9reLlUmcWXlsEK3W3EpdKXKxUTAPBgNVHRMBAf8EBTADAQH/MDoGA1UdEQQzMDGCD3ByaW1hcnkuZXhhbXBsZYIOKi53aWxkLmV4YW1wbGWCDnNlY29uZC5leGFtcGxlMA0GCSqGSIb3DQEBCwUAA4IBAQBY9gzVwrnwHUxlE1YWIcv12kR13OZrFCM6jjKKzhBnE/jNrCeeDZuKgNi33FvY8lT0XJ4hkmxtZP9revHlUuWp5mp4rtcN55Wz4srl2+KdbYgSP2IqYebB/oGtOx/gc6f1g9lt2oC4O7xk+yHaAZlUpz/oaK6fIcviSnV2oORItt3qPVzEkopQMBITzV2/qyZcvsbO+txHcWkPWgvXQZofog2oBvNBkN9mIk0YtHaK8csJGI8CUjkj3597F9aMyAb3ssdts1Jm3hRPgnoTNsLc5gQGmv+AQ6ccbOnI/5x6eegqPzVIUVLpnYAn1sOSzzfwlYXtJ7MgHeB8iS5cEy5q
    """

    /// The older fixture: CN=fixture.example and no SAN extension at all.
    private static let commonNameOnlyBase64 = """
    MIIDFTCCAf2gAwIBAgIURUz3VTTlE0H71h8YCaczUq7YfbwwDQYJKoZIhvcNAQELBQAwGjEYMBYGA1UEAwwPZml4dHVyZS5leGFtcGxlMB4XDTI2MDgwMTE4NDAxMloXDTM2MDcyOTE4NDAxMlowGjEYMBYGA1UEAwwPZml4dHVyZS5leGFtcGxlMIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAlp5UR+pMVreAVSq4tCFmbb5efx78DXHrmTwKuT1Cs2+J+8ZS3NNST0R1t7mRfc4oDH3xngETOaEUMHuwKVNB9A1LVbeM17BDiyaWReJC6DADGEhBREg0Uv2tcn1rG5eD/dY7I8x8WWLKg2Mg3nwThNN6SZNqCKr0BCjcyAE0ixBCtkQmA5bv0ecCAYHP4o7Z/0zHPwFL1XaTWdjkEiFBe2H5ePNj54GQgcpanfurwfCRUMgrHbGs0OX1bTvVwVDyuWscHaLdKm9s7NobdyelH1pLUyaXhvX2uYCyLKuNKPYnr91QMGY9iHo06ffnF2Kijxc+Kn65sM4mQvbrK6c/8wIDAQABo1MwUTAdBgNVHQ4EFgQU29M5ahjpHtnb9s2xPYU2IdPQCuswHwYDVR0jBBgwFoAU29M5ahjpHtnb9s2xPYU2IdPQCuswDwYDVR0TAQH/BAUwAwEB/zANBgkqhkiG9w0BAQsFAAOCAQEARpJOwlGKmmfqiXkWp6iAmb+GueFm93ZKP8fs9NAqCpIErTOtQHdvTB1h0OK6M5oQNQ3vXA4xdUjFFos2zOYDlYb6udS7efnDx5+aK+RaPcVQxAW9oxranHHMIYd0QewbUl7tJa/SZrYec8be3SD+SNS7Jza5ODndxENQoq+J5XBFyjD+Tf7I3Ic60u9xgmo+cytLjeL2xroTRmsu89kuLcO3ILDbEU7kgzBh9Scz2fde73NLK0JJ90gtBnHOgzrKX+LOnkZ94REcut9LvrhZt9c7HaZz8ofhoL0tZ0FjUs/uTPb46cwwa8QRc3QKrVmAyMl1Znxsn+DpWBCl6ED2VQ==
    """

    private func sanCertificate() throws -> Data {
        try XCTUnwrap(Data(base64Encoded: Self.sanCertificateBase64))
    }

    private func commonNameOnlyCertificate() throws -> Data {
        try XCTUnwrap(Data(base64Encoded: Self.commonNameOnlyBase64))
    }

    // MARK: - Reading names

    func testSubjectAltNamesAreReadInOrder() throws {
        XCTAssertEqual(
            CertificateSubject.dnsNames(certificateDER: try sanCertificate()),
            ["primary.example", "*.wild.example", "second.example"]
        )
    }

    func testCommonNameIsRead() throws {
        XCTAssertEqual(
            CertificateSubject.commonName(certificateDER: try sanCertificate()),
            "primary.example"
        )
        XCTAssertEqual(
            CertificateSubject.commonName(certificateDER: try commonNameOnlyCertificate()),
            "fixture.example"
        )
    }

    func testCertificateWithoutSANReportsNoDNSNames() throws {
        XCTAssertTrue(CertificateSubject.dnsNames(certificateDER: try commonNameOnlyCertificate()).isEmpty)
    }

    func testGarbageIsNotACertificate() {
        let garbage = Data([0x01, 0x02, 0x03, 0x04])
        XCTAssertTrue(CertificateSubject.dnsNames(certificateDER: garbage).isEmpty)
        XCTAssertNil(CertificateSubject.commonName(certificateDER: garbage))
        XCTAssertFalse(CertificateSubject.matches(host: "example.com", certificateDER: garbage))
    }

    // MARK: - Matching

    func testExactSANMatch() throws {
        let der = try sanCertificate()
        XCTAssertTrue(CertificateSubject.matches(host: "primary.example", certificateDER: der))
        XCTAssertTrue(CertificateSubject.matches(host: "second.example", certificateDER: der))
    }

    func testMatchingIgnoresCase() throws {
        XCTAssertTrue(CertificateSubject.matches(
            host: "PRIMARY.example",
            certificateDER: try sanCertificate()
        ))
    }

    func testUnlistedHostDoesNotMatch() throws {
        XCTAssertFalse(CertificateSubject.matches(
            host: "attacker.example",
            certificateDER: try sanCertificate()
        ))
    }

    func testWildcardCoversOneLabel() throws {
        let der = try sanCertificate()
        XCTAssertTrue(CertificateSubject.matches(host: "anything.wild.example", certificateDER: der))
    }

    /// A wildcard must not cover the bare domain, nor more than one label.
    func testWildcardDoesNotCoverBareDomainOrDeeperLabels() throws {
        let der = try sanCertificate()
        XCTAssertFalse(CertificateSubject.matches(host: "wild.example", certificateDER: der))
        XCTAssertFalse(CertificateSubject.matches(host: "a.b.wild.example", certificateDER: der))
    }

    /// A certificate with no SAN falls back to its common name, which is still the norm
    /// in Geminispace.
    func testCommonNameIsUsedOnlyWhenThereIsNoSAN() throws {
        XCTAssertTrue(CertificateSubject.matches(
            host: "fixture.example",
            certificateDER: try commonNameOnlyCertificate()
        ))
        XCTAssertFalse(CertificateSubject.matches(
            host: "other.example",
            certificateDER: try commonNameOnlyCertificate()
        ))
    }

    /// When SANs exist they are authoritative; the common name is not also consulted.
    /// Here the CN happens to be listed in the SAN too, so a name that is *only* a CN
    /// elsewhere is covered by the fallback test above.
    func testSANPresenceMakesItAuthoritative() throws {
        let der = try sanCertificate()
        XCTAssertEqual(CertificateSubject.commonName(certificateDER: der), "primary.example")
        XCTAssertFalse(CertificateSubject.dnsNames(certificateDER: der).isEmpty)
    }

    /// The refactor that moved DER parsing into a shared reader must not have changed the
    /// fingerprint it produces.
    func testFingerprintStillMatchesOpenSSLAfterTheRefactor() throws {
        XCTAssertEqual(
            try SubjectPublicKeyFingerprint.sha256(certificateDER: try commonNameOnlyCertificate()),
            "139e969c9c4dfb0d1281c745e7c6b0f7d95ebc5200223680b903e6261e8c39fe"
        )
    }
}
