import Foundation

/// The names a certificate claims, and whether a host is among them.
///
/// Gemini certificates are usually self-signed, so no authority vouches for the binding
/// between a name and a key. That makes the question "does this certificate even claim to
/// be the host I asked for?" worth answering on its own: a certificate for a different
/// name is a signal regardless of who signed it.
public enum CertificateSubject {
    /// OID 2.5.29.17, subjectAltName, content bytes only.
    private static let subjectAltNameOID: [UInt8] = [0x55, 0x1D, 0x11]
    /// OID 2.5.4.3, commonName, content bytes only.
    private static let commonNameOID: [UInt8] = [0x55, 0x04, 0x03]

    /// The dNSName entries of the Subject Alternative Name extension.
    public static func dnsNames(certificateDER: Data) -> [String] {
        guard let tbsChildren = try? DERElement.tbsChildren(ofCertificate: certificateDER),
              // extensions is [3] EXPLICIT, which wraps the SEQUENCE OF Extension.
              let extensionsWrapper = tbsChildren.first(where: { $0.tag == 0xA3 }),
              let sequence = try? extensionsWrapper.children(in: certificateDER).first,
              let entries = try? sequence.children(in: certificateDER) else { return [] }

        for entry in entries {
            guard let fields = try? entry.children(in: certificateDER),
                  let oid = fields.first,
                  oid.tag == 0x06,
                  certificateDER[oid.contentRange].elementsEqual(subjectAltNameOID),
                  // extnValue is an OCTET STRING wrapping the real value; `critical` may
                  // sit between the OID and it, so take the last field rather than [1].
                  let extensionValue = fields.last,
                  extensionValue.tag == 0x04,
                  let generalNames = try? DERElement.parse(
                      in: certificateDER,
                      at: extensionValue.contentRange.lowerBound
                  ),
                  let names = try? generalNames.children(in: certificateDER) else { continue }

            // dNSName is [2] IA5String within GeneralName.
            return names
                .filter { $0.tag == 0x82 }
                .compactMap { String(data: Data(certificateDER[$0.contentRange]), encoding: .utf8) }
        }
        return []
    }

    /// The subject's common name, used only when a certificate carries no SAN at all.
    public static func commonName(certificateDER: Data) -> String? {
        guard let tbsChildren = try? DERElement.tbsChildren(ofCertificate: certificateDER) else {
            return nil
        }
        let hasExplicitVersion = tbsChildren.first?.tag == 0xA0
        let subjectIndex = hasExplicitVersion ? 5 : 4
        guard tbsChildren.indices.contains(subjectIndex),
              let relativeNames = try? tbsChildren[subjectIndex].children(in: certificateDER) else {
            return nil
        }

        // Name is a sequence of SETs, each holding attribute type/value pairs.
        for relativeName in relativeNames {
            guard let attributes = try? relativeName.children(in: certificateDER) else { continue }
            for attribute in attributes {
                guard let pair = try? attribute.children(in: certificateDER),
                      pair.count == 2,
                      pair[0].tag == 0x06,
                      certificateDER[pair[0].contentRange].elementsEqual(commonNameOID) else { continue }
                return String(data: Data(certificateDER[pair[1].contentRange]), encoding: .utf8)
            }
        }
        return nil
    }

    /// Whether `host` is one of the names the certificate claims.
    ///
    /// SAN entries win outright when present; the common name is consulted only for a
    /// certificate that has no SAN, which web clients stopped honouring years ago but
    /// which is still common in Geminispace.
    public static func matches(host: String, certificateDER: Data) -> Bool {
        let sanNames = dnsNames(certificateDER: certificateDER)
        let names = sanNames.isEmpty
            ? [commonName(certificateDER: certificateDER)].compactMap { $0 }
            : sanNames
        let target = host.lowercased()
        return names.contains { matches(host: target, name: $0.lowercased()) }
    }

    private static func matches(host: String, name: String) -> Bool {
        guard name.hasPrefix("*.") else { return host == name }
        // A wildcard stands for exactly one label: *.wild.example covers a.wild.example
        // but neither wild.example itself nor a.b.wild.example.
        guard !host.hasPrefix("."), let firstDot = host.firstIndex(of: ".") else { return false }
        return host[host.index(after: firstDot)...] == name.dropFirst(2)
    }
}
