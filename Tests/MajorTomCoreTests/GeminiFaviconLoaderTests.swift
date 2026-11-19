import Foundation
import XCTest
@testable import MajorTomCore

final class GeminiFaviconLoaderTests: XCTestCase {
    private let endpoint = CapsuleEndpoint(host: "example.com")
    private let url = URL(string: "gemini://example.com/favicon.txt")!

    func testUnknownObservationIsCachedForFifteenDays() async throws {
        let clock = FaviconClock()
        let probe = FaviconFetchProbe { throw GeminiTransportError.connectionTimedOut }
        let loader = makeLoader(try cache(), probe, clock)
        let first = await loader.observation(for: endpoint)
        XCTAssertEqual(first.kind, .unknown)
        clock.advance(days: 14)
        let cached = await loader.observation(for: endpoint)
        XCTAssertEqual(cached, first)
        let beforeExpiry = await probe.count
        XCTAssertEqual(beforeExpiry, 1)
        clock.advance(days: 1)
        _ = await loader.observation(for: endpoint)
        let afterExpiry = await probe.count
        XCTAssertEqual(afterExpiry, 2)
    }

    func testKnownAbsenceAndValidFaviconAreCachedForThirtyDays() async throws {
        for kind in [GeminiFaviconObservation.Kind.absent, .found("🚀")] {
            let clock = FaviconClock()
            let resourceURL = url
            let probe = FaviconFetchProbe {
                if kind == .absent { throw GeminiRetrievalError.responseStatus(try GeminiResponseHeader(status: 51, meta: "Not found")) }
                return ContentResponse(url: resourceURL, status: 20, meta: Data("text/plain".utf8), mimeType: "text/plain", body: Data("🚀\n".utf8), receivedAt: clock.value)
            }
            let loader = makeLoader(try cache(), probe, clock)
            let first = await loader.observation(for: endpoint)
            XCTAssertEqual(first.kind, kind)
            clock.advance(days: 29)
            let cached = await loader.observation(for: endpoint)
            XCTAssertEqual(cached.receivedAt, first.receivedAt)
            let beforeExpiry = await probe.count
            XCTAssertEqual(beforeExpiry, 1)
            clock.advance(days: 1)
            _ = await loader.observation(for: endpoint)
            let afterExpiry = await probe.count
            XCTAssertEqual(afterExpiry, 2)
        }
    }

    func testOnlyNotFoundAndGoneFailuresAreConclusiveAbsence() async throws {
        for status in [10, 11, 30, 31, 40, 44, 50, 51, 52, 53, 59, 60, 61, 62] {
            let clock = FaviconClock()
            let probe = FaviconFetchProbe {
                throw GeminiRetrievalError.responseStatus(try GeminiResponseHeader(status: status, meta: "Fixture"))
            }
            let observation = await makeLoader(try cache(), probe, clock).observation(for: endpoint)
            XCTAssertEqual(observation.kind, status == 51 || status == 52 ? .absent : .unknown, "Status \(status)")
        }
    }

    func testSuccessfulInvalidFaviconIsConclusiveAbsence() async throws {
        let clock = FaviconClock()
        let resourceURL = url
        let probe = FaviconFetchProbe {
            ContentResponse(url: resourceURL, status: 20, meta: Data("text/plain".utf8), mimeType: "text/plain", body: Data("not an emoji".utf8), receivedAt: clock.value)
        }
        let observation = await makeLoader(try cache(), probe, clock).observation(for: endpoint)
        XCTAssertEqual(observation.kind, .absent)
    }

    func testCacheClearPermitsAnImmediateRetry() async throws {
        let clock = FaviconClock()
        let store = try cache()
        let probe = FaviconFetchProbe { throw URLError(.cannotConnectToHost) }
        let loader = makeLoader(store, probe, clock)
        _ = await loader.observation(for: endpoint)
        try await store.removeResponses(since: nil)
        _ = await loader.observation(for: endpoint)
        let count = await probe.count
        XCTAssertEqual(count, 2)
    }

    func testCachedUnknownRemainsDistinctFromBookmarkDeletionWithoutFetching() async throws {
        let clock = FaviconClock()
        let store = try cache()
        let probe = FaviconFetchProbe { throw GeminiTransportError.trustDeclined }
        _ = await makeLoader(store, probe, clock).observation(for: endpoint)
        let known = await GeminiFaviconLoader.cachedObservations(cache: store, now: clock.value)
        XCTAssertEqual(known[endpoint]?.kind, .unknown)
        let single = await GeminiFaviconLoader.cachedObservation(for: url, cache: store, now: clock.value)
        XCTAssertEqual(single?.kind, .unknown)
        let count = await probe.count
        XCTAssertEqual(count, 1)
    }

    func testClearingDuringProbePreventsLateCacheRepopulation() async throws {
        let clock = FaviconClock()
        let store = try cache()
        let entered = XCTestExpectation(description: "Probe entered")
        let gate = AsyncStream<Void>.makeStream()
        let resourceURL = url
        let probe = FaviconFetchProbe {
            entered.fulfill()
            for await _ in gate.stream { break }
            return ContentResponse(url: resourceURL, status: 20, meta: Data("text/plain".utf8), mimeType: "text/plain", body: Data("🚀".utf8), receivedAt: clock.value)
        }
        let loader = makeLoader(store, probe, clock)
        let destination = endpoint
        let task = Task { await loader.observation(for: destination) }
        let ready = await XCTWaiter.fulfillment(of: [entered], timeout: 2)
        XCTAssertEqual(ready, .completed)
        try await store.removeResponses(since: nil)
        gate.continuation.yield(())
        gate.continuation.finish()
        _ = await task.value
        let retained = try await store.freshResponse(for: url, now: clock.value)
        XCTAssertNil(retained)
    }

    private func cache() throws -> ContentCache { ContentCache(database: try ContentCacheDatabase(inMemory: ())) }
    private func makeLoader(_ cache: ContentCache, _ probe: FaviconFetchProbe, _ clock: FaviconClock) -> GeminiFaviconLoader {
        GeminiFaviconLoader(cache: cache, retrieve: { _ in try await probe.fetch() }, now: { clock.value })
    }
}

private actor FaviconFetchProbe {
    private(set) var count = 0
    private let reply: @Sendable () async throws -> ContentResponse
    init(reply: @escaping @Sendable () async throws -> ContentResponse) { self.reply = reply }
    func fetch() async throws -> ContentResponse { count += 1; return try await reply() }
}

private final class FaviconClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date = Date(timeIntervalSince1970: 1_800_000_000)
    var value: Date { lock.withLock { date } }
    func advance(days: Int) { lock.withLock { date.addTimeInterval(Double(days) * 86_400) } }
}
