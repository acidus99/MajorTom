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
        let certificate = try DERElement.parse(in: certificateDER, at: 0)
        guard certificate.tag == 0x30 else { throw DERError.invalidCertificate }

        let certificateChildren = try certificate.children(in: certificateDER)
        guard let tbsCertificate = certificateChildren.first, tbsCertificate.tag == 0x30 else {
            throw DERError.invalidCertificate
        }

        let tbsChildren = try tbsCertificate.children(in: certificateDER)
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

public enum DERError: Error, Equatable, Sendable {
    case truncated
    case indefiniteLength
    case excessiveLength
    case invalidLength
    case invalidCertificate
}

private struct DERElement {
    let tag: UInt8
    let fullRange: Range<Data.Index>
    let contentRange: Range<Data.Index>

    static func parse(in data: Data, at offset: Data.Index) throws -> DERElement {
        guard data.indices.contains(offset), data.indices.contains(offset + 1) else {
            throw DERError.truncated
        }

        let tag = data[offset]
        let firstLengthByte = data[offset + 1]
        var contentStart = offset + 2
        let contentLength: Int

        if firstLengthByte & 0x80 == 0 {
            contentLength = Int(firstLengthByte)
        } else {
            let lengthByteCount = Int(firstLengthByte & 0x7F)
            guard lengthByteCount > 0 else { throw DERError.indefiniteLength }
            guard lengthByteCount <= MemoryLayout<Int>.size else { throw DERError.excessiveLength }
            guard contentStart + lengthByteCount <= data.endIndex else { throw DERError.truncated }

            var value = 0
            for byte in data[contentStart..<(contentStart + lengthByteCount)] {
                guard value <= (Int.max - Int(byte)) / 256 else { throw DERError.excessiveLength }
                value = value * 256 + Int(byte)
            }
            contentLength = value
            contentStart += lengthByteCount
        }

        guard contentLength >= 0, contentStart <= data.endIndex - contentLength else {
            throw DERError.invalidLength
        }
        let contentEnd = contentStart + contentLength
        return DERElement(
            tag: tag,
            fullRange: offset..<contentEnd,
            contentRange: contentStart..<contentEnd
        )
    }

    func children(in data: Data) throws -> [DERElement] {
        var result: [DERElement] = []
        var offset = contentRange.lowerBound
        while offset < contentRange.upperBound {
            let child = try DERElement.parse(in: data, at: offset)
            guard child.fullRange.upperBound <= contentRange.upperBound else {
                throw DERError.invalidLength
            }
            result.append(child)
            offset = child.fullRange.upperBound
        }
        guard offset == contentRange.upperBound else { throw DERError.invalidLength }
        return result
    }
}
