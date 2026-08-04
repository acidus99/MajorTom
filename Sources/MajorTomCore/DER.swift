import Foundation

public enum DERError: Error, Equatable, Sendable {
    case truncated
    case indefiniteLength
    case excessiveLength
    case invalidLength
    case invalidCertificate
}

/// One tag-length-value element inside a DER document, described as ranges into the
/// original bytes rather than as copies.
///
/// Shared by the readers that pull individual facts out of a certificate — the public key
/// for fingerprinting, the subject names for host matching — so there is one length-and-
/// bounds implementation to trust rather than one per caller.
struct DERElement {
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

    /// The fields of a certificate's TBSCertificate, which is where nearly everything
    /// worth reading lives.
    static func tbsChildren(ofCertificate certificateDER: Data) throws -> [DERElement] {
        let certificate = try DERElement.parse(in: certificateDER, at: certificateDER.startIndex)
        guard certificate.tag == 0x30 else { throw DERError.invalidCertificate }
        let children = try certificate.children(in: certificateDER)
        guard let tbsCertificate = children.first, tbsCertificate.tag == 0x30 else {
            throw DERError.invalidCertificate
        }
        return try tbsCertificate.children(in: certificateDER)
    }
}
