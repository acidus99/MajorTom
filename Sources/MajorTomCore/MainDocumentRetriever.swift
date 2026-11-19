import Foundation

/// A matched identity can exist even when its credential is unavailable or invalid.
/// The opaque credential is supplied to transport only; it never enters response data.
public struct MainDocumentIdentity<Credential: Sendable>: Sendable {
    public let descriptor: ClientCertificateDescriptor
    public let credential: Credential?

    public init(descriptor: ClientCertificateDescriptor, credential: Credential?) {
        self.descriptor = descriptor
        self.credential = credential
    }
}

public struct MainDocumentResponse: Sendable {
    public enum Origin: Sendable { case live, cache }
    public enum Outcome: Equatable, Sendable {
        case success(mimeType: String)
        case inputRequired(isSensitive: Bool)
        case identityRequired
        case temporaryFailure
        case permanentFailure
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

public enum MainDocumentRedirectError: Error, Equatable, Sendable {
    case loop(URL)
    case limit(URL)
    case invalid(source: URL, meta: String)
}

public enum MainDocumentResult: Sendable {
    case completed
    case cancelled
    case trustDeclined
    /// Receiving bytes does not imply that Browser has committed or displayed them.
    case failed(error: any Error, receivedBody: Bool)
}

public enum MainDocumentEvent: Sendable {
    case connecting(CapsuleEndpoint)
    case serverIdentity(PresentedServerIdentity)
    case redirect(GeminiRequestTarget)
    case loadingCachedResponse
    case response(MainDocumentResponse)
    case body(Data)
    case finished(MainDocumentResult)
}

/// Retrieves one main document, including its redirects. It owns no tab, parsing,
/// presentation, or decision state. Each subscription owns and cancels its source.
public struct MainDocumentRetriever<Credential: Sendable>: Sendable {
    public typealias TransportEvents = @Sendable (
        GeminiRequestTarget, Credential?, @escaping GeminiTransport.TrustAuthorization
    ) -> AsyncThrowingStream<GeminiTransportEvent, any Error>
    public typealias IdentityResolver = @Sendable (URL) async -> MainDocumentIdentity<Credential>?

    private let transportEvents: TransportEvents
    private let cache: ContentCache?
    private let resolveIdentity: IdentityResolver
    private let authorizeTrust: GeminiTransport.TrustAuthorization

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
    }

    public func events(
        for target: GeminiRequestTarget,
        proxy: GeminiProxyConfiguration? = nil,
        bypassesCache: Bool = false
    ) -> AsyncStream<MainDocumentEvent> {
        AsyncStream { continuation in
            let task = Task {
                let result = await retrieve(
                    target, proxy: proxy, bypassesCache: bypassesCache,
                    continuation: continuation
                )
                continuation.yield(.finished(result))
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func retrieve(
        _ initialTarget: GeminiRequestTarget,
        proxy: GeminiProxyConfiguration?,
        bypassesCache: Bool,
        continuation: AsyncStream<MainDocumentEvent>.Continuation
    ) async -> MainDocumentResult {
        var target = initialTarget
        var visited = Set<URL>()
        var redirects = 0
        var receivedBody = false
        do {
            while true {
                try Task.checkCancellation()
                guard !visited.contains(target.url) else {
                    throw MainDocumentRedirectError.loop(target.url)
                }
                guard redirects <= 10 else {
                    throw MainDocumentRedirectError.limit(target.url)
                }
                visited.insert(target.url)
                let generation = await cache?.writeGeneration
                let identity = await resolveIdentity(target.url)
                try Task.checkCancellation()
                let offered = identity?.credential == nil ? nil : identity?.descriptor
                let cached: ContentResponse?
                if bypassesCache {
                    try? await cache?.removeResponse(for: target.url)
                    cached = nil
                } else if offered == nil,
                          let response = try? await cache?.freshResponse(for: target.url),
                          let status = response.status, status / 10 == 2 {
                    cached = response
                } else {
                    cached = nil
                }
                try Task.checkCancellation()
                let events: AsyncThrowingStream<GeminiTransportEvent, any Error>
                if let cached {
                    continuation.yield(.loadingCachedResponse)
                    events = GeminiResponseReplay.events(for: cached)
                } else {
                    events = transportEvents(target, identity?.credential, authorizeTrust)
                }
                var response: MainDocumentResponse?
                var cacheBody = Data()
                var cacheDecision = ContentCacheDecision.doNotStore
                var redirectTarget: GeminiRequestTarget?
                for try await event in events {
                    try Task.checkCancellation()
                    switch event {
                    case .connecting(let endpoint):
                        continuation.yield(.connecting(endpoint))
                    case .serverIdentity(let identity):
                        continuation.yield(.serverIdentity(identity))
                    case .responseHeader(let header):
                        if header.isRedirect {
                            guard let url = URL(
                                string: header.meta.trimmingCharacters(in: .whitespacesAndNewlines),
                                relativeTo: target.url
                            )?.absoluteURL,
                                  let next = GeminiRequestTarget.navigationTarget(for: url, proxy: proxy) else {
                                throw MainDocumentRedirectError.invalid(source: target.url, meta: header.meta)
                            }
                            redirectTarget = next
                            continuation.yield(.redirect(next))
                            break
                        }
                        let outcome: MainDocumentResponse.Outcome
                        switch header.category {
                        case 1: outcome = .inputRequired(isSensitive: header.status == 11)
                        case 2:
                            let mime = header.meta.split(separator: ";", maxSplits: 1).first
                                .map { $0.trimmingCharacters(in: .whitespaces).lowercased() } ?? ""
                            outcome = .success(mimeType: mime)
                        case 4: outcome = .temporaryFailure
                        case 5: outcome = .permanentFailure
                        default: outcome = .identityRequired
                        }
                        let metadata = MainDocumentResponse(
                            target: target, header: header, outcome: outcome,
                            origin: cached == nil ? .live : .cache,
                            receivedAt: cached?.receivedAt ?? Date(),
                            matchedCertificate: identity?.descriptor,
                            offeredCertificate: offered
                        )
                        response = metadata
                        if cached == nil {
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
                    if redirectTarget != nil { break }
                }
                try Task.checkCancellation()
                guard let next = redirectTarget else {
                    throw GeminiProtocolError.responseEndedBeforeHeader
                }
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
