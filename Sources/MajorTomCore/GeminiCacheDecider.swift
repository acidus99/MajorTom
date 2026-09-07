import Foundation

public enum ContentCacheDecision: Equatable, Sendable {
    case doNotStore
    case store(resourceType: ResourceType, lifetime: TimeInterval)
}

/// Gemini's deliberately small initial cache policy. Favicon validation and
/// negative favicon entries are owned by the favicon feature instead.
public struct GeminiCacheDecider: Sendable {
    public static let imageLifetime: TimeInterval = 24 * 60 * 60

    public init() {}

    public func decision(
        for request: GeminiRequestTarget,
        response: ContentResponse
    ) -> ContentCacheDecision {
        guard request.url.scheme?.lowercased() == "gemini",
              let status = response.status,
              status / 10 == 2,
              response.mimeType?.lowercased().hasPrefix("image/") == true else {
            return .doNotStore
        }
        return .store(resourceType: .image, lifetime: Self.imageLifetime)
    }
}

/// Replays a complete stored Gemini response through the same response events
/// consumed from a live transport.
public enum GeminiResponseReplay {
    public static func events(
        for response: ContentResponse
    ) -> AsyncThrowingStream<GeminiTransportEvent, any Error> {
        AsyncThrowingStream { continuation in
            do {
                guard let status = response.status,
                      let meta = String(data: response.meta, encoding: .utf8) else {
                    throw GeminiProtocolError.malformedResponseHeader
                }
                continuation.yield(.responseHeader(
                    try GeminiResponseHeader(status: status, meta: meta)
                ))
                if !response.body.isEmpty {
                    continuation.yield(.body(response.body))
                }
                continuation.yield(.completed)
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
    }
}
