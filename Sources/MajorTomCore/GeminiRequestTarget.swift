import Foundation

public struct GeminiRequestTarget: Equatable, Sendable {
    public static let defaultPort: UInt16 = 1_965
    public static let maximumURLByteCount = 1_024

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
        guard serialized.utf8.count <= Self.maximumURLByteCount else {
            throw GeminiRequestError.urlTooLong
        }

        self.url = normalizedURL
        self.endpoint = CapsuleEndpoint(host: host, port: port)
        self.requestData = Data((serialized + "\r\n").utf8)
    }
}

public enum GeminiRequestError: Error, Equatable, Sendable {
    case invalidURL
    case invalidPort
    case urlTooLong
}
