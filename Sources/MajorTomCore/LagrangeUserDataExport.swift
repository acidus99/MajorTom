import Foundation

/// The portable subset of a Lagrange User Data export. Archive access deliberately
/// lives in the app target; this type only interprets the exported bytes so it is easy
/// to validate and test without extracting untrusted archives to disk.
public struct LagrangeUserDataExport: Sendable {
    public struct Bookmark: Sendable, Equatable {
        public let title: String
        public let url: URL
        public let isHomepage: Bool
    }

    public struct Identity: Sendable {
        /// Lagrange names exported certificate/key pairs with this certificate digest.
        public let digest: String
        public let certificatePEM: String
        public let privateKeyPEM: String
    }

    public struct IdentityAssignment: Sendable, Equatable {
        public let url: URL
        public let identityDigest: String
    }

    public struct TrustedIdentity: Sendable, Equatable {
        public let endpoint: CapsuleEndpoint
        public let publicKeySHA256: String
    }

    public enum Error: LocalizedError, Equatable {
        case missingManifest
        case unsupportedVersion(String)
        case missingBookmarks

        public var errorDescription: String? {
            switch self {
            case .missingManifest: "This is not a Lagrange User Data export."
            case .unsupportedVersion(let version): "Lagrange export version \(version) is not supported."
            case .missingBookmarks: "The Lagrange export does not contain bookmarks.ini."
            }
        }
    }

    public let version: String
    public let bookmarks: [Bookmark]
    public let identities: [Identity]
    public let identityAssignments: [IdentityAssignment]
    public let trustedIdentities: [TrustedIdentity]

    public init(files: [String: Data]) throws {
        guard let manifest = files["lagrange-export.ini"].flatMap(Self.text),
              let version = Self.value(named: "version", in: manifest) else {
            throw Error.missingManifest
        }
        // The manifest is the compatibility contract. Version 1 is Lagrange's stable
        // User Data archive format; a new major format must be consciously supported.
        guard version.split(separator: ".").first == "1" else {
            throw Error.unsupportedVersion(version)
        }
        guard let bookmarkText = files["bookmarks.ini"].flatMap(Self.text) else {
            throw Error.missingBookmarks
        }

        self.version = version
        bookmarks = Self.bookmarks(from: bookmarkText)
        identityAssignments = Self.assignments(from: files["sitespec.ini"].flatMap(Self.text) ?? "")
        trustedIdentities = Self.trustedIdentities(from: files["trusted.txt"].flatMap(Self.text) ?? "")
        identities = files.compactMap { name, data in
            guard name.hasPrefix("idents/"), name.hasSuffix(".crt"),
                  let certificate = Self.text(data) else { return nil }
            let digest = String(name.dropFirst("idents/".count).dropLast(".crt".count)).lowercased()
            guard digest.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil,
                  let key = files["idents/\(digest).key"].flatMap(Self.text) else { return nil }
            return Identity(digest: digest, certificatePEM: certificate, privateKeyPEM: key)
        }.sorted { $0.digest < $1.digest }
    }

    private static func text(_ data: Data) -> String? { String(data: data, encoding: .utf8) }

    private static func value(named name: String, in text: String) -> String? {
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix(name), let equals = line.firstIndex(of: "=") else { continue }
            let key = line[..<equals].trimmingCharacters(in: .whitespaces)
            guard key == name else { continue }
            return line[line.index(after: equals)...]
                .trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        }
        return nil
    }

    private static func sections(in text: String) -> [(name: String, values: [String: String])] {
        var results: [(String, [String: String])] = []
        var name: String?
        var values: [String: String] = [:]
        func finish() {
            if let name { results.append((name, values)) }
        }
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("["), line.hasSuffix("]") {
                finish(); name = String(line.dropFirst().dropLast()); values = [:]
            } else if let equals = line.firstIndex(of: "="), name != nil {
                let key = line[..<equals].trimmingCharacters(in: .whitespaces)
                var value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
                if let comment = value.range(of: "  #") { value = String(value[..<comment.lowerBound]) }
                values[key] = value.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            }
        }
        finish()
        return results
    }

    private static func bookmarks(from text: String) -> [Bookmark] {
        sections(in: text).compactMap { _, values in
            guard let urlText = values["url"], let url = URL(string: urlText) else { return nil }
            return Bookmark(title: values["title"] ?? url.absoluteString, url: url,
                            isHomepage: values["tags", default: ""].split(separator: " ").contains(".homepage"))
        }
    }

    private static func assignments(from text: String) -> [IdentityAssignment] {
        sections(in: text).compactMap { name, values in
            guard let url = URL(string: name), let digest = values["usedIdentities"]?.lowercased(),
                  digest.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil else { return nil }
            return IdentityAssignment(url: url, identityDigest: digest)
        }
    }

    private static func trustedIdentities(from text: String) -> [TrustedIdentity] {
        text.split(whereSeparator: \.isNewline).compactMap { line in
            let parts = line.split(separator: " ")
            guard parts.count == 3, let separator = parts[0].lastIndex(of: ";"),
                  let port = UInt16(parts[0][parts[0].index(after: separator)...]),
                  parts[2].range(of: "^[0-9a-fA-F]{64}$", options: .regularExpression) != nil else { return nil }
            return TrustedIdentity(endpoint: CapsuleEndpoint(host: String(parts[0][..<separator]), port: port),
                                   publicKeySHA256: String(parts[2]).lowercased())
        }
    }
}
