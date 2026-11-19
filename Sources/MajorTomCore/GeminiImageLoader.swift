import Foundation

/// Monotonic scheduling time is supplied independently from response receipt time.
struct GeminiImageClock: Sendable {
    let now: @Sendable () -> ContinuousClock.Instant
    let sleep: @Sendable (ContinuousClock.Instant) async throws -> Void
    static let continuous = GeminiImageClock(now: { .now }, sleep: { deadline in
        try await Task.sleep(until: deadline, clock: .continuous)
    })
}

/// Shared by tabs. Only cache misses enter the per-capsule network queues; the
/// cache remains a passive store and WebKit never owns retrieval policy.
public actor GeminiImageLoader {
    public enum State: String, Sendable {
        case idle
        case pending
        case requesting
    }

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
    private let transportEvents: GeminiResourceRetriever<ClientTLSIdentity>.TransportEvents
    private let clock: GeminiImageClock
    private var queues: [CapsuleEndpoint: [Request]] = [:]
    private var workers: [CapsuleEndpoint: Task<Void, Never>] = [:]
    private var workerIDs: [CapsuleEndpoint: UUID] = [:]
    private var cooldowns: [CapsuleEndpoint: Cooldown] = [:]

    public init(cache: ContentCache?, transport: GeminiTransport = GeminiTransport()) {
        self.cache = cache
        self.transportEvents = { target, _, configuration, authorize in
            transport.events(for: target, configuration: configuration, authorizeTrust: authorize)
        }
        self.clock = .continuous
    }

    init(
        cache: ContentCache?,
        transportEvents: @escaping GeminiResourceRetriever<ClientTLSIdentity>.TransportEvents,
        clock: GeminiImageClock
    ) {
        self.cache = cache
        self.transportEvents = transportEvents
        self.clock = clock
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
        if let cached = try? await cache?.freshResponse(for: target.url),
           cached.status.map({ $0 / 10 == 2 }) == true, cached.mimeType?.hasPrefix("image/") == true {
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
        let retriever = GeminiResourceRetriever<ClientTLSIdentity>(
            transportEvents: transportEvents, cache: cache, authorizeTrust: request.authorize,
            imageSchedule: GeminiImageRequestSchedule(
                waitForSlot: { try await self.waitForSlot(request) },
                didStart: { try await self.didStart(request) },
                didReceive: { await self.didReceive($0, for: request) }
            ),
            cacheWriteGeneration: request.cacheGeneration
        )
        let response = try await retriever.response(for: request.target, purpose: .inlineImage)
        guard response.mimeType?.hasPrefix("image/") == true else {
            throw URLError(.cannotDecodeContentData)
        }
        return response
    }

    private func waitForSlot(_ request: Request) async throws {
        let cooldown = cooldowns[request.target.endpoint] ?? Cooldown()
        var deadline = request.notBefore
        if let lastStarted = cooldown.lastStarted {
            deadline = max(deadline, lastStarted.advanced(by: .seconds(request.interval)))
        }
        if let retryNotBefore = cooldown.retryNotBefore {
            deadline = max(deadline, retryNotBefore)
        }
        try await clock.sleep(deadline)
        try Task.checkCancellation()
    }

    private func didStart(_ request: Request) throws {
        try Task.checkCancellation()
        guard queues[request.target.endpoint]?.first?.id == request.id else { throw CancellationError() }
        cooldowns[request.target.endpoint, default: Cooldown()].lastStarted = clock.now()
        setState(.requesting, for: request)
    }

    private func didReceive(_ header: GeminiResponseHeader, for request: Request) {
        let endpoint = request.target.endpoint
        guard queues[endpoint]?.first?.id == request.id else { return }
        setState(header.status == 44 || header.isRedirect ? .pending : .idle, for: request)
        if header.status == 44 {
            var cooldown = cooldowns[endpoint] ?? Cooldown()
            // META is explanatory text, never a numeric retry delay.
            cooldown.backoff = min(max(request.interval, cooldown.backoff) * 2, 86_400)
            cooldown.retryNotBefore = clock.now().advanced(by: .seconds(cooldown.backoff))
            cooldowns[endpoint] = cooldown
        } else if header.isSuccess {
            cooldowns[endpoint]?.backoff = 0
            cooldowns[endpoint]?.retryNotBefore = nil
        }
    }
}
