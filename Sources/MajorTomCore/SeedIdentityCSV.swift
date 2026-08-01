import Foundation

public enum SeedIdentityCSV {
    public static func parse(_ text: String) -> Set<SeedServerIdentity> {
        var result = Set<SeedServerIdentity>()

        for (index, rawLine) in text.split(whereSeparator: \.isNewline).enumerated() {
            if index == 0, rawLine.lowercased().hasPrefix("host,") { continue }
            let fields = rawLine.split(separator: ",", omittingEmptySubsequences: false)
            guard fields.count >= 3,
                  let port = UInt16(fields[1].trimmingCharacters(in: .whitespaces)),
                  isSHA256Hex(String(fields[2])) else {
                continue
            }

            let host = fields[0].trimmingCharacters(in: .whitespaces)
            guard !host.isEmpty else { continue }
            result.insert(SeedServerIdentity(
                endpoint: CapsuleEndpoint(host: host, port: port),
                publicKeySHA256: String(fields[2])
            ))
        }
        return result
    }

    private static func isSHA256Hex(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy(\.isHexDigit)
    }
}
