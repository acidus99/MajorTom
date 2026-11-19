import XCTest
@testable import MajorTomCore

final class GeminiImageLoaderTests: XCTestCase {
    private let url = URL(string: "gemini://images.example/one.png")!
    private let authorize: GeminiTransport.TrustAuthorization = { _, _ in true }

    func testFirstNetworkRequestWaitsForPageCooldown() async throws {
        let probe = ImageFetchProbe()
        let loader = makeLoader(probe)
        let opened = probe.clock.now
        _ = try await loader.image(for: url, interval: 2, pageStartedAt: opened, authorize: authorize)
        let starts = await probe.starts
        XCTAssertGreaterThanOrEqual(opened.duration(to: starts[0].time), .seconds(2))
    }

    func testCachedImageReturnsWhileNetworkQueueIsWaiting() async throws {
        let cache = try makeCache()
        let cached = response(url: url)
        try await cache.store(cached, resourceType: .image, lifetime: 60)
        let probe = ImageFetchProbe()
        let loader = makeLoader(probe, cache: cache)
        probe.clock.automatic = false
        let uncachedURL = URL(string: "gemini://images.example/two.png")!
        let waiting = Task { [authorize] in
            try await loader.image(for: uncachedURL, interval: 60, pageStartedAt: probe.clock.now, authorize: authorize)
        }
        let returned = expectation(description: "Cached image bypasses network cooldown")
        let activity = ImageActivity()
        let hit = Task { [url, authorize] in
            let result = try await loader.image(
                for: url, interval: 60, pageStartedAt: probe.clock.now,
                stateChanged: { activity.record($0) }, authorize: authorize
            )
            returned.fulfill()
            return result
        }
        await fulfillment(of: [returned], timeout: 1)
        hit.cancel()
        waiting.cancel()
        let result = try await completed(hit)
        XCTAssertEqual(result, cached)
        _ = try? await completed(waiting)
        let starts = await probe.starts
        XCTAssertTrue(starts.isEmpty)
        XCTAssertTrue(activity.values.isEmpty, "A cache hit must never signal an active network request")
    }

    func testCachedImagesAreImmediateOnNewVisitsAndCacheMissesArePaced() async throws {
        let cache = try makeCache()
        let probe = ImageFetchProbe()
        let loader = makeLoader(probe, cache: cache)
        let opened = probe.clock.now.advanced(by: .seconds(-60))
        let first = try await loader.image(for: url, interval: 1, pageStartedAt: opened, authorize: authorize)
        // Reload previously bypassed cached inline images and unnecessarily restarted
        // the network cooldown. A new page visit must reuse the completed response.
        let hit = try await loader.image(for: url, interval: 60, pageStartedAt: probe.clock.now, authorize: authorize)
        XCTAssertEqual(hit.url, first.url)
        XCTAssertEqual(hit.status, first.status)
        XCTAssertEqual(hit.meta, first.meta)
        XCTAssertEqual(hit.mimeType, first.mimeType)
        XCTAssertEqual(hit.body, first.body)
        XCTAssertEqual(hit.receivedAt.timeIntervalSince1970, first.receivedAt.timeIntervalSince1970, accuracy: 0.001)
        let nextURL = URL(string: "gemini://images.example/two.png")!
        _ = try await loader.image(for: nextURL, interval: 1, pageStartedAt: opened, authorize: authorize)
        let starts = await probe.starts
        XCTAssertEqual(starts.map(\.url), [url, nextURL])
        XCTAssertGreaterThanOrEqual(starts[0].time.duration(to: starts[1].time), .seconds(1))
    }

    func testDuplicateRequestsShareFetchAndCancelIndependently() async throws {
        let probe = ImageFetchProbe()
        probe.clock.automatic = false
        let loader = makeLoader(probe)
        let opened = probe.clock.now
        let first = Task { [url, authorize] in
            try await loader.image(for: url, interval: 1, pageStartedAt: opened, authorize: authorize)
        }
        let joined = expectation(description: "Duplicate joined")
        let second = Task { [url, authorize] in
            try await loader.image(for: url, interval: 1, pageStartedAt: opened,
                stateChanged: { if $0 == .pending { joined.fulfill() } }, authorize: authorize)
        }
        await fulfillment(of: [joined], timeout: 2)
        first.cancel()
        do {
            _ = try await completed(first)
            XCTFail("A canceled caller must not receive an image")
        } catch is CancellationError {}
        probe.clock.resumeAutomatically()
        _ = try await completed(second)
        let starts = await probe.starts
        XCTAssertEqual(starts.count, 1)
    }

    func testSlowDownDoublesDelayAndSuccessResetsIt() async throws {
        let probe = ImageFetchProbe(statuses: [44, 44, 20, 20])
        let activity = ImageActivity()
        let loader = makeLoader(probe)
        let opened = probe.clock.now.advanced(by: .seconds(-60))
        _ = try await loader.image(
            for: url, interval: 1, pageStartedAt: opened,
            stateChanged: { activity.record($0) }, authorize: authorize
        )
        let nextURL = URL(string: "gemini://images.example/two.png")!
        _ = try await loader.image(for: nextURL, interval: 1, pageStartedAt: opened, authorize: authorize)
        let starts = await probe.starts
        XCTAssertEqual(starts.count, 4)
        let gaps = zip(starts, starts.dropFirst()).map { $0.time.duration(to: $1.time) }
        XCTAssertGreaterThanOrEqual(gaps[0], .seconds(2))
        XCTAssertGreaterThanOrEqual(gaps[1], .seconds(4))
        XCTAssertGreaterThanOrEqual(gaps[2], .seconds(1))
        // META is "0": treating it as a numeric delay would bypass backoff.
        // A reset must also allow the next image before the old four-second delay.
        XCTAssertLessThan(gaps[2], gaps[1])
        // Prevents queue/backoff waits being presented as active network transfers.
        XCTAssertEqual(activity.values, [.pending, .requesting, .pending, .requesting, .pending, .requesting, .idle])
    }

    func testSlowDownSurvivesCancellationAndDoesNotBlockOtherCapsules() async throws {
        let probe = ImageFetchProbe(statuses: [44, 20, 20])
        probe.clock.automatic = false
        let loader = makeLoader(probe)
        let opened = probe.clock.now.advanced(by: .seconds(-60))
        let waiting = Task { [url, authorize] in
            try await loader.image(for: url, interval: 1, pageStartedAt: opened, authorize: authorize)
        }
        await probe.clock.waitForSleep(1)
        let other = URL(string: "gemini://other.example/image.png")!
        _ = try await loader.image(for: other, interval: 1, pageStartedAt: opened, authorize: authorize)
        waiting.cancel()
        _ = try? await completed(waiting)
        probe.clock.resumeAutomatically()
        _ = try await loader.image(for: url, interval: 1, pageStartedAt: opened, authorize: authorize)
        let starts = await probe.starts
        XCTAssertEqual(starts.map(\.url), [url, other, url])
        XCTAssertGreaterThanOrEqual(starts[0].time.duration(to: starts[2].time), .seconds(2))
    }

    func testCancelingOnlyQueuedRequestDoesNotBlockNextPage() async throws {
        let probe = ImageFetchProbe()
        probe.clock.automatic = false
        let activity = ImageActivity()
        let loader = makeLoader(probe)
        let waiting = Task { [url, authorize] in
            try await loader.image(
                for: url, interval: 60, pageStartedAt: probe.clock.now,
                stateChanged: { activity.record($0) }, authorize: authorize
            )
        }
        await probe.clock.waitForSleep(1)
        waiting.cancel()
        do {
            _ = try await completed(waiting)
            XCTFail("Cancellation must release a queued request")
        } catch is CancellationError {}
        XCTAssertEqual(activity.values, [.pending, .idle], "Canceled queued work must never report a transfer")
        probe.clock.resumeAutomatically()
        _ = try await loader.image(
            for: url, interval: 1, pageStartedAt: probe.clock.now.advanced(by: .seconds(-60)), authorize: authorize
        )
        let starts = await probe.starts
        XCTAssertEqual(starts.count, 1)
    }

    func testCancelingActiveTransferReleasesQueueAndRechecksCache() async throws {
        let cache = try makeCache()
        let probe = ImageFetchProbe(blocksFirstRequest: true)
        let loader = makeLoader(probe, cache: cache)
        let opened = probe.clock.now.advanced(by: .seconds(-60))
        let activity = ImageActivity()
        let active = Task { [url, authorize] in
            try await loader.image(
                for: url, interval: 1, pageStartedAt: opened,
                stateChanged: { activity.record($0) }, authorize: authorize
            )
        }
        await probe.waitForStarts(1)
        XCTAssertEqual(activity.values, [.pending, .requesting])
        let nextURL = URL(string: "gemini://images.example/two.png")!
        let enqueued = expectation(description: "Next image queued")
        let queued = Task { [authorize] in
            try await loader.image(for: nextURL, interval: 60, pageStartedAt: probe.clock.now,
                stateChanged: { if $0 == .pending { enqueued.fulfill() } }, authorize: authorize)
        }
        await fulfillment(of: [enqueued], timeout: 2)
        let cached = response(url: nextURL)
        try await cache.store(cached, resourceType: .image, lifetime: 60)
        active.cancel()
        _ = try? await completed(active)
        XCTAssertEqual(activity.values, [.pending, .requesting, .idle], "Canceling an active caller must clear its indicator")
        let returned = expectation(description: "Queued image checks cache before waiting for a network slot")
        let result = Task {
            let image = try await queued.value
            returned.fulfill()
            return image
        }
        await fulfillment(of: [returned], timeout: 1)
        queued.cancel()
        let image = try await completed(result)
        XCTAssertEqual(image, cached)
        let starts = await probe.starts
        XCTAssertEqual(starts.count, 1)
    }

    func testSameCapsuleRedirectsArePacedAndCrossCapsuleRedirectsAreRejected() async throws {
        let probe = ImageFetchProbe(statuses: [30, 20])
        let loader = makeLoader(probe)
        let opened = probe.clock.now.advanced(by: .seconds(-60))
        let result = try await loader.image(for: url, interval: 1, pageStartedAt: opened, authorize: authorize)
        let starts = await probe.starts
        XCTAssertEqual(starts.map(\.url.path), ["/one.png", "/two.png"])
        XCTAssertEqual(result.url.path, "/two.png")
        XCTAssertGreaterThanOrEqual(starts[0].time.duration(to: starts[1].time), .seconds(1))

        let crossCapsule = ImageFetchProbe(statuses: [30], redirect: "gemini://other.example/image.png")
        let otherLoader = makeLoader(crossCapsule)
        do {
            _ = try await otherLoader.image(for: url, interval: 1, pageStartedAt: opened, authorize: authorize)
            XCTFail("An automatic inline image must not redirect to another capsule")
        } catch {}
        let otherStarts = await crossCapsule.starts
        XCTAssertEqual(otherStarts.count, 1)
    }

    func testFailuresAreNotCached() async throws {
        let cache = try makeCache()
        let probe = ImageFetchProbe(statuses: [51])
        let loader = makeLoader(probe, cache: cache)
        do {
            _ = try await loader.image(
                for: url, interval: 1, pageStartedAt: probe.clock.now.advanced(by: .seconds(-60)), authorize: authorize
            )
            XCTFail("A failed response is not an image")
        } catch {}
        let cached = try await cache.freshResponse(for: url)
        XCTAssertNil(cached)
    }

    func testCacheFilledDuringWaitConsumesNoNetworkSlot() async throws {
        let cache = try makeCache()
        let probe = ImageFetchProbe()
        probe.clock.automatic = false
        let loader = makeLoader(probe, cache: cache)
        let opened = probe.clock.now
        let pending = Task { [url, authorize] in
            try await loader.image(for: url, interval: 2, pageStartedAt: opened, authorize: authorize)
        }
        await probe.clock.waitForSleep(1)
        try await cache.store(response(url: url), resourceType: .image, lifetime: 60)
        probe.clock.resumeAutomatically()
        _ = try await completed(pending)
        let filledAt = probe.clock.now
        _ = try await loader.image(for: URL(string: "gemini://images.example/next.png")!,
            interval: 2, pageStartedAt: opened, authorize: authorize)
        let starts = await probe.starts
        XCTAssertEqual(starts.count, 1)
        XCTAssertEqual(starts[0].time, filledAt, "A cache hit cannot reserve a network start")
    }

    func testClearingDuringActiveImagePreventsRepopulation() async throws {
        let cache = try makeCache()
        let probe = ImageFetchProbe(blocksFirstRequest: true)
        let loader = makeLoader(probe, cache: cache)
        let active = Task { [url, authorize] in
            try await loader.image(for: url, interval: 1,
                pageStartedAt: probe.clock.now.advanced(by: .seconds(-60)), authorize: authorize)
        }
        await probe.waitForStarts(1)
        try await cache.removeResponses(since: nil)
        await probe.releaseFirst()
        _ = try await completed(active)
        let stored = try await cache.freshResponse(for: url)
        XCTAssertNil(stored)
    }

    func testRepeatedSlowDownSaturatesAtTwentyFourHours() async throws {
        let probe = ImageFetchProbe(statuses: Array(repeating: 44, count: 20) + [20])
        let loader = makeLoader(probe)
        _ = try await loader.image(for: url, interval: 1,
            pageStartedAt: probe.clock.now.advanced(by: .seconds(-60)), authorize: authorize)
        let starts = await probe.starts
        let gaps = zip(starts, starts.dropFirst()).map { $0.time.duration(to: $1.time) }
        XCTAssertEqual(gaps.prefix(3), [.seconds(2), .seconds(4), .seconds(8)])
        XCTAssertEqual(gaps.last, .seconds(86_400))
        XCTAssertTrue(gaps.allSatisfy { $0 <= .seconds(86_400) })
    }

    private func makeLoader(_ probe: ImageFetchProbe, cache: ContentCache? = nil) -> GeminiImageLoader {
        GeminiImageLoader(cache: cache, transportEvents: { target, credential, configuration, _ in
            XCTAssertNil(credential, "Inline images must remain anonymous")
            XCTAssertEqual(configuration.maximumResponseByteCount, 16 * 1_024 * 1_024)
            return AsyncThrowingStream { continuation in
                let task = Task {
                    do {
                        let response = try await probe.fetch(target)
                        continuation.yield(.responseHeader(try GeminiResponseHeader(
                            status: response.status!, meta: String(decoding: response.meta, as: UTF8.self)
                        )))
                        continuation.yield(.body(response.body))
                        continuation.yield(.completed)
                        continuation.finish()
                    } catch { continuation.finish(throwing: error) }
                }
                continuation.onTermination = { _ in task.cancel() }
            }
        }, clock: GeminiImageClock(now: { probe.clock.now }, sleep: { try await probe.clock.sleep(until: $0) }))
    }

    private func completed<T: Sendable>(_ task: Task<T, any Error>) async throws -> T {
        let finished = expectation(description: "Image operation finished")
        let observer = Task { _ = await task.result; finished.fulfill() }
        let result = await XCTWaiter.fulfillment(of: [finished], timeout: 2)
        if result != .completed { task.cancel() }
        XCTAssertEqual(result, .completed)
        _ = await observer.value
        return try await task.value
    }

    private func makeCache() throws -> ContentCache {
        ContentCache(database: try ContentCacheDatabase(inMemory: ()))
    }

    func testClickPromotesAnImageDuringInitialCooldown() async throws {
        let probe = ImageFetchProbe()
        probe.clock.automatic = false
        let loader = makeLoader(probe)
        let opened = probe.clock.now
        let secondURL = URL(string: "gemini://images.example/second.png")!
        let firstQueued = expectation(description: "First image queued")
        let first = Task { [url, authorize] in
            try await loader.image(for: url, interval: 1, pageStartedAt: opened,
                stateChanged: { if $0 == .pending { firstQueued.fulfill() } }, authorize: authorize)
        }
        await fulfillment(of: [firstQueued], timeout: 2)
        let secondQueued = expectation(description: "Clicked image queued")
        let second = Task { [authorize] in
            try await loader.image(for: secondURL, interval: 1, pageStartedAt: opened,
                stateChanged: { if $0 == .pending { secondQueued.fulfill() } }, authorize: authorize)
        }
        await fulfillment(of: [secondQueued], timeout: 2)
        await loader.prioritize(secondURL)
        probe.clock.resumeAutomatically()
        _ = try await completed(second)
        _ = try await completed(first)
        let starts = await probe.starts
        XCTAssertEqual(starts.map(\.url), [secondURL, url])
        XCTAssertGreaterThanOrEqual(opened.duration(to: starts[0].time), .seconds(1))
        XCTAssertGreaterThanOrEqual(starts[0].time.duration(to: starts[1].time), .seconds(1))
    }

    func testClickWaitsForActiveTransferThenGoesBeforeOtherQueuedImages() async throws {
        let probe = ImageFetchProbe(blocksFirstRequest: true)
        let loader = makeLoader(probe)
        let opened = probe.clock.now.advanced(by: .seconds(-60))
        let active = Task { [url, authorize] in
            try await loader.image(for: url, interval: 1, pageStartedAt: opened, authorize: authorize)
        }
        await probe.waitForStarts(1)
        let secondURL = URL(string: "gemini://images.example/second.png")!
        let secondQueued = expectation(description: "Second image queued")
        let second = Task { [authorize] in
            try await loader.image(for: secondURL, interval: 1, pageStartedAt: opened,
                stateChanged: { if $0 == .pending { secondQueued.fulfill() } }, authorize: authorize)
        }
        await fulfillment(of: [secondQueued], timeout: 2)
        let clickedURL = URL(string: "gemini://images.example/clicked.png")!
        let clickedQueued = expectation(description: "Clicked image queued")
        let clicked = Task { [authorize] in
            try await loader.image(for: clickedURL, interval: 1, pageStartedAt: opened, prioritize: true,
                stateChanged: { if $0 == .pending { clickedQueued.fulfill() } }, authorize: authorize)
        }
        await fulfillment(of: [clickedQueued], timeout: 2)
        let beforeRelease = await probe.starts
        XCTAssertEqual(beforeRelease.map(\.url), [url], "A click must not interrupt an active transfer")
        await probe.releaseFirst()
        _ = try await completed(active)
        _ = try await completed(clicked)
        _ = try await completed(second)
        let starts = await probe.starts
        XCTAssertEqual(starts.map(\.url), [url, clickedURL, secondURL])
        XCTAssertGreaterThanOrEqual(starts[0].time.duration(to: starts[1].time), .seconds(1))
        XCTAssertGreaterThanOrEqual(starts[1].time.duration(to: starts[2].time), .seconds(1))
    }

    private func response(url: URL, body: Data = Data([1, 2, 3])) -> ContentResponse {
        ContentResponse(url: url, status: 20, meta: Data("image/png".utf8), mimeType: "image/png", body: body, receivedAt: Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down)))
    }
}

private final class ImageActivity: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [GeminiImageLoader.State] = []
    var values: [GeminiImageLoader.State] { lock.withLock { recorded } }
    func record(_ value: GeminiImageLoader.State) { lock.withLock { recorded.append(value) } }
}

private actor ImageFetchProbe {
    struct Start: Sendable {
        let url: URL
        let time: ContinuousClock.Instant
    }

    nonisolated let clock = ImageTestClock()
    var starts: [Start] = []
    private var statuses: [Int]
    private let blocksFirstRequest: Bool
    private let redirect: String
    private var firstGate: AsyncStream<Void>.Continuation?
    private var observers: [(Int, XCTestExpectation)] = []

    init(statuses: [Int] = [], blocksFirstRequest: Bool = false, redirect: String = "/two.png") {
        self.statuses = statuses
        self.blocksFirstRequest = blocksFirstRequest
        self.redirect = redirect
    }

    func fetch(_ target: GeminiRequestTarget) async throws -> ContentResponse {
        starts.append(Start(url: target.url, time: clock.now))
        let ready = observers.filter { starts.count >= $0.0 }
        observers.removeAll { starts.count >= $0.0 }
        for (_, observer) in ready { observer.fulfill() }
        if blocksFirstRequest, starts.count == 1 {
            let gate = AsyncStream<Void>.makeStream()
            firstGate = gate.continuation
            for await _ in gate.stream {}
            firstGate = nil
            try Task.checkCancellation()
        }
        let status = statuses.isEmpty ? 20 : statuses.removeFirst()
        return ContentResponse(
            url: target.url, status: status,
            meta: Data((status == 20 ? "image/png" : status == 30 ? redirect : "0").utf8),
            mimeType: status == 20 ? "image/png" : nil,
            body: status == 20 ? Data([1, 2, 3]) : Data(), receivedAt: Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
        )
    }

    func releaseFirst() { firstGate?.finish() }

    func waitForStarts(_ count: Int) async {
        if starts.count >= count { return }
        let reached = XCTestExpectation(description: "Transport started \(count) times")
        observers.append((count, reached))
        let result = await XCTWaiter.fulfillment(of: [reached], timeout: 2)
        XCTAssertEqual(result, .completed)
    }
}

/// Sleep registration and advancement are explicit; no protocol delay consumes wall time.
private final class ImageTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var instant = ContinuousClock.now
    private var advancesAutomatically = true
    private var sleepers: [UUID: (ContinuousClock.Instant, AsyncStream<Void>.Continuation)] = [:]
    private var sleepCount = 0
    private var observers: [(Int, XCTestExpectation)] = []
    var now: ContinuousClock.Instant { lock.withLock { instant } }
    var automatic: Bool {
        get { lock.withLock { advancesAutomatically } }
        set { lock.withLock { advancesAutomatically = newValue } }
    }
    func sleep(until deadline: ContinuousClock.Instant) async throws {
        try Task.checkCancellation()
        let id = UUID()
        let stream = AsyncStream<Void>.makeStream()
        lock.withLock {
            if advancesAutomatically { instant = max(instant, deadline) }
            if instant >= deadline { stream.continuation.finish(); return }
            sleepers[id] = (deadline, stream.continuation)
            sleepCount += 1
            let ready = observers.filter { sleepCount >= $0.0 }
            observers.removeAll { sleepCount >= $0.0 }
            for (_, observer) in ready { observer.fulfill() }
        }
        for await _ in stream.stream {}
        lock.withLock { _ = sleepers.removeValue(forKey: id) }
        try Task.checkCancellation()
    }
    func waitForSleep(_ count: Int) async {
        let reached = XCTestExpectation(description: "Clock reached wait \(count)")
        lock.withLock {
            if sleepCount >= count { reached.fulfill() }
            else { observers.append((count, reached)) }
        }
        let result = await XCTWaiter.fulfillment(of: [reached], timeout: 2)
        XCTAssertEqual(result, .completed)
    }
    func resumeAutomatically() {
        lock.withLock {
            advancesAutomatically = true
            for (deadline, continuation) in sleepers.values {
                instant = max(instant, deadline)
                continuation.finish()
            }
            sleepers.removeAll()
        }
    }
}
