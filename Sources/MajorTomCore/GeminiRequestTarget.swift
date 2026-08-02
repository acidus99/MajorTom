import Foundation

public struct GeminiRequestTarget: Equatable, Sendable {
    public static let defaultPort: UInt16 = 1_965

    /// A Gemini request is one CRLF-terminated line of at most 1024 bytes *including*
    /// the CRLF, so the URL itself may occupy at most 1022.
    public static let maximumRequestByteCount = 1_024
    public static let maximumURLByteCount = maximumRequestByteCount - 2

    public let url: URL
    public let endpoint: CapsuleEndpoint
    public let requestData: Data

    public init(_ input: String) throws {
        guard var components = URLComponents(string: input),
              components.scheme?.lowercased() == "gemini",
              let host = components.host,
              !host.isEmpty,
              components.user == nil,
              components.password == nil else {
            throw GeminiRequestError.invalidURL
        }

        let integerPort = components.port ?? Int(Self.defaultPort)
        guard let port = UInt16(exactly: integerPort), integerPort > 0 else {
            throw GeminiRequestError.invalidPort
        }

        components.scheme = "gemini"
        components.host = host.lowercased()
        components.fragment = nil
        if components.path.isEmpty { components.path = "/" }
        guard let normalizedURL = components.url else { throw GeminiRequestError.invalidURL }

        let serialized = normalizedURL.absoluteString
        let request = Data((serialized + "\r\n").utf8)
        guard request.count <= Self.maximumRequestByteCount else {
            throw GeminiRequestError.urlTooLong
        }

        self.url = normalizedURL
        self.endpoint = CapsuleEndpoint(host: host, port: port)
        self.requestData = request
    }

    /// A request routed **through** a Gemini proxy such as Stargate.
    ///
    /// The connection is an ordinary Gemini connection to the proxy's host and port;
    /// what differs is the request line, which carries the original absolute URL —
    /// typically `http://` or `https://` — instead of a `gemini://` one. The proxy
    /// fetches that resource, converts it, and replies with a normal Gemini response.
    /// A proxy that will not serve the scheme replies `53`.
    ///
    /// Two consequences worth being explicit about:
    ///
    /// - `endpoint` is the **proxy**, so TOFU pins the proxy's certificate. That is
    ///   correct: the proxy is the server actually being talked to, and it is the party
    ///   that must be trusted, since it sees and rewrites everything.
    /// - `url` remains the original resource, so history, the address field and the
    ///   page title show what the user asked for rather than the proxy's address.
    public init(proxying url: URL, through proxy: GeminiProxyConfiguration) throws {
        guard let scheme = url.scheme, !scheme.isEmpty, url.host != nil else {
            throw GeminiRequestError.invalidURL
        }
        guard !proxy.host.trimmingCharacters(in: .whitespaces).isEmpty, proxy.port > 0 else {
            throw GeminiRequestError.invalidPort
        }

        let serialized = url.absoluteString
        let request = Data((serialized + "\r\n").utf8)
        guard request.count <= Self.maximumRequestByteCount else {
            throw GeminiRequestError.urlTooLong
        }

        self.url = url
        self.endpoint = CapsuleEndpoint(host: proxy.host, port: proxy.port)
        self.requestData = request
    }
}

public enum GeminiRequestError: Error, Equatable, Sendable {
    case invalidURL
    case invalidPort
    case urlTooLong
}
