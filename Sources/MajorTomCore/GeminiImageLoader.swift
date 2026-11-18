import Foundation

/// Shared by tabs. Only cache misses enter the per-capsule network queues; the
/// cache remains a passive store and WebKit never owns retrieval policy.
public actor GeminiImageLoader {
    public enum State: String, Sendable {
        case idle
        case pending
        case requesting
    }

    typealias Fetch = @Sendable (
        GeminiRequestTarget, @escaping GeminiTransport.TrustAuthorization
    ) async throws -> ContentResponse

    private struct Waiter {
        let continuation: CheckedContinuation<ContentResponse, any Error>
        let stateChanged: @Sendable (State) -> Void
    }

    private struct Request {
        let id = UUID()
        let target: GeminiRequestTarget
        let interval: TimeInterval
        let notBefore: ContinuousClock.Instant
        let cacheGeneration: UInt64?
        let authorize: GeminiTransport.TrustAuthorization
        var state: State = .pending
        var waiters: [UUID: Waiter]
    }

    private struct Cooldown {
        var lastStarted: ContinuousClock.Instant?
        var retryNotBefore: ContinuousClock.Instant?
        var backoff: TimeInterval = 0
    }

    private let cache: ContentCache?
    private let fetch: Fetch
    private var queues: [CapsuleEndpoint: [Request]] = [:]
    private var workers: [CapsuleEndpoint: Task<Void, Never>] = [:]
    private var workerIDs: [CapsuleEndpoint: UUID] = [:]
    private var cooldowns: [CapsuleEndpoint: Cooldown] = [:]

    public init(cache: ContentCache?, transport: GeminiTransport = GeminiTransport()) {
        self.cache = cache
        self.fetch = { target, authorize in
            try await Self.fetchImage(target, transport: transport, authorize: authorize)
        }
    }

    // Inject only the network boundary: tests exercise the real cache, queue,
    // cancellation, and monotonic cooldown without contacting a capsule.
    init(cache: ContentCache?, fetch: @escaping Fetch) {
        self.cache = cache
        self.fetch = fetch
    }

    public func image(
        for url: URL,
        interval: TimeInterval,
        pageStartedAt: ContinuousClock.Instant,
        prioritize: Bool = false,
        stateChanged: @escaping @Sendable (State) -> Void = { _ in },
        authorize: @escaping GeminiTransport.TrustAuthorization
    ) async throws -> ContentResponse {
        let cacheGeneration = await cache?.writeGeneration
        let target = try GeminiRequestTarget(url.absoluteString)
        try Task.checkCancellation()
        if let cached = try? await cache?.freshResponse(for: target.url) {
            try Task.checkCancellation()
            return cached
        }
        let interval = interval.isFinite ? max(1, min(interval, 60)) : 2
        let waiter = UUID()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                let endpoint = target.endpoint
                if let index = queues[endpoint]?.firstIndex(where: {
                    $0.target.url == target.url && $0.cacheGeneration == cacheGeneration
                        && $0.interval == interval
                }) {
                    queues[endpoint]![index].waiters[waiter] = Waiter(
                        continuation: continuation, stateChanged: stateChanged
                    )
                } else {
                    queues[endpoint, default: []].append(Request(
                        target: target,
                        interval: interval,
                        notBefore: pageStartedAt.advanced(by: .seconds(interval)),
                        cacheGeneration: cacheGeneration,
                        authorize: authorize,
                        waiters: [waiter: Waiter(continuation: continuation, stateChanged: stateChanged)]
                    ))
                }
                if let joined = queues[endpoint]?.first(where: { $0.waiters[waiter] != nil }) {
                    stateChanged(joined.state)
                }
                if prioritize { promote(target) }
                startNext(for: endpoint)
            }
        } onCancel: {
            Task { await self.cancel(waiter: waiter, endpoint: target.endpoint) }
        }
    }

    /// A click changes order, never the capsule's cooldown or an active transfer.
    public func prioritize(_ url: URL) {
        guard let target = try? GeminiRequestTarget(url.absoluteString) else { return }
        promote(target)
    }

    private func promote(_ target: GeminiRequestTarget) {
        let endpoint = target.endpoint
        guard let index = queues[endpoint]?.firstIndex(where: { $0.target.url == target.url }),
              index > 0 else { return }
        let active = queues[endpoint]!.first!.state != .pending
        let request = queues[endpoint]!.remove(at: index)
        queues[endpoint]!.insert(request, at: active ? 1 : 0)
        if !active {
            workerIDs[endpoint] = nil
            workers.removeValue(forKey: endpoint)?.cancel()
            startNext(for: endpoint)
        }
    }

    private func startNext(for endpoint: CapsuleEndpoint) {
        guard workers[endpoint] == nil, let request = queues[endpoint]?.first else { return }
        let workerID = UUID()
        workerIDs[endpoint] = workerID
        workers[endpoint] = Task {
            do {
                let response = try await retrieve(request)
                finish(request, result: .success(response), workerID: workerID)
            } catch {
                finish(request, result: .failure(error), workerID: workerID)
            }
        }
    }

    private func cancel(waiter: UUID, endpoint: CapsuleEndpoint) {
        guard let index = queues[endpoint]?.firstIndex(where: { $0.waiters[waiter] != nil }),
              let removed = queues[endpoint]![index].waiters.removeValue(forKey: waiter)
        else { return }
        removed.stateChanged(.idle)
        removed.continuation.resume(throwing: CancellationError())
        guard queues[endpoint]![index].waiters.isEmpty else { return }
        queues[endpoint]!.remove(at: index)
        if index == 0 {
            workerIDs[endpoint] = nil
            workers.removeValue(forKey: endpoint)?.cancel()
            startNext(for: endpoint)
        }
        if queues[endpoint]?.isEmpty == true { queues[endpoint] = nil }
    }

    private func finish(_ request: Request, result: Result<ContentResponse, any Error>, workerID: UUID) {
        let endpoint = request.target.endpoint
        // A canceled worker may finish after its replacement has already started.
        guard workerIDs[endpoint] == workerID, queues[endpoint]?.first?.id == request.id else { return }
        let finished = queues[endpoint]!.removeFirst()
        workers[endpoint] = nil
        workerIDs[endpoint] = nil
        for waiter in finished.waiters.values {
            if finished.state != .idle { waiter.stateChanged(.idle) }
            waiter.continuation.resume(with: result)
        }
        startNext(for: endpoint)
        if queues[endpoint]?.isEmpty == true { queues[endpoint] = nil }
    }

    private func setState(_ state: State, for request: Request) {
        let endpoint = request.target.endpoint
        guard queues[endpoint]?.first?.id == request.id else { return }
        guard queues[endpoint]![0].state != state else { return }
        queues[endpoint]![0].state = state
        for waiter in queues[endpoint]![0].waiters.values { waiter.stateChanged(state) }
    }

    private func retrieve(_ request: Request) async throws -> ContentResponse {
        var target = request.target
        var redirects = 0
        while true {
            try Task.checkCancellation()
            if let cached = try? await cache?.freshResponse(for: target.url) {
                try Task.checkCancellation()
                return cached
            }
            let cooldown = cooldowns[target.endpoint] ?? Cooldown()
            var deadline = request.notBefore
            if let lastStarted = cooldown.lastStarted {
                deadline = max(deadline, lastStarted.advanced(by: .seconds(request.interval)))
            }
            if let retryNotBefore = cooldown.retryNotBefore {
                deadline = max(deadline, retryNotBefore)
            }
            try await Task.sleep(until: deadline, clock: .continuous)
            try Task.checkCancellation()
            // A different tab or direct image navigation may have filled the cache
            // during the wait. Such a hit does not consume a network slot.
            if let cached = try? await cache?.freshResponse(for: target.url) {
                try Task.checkCancellation()
                return cached
            }
            try Task.checkCancellation()
            cooldowns[target.endpoint, default: Cooldown()].lastStarted = .now
            setState(.requesting, for: request)
            let response: ContentResponse
            do {
                response = try await fetch(target, request.authorize)
            } catch {
                setState(.idle, for: request)
                throw error
            }
            setState(response.status == 44 || response.status.map { $0 / 10 == 3 } == true ? .pending : .idle, for: request)
            try Task.checkCancellation()
            if response.status == 44 {
                var cooldown = cooldowns[target.endpoint] ?? Cooldown()
                // META is explanatory text, never a numeric retry delay. Saturate
                // only to keep a malicious endless sequence from overflowing.
                cooldown.backoff = min(max(request.interval, cooldown.backoff) * 2, 86_400)
                cooldown.retryNotBefore = ContinuousClock.now.advanced(by: .seconds(cooldown.backoff))
                cooldowns[target.endpoint] = cooldown
                continue
            }
            if let status = response.status, status / 10 == 2 {
                cooldowns[target.endpoint]?.backoff = 0
                cooldowns[target.endpoint]?.retryNotBefore = nil
            }
            if let status = response.status, status / 10 == 3 {
                guard redirects < 5,
                      let meta = String(data: response.meta, encoding: .utf8),
                      let url = URL(string: meta, relativeTo: target.url)?.absoluteURL,
                      GemtextLinkHint.isSameCapsule(url, target.url) else {
                    throw URLError(.badServerResponse)
                }
                target = try GeminiRequestTarget(url.absoluteString)
                redirects += 1
                continue
            }
            guard let status = response.status, status / 10 == 2,
                  response.mimeType?.hasPrefix("image/") == true else {
                throw URLError(.cannotDecodeContentData)
            }
            // Complete the write before returning so the next queued duplicate can
            // reuse it. There is no second in-memory response cache.
            _ = try? await cache?.store(response, resourceType: .image, lifetime: GeminiCacheDecider.imageLifetime, generation: request.cacheGeneration)
            try Task.checkCancellation()
            return response
        }
    }

    private static func fetchImage(
        _ target: GeminiRequestTarget,
        transport: GeminiTransport,
        authorize: @escaping GeminiTransport.TrustAuthorization
    ) async throws -> ContentResponse {
        var header: GeminiResponseHeader?
        var receivedAt = Date()
        var body = Data()
        let events = transport.events(
            for: target,
            configuration: GeminiTransportConfiguration(maximumResponseByteCount: 16 * 1_024 * 1_024),
            authorizeTrust: authorize
        )
        for try await event in events {
            try Task.checkCancellation()
            switch event {
            case .responseHeader(let responseHeader):
                header = responseHeader
                receivedAt = Date()
            case .body(let data):
                body.append(data)
            case .completed:
                guard let header else { throw URLError(.badServerResponse) }
                let mime = header.meta.split(separator: ";", maxSplits: 1).first
                    .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
                return ContentResponse(
                    url: target.url,
                    status: header.status,
                    meta: Data(header.meta.utf8),
                    mimeType: header.isSuccess ? mime : nil,
                    body: body,
                    receivedAt: receivedAt
                )
            default:
                break
            }
        }
        throw URLError(.badServerResponse)
    }
}
