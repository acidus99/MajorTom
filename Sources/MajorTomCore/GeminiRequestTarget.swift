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
}

public enum GeminiRequestError: Error, Equatable, Sendable {
    case invalidURL
    case invalidPort
    case urlTooLong
}
