import Foundation
import XCTest
@testable import MajorTomCore

final class ServerTrustPolicyTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let endpoint = CapsuleEndpoint(host: "Example.COM")
    private let fingerprint = String(repeating: "a", count: 64)
    private let otherFingerprint = String(repeating: "b", count: 64)

    func testSeedMatchIsAcceptedSilently() {
        let presented = validIdentity(fingerprint: fingerprint)
        let seed = SeedServerIdentity(endpoint: endpoint, publicKeySHA256: fingerprint)

        XCTAssertEqual(
            ServerTrustPolicy().evaluate(presented: presented, locallyTrusted: nil, seeds: [seed], now: now),
            .allowSilently(source: .seed)
        )
    }

    func testUnknownIdentityRequiresFirstUseApproval() {
        let presented = validIdentity(fingerprint: fingerprint)
        XCTAssertEqual(
            ServerTrustPolicy().evaluate(presented: presented, locallyTrusted: nil, seeds: [], now: now),
            .requiresApproval(.firstUse(presented: presented))
        )
    }

    func testLocalFingerprintChangeRequiresApprovalEvenWhenNewKeyIsSeeded() {
        let presented = validIdentity(fingerprint: otherFingerprint)
        let previous = trustedIdentity(fingerprint: fingerprint)
        let newSeed = SeedServerIdentity(endpoint: endpoint, publicKeySHA256: otherFingerprint)

        XCTAssertEqual(
            ServerTrustPolicy().evaluate(presented: presented, locallyTrusted: previous, seeds: [newSeed], now: now),
            .requiresApproval(.changed(presented: presented, previouslyTrusted: previous))
        )
    }

    func testSeedMismatchRequiresApproval() {
        let presented = validIdentity(fingerprint: otherFingerprint)
        let seed = SeedServerIdentity(endpoint: endpoint, publicKeySHA256: fingerprint)

        XCTAssertEqual(
            ServerTrustPolicy().evaluate(presented: presented, locallyTrusted: nil, seeds: [seed], now: now),
            .requiresApproval(.seedMismatch(presented: presented, expectedFingerprints: [fingerprint]))
        )
    }

    func testMatchingKeyWithExpiredCertificateRequiresDateApproval() {
        let presented = PresentedServerIdentity(
            endpoint: endpoint,
            publicKeySHA256: fingerprint,
            certificateNotBefore: now.addingTimeInterval(-1_000),
            certificateNotAfter: now.addingTimeInterval(-1)
        )
        let previous = trustedIdentity(fingerprint: fingerprint)

        XCTAssertEqual(
            ServerTrustPolicy().evaluate(presented: presented, locallyTrusted: previous, seeds: [], now: now),
            .requiresApproval(.invalidCertificateDates(
                presented: presented,
                issue: .expired(expiredAt: now.addingTimeInterval(-1))
            ))
        )
    }

    func testCSVSeedParserAcceptsExistingFormat() {
        let csv = """
        host,port,public_key_sha256,last_seen_utc,times_seen,not_after_utc
        example.com,1965,\(fingerprint),2026-01-01T00:00:00Z,1,2030-01-01T00:00:00Z
        malformed.example,port,nope
        """
        XCTAssertEqual(SeedIdentityCSV.parse(csv), [
            SeedServerIdentity(endpoint: endpoint, publicKeySHA256: fingerprint)
        ])
    }

    func testTrustedIdentityStorePersistsAndRemovesRecords() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MajorTomTrustTests-\(UUID().uuidString)", isDirectory: true)
        let file = directory.appendingPathComponent("trusted-identities.json")
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = try TrustedIdentityStore(fileURL: file)
        let presented = validIdentity(fingerprint: fingerprint)
        try await store.trust(presented, source: .user, at: now)

        let reopened = try TrustedIdentityStore(fileURL: file)
        let persistedFingerprint = await reopened.identity(for: endpoint)?.publicKeySHA256
        XCTAssertEqual(persistedFingerprint, fingerprint)
        try await reopened.removeTrust(for: endpoint)
        let removedIdentity = await reopened.identity(for: endpoint)
        XCTAssertNil(removedIdentity)
    }

    func testSPKIFingerprintMatchesOpenSSL() throws {
        let certificateBase64 = """
        MIIDFTCCAf2gAwIBAgIURUz3VTTlE0H71h8YCaczUq7YfbwwDQYJKoZIhvcNAQELBQAwGjEYMBYGA1UEAwwPZml4dHVyZS5leGFtcGxlMB4XDTI2MDgwMTE4NDAxMloXDTM2MDcyOTE4NDAxMlowGjEYMBYGA1UEAwwPZml4dHVyZS5leGFtcGxlMIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAlp5UR+pMVreAVSq4tCFmbb5efx78DXHrmTwKuT1Cs2+J+8ZS3NNST0R1t7mRfc4oDH3xngETOaEUMHuwKVNB9A1LVbeM17BDiyaWReJC6DADGEhBREg0Uv2tcn1rG5eD/dY7I8x8WWLKg2Mg3nwThNN6SZNqCKr0BCjcyAE0ixBCtkQmA5bv0ecCAYHP4o7Z/0zHPwFL1XaTWdjkEiFBe2H5ePNj54GQgcpanfurwfCRUMgrHbGs0OX1bTvVwVDyuWscHaLdKm9s7NobdyelH1pLUyaXhvX2uYCyLKuNKPYnr91QMGY9iHo06ffnF2Kijxc+Kn65sM4mQvbrK6c/8wIDAQABo1MwUTAdBgNVHQ4EFgQU29M5ahjpHtnb9s2xPYU2IdPQCuswHwYDVR0jBBgwFoAU29M5ahjpHtnb9s2xPYU2IdPQCuswDwYDVR0TAQH/BAUwAwEB/zANBgkqhkiG9w0BAQsFAAOCAQEARpJOwlGKmmfqiXkWp6iAmb+GueFm93ZKP8fs9NAqCpIErTOtQHdvTB1h0OK6M5oQNQ3vXA4xdUjFFos2zOYDlYb6udS7efnDx5+aK+RaPcVQxAW9oxranHHMIYd0QewbUl7tJa/SZrYec8be3SD+SNS7Jza5ODndxENQoq+J5XBFyjD+Tf7I3Ic60u9xgmo+cytLjeL2xroTRmsu89kuLcO3ILDbEU7kgzBh9Scz2fde73NLK0JJ90gtBnHOgzrKX+LOnkZ94REcut9LvrhZt9c7HaZz8ofhoL0tZ0FjUs/uTPb46cwwa8QRc3QKrVmAyMl1Znxsn+DpWBCl6ED2VQ==
        """
        let certificate = try XCTUnwrap(Data(base64Encoded: certificateBase64))
        XCTAssertEqual(
            try SubjectPublicKeyFingerprint.sha256(certificateDER: certificate),
            "139e969c9c4dfb0d1281c745e7c6b0f7d95ebc5200223680b903e6261e8c39fe"
        )
    }

    private func validIdentity(fingerprint: String) -> PresentedServerIdentity {
        PresentedServerIdentity(
            endpoint: endpoint,
            publicKeySHA256: fingerprint,
            certificateNotBefore: now.addingTimeInterval(-1_000),
            certificateNotAfter: now.addingTimeInterval(1_000)
        )
    }

    private func trustedIdentity(fingerprint: String) -> TrustedServerIdentity {
        TrustedServerIdentity(
            endpoint: endpoint,
            publicKeySHA256: fingerprint,
            source: .user,
            firstTrustedAt: now.addingTimeInterval(-10_000),
            lastSeenAt: now.addingTimeInterval(-100)
        )
    }
}
