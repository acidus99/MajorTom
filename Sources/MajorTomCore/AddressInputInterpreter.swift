import Foundation

public enum AddressInputResult: Equatable, Sendable {
    case gemini(GeminiRequestTarget)
    /// Fetch this resource but present its bytes as source rather than rendering them.
    case viewSource(GeminiRequestTarget)
    /// A page Major Tom serves itself, such as `about:bookmarks`.
    case internalPage(InternalPage)
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

        // Checked before the "://" test below, which would otherwise classify
        // view-source:gemini://… as an external URL and hand it to the system opener.
        // Only gemini resources can be viewed as source; a web page would have to be
        // fetched through the proxy, and its source would be the proxy's Gemtext rather
        // than the page's own markup, which is not what the address asks for.
        if let inner = ViewSourceURL.unwrap(text: value) {
            guard let target = try? GeminiRequestTarget(inner) else {
                throw AddressInputError.invalidGeminiURL
            }
            return .viewSource(target)
        }

        // Checked before the search fallback, which would otherwise send "about:bookmarks"
        // off to a search engine.
        if let url = URL(string: value), let page = InternalPage.page(for: url) {
            return .internalPage(page)
        }

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

        guard let searchURL = GeminiQueryEncoding.url(base: searchEndpoint, query: value),
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
