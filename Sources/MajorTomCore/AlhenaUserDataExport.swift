import Foundation

/// The portable subset of an Alhena User Data export. Alhena exports its H2
/// database as SQL; this parser reads only the known data rows and never executes
/// statements from the archive.
public struct AlhenaUserDataExport: Sendable {
    public struct Bookmark: Sendable, Equatable {
        public let title: String
        public let url: URL
        public let folder: String
    }

    public struct Identity: Sendable, Equatable {
        public let identifier: String
        public let certificatePEM: String
        public let privateKeyPEM: String
        public let url: URL?
        public let isActive: Bool
    }

    public enum Error: LocalizedError, Equatable {
        case missingVersion
        case unsupportedVersion(String)
        case missingDatabase
        case invalidDatabase

        public var errorDescription: String? {
            switch self {
            case .missingVersion: "This is not an Alhena User Data export."
            case .unsupportedVersion(let version): "Alhena export version \(version) is not supported."
            case .missingDatabase: "The Alhena export does not contain script.sql."
            case .invalidDatabase: "The Alhena database export is not valid."
            }
        }
    }

    public let version: String
    public let bookmarks: [Bookmark]
    public let identities: [Identity]
    public let preferences: [String: String]

    public init(files: [String: Data]) throws {
        guard let versionData = files["version.txt"],
              let version = String(data: versionData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !version.isEmpty else {
            throw Error.missingVersion
        }
        guard version.split(separator: ".").first == "2" else {
            throw Error.unsupportedVersion(version)
        }
        guard let scriptData = files["script.sql"],
              let script = String(data: scriptData, encoding: .utf8) else {
            throw Error.missingDatabase
        }
        // These tables distinguish an Alhena database script from an arbitrary H2
        // export with a coincidental version.txt file.
        guard script.contains("CREATE CACHED TABLE \"PUBLIC\".\"BOOKMARKS\""),
              script.contains("CREATE CACHED TABLE \"PUBLIC\".\"CLIENTCERTS\""),
              script.contains("CREATE CACHED TABLE \"PUBLIC\".\"PREFS\"") else {
            throw Error.invalidDatabase
        }

        self.version = version
        bookmarks = SQLRows.rows(in: script, table: "BOOKMARKS").compactMap { row in
            guard row.count >= 4, let title = row[1], let rawURL = row[2],
                  let url = URL(string: rawURL) else { return nil }
            return Bookmark(title: title, url: url, folder: row[3] ?? "ROOT")
        }
        identities = SQLRows.rows(in: script, table: "CLIENTCERTS").compactMap { row in
            guard row.count >= 5, let identifier = row[0], let domain = row[1],
                  let certificate = row[2], let privateKey = row[3] else { return nil }
            return Identity(
                identifier: identifier,
                certificatePEM: certificate,
                privateKeyPEM: privateKey,
                url: Self.identityURL(from: domain),
                isActive: row[4]?.uppercased() == "TRUE"
            )
        }
        preferences = Dictionary(
            SQLRows.rows(in: script, table: "PREFS").compactMap { row in
                guard row.count >= 3, let key = row[1], let value = row[2] else { return nil }
                return (key.lowercased(), value)
            },
            uniquingKeysWith: { _, newest in newest }
        )
    }

    private static func identityURL(from domain: String) -> URL? {
        let value = domain.hasPrefix("gemini://") ? domain : "gemini://" + domain
        return URL(string: value)
    }
}

private enum SQLRows {
    static func rows(in script: String, table: String) -> [[String?]] {
        let marker = "INSERT INTO \"PUBLIC\".\"\(table)\" VALUES"
        guard let markerRange = script.range(of: marker) else { return [] }
        var scanner = Scanner(String(script[markerRange.upperBound...]))
        return scanner.parseRows()
    }

    private struct Scanner {
        let characters: [Character]
        var index = 0

        init(_ text: String) { characters = Array(text) }

        mutating func parseRows() -> [[String?]] {
            var result: [[String?]] = []
            while index < characters.count {
                skipWhitespaceAndCommas()
                if current == ";" { break }
                guard consume("(") else { break }
                var row: [String?] = []
                while index < characters.count {
                    skipWhitespace()
                    row.append(parseValue())
                    skipWhitespace()
                    if consume(")") { break }
                    guard consume(",") else { return result }
                }
                result.append(row)
            }
            return result
        }

        private var current: Character? {
            index < characters.count ? characters[index] : nil
        }

        private mutating func parseValue() -> String? {
            skipWhitespace()
            if current == "'" { return parseQuoted(unicodeEscapes: false) }
            if current == "U", peek(1) == "&", peek(2) == "'" {
                index += 2
                return parseQuoted(unicodeEscapes: true)
            }

            // H2 prefixes date/time literals with a type name. The value itself is
            // irrelevant to imports, but consuming its quoted part keeps row parsing
            // aligned.
            let start = index
            while let character = current, character != ",", character != ")", character != "'" {
                index += 1
            }
            if current == "'" {
                _ = parseQuoted(unicodeEscapes: false)
                return String(characters[start..<index]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            let token = String(characters[start..<index]).trimmingCharacters(in: .whitespacesAndNewlines)
            return token.uppercased() == "NULL" ? nil : token
        }

        private mutating func parseQuoted(unicodeEscapes: Bool) -> String {
            guard consume("'") else { return "" }
            var result = ""
            while let character = current {
                index += 1
                if character == "'" {
                    if current == "'" {
                        result.append("'")
                        index += 1
                        continue
                    }
                    break
                }
                if unicodeEscapes, character == "\\" {
                    if current == "\\" {
                        result.append("\\")
                        index += 1
                    } else if current == "+" {
                        index += 1
                        appendUnicodeEscape(length: 6, to: &result)
                    } else {
                        appendUnicodeEscape(length: 4, to: &result)
                    }
                } else {
                    result.append(character)
                }
            }
            return result
        }

        private mutating func appendUnicodeEscape(length: Int, to result: inout String) {
            guard index + length <= characters.count else { return }
            let digits = String(characters[index..<(index + length)])
            guard let scalarValue = UInt32(digits, radix: 16),
                  let scalar = UnicodeScalar(scalarValue) else { return }
            result.unicodeScalars.append(scalar)
            index += length
        }

        private func peek(_ offset: Int) -> Character? {
            let position = index + offset
            return position < characters.count ? characters[position] : nil
        }

        private mutating func consume(_ character: Character) -> Bool {
            guard current == character else { return false }
            index += 1
            return true
        }

        private mutating func skipWhitespace() {
            while current?.isWhitespace == true { index += 1 }
        }

        private mutating func skipWhitespaceAndCommas() {
            while current?.isWhitespace == true || current == "," { index += 1 }
        }
    }
}
