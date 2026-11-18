import XCTest
@testable import MajorTomCore

final class GeminiImageLoaderTests: XCTestCase {
    private let url = URL(string: "gemini://images.example/one.png")!
    private let authorize: GeminiTransport.TrustAuthorization = { _, _ in true }

    func testFirstNetworkRequestWaitsForPageCooldown() async throws {
        let probe = ImageFetchProbe()
        let loader = GeminiImageLoader(cache: nil, fetch: { target, authorize in try await probe.fetch(target, authorize: authorize) })
        let opened = ContinuousClock.now
        _ = try await loader.image(for: url, interval: 2, pageStartedAt: opened, authorize: authorize)
        let starts = await probe.starts
        XCTAssertGreaterThanOrEqual(opened.duration(to: starts[0].time), .seconds(2))
    }

    func testCachedImageReturnsWhileNetworkQueueIsWaiting() async throws {
        let cache = try makeCache()
        let cached = response(url: url)
        try await cache.store(cached, resourceType: .image, lifetime: 60)
        let probe = ImageFetchProbe()
        let loader = GeminiImageLoader(cache: cache, fetch: { target, authorize in try await probe.fetch(target, authorize: authorize) })
        let uncachedURL = URL(string: "gemini://images.example/two.png")!
        let waiting = Task { [authorize] in
            try await loader.image(for: uncachedURL, interval: 60, pageStartedAt: .now, authorize: authorize)
        }
        let returned = expectation(description: "Cached image bypasses network cooldown")
        let activity = ImageActivity()
        let hit = Task { [url, authorize] in
            let result = try await loader.image(
                for: url, interval: 60, pageStartedAt: .now,
                stateChanged: { activity.record($0) }, authorize: authorize
            )
            returned.fulfill()
            return result
        }
        await fulfillment(of: [returned], timeout: 1)
        hit.cancel()
        waiting.cancel()
        let result = try await hit.value
        XCTAssertEqual(result, cached)
        _ = try? await waiting.value
        let starts = await probe.starts
        XCTAssertTrue(starts.isEmpty)
        XCTAssertTrue(activity.values.isEmpty, "A cache hit must never signal an active network request")
    }

    func testCachedImagesAreImmediateOnNewVisitsAndCacheMissesArePaced() async throws {
        let cache = try makeCache()
        let probe = ImageFetchProbe()
        let loader = GeminiImageLoader(cache: cache, fetch: { target, authorize in try await probe.fetch(target, authorize: authorize) })
        let opened = ContinuousClock.now.advanced(by: .seconds(-60))
        let first = try await loader.image(for: url, interval: 1, pageStartedAt: opened, authorize: authorize)
        // Reload previously bypassed cached inline images and unnecessarily restarted
        // the network cooldown. A new page visit must reuse the completed response.
        let hit = try await loader.image(for: url, interval: 60, pageStartedAt: .now, authorize: authorize)
        XCTAssertEqual(hit, first)
        let nextURL = URL(string: "gemini://images.example/two.png")!
        _ = try await loader.image(for: nextURL, interval: 1, pageStartedAt: opened, authorize: authorize)
        let starts = await probe.starts
        XCTAssertEqual(starts.map(\.url), [url, nextURL])
        XCTAssertGreaterThanOrEqual(starts[0].time.duration(to: starts[1].time), .seconds(1))
    }

    func testDuplicateRequestsShareFetchAndCancelIndependently() async throws {
        let probe = ImageFetchProbe()
        let loader = GeminiImageLoader(cache: nil, fetch: { target, authorize in try await probe.fetch(target, authorize: authorize) })
        let opened = ContinuousClock.now
        let first = Task { [url, authorize] in
            try await loader.image(for: url, interval: 1, pageStartedAt: opened, authorize: authorize)
        }
        let second = Task { [url, authorize] in
            try await loader.image(for: url, interval: 1, pageStartedAt: opened, authorize: authorize)
        }
        // Both callers have time to join the delayed request before one leaves.
        try await Task.sleep(for: .milliseconds(50))
        first.cancel()
        do {
            _ = try await first.value
            XCTFail("A canceled caller must not receive an image")
        } catch is CancellationError {}
        _ = try await second.value
        let starts = await probe.starts
        XCTAssertEqual(starts.count, 1)
    }

    func testSlowDownDoublesDelayAndSuccessResetsIt() async throws {
        let probe = ImageFetchProbe(statuses: [44, 44, 20, 20])
        let activity = ImageActivity()
        let loader = GeminiImageLoader(cache: nil, fetch: { target, authorize in try await probe.fetch(target, authorize: authorize) })
        let opened = ContinuousClock.now.advanced(by: .seconds(-60))
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
        let loader = GeminiImageLoader(cache: nil, fetch: { target, authorize in try await probe.fetch(target, authorize: authorize) })
        let opened = ContinuousClock.now.advanced(by: .seconds(-60))
        let waiting = Task { [url, authorize] in
            try await loader.image(for: url, interval: 1, pageStartedAt: opened, authorize: authorize)
        }
        await probe.waitForStarts(1)
        let other = URL(string: "gemini://other.example/image.png")!
        _ = try await loader.image(for: other, interval: 1, pageStartedAt: opened, authorize: authorize)
        waiting.cancel()
        _ = try? await waiting.value
        _ = try await loader.image(for: url, interval: 1, pageStartedAt: opened, authorize: authorize)
        let starts = await probe.starts
        XCTAssertEqual(starts.map(\.url), [url, other, url])
        XCTAssertGreaterThanOrEqual(starts[0].time.duration(to: starts[2].time), .seconds(2))
    }

    func testCancelingOnlyQueuedRequestDoesNotBlockNextPage() async throws {
        let probe = ImageFetchProbe()
        let activity = ImageActivity()
        let loader = GeminiImageLoader(cache: nil, fetch: { target, authorize in try await probe.fetch(target, authorize: authorize) })
        let waiting = Task { [url, authorize] in
            try await loader.image(
                for: url, interval: 60, pageStartedAt: .now,
                stateChanged: { activity.record($0) }, authorize: authorize
            )
        }
        try await Task.sleep(for: .milliseconds(50))
        waiting.cancel()
        do {
            _ = try await waiting.value
            XCTFail("Cancellation must release a queued request")
        } catch is CancellationError {}
        XCTAssertEqual(activity.values, [.pending, .idle], "Canceled queued work must never report a transfer")
        _ = try await loader.image(
            for: url, interval: 1, pageStartedAt: .now.advanced(by: .seconds(-60)), authorize: authorize
        )
        let starts = await probe.starts
        XCTAssertEqual(starts.count, 1)
    }

    func testCancelingActiveTransferReleasesQueueAndRechecksCache() async throws {
        let cache = try makeCache()
        let probe = ImageFetchProbe(blocksFirstRequest: true)
        let loader = GeminiImageLoader(cache: cache, fetch: { target, authorize in
            try await probe.fetch(target, authorize: authorize)
        })
        let opened = ContinuousClock.now.advanced(by: .seconds(-60))
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
        let queued = Task { [authorize] in
            try await loader.image(for: nextURL, interval: 60, pageStartedAt: .now, authorize: authorize)
        }
        try await Task.sleep(for: .milliseconds(50))
        let cached = response(url: nextURL)
        try await cache.store(cached, resourceType: .image, lifetime: 60)
        active.cancel()
        _ = try? await active.value
        XCTAssertEqual(activity.values, [.pending, .requesting, .idle], "Canceling an active caller must clear its indicator")
        let returned = expectation(description: "Queued image checks cache before waiting for a network slot")
        let result = Task {
            let image = try await queued.value
            returned.fulfill()
            return image
        }
        await fulfillment(of: [returned], timeout: 1)
        queued.cancel()
        let image = try await result.value
        XCTAssertEqual(image, cached)
        let starts = await probe.starts
        XCTAssertEqual(starts.count, 1)
    }

    func testSameCapsuleRedirectsArePacedAndCrossCapsuleRedirectsAreRejected() async throws {
        let probe = ImageFetchProbe(statuses: [30, 20])
        let loader = GeminiImageLoader(cache: nil, fetch: { target, authorize in
            try await probe.fetch(target, authorize: authorize)
        })
        let opened = ContinuousClock.now.advanced(by: .seconds(-60))
        let result = try await loader.image(for: url, interval: 1, pageStartedAt: opened, authorize: authorize)
        let starts = await probe.starts
        XCTAssertEqual(starts.map(\.url.path), ["/one.png", "/two.png"])
        XCTAssertEqual(result.url.path, "/two.png")
        XCTAssertGreaterThanOrEqual(starts[0].time.duration(to: starts[1].time), .seconds(1))

        let crossCapsule = ImageFetchProbe(statuses: [30], redirect: "gemini://other.example/image.png")
        let otherLoader = GeminiImageLoader(cache: nil, fetch: { target, authorize in
            try await crossCapsule.fetch(target, authorize: authorize)
        })
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
        let loader = GeminiImageLoader(cache: cache, fetch: { target, authorize in try await probe.fetch(target, authorize: authorize) })
        do {
            _ = try await loader.image(
                for: url, interval: 1, pageStartedAt: .now.advanced(by: .seconds(-60)), authorize: authorize
            )
            XCTFail("A failed response is not an image")
        } catch {}
        let cached = try await cache.freshResponse(for: url)
        XCTAssertNil(cached)
    }

    private func makeCache() throws -> ContentCache {
        ContentCache(database: try ContentCacheDatabase(inMemory: ()))
    }

    func testClickPromotesAnImageDuringInitialCooldown() async throws {
        let probe = ImageFetchProbe()
        let loader = GeminiImageLoader(cache: nil, fetch: { target, authorize in
            try await probe.fetch(target, authorize: authorize)
        })
        let opened = ContinuousClock.now
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
        _ = try await second.value
        _ = try await first.value
        let starts = await probe.starts
        XCTAssertEqual(starts.map(\.url), [secondURL, url])
        XCTAssertGreaterThanOrEqual(opened.duration(to: starts[0].time), .seconds(1))
        XCTAssertGreaterThanOrEqual(starts[0].time.duration(to: starts[1].time), .seconds(1))
    }

    func testClickWaitsForActiveTransferThenGoesBeforeOtherQueuedImages() async throws {
        let probe = ImageFetchProbe(blocksFirstRequest: true)
        let loader = GeminiImageLoader(cache: nil, fetch: { target, authorize in
            try await probe.fetch(target, authorize: authorize)
        })
        let opened = ContinuousClock.now.advanced(by: .seconds(-60))
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
        _ = try await active.value
        _ = try await clicked.value
        _ = try await second.value
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

    var starts: [Start] = []
    private var statuses: [Int]
    private let blocksFirstRequest: Bool
    private let redirect: String
    private var firstGate: AsyncStream<Void>.Continuation?
    private var observers: [(Int, CheckedContinuation<Void, Never>)] = []

    init(statuses: [Int] = [], blocksFirstRequest: Bool = false, redirect: String = "/two.png") {
        self.statuses = statuses
        self.blocksFirstRequest = blocksFirstRequest
        self.redirect = redirect
    }

    func fetch(_ target: GeminiRequestTarget, authorize: @escaping GeminiTransport.TrustAuthorization) async throws -> ContentResponse {
        starts.append(Start(url: target.url, time: .now))
        let ready = observers.filter { starts.count >= $0.0 }
        observers.removeAll { starts.count >= $0.0 }
        for (_, observer) in ready { observer.resume() }
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
        await withCheckedContinuation { observers.append((count, $0)) }
    }
}
