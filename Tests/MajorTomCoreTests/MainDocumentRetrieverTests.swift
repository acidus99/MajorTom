import Foundation
import XCTest
@testable import MajorTomCore

private let fixtureBytes = Data([0, 255, 0xE2, 0x98, 0x83])

private func fixtureHeader(_ status: Int = 20, _ meta: String = "text/gemini") throws -> GeminiResponseHeader {
    try GeminiResponseHeader(status: status, meta: meta)
}

final class MainDocumentRetrieverTests: XCTestCase {
    private let url = URL(string: "gemini://example.com/start")!
    private let bytes = fixtureBytes

    func testProxiedHTTPDoesNotDiscloseAGeminiScopedIdentity() async throws {
        let descriptor = certificate()
        let scope = ClientCertificateAssociation.entireCapsule(
            certificateID: descriptor.id, endpoint: CapsuleEndpoint(host: "example.com")
        )
        let source = ScriptedDocumentSource { _ in [.responseHeader(try fixtureHeader()), .completed] }
        let retriever = makeRetriever(source.events, resolve: { destination in
            // Uses the same actual scope matcher as ClientCertificateStore resolution.
            guard scope.matches(destination) else { return nil }
            return MainDocumentIdentity(descriptor: descriptor, credential: "synthetic-secret")
        })
        for scheme in ["http", "https"] {
            let resource = URL(string: "\(scheme)://example.com/private/file")!
            let proxy = GeminiProxyConfiguration(host: "proxy.example", port: 1965)
            _ = await collect(retriever.events(for: try GeminiRequestTarget(proxying: resource, through: proxy), proxy: proxy))
            XCTAssertNil(source.requests.last?.credential, "A Gemini identity must not be offered to the proxy for an HTTP(S) origin")
        }
    }

    func testProxyTransportNeverResolvesOrOffersAClientIdentity() async throws {
        let source = ScriptedDocumentSource { _ in [.responseHeader(try fixtureHeader()), .completed] }
        let retriever = makeRetriever(source.events, resolve: { _ in
            XCTFail("Proxy requests must not resolve client credentials")
            return nil
        })
        let proxy = GeminiProxyConfiguration(host: "proxy.example", port: 1965)
        for scheme in ["http", "https", "gemini"] {
            let resource = URL(string: "\(scheme)://example.com/private")!
            _ = await collect(retriever.events(for: try GeminiRequestTarget(proxying: resource, through: proxy), proxy: proxy))
            XCTAssertNil(source.requests.last?.credential)
        }
    }

    func testStreamsExactChunksBeforeOneTerminalResult() async throws {
        let source = ControlledDocumentSource()
        let received = expectation(description: "First body delivered before completion")
        received.expectedFulfillmentCount = 2
        let retriever = makeRetriever(source.events)
        let stream = retriever.events(for: try target())
        let collector = Task {
            await collect(stream) {
                if case .body = $0 { received.fulfill() }
            }
        }
        source.continuation.yield(.responseHeader(try header()))
        let chunks = [Data(bytes.prefix(3)), Data(bytes.dropFirst(3))]
        for chunk in chunks { source.continuation.yield(.body(chunk)) }
        await fulfillment(of: [received], timeout: 2)
        source.continuation.yield(.completed)
        let events = await collector.value
        XCTAssertEqual(body(events), bytes)
        XCTAssertEqual(events.compactMap { if case .body(let data) = $0 { return data }; return nil }, chunks)
        XCTAssertEqual(responses(events).count, 1)
        assertCompleted(events)
    }

    func testRedirectChainExposesOnlyFinalHeaderAndBody() async throws {
        let source = ScriptedDocumentSource { target in
            switch target.url.path {
            case "/start": return [.responseHeader(try fixtureHeader(31, "/middle"))]
            case "/middle": return [.responseHeader(try fixtureHeader(30, "/final"))]
            default: return [.responseHeader(try fixtureHeader()), .body(Data("final".utf8)), .completed]
            }
        }
        let events = await collect(makeRetriever(source.events).events(for: try target()))
        XCTAssertEqual(source.requests.map(\.target.url.path), ["/start", "/middle", "/final"])
        XCTAssertEqual(responses(events).map(\.target.url.path), ["/final"])
        XCTAssertEqual(events.filter { if case .redirect = $0 { return true }; return false }.count, 2)
        XCTAssertEqual(body(events), Data("final".utf8))
        assertCompleted(events)
    }

    func testRedirectLoopAndEleventhHopAreDistinctFailures() async throws {
        let loop = ScriptedDocumentSource { _ in [.responseHeader(try fixtureHeader(31, "/start"))] }
        let loopEvents = await collect(makeRetriever(loop.events).events(for: try target()))
        guard case .finished(.failed(let loopError, false)) = loopEvents.last else {
            return XCTFail("Expected redirect-loop failure")
        }
        XCTAssertEqual(loopError as? MainDocumentRedirectError, .loop(url))
        XCTAssertEqual(loop.requests.count, 1)

        let chain = ScriptedDocumentSource { target in
            let hop = Int(target.url.lastPathComponent) ?? 0
            return [.responseHeader(try fixtureHeader(31, "/\(hop + 1)"))]
        }
        let events = await collect(makeRetriever(chain.events).events(for: try target()))
        guard case .finished(.failed(let limitError, false)) = events.last else {
            return XCTFail("Expected redirect-limit failure")
        }
        XCTAssertEqual(limitError as? MainDocumentRedirectError, .limit(URL(string: "gemini://example.com/11")!))
        XCTAssertEqual(chain.requests.count, 11)
    }

    func testRedirectResolvesEachDestinationWithoutForwardingCredentials() async throws {
        let first = certificate()
        let second = certificate()
        let source = ScriptedDocumentSource { target in
            switch target.url.host {
            case "example.com": return [.responseHeader(try fixtureHeader(31, "gemini://other.example/private"))]
            case "other.example": return [.responseHeader(try fixtureHeader(31, "gemini://anonymous.example/"))]
            default: return [.responseHeader(try fixtureHeader()), .completed]
            }
        }
        let retriever = makeRetriever(source.events, resolve: { url in
            switch url.host {
            case "example.com": MainDocumentIdentity(descriptor: first, credential: "first")
            case "other.example": MainDocumentIdentity(descriptor: second, credential: "second")
            default: nil
            }
        })
        let events = await collect(retriever.events(for: try target()))
        XCTAssertEqual(source.requests.map(\.credential), ["first", "second", nil])
        XCTAssertNil(responses(events).first?.offeredCertificate)
        assertCompleted(events)
    }

    func testProxiedRelativeRedirectUsesOriginalResourceURL() async throws {
        let proxy = GeminiProxyConfiguration(host: "proxy.example", port: 1965)
        let original = URL(string: "https://web.example/directory/start")!
        let source = ScriptedDocumentSource { target in
            target.url.path.hasSuffix("start")
                ? [.responseHeader(try fixtureHeader(31, "next"))]
                : [.responseHeader(try fixtureHeader()), .completed]
        }
        let events = await collect(makeRetriever(source.events).events(
            for: try GeminiRequestTarget(proxying: original, through: proxy), proxy: proxy
        ))
        XCTAssertEqual(source.requests.map(\.target.endpoint.host), ["proxy.example", "proxy.example"])
        XCTAssertEqual(source.requests.last?.target.url.absoluteString, "https://web.example/directory/next")
        XCTAssertEqual(source.requests.last?.target.requestData, Data("https://web.example/directory/next\r\n".utf8))
        assertCompleted(events)
    }

    func testUnsupportedRedirectIsTypedFailure() async throws {
        let source = ScriptedDocumentSource { _ in [.responseHeader(try fixtureHeader(31, "file:///fixture"))] }
        let events = await collect(makeRetriever(source.events).events(for: try target()))
        guard case .finished(.failed(let error, false)) = events.last else {
            return XCTFail("Expected invalid redirect")
        }
        XCTAssertEqual(error as? MainDocumentRedirectError, .invalid(source: url, meta: "file:///fixture"))
        XCTAssertTrue(responses(events).isEmpty)
    }

    func testReloadRemovesEntryAndRetrievesLiveResponse() async throws {
        let cache = try makeCache()
        try await seed(cache)
        let source = ScriptedDocumentSource { _ in [.responseHeader(try fixtureHeader()), .body(fixtureBytes), .completed] }
        let events = await collect(makeRetriever(source.events, cache: cache).events(for: try target(), bypassesCache: true))
        XCTAssertEqual(source.requests.count, 1)
        XCTAssertEqual(responses(events).first?.origin, .live)
        XCTAssertEqual(body(events), bytes)
        let retained = try await cache.freshResponse(for: url)
        XCTAssertNil(retained)
        assertCompleted(events)
    }

    func testFreshImageReplayPreservesReceiptTimeAndResponseSequence() async throws {
        let cache = try makeCache()
        let receivedAt = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970) - 600)
        try await seed(cache, receivedAt: receivedAt)
        let source = ScriptedDocumentSource { _ in
            [.connecting(CapsuleEndpoint(host: "example.com")), .responseHeader(try fixtureHeader(20, "image/png")), .body(fixtureBytes), .completed]
        }
        let retriever = makeRetriever(source.events, cache: cache)
        let replayed = await collect(retriever.events(for: try target()))
        XCTAssertTrue(source.requests.isEmpty)
        XCTAssertEqual(responses(replayed).first?.origin, .cache)
        XCTAssertEqual(responses(replayed).first?.receivedAt, receivedAt)
        let live = await collect(retriever.events(for: try target(), bypassesCache: true))
        XCTAssertEqual(responseSequence(replayed), responseSequence(live))
        XCTAssertEqual(body(replayed), bytes)
        XCTAssertEqual(body(live), bytes)
        assertCompleted(replayed)
        assertCompleted(live)
    }

    func testIdentityResolutionPrecedesCacheLookupAndPersonalizedBytesAreNeverStored() async throws {
        // BUG-01: URL-only cache data must never replace or retain an identity-bearing response.
        let cache = try makeCache()
        try await seed(cache)
        let descriptor = certificate()
        let personalized = Data("private fixture".utf8)
        let source = ScriptedDocumentSource { _ in
            [.responseHeader(try fixtureHeader(20, "image/png")), .body(personalized), .completed]
        }
        let retriever = makeRetriever(source.events, cache: cache, resolve: { _ in
            MainDocumentIdentity(descriptor: descriptor, credential: "fixture")
        })
        let events = await collect(retriever.events(for: try target()))
        XCTAssertEqual(source.requests.first?.credential, "fixture")
        XCTAssertEqual(body(events), personalized)
        XCTAssertEqual(responses(events).first?.offeredCertificate, descriptor)
        let anonymous = try await cache.freshResponse(for: url)
        XCTAssertEqual(anonymous?.body, bytes)

        try await cache.removeResponse(for: url)
        _ = await collect(retriever.events(for: try target()))
        let retained = try await cache.freshResponse(for: url)
        XCTAssertNil(retained)
    }

    func testSyntheticFaviconAbsenceIsNeverReplayedAsAPage() async throws {
        let cache = try makeCache()
        try await cache.store(GeminiFavicon.negativeResponse(for: url, receivedAt: Date()), resourceType: .favicon, lifetime: 600)
        let source = ScriptedDocumentSource { _ in [.responseHeader(try fixtureHeader()), .body(fixtureBytes), .completed] }
        let events = await collect(makeRetriever(source.events, cache: cache).events(for: try target()))
        XCTAssertEqual(source.requests.count, 1)
        XCTAssertEqual(body(events), bytes)
        assertCompleted(events)
    }

    func testProtocolOutcomesRemainDistinctAndEndWithoutAResponseBody() async throws {
        for status in [10, 11, 60, 61, 62, 40, 44, 51, 52, 59] {
            let source = ScriptedDocumentSource { _ in [.responseHeader(try fixtureHeader(status, "fixture")), .body(fixtureBytes)] }
            let events = await collect(makeRetriever(source.events).events(for: try target()))
            let response = try XCTUnwrap(responses(events).first)
            XCTAssertEqual(response.header.status, status)
            switch status {
            case 10, 11: XCTAssertEqual(response.outcome, .inputRequired(isSensitive: status == 11))
            case 60...62: XCTAssertEqual(response.outcome, .identityRequired)
            case 40, 44: XCTAssertEqual(response.outcome, .temporaryFailure)
            default: XCTAssertEqual(response.outcome, .permanentFailure)
            }
            XCTAssertTrue(body(events).isEmpty)
            assertCompleted(events)
        }
    }

    func testIdentityChallengePreservesAttemptedUnavailableAndInvalidMetadata() async throws {
        let valid = certificate()
        var invalid = valid
        invalid.notAfter = .distantPast
        for selection in [
            MainDocumentIdentity(descriptor: valid, credential: "fixture"),
            MainDocumentIdentity<String>(descriptor: valid, credential: nil),
            MainDocumentIdentity<String>(descriptor: invalid, credential: nil)
        ] {
            let source = ScriptedDocumentSource { _ in [.responseHeader(try fixtureHeader(61, "fixture"))] }
            let events = await collect(makeRetriever(source.events, resolve: { _ in selection }).events(for: try target()))
            let response = try XCTUnwrap(responses(events).first)
            XCTAssertEqual(response.matchedCertificate, selection.descriptor)
            XCTAssertEqual(response.offeredCertificate, selection.credential == nil ? nil : selection.descriptor)
        }
    }

    func testUnsupportedSuccessfulContentPassesThroughUnchanged() async throws {
        let source = ScriptedDocumentSource { _ in
            [.responseHeader(try fixtureHeader(20, " application/pgp-keys ; charset=utf-8")), .body(fixtureBytes), .completed]
        }
        let events = await collect(makeRetriever(source.events).events(for: try target()))
        XCTAssertEqual(responses(events).first?.outcome, .success(mimeType: "application/pgp-keys"))
        XCTAssertEqual(body(events), bytes)
        assertCompleted(events)
    }

    func testFailuresReportWhetherBodyBytesArrivedAndNeverCachePartialImages() async throws {
        for hasBody in [false, true] {
            let cache = try makeCache()
            let source = ScriptedDocumentSource(error: GeminiTransportError.responseTimedOut) { _ in
                [.responseHeader(try fixtureHeader(20, "image/png"))] + (hasBody ? [.body(fixtureBytes)] : [])
            }
            let events = await collect(makeRetriever(source.events, cache: cache).events(for: try target()))
            guard case .finished(.failed(let error, let receivedBody)) = events.last,
                  case GeminiTransportError.responseTimedOut = error else {
                return XCTFail("Expected original timeout failure")
            }
            XCTAssertEqual(receivedBody, hasBody)
            XCTAssertEqual(body(events), hasBody ? bytes : Data())
            let retained = try await cache.freshResponse(for: url)
            XCTAssertNil(retained)
        }
    }

    func testTrustDeclinedIsNotReportedAsAFailure() async throws {
        let source = ScriptedDocumentSource(error: GeminiTransportError.trustDeclined) { _ in [] }
        let events = await collect(makeRetriever(source.events).events(for: try target()))
        guard case .finished(.trustDeclined) = events.last else { return XCTFail("Expected declined trust") }
        XCTAssertTrue(body(events).isEmpty)
    }

    func testCancellationWhileConnectingAndMidBodyTerminatesSourceAndRejectsLateEvents() async throws {
        for inBody in [false, true] {
            let terminated = expectation(description: "Underlying source terminated")
            let observed = expectation(description: "Consumer reached cancellation point")
            let source = ControlledDocumentSource(onTermination: { terminated.fulfill() })
            let stream = makeRetriever(source.events).events(for: try target())
            let task = Task {
                var result: [MainDocumentEvent] = []
                for await event in stream {
                    result.append(event)
                    switch event {
                    case .connecting where !inBody: observed.fulfill()
                    case .body where inBody: observed.fulfill()
                    default: break
                    }
                }
                return result
            }
            source.continuation.yield(.connecting(CapsuleEndpoint(host: "example.com")))
            if inBody {
                source.continuation.yield(.responseHeader(try header()))
                source.continuation.yield(.body(bytes))
            }
            await fulfillment(of: [observed], timeout: 2)
            task.cancel()
            await fulfillment(of: [terminated], timeout: 2)
            if case .terminated = source.continuation.yield(.body(Data("late".utf8))) {} else {
                XCTFail("Cancelled source accepted late work")
            }
            let events = await task.value
            XCTAssertEqual(body(events), inBody ? bytes : Data())
        }
    }

    func testCancellationWhileTrustIsSuspendedCancelsAuthorizationWork() async throws {
        let entered = expectation(description: "Trust decision entered")
        let detached = expectation(description: "Trust decision cancelled")
        let terminated = expectation(description: "Transport cancelled")
        let decision = AsyncStream<Bool>.makeStream()
        decision.continuation.onTermination = { _ in detached.fulfill() }
        let authorize: GeminiTransport.TrustAuthorization = { _, _ in
            entered.fulfill()
            for await answer in decision.stream { return answer }
            return false
        }
        let identity = PresentedServerIdentity(endpoint: CapsuleEndpoint(host: "example.com"), publicKeySHA256: String(repeating: "a", count: 64))
        let retriever = MainDocumentRetriever<String>(transportEvents: { _, _, authorize in
            AsyncThrowingStream { continuation in
                let work = Task {
                    _ = await authorize(identity, Data())
                    guard !Task.isCancelled else { return }
                    continuation.yield(.body(Data("late".utf8)))
                }
                continuation.onTermination = { _ in work.cancel(); terminated.fulfill() }
            }
        }, cache: nil, resolveIdentity: { _ in nil }, authorizeTrust: authorize)
        let stream = retriever.events(for: try target())
        let task = Task { for await _ in stream {} }
        await fulfillment(of: [entered], timeout: 2)
        task.cancel()
        await fulfillment(of: [detached, terminated], timeout: 2)
        await task.value
    }

    func testClearDuringRetrievalRejectsOldGenerationWrite() async throws {
        let cache = try makeCache()
        let source = ControlledDocumentSource()
        let received = expectation(description: "Body received before clearing")
        let stream = makeRetriever(source.events, cache: cache).events(for: try target())
        let task = Task { await collect(stream) { if case .body = $0 { received.fulfill() } } }
        source.continuation.yield(.responseHeader(try header(20, "image/png")))
        source.continuation.yield(.body(bytes))
        await fulfillment(of: [received], timeout: 2)
        try await cache.removeResponses(since: nil)
        source.continuation.yield(.completed)
        let events = await task.value
        assertCompleted(events)
        let retained = try await cache.freshResponse(for: url)
        XCTAssertNil(retained)
    }

    private func target() throws -> GeminiRequestTarget { try GeminiRequestTarget(url.absoluteString) }
    private func header(_ status: Int = 20, _ meta: String = "text/gemini") throws -> GeminiResponseHeader {
        try GeminiResponseHeader(status: status, meta: meta)
    }
    private func certificate() -> ClientCertificateDescriptor {
        ClientCertificateDescriptor(id: UUID(), commonName: "Fixture", notBefore: .distantPast, notAfter: .distantFuture,
            certificateSHA256: String(repeating: "a", count: 64), publicKeySHA256: String(repeating: "b", count: 64))
    }
    private func makeCache() throws -> ContentCache { ContentCache(database: try ContentCacheDatabase(inMemory: ())) }
    private func seed(_ cache: ContentCache, receivedAt: Date = Date()) async throws {
        try await cache.store(ContentResponse(url: url, status: 20, meta: Data("image/png".utf8), mimeType: "image/png", body: bytes, receivedAt: receivedAt), resourceType: .image, lifetime: 86_400)
    }
    private func makeRetriever(
        _ source: @escaping MainDocumentRetriever<String>.TransportEvents,
        cache: ContentCache? = nil,
        resolve: @escaping MainDocumentRetriever<String>.IdentityResolver = { _ in nil }
    ) -> MainDocumentRetriever<String> {
        MainDocumentRetriever(transportEvents: source, cache: cache, resolveIdentity: resolve, authorizeTrust: { _, _ in true })
    }
    private func responses(_ events: [MainDocumentEvent]) -> [MainDocumentResponse] {
        events.compactMap { if case .response(let response) = $0 { return response }; return nil }
    }
    private func body(_ events: [MainDocumentEvent]) -> Data {
        events.reduce(into: Data()) { if case .body(let data) = $1 { $0.append(data) } }
    }
    private func assertCompleted(_ events: [MainDocumentEvent], file: StaticString = #filePath, line: UInt = #line) {
        let terminals = events.filter { if case .finished = $0 { return true }; return false }
        XCTAssertEqual(terminals.count, 1, file: file, line: line)
        guard case .finished(.completed) = events.last else { return XCTFail("Expected completed retrieval", file: file, line: line) }
    }
    private func responseSequence(_ events: [MainDocumentEvent]) -> [String] {
        events.compactMap {
            switch $0 {
            case .response(let metadata): "header:\(metadata.header.status):\(metadata.header.meta)"
            case .body(let bytes): "body:\(bytes.base64EncodedString())"
            case .finished(.completed): "completed"
            default: nil
            }
        }
    }
}

private final class ScriptedDocumentSource: @unchecked Sendable {
    struct Request: Sendable { let target: GeminiRequestTarget; let credential: String? }
    private let lock = NSLock()
    private var recorded: [Request] = []
    private let script: @Sendable (GeminiRequestTarget) throws -> [GeminiTransportEvent]
    private let error: (any Error)?
    var requests: [Request] { lock.withLock { recorded } }

    init(error: (any Error)? = nil, script: @escaping @Sendable (GeminiRequestTarget) throws -> [GeminiTransportEvent]) {
        self.script = script
        self.error = error
    }
    func events(_ target: GeminiRequestTarget, _ credential: String?, _ authorize: @escaping GeminiTransport.TrustAuthorization) -> AsyncThrowingStream<GeminiTransportEvent, any Error> {
        lock.withLock { recorded.append(Request(target: target, credential: credential)) }
        return AsyncThrowingStream { continuation in
            do {
                for event in try script(target) { continuation.yield(event) }
                continuation.finish(throwing: error)
            } catch { continuation.finish(throwing: error) }
        }
    }
}

private final class ControlledDocumentSource: Sendable {
    let stream: AsyncThrowingStream<GeminiTransportEvent, any Error>
    let continuation: AsyncThrowingStream<GeminiTransportEvent, any Error>.Continuation

    init(onTermination: @escaping @Sendable () -> Void = {}) {
        let pair = AsyncThrowingStream<GeminiTransportEvent, any Error>.makeStream()
        stream = pair.stream
        continuation = pair.continuation
        continuation.onTermination = { _ in onTermination() }
    }
    func events(_ target: GeminiRequestTarget, _ credential: String?, _ authorize: @escaping GeminiTransport.TrustAuthorization) -> AsyncThrowingStream<GeminiTransportEvent, any Error> { stream }
}

private func collect(
    _ stream: AsyncStream<MainDocumentEvent>,
    observe: @escaping @Sendable (MainDocumentEvent) -> Void = { _ in }
) async -> [MainDocumentEvent] {
    let finished = XCTestExpectation(description: "Retrieval terminates")
    let task = Task {
        var result: [MainDocumentEvent] = []
        for await event in stream { result.append(event); observe(event) }
        finished.fulfill()
        return result
    }
    let result = await XCTWaiter.fulfillment(of: [finished], timeout: 3)
    XCTAssertEqual(result, .completed)
    task.cancel()
    return await task.value
}
