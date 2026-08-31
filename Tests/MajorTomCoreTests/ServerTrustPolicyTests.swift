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

    // MARK: - Certificate dates

    func testFirstUseWithExpiredCertificateRequiresDateApproval() {
        let expiry = now.addingTimeInterval(-1)
        let presented = PresentedServerIdentity(
            endpoint: endpoint,
            publicKeySHA256: fingerprint,
            certificateNotBefore: now.addingTimeInterval(-1_000),
            certificateNotAfter: expiry
        )

        // Trust on first use is granted automatically, so an unchecked date here meant a
        // capsule's very first certificate was pinned however stale it was.
        XCTAssertEqual(
            ServerTrustPolicy().evaluate(presented: presented, locallyTrusted: nil, seeds: [], now: now),
            .requiresApproval(.invalidCertificateDates(
                presented: presented,
                issue: .expired(expiredAt: expiry)
            ))
        )
    }

    func testFirstUseWithNotYetValidCertificateRequiresDateApproval() {
        let validFrom = now.addingTimeInterval(1_000)
        let presented = PresentedServerIdentity(
            endpoint: endpoint,
            publicKeySHA256: fingerprint,
            certificateNotBefore: validFrom,
            certificateNotAfter: now.addingTimeInterval(10_000)
        )

        XCTAssertEqual(
            ServerTrustPolicy().evaluate(presented: presented, locallyTrusted: nil, seeds: [], now: now),
            .requiresApproval(.invalidCertificateDates(
                presented: presented,
                issue: .notYetValid(validFrom: validFrom)
            ))
        )
    }

    func testFirstUseWithNoCertificateDatesStillRequiresFirstUseApproval() {
        // Dates are optional. Their absence must not be mistaken for an invalid range.
        let presented = PresentedServerIdentity(endpoint: endpoint, publicKeySHA256: fingerprint)

        XCTAssertEqual(
            ServerTrustPolicy().evaluate(presented: presented, locallyTrusted: nil, seeds: [], now: now),
            .requiresApproval(.firstUse(presented: presented))
        )
    }

    func testSeedMatchWithExpiredCertificateRequiresDateApproval() {
        let expiry = now.addingTimeInterval(-1)
        let presented = PresentedServerIdentity(
            endpoint: endpoint,
            publicKeySHA256: fingerprint,
            certificateNotBefore: now.addingTimeInterval(-1_000),
            certificateNotAfter: expiry
        )
        let seed = SeedServerIdentity(endpoint: endpoint, publicKeySHA256: fingerprint)

        XCTAssertEqual(
            ServerTrustPolicy().evaluate(presented: presented, locallyTrusted: nil, seeds: [seed], now: now),
            .requiresApproval(.invalidCertificateDates(
                presented: presented,
                issue: .expired(expiredAt: expiry)
            ))
        )
    }

    // MARK: - Precedence between a key mismatch and a date problem

    func testChangedKeyOutranksAnExpiredCertificate() {
        let presented = PresentedServerIdentity(
            endpoint: endpoint,
            publicKeySHA256: otherFingerprint,
            certificateNotBefore: now.addingTimeInterval(-1_000),
            certificateNotAfter: now.addingTimeInterval(-1)
        )
        let previous = trustedIdentity(fingerprint: fingerprint)

        // A substituted key is the interception signal. Describing it as merely out of
        // date would understate what the reader is being asked to decide.
        XCTAssertEqual(
            ServerTrustPolicy().evaluate(presented: presented, locallyTrusted: previous, seeds: [], now: now),
            .requiresApproval(.changed(presented: presented, previouslyTrusted: previous))
        )
    }

    func testSeedMismatchOutranksAnExpiredCertificate() {
        let presented = PresentedServerIdentity(
            endpoint: endpoint,
            publicKeySHA256: otherFingerprint,
            certificateNotBefore: now.addingTimeInterval(-1_000),
            certificateNotAfter: now.addingTimeInterval(-1)
        )
        let seed = SeedServerIdentity(endpoint: endpoint, publicKeySHA256: fingerprint)

        XCTAssertEqual(
            ServerTrustPolicy().evaluate(presented: presented, locallyTrusted: nil, seeds: [seed], now: now),
            .requiresApproval(.seedMismatch(presented: presented, expectedFingerprints: [fingerprint]))
        )
    }

    func testSeedsForOtherEndpointsAreIgnored() {
        let presented = validIdentity(fingerprint: fingerprint)
        let unrelated = SeedServerIdentity(
            endpoint: CapsuleEndpoint(host: "other.example"),
            publicKeySHA256: otherFingerprint
        )

        XCTAssertEqual(
            ServerTrustPolicy().evaluate(presented: presented, locallyTrusted: nil, seeds: [unrelated], now: now),
            .requiresApproval(.firstUse(presented: presented))
        )
    }

    func testLocalPinSupersedesSeedPolicyForTheSameKey() {
        // A seed for a different key must not turn an already-pinned, matching identity
        // into a mismatch warning.
        let presented = validIdentity(fingerprint: fingerprint)
        let previous = trustedIdentity(fingerprint: fingerprint)
        let staleSeed = SeedServerIdentity(endpoint: endpoint, publicKeySHA256: otherFingerprint)

        XCTAssertEqual(
            ServerTrustPolicy().evaluate(
                presented: presented,
                locallyTrusted: previous,
                seeds: [staleSeed],
                now: now
            ),
            .allowSilently(source: .user)
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

    func testCloudTrustCannotOverrideLocalSeedPolicy() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MajorTomTrustTests-\(UUID().uuidString)", isDirectory: true)
        let file = directory.appendingPathComponent("trusted-identities.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try TrustedIdentityStore(fileURL: file)
        try await store.trust(validIdentity(fingerprint: fingerprint), source: .seed, at: now)
        let cloud = SyncedServerTrustDecision(
            endpoint: endpoint,
            publicKeySHA256: otherFingerprint,
            firstTrustedAt: now,
            modifiedAt: now
        )

        try await store.applySyncedUserTrust([cloud])

        let identity = await store.identity(for: endpoint)
        XCTAssertEqual(identity?.publicKeySHA256, fingerprint)
        XCTAssertEqual(identity?.source, .seed)
    }

    func testUnambiguousCloudTrustIsAppliedWithoutCertificateObservations() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MajorTomTrustTests-\(UUID().uuidString)", isDirectory: true)
        let file = directory.appendingPathComponent("trusted-identities.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try TrustedIdentityStore(fileURL: file)
        let cloud = SyncedServerTrustDecision(
            endpoint: endpoint,
            publicKeySHA256: fingerprint,
            firstTrustedAt: now,
            modifiedAt: now
        )

        try await store.applySyncedUserTrust([cloud])

        let identity = await store.identity(for: endpoint)
        XCTAssertEqual(identity?.publicKeySHA256, fingerprint)
        XCTAssertEqual(identity?.source, .user)
        XCTAssertEqual(identity?.timesSeen, 0)
        XCTAssertNil(identity?.certificatePEM)
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
