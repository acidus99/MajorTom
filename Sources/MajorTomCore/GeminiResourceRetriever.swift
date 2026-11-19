import Foundation

public enum GeminiRetrievalPurpose: Sendable {
    case navigation
    case download
    case favicon
    case inlineImage

    var redirectLimit: Int { self == .navigation ? 10 : (self == .favicon ? 0 : 5) }
    var configuration: GeminiTransportConfiguration {
        switch self {
        case .favicon: GeminiTransportConfiguration(idleTimeout: .seconds(10), maximumResponseByteCount: 4 * 1_024)
        case .inlineImage: GeminiTransportConfiguration(maximumResponseByteCount: 16 * 1_024 * 1_024)
        default: GeminiTransportConfiguration()
        }
    }
}

/// The shared image queue reserves each network hop. Cache hits, including hits
/// discovered while waiting, consume no slot and do not reset capsule backoff.
struct GeminiImageRequestSchedule: Sendable {
    let waitForSlot: @Sendable () async throws -> Void
    let didStart: @Sendable () async throws -> Void
    let didReceive: @Sendable (GeminiResponseHeader) async -> Void
}

public enum GeminiRetrievalError: Error, Sendable {
    case responseStatus(GeminiResponseHeader)
    case incompleteResponse
}

/// A matched identity can exist even when its credential is unavailable or invalid.
/// The opaque credential is supplied to transport only; it never enters response data.
public struct GeminiRetrievalIdentity<Credential: Sendable>: Sendable {
    public let descriptor: ClientCertificateDescriptor
    public let credential: Credential?

    public init(descriptor: ClientCertificateDescriptor, credential: Credential?) {
        self.descriptor = descriptor
        self.credential = credential
    }
}

public struct GeminiRetrievalResponse: Sendable {
    public enum Origin: Sendable { case live, cache }
    public enum Outcome: Equatable, Sendable {
        case success(mimeType: String)
        case inputRequired(isSensitive: Bool)
        case identityRequired
        case temporaryFailure
        case permanentFailure
        case redirect
    }

    public let target: GeminiRequestTarget
    public let header: GeminiResponseHeader
    public let outcome: Outcome
    public let origin: Origin
    public let receivedAt: Date
    public let matchedCertificate: ClientCertificateDescriptor?
    public let offeredCertificate: ClientCertificateDescriptor?

    public var mimeType: String {
        if case .success(let mimeType) = outcome { return mimeType }
        return ""
    }
}

public enum GeminiRetrievalRedirectError: Error, Equatable, Sendable {
    case loop(URL)
    case limit(URL)
    case invalid(source: URL, meta: String)
}

public enum GeminiRetrievalResult: Sendable {
    case completed
    case cancelled
    case trustDeclined
    /// Receiving bytes does not imply that Browser has committed or displayed them.
    case failed(error: any Error, receivedBody: Bool)
}

public enum GeminiRetrievalEvent: Sendable {
    case connecting(CapsuleEndpoint)
    case serverIdentity(PresentedServerIdentity)
    case redirect(GeminiRequestTarget)
    case loadingCachedResponse
    case response(GeminiRetrievalResponse)
    case body(Data)
    case finished(GeminiRetrievalResult)
}

/// Retrieves a response under its request-purpose policy. It owns no tab, parsing,
/// presentation, or decision state. Each subscription owns and cancels its source.
public struct GeminiResourceRetriever<Credential: Sendable>: Sendable {
    public typealias TransportEvents = @Sendable (
        GeminiRequestTarget, Credential?, GeminiTransportConfiguration, @escaping GeminiTransport.TrustAuthorization
    ) -> AsyncThrowingStream<GeminiTransportEvent, any Error>
    public typealias IdentityResolver = @Sendable (URL) async -> GeminiRetrievalIdentity<Credential>?

    private let transportEvents: TransportEvents
    private let cache: ContentCache?
    private let resolveIdentity: IdentityResolver
    private let authorizeTrust: GeminiTransport.TrustAuthorization
    private let imageSchedule: GeminiImageRequestSchedule?
    private let cacheWriteGeneration: UInt64?

    public init(
        transportEvents: @escaping TransportEvents,
        cache: ContentCache?,
        resolveIdentity: @escaping IdentityResolver,
        authorizeTrust: @escaping GeminiTransport.TrustAuthorization
    ) {
        self.transportEvents = transportEvents
        self.cache = cache
        self.resolveIdentity = resolveIdentity
        self.authorizeTrust = authorizeTrust
        self.imageSchedule = nil
        self.cacheWriteGeneration = nil
    }

    init(
        transportEvents: @escaping TransportEvents, cache: ContentCache?,
        authorizeTrust: @escaping GeminiTransport.TrustAuthorization,
        imageSchedule: GeminiImageRequestSchedule, cacheWriteGeneration: UInt64?
    ) {
        self.transportEvents = transportEvents
        self.cache = cache
        self.resolveIdentity = { _ in nil }
        self.authorizeTrust = authorizeTrust
        self.imageSchedule = imageSchedule
        self.cacheWriteGeneration = cacheWriteGeneration
    }

    public func events(
        for target: GeminiRequestTarget,
        proxy: GeminiProxyConfiguration? = nil,
        bypassesCache: Bool = false,
        purpose: GeminiRetrievalPurpose = .navigation
    ) -> AsyncStream<GeminiRetrievalEvent> {
        AsyncStream { continuation in
            let task = Task {
                let result = await retrieve(
                    target, proxy: proxy, bypassesCache: bypassesCache, purpose: purpose,
                    continuation: continuation
                )
                continuation.yield(.finished(result))
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Collects a complete resource for workflows such as explicit downloads.
    /// The same streaming pipeline owns redirects, credentials and cache eligibility.
    public func response(
        for target: GeminiRequestTarget,
        proxy: GeminiProxyConfiguration? = nil,
        purpose: GeminiRetrievalPurpose = .download
    ) async throws -> ContentResponse {
        var metadata: GeminiRetrievalResponse?
        var body = Data()
        for await event in events(for: target, proxy: proxy, purpose: purpose) {
            try Task.checkCancellation()
            switch event {
            case .response(let response):
                guard response.header.isSuccess else { throw GeminiRetrievalError.responseStatus(response.header) }
                metadata = response
            case .body(let data): body.append(data)
            case .finished(.completed):
                guard let metadata else { throw GeminiRetrievalError.incompleteResponse }
                return ContentResponse(
                    url: metadata.target.url, status: metadata.header.status, meta: Data(metadata.header.meta.utf8),
                    mimeType: metadata.mimeType, body: body, receivedAt: metadata.receivedAt
                )
            case .finished(.cancelled): throw CancellationError()
            case .finished(.trustDeclined): throw GeminiTransportError.trustDeclined
            case .finished(.failed(let error, _)): throw error
            default: break
            }
        }
        try Task.checkCancellation()
        throw GeminiRetrievalError.incompleteResponse
    }

    private func retrieve(
        _ initialTarget: GeminiRequestTarget,
        proxy: GeminiProxyConfiguration?,
        bypassesCache: Bool,
        purpose: GeminiRetrievalPurpose,
        continuation: AsyncStream<GeminiRetrievalEvent>.Continuation
    ) async -> GeminiRetrievalResult {
        var target = initialTarget
        var visited = Set<URL>()
        var redirects = 0
        var receivedBody = false
        let generation: UInt64?
        if let cacheWriteGeneration { generation = cacheWriteGeneration }
        else { generation = await cache?.writeGeneration }
        visited.insert(target.url)
        do {
            while true {
                try Task.checkCancellation()
                guard redirects <= purpose.redirectLimit else {
                    throw GeminiRetrievalRedirectError.limit(target.url)
                }
                let isDirectGemini = target.url.scheme?.lowercased() == "gemini"
                    && CapsuleEndpoint(url: target.url) == target.endpoint
                let identity = isDirectGemini && (purpose == .navigation || purpose == .download) ? await resolveIdentity(target.url) : nil
                try Task.checkCancellation()
                let offered = identity?.credential == nil ? nil : identity?.descriptor
                var cached: ContentResponse?
                if bypassesCache {
                    try? await cache?.removeResponse(for: target.url)
                    cached = nil
                } else if purpose != .favicon, offered == nil,
                          let response = try? await cache?.freshResponse(for: target.url),
                          let status = response.status, status / 10 == 2,
                          purpose != .inlineImage || response.mimeType?.hasPrefix("image/") == true {
                    cached = response
                } else {
                    cached = nil
                }
                try Task.checkCancellation()
                if cached == nil, let imageSchedule {
                    try await imageSchedule.waitForSlot()
                    try Task.checkCancellation()
                    if let response = try? await cache?.freshResponse(for: target.url),
                       response.status.map({ $0 / 10 == 2 }) == true,
                       response.mimeType?.hasPrefix("image/") == true {
                        cached = response
                    }
                }
                let events: AsyncThrowingStream<GeminiTransportEvent, any Error>
                if let cached {
                    continuation.yield(.loadingCachedResponse)
                    events = GeminiResponseReplay.events(for: cached)
                } else {
                    try await imageSchedule?.didStart()
                    try Task.checkCancellation()
                    events = transportEvents(target, identity?.credential, purpose.configuration, authorizeTrust)
                }
                var response: GeminiRetrievalResponse?
                var cacheBody = Data()
                var cacheDecision = ContentCacheDecision.doNotStore
                var redirectTarget: GeminiRequestTarget?
                var retriesImage = false
                for try await event in events {
                    try Task.checkCancellation()
                    switch event {
                    case .connecting(let endpoint):
                        continuation.yield(.connecting(endpoint))
                    case .serverIdentity(let identity):
                        continuation.yield(.serverIdentity(identity))
                    case .responseHeader(let header):
                        if cached == nil, !header.isSuccess { await imageSchedule?.didReceive(header) }
                        if purpose == .inlineImage, imageSchedule != nil, header.status == 44 {
                            retriesImage = true
                            break
                        }
                        if header.isRedirect && purpose != .favicon {
                            guard let url = URL(
                                string: header.meta.trimmingCharacters(in: .whitespacesAndNewlines),
                                relativeTo: target.url
                            )?.absoluteURL,
                                  let next = GeminiRequestTarget.navigationTarget(for: url, proxy: proxy) else {
                                throw GeminiRetrievalRedirectError.invalid(source: target.url, meta: header.meta)
                            }
                            if purpose == .inlineImage, !GemtextLinkHint.isSameCapsule(next.url, initialTarget.url) {
                                throw GeminiRetrievalRedirectError.invalid(source: target.url, meta: header.meta)
                            }
                            redirectTarget = next
                            continuation.yield(.redirect(next))
                            break
                        }
                        let outcome: GeminiRetrievalResponse.Outcome
                        switch header.category {
                        case 1: outcome = .inputRequired(isSensitive: header.status == 11)
                        case 2:
                            let mime = header.meta.split(separator: ";", maxSplits: 1).first
                                .map { $0.trimmingCharacters(in: .whitespaces).lowercased() } ?? ""
                            outcome = .success(mimeType: mime)
                        case 4: outcome = .temporaryFailure
                        case 5: outcome = .permanentFailure
                        case 3: outcome = .redirect
                        default: outcome = .identityRequired
                        }
                        let metadata = GeminiRetrievalResponse(
                            target: target, header: header, outcome: outcome,
                            origin: cached == nil ? .live : .cache,
                            receivedAt: cached?.receivedAt ?? Date(),
                            matchedCertificate: identity?.descriptor,
                            offeredCertificate: offered
                        )
                        response = metadata
                        if cached == nil && purpose != .favicon {
                            cacheDecision = GeminiCacheDecider().decision(
                                for: target,
                                response: ContentResponse(
                                    url: target.url, status: header.status, meta: Data(header.meta.utf8),
                                    mimeType: metadata.mimeType, body: Data(), receivedAt: metadata.receivedAt
                                ),
                                clientIdentityOffered: offered != nil
                            )
                        }
                        continuation.yield(.response(metadata))
                        if !header.isSuccess { return .completed }
                    case .body(let data):
                        guard response?.header.isSuccess == true else { continue }
                        receivedBody = receivedBody || !data.isEmpty
                        if case .store = cacheDecision { cacheBody.append(data) }
                        continuation.yield(.body(data))
                    case .completed:
                        guard let response else { throw GeminiProtocolError.responseEndedBeforeHeader }
                        if cached == nil { await imageSchedule?.didReceive(response.header) }
                        if case .store(let type, let lifetime) = cacheDecision {
                            _ = try? await cache?.store(
                                ContentResponse(
                                    url: target.url, status: response.header.status,
                                    meta: Data(response.header.meta.utf8), mimeType: response.mimeType,
                                    body: cacheBody, receivedAt: response.receivedAt
                                ),
                                resourceType: type, lifetime: lifetime, generation: generation
                            )
                        }
                        try Task.checkCancellation()
                        return .completed
                    }
                    if redirectTarget != nil || retriesImage { break }
                }
                try Task.checkCancellation()
                if retriesImage { continue }
                guard let next = redirectTarget else {
                    throw GeminiProtocolError.responseEndedBeforeHeader
                }
                guard visited.insert(next.url).inserted else { throw GeminiRetrievalRedirectError.loop(next.url) }
                target = next
                redirects += 1
            }
        } catch is CancellationError {
            return .cancelled
        } catch GeminiTransportError.trustDeclined {
            return Task.isCancelled ? .cancelled : .trustDeclined
        } catch {
            return Task.isCancelled ? .cancelled : .failed(error: error, receivedBody: receivedBody)
        }
    }
}
