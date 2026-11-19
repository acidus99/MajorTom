import Foundation

public struct GeminiFaviconObservation: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case found(String)
        case absent
        case unknown
    }
    public let kind: Kind
    public let receivedAt: Date
    public var emoji: String? { if case .found(let emoji) = kind { return emoji }; return nil }
}

/// Favicon acquisition and negative caching. An inconclusive check suppresses
/// repeated traffic but carries no instruction to delete a bookmark's known icon.
public struct GeminiFaviconLoader: Sendable {
    public typealias Retrieve = @Sendable (GeminiRequestTarget) async throws -> ContentResponse
    private static let unknownMeta = Data("MajorTom temporary favicon absence".utf8)
    private let cache: ContentCache?
    private let retrieve: Retrieve
    private let now: @Sendable () -> Date

    public init(cache: ContentCache?, retrieve: @escaping Retrieve, now: @escaping @Sendable () -> Date = { Date() }) {
        self.cache = cache
        self.retrieve = retrieve
        self.now = now
    }

    public func observation(for endpoint: CapsuleEndpoint) async -> GeminiFaviconObservation {
        guard let url = GeminiFavicon.url(for: endpoint),
              let target = try? GeminiRequestTarget(url.absoluteString) else {
            return GeminiFaviconObservation(kind: .unknown, receivedAt: now())
        }
        let generation = await cache?.writeGeneration
        if let cached = try? await cache?.freshResponse(for: url, now: now()) {
            let known = Self.observation(from: cached)
            if known.kind == .absent, cached.status != 51 {
                _ = try? await cache?.store(
                    GeminiFavicon.negativeResponse(for: url, receivedAt: cached.receivedAt),
                    resourceType: .favicon, lifetime: GeminiFavicon.cacheLifetime, now: now(), generation: generation
                )
            }
            return known
        }
        let observation: GeminiFaviconObservation
        let response: ContentResponse
        do {
            let fetched = try await retrieve(target)
            let kind: GeminiFaviconObservation.Kind
            if let emoji = GeminiFavicon.parse(response: fetched) { kind = .found(emoji) }
            else if fetched.status.map({ $0 / 10 == 2 || $0 == 51 || $0 == 52 }) == true { kind = .absent }
            else { kind = .unknown }
            observation = GeminiFaviconObservation(kind: kind, receivedAt: fetched.receivedAt)
            response = fetched
        } catch {
            let kind: GeminiFaviconObservation.Kind
            if case GeminiRetrievalError.responseStatus(let header) = error,
               header.status == 51 || header.status == 52 {
                kind = .absent
            } else {
                kind = .unknown
            }
            observation = GeminiFaviconObservation(kind: kind, receivedAt: now())
            response = GeminiFavicon.negativeResponse(for: url, receivedAt: observation.receivedAt)
        }
        var stored: ContentResponse
        switch observation.kind {
        case .found: stored = response
        case .absent, .unknown:
            stored = GeminiFavicon.negativeResponse(for: url, receivedAt: observation.receivedAt)
        }
        if observation.kind == .unknown { stored.meta = Self.unknownMeta }
        _ = try? await cache?.store(
            stored, resourceType: .favicon,
            lifetime: observation.kind == .unknown ? 15 * 24 * 60 * 60 : GeminiFavicon.cacheLifetime,
            now: now(), generation: generation
        )
        return observation
    }

    /// Read-only surfaces can decorate known records without making requests.
    public static func cachedObservation(for url: URL, cache: ContentCache?, now: Date = Date()) async -> GeminiFaviconObservation? {
        guard let response = try? await cache?.freshResponse(for: url, now: now) else { return nil }
        return observation(from: response)
    }

    public static func cachedObservations(cache: ContentCache?, now: Date = Date()) async -> [CapsuleEndpoint: GeminiFaviconObservation] {
        let responses = (try? await cache?.freshResponses(ofType: .favicon, now: now)) ?? []
        var known: [CapsuleEndpoint: GeminiFaviconObservation] = [:]
        for response in responses {
            if let endpoint = CapsuleEndpoint(url: response.url) { known[endpoint] = observation(from: response) }
        }
        return known
    }

    private static func observation(from response: ContentResponse) -> GeminiFaviconObservation {
        if let emoji = GeminiFavicon.parse(response: response) {
            return GeminiFaviconObservation(kind: .found(emoji), receivedAt: response.receivedAt)
        }
        return GeminiFaviconObservation(
            kind: response.status == 51 && response.meta == unknownMeta ? .unknown : .absent,
            receivedAt: response.receivedAt
        )
    }
}
