import CryptoKit
import Foundation

/// Facts derived from a server certificate for display and for the trust record.
///
/// Kept separate from ``SubjectPublicKeyFingerprint``, which extracts the one value TOFU
/// pins. These are the values a person compares against other tooling.
public enum CertificateDetails {
    /// SHA-256 of the entire certificate, lowercase hex.
    ///
    /// Deliberately *not* what trust is pinned to: a capsule that renews its certificate
    /// while keeping its key gets a new certificate digest but the same Subject Public
    /// Key Info fingerprint, and treating that as an identity change would cry wolf on
    /// every routine renewal. It is still worth showing, because it is what
    /// `openssl x509 -fingerprint -sha256` prints and therefore what someone verifying a
    /// capsule out of band will have in hand.
    public static func sha256(certificateDER: Data) -> String {
        SHA256.hash(data: certificateDER)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    /// The certificate as PEM, so it can be pasted into `openssl` or a keychain.
    public static func pem(certificateDER: Data) -> String {
        let base64 = certificateDER.base64EncodedString()
        // PEM wraps at 64 characters per RFC 7468.
        var lines: [String] = ["-----BEGIN CERTIFICATE-----"]
        var index = base64.startIndex
        while index < base64.endIndex {
            let end = base64.index(index, offsetBy: 64, limitedBy: base64.endIndex) ?? base64.endIndex
            lines.append(String(base64[index..<end]))
            index = end
        }
        lines.append("-----END CERTIFICATE-----")
        return lines.joined(separator: "\n")
    }
}
