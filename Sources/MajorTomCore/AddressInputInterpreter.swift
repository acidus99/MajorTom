import Foundation

public enum AddressInputResult: Equatable, Sendable {
    case gemini(GeminiRequestTarget)
    case external(URL)
}

public enum AddressInputError: Error, Equatable, Sendable {
    case empty
    case invalidGeminiURL
    case invalidExternalURL
}

public struct AddressInputInterpreter: Sendable {
    public let searchEndpoint: URL

    public init(searchEndpoint: URL = URL(string: "gemini://kennedy.gemi.dev/search")!) {
        self.searchEndpoint = searchEndpoint
    }

    public func interpret(_ input: String) throws -> AddressInputResult {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { throw AddressInputError.empty }

        if value.lowercased().hasPrefix("gemini:") {
            guard let target = try? GeminiRequestTarget(value) else {
                throw AddressInputError.invalidGeminiURL
            }
            return .gemini(target)
        }

        if value.contains("://") {
            guard let url = URL(string: value), url.scheme != nil else {
                throw AddressInputError.invalidExternalURL
            }
            return .external(url)
        }

        if isProbableCapsuleLocation(value),
           let target = try? GeminiRequestTarget("gemini://" + value) {
            return .gemini(target)
        }

        var components = URLComponents(url: searchEndpoint, resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: value, value: nil)]
        guard let searchURL = components?.url,
              let target = try? GeminiRequestTarget(searchURL.absoluteString) else {
            throw AddressInputError.invalidGeminiURL
        }
        return .gemini(target)
    }

    private func isProbableCapsuleLocation(_ value: String) -> Bool {
        guard !value.contains(where: \Character.isWhitespace) else { return false }
        let authority = value.split(separator: "/", maxSplits: 1).first.map(String.init) ?? value
        if authority.lowercased() == "localhost" || authority.lowercased().hasPrefix("localhost:") {
            return true
        }
        if authority.hasPrefix("[") && authority.contains("]") { return true }
        if authority.contains(".") { return true }

        let hostAndPort = authority.split(separator: ":", maxSplits: 1)
        return hostAndPort.count == 2 && UInt16(hostAndPort[1]) != nil
    }
}
