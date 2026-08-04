import CryptoKit
import Foundation

public enum SubjectPublicKeyFingerprint {
    public static func sha256(certificateDER: Data) throws -> String {
        let subjectPublicKeyInfo = try extractSubjectPublicKeyInfo(from: certificateDER)
        return SHA256.hash(data: subjectPublicKeyInfo)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    public static func extractSubjectPublicKeyInfo(from certificateDER: Data) throws -> Data {
        let tbsChildren = try DERElement.tbsChildren(ofCertificate: certificateDER)
        let hasExplicitVersion = tbsChildren.first?.tag == 0xA0
        let subjectPublicKeyInfoIndex = hasExplicitVersion ? 6 : 5
        guard tbsChildren.indices.contains(subjectPublicKeyInfoIndex) else {
            throw DERError.invalidCertificate
        }

        let subjectPublicKeyInfo = tbsChildren[subjectPublicKeyInfoIndex]
        guard subjectPublicKeyInfo.tag == 0x30 else { throw DERError.invalidCertificate }
        return Data(certificateDER[subjectPublicKeyInfo.fullRange])
    }
}
