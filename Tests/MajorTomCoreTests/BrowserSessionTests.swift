import Combine
import Foundation
import XCTest
@testable import MajorTomCore

final class BrowserSessionTests: XCTestCase {
    @MainActor
    func testStreamingNavigationPreservesExactBytesAndRecordsOneFinalVisit() async throws {
        let fixture = SessionFixture()
        defer { fixture.close() }
        fixture.session.openLink(fixture.a)
        await fixture.source.waitForRequests(1)
        let bytes = Data("# Café 🚀\r\nA body without a final newline".utf8)
        fixture.source.send(0, status: 20, meta: "text/gemini", chunks: [bytes.prefix(9), bytes.dropFirst(9)])
        await fixture.wait { !fixture.session.isLoading }
        XCTAssertEqual(fixture.session.committedURL, fixture.a)
        XCTAssertEqual(fixture.session.sourceBytes, bytes)
        XCTAssertEqual(fixture.session.title, "Café 🚀")
        XCTAssertEqual(fixture.session.restorationState.history.count, 1)
        XCTAssertEqual(fixture.visits.map(\.0), [fixture.a])
    }

    @MainActor
    func testSupersededRequestCannotReplaceNewerDocumentOrHistory() async throws {
        let fixture = SessionFixture()
        defer { fixture.close() }
        fixture.session.openLink(fixture.a)
        await fixture.source.waitForRequests(1)
        fixture.session.openLink(fixture.b)
        await fixture.source.waitForRequests(2)
        fixture.source.send(1, status: 20, meta: "text/plain", chunks: [Data("new bytes".utf8)])
        await fixture.wait { !fixture.session.isLoading }
        await fixture.source.waitForTermination(0)
        fixture.source.send(0, status: 20, meta: "text/gemini", chunks: [Data("# Stale title".utf8)])
        XCTAssertEqual(fixture.session.committedURL, fixture.b)
        XCTAssertEqual(fixture.session.sourceBytes, Data("new bytes".utf8))
        XCTAssertEqual(fixture.session.restorationState.history, [fixture.b])
        XCTAssertEqual(fixture.visits.map(\.0), [fixture.b])
    }

    @MainActor
    func testStopAfterHeaderKeepsExactPartialBodyAndDoesNotRecordSuccess() async throws {
        let fixture = SessionFixture()
        defer { fixture.close() }
        fixture.session.openLink(fixture.a)
        await fixture.source.waitForRequests(1)
        let partial = Data([0x23, 0x20, 0x41, 0x0A, 0xF0, 0x9F])
        fixture.source.send(0, status: 20, meta: "text/gemini", chunks: [partial], completes: false)
        await fixture.wait { fixture.session.sourceBytes == partial }
        fixture.session.stop()
        await fixture.source.waitForTermination(0)
        fixture.source.sendBody(0, Data([0x9A, 0x80]))
        XCTAssertFalse(fixture.session.isLoading)
        XCTAssertEqual(fixture.session.sourceBytes, partial)
        XCTAssertEqual(fixture.session.restorationState.cachedPages.first?.completion, .stopped)
        XCTAssertTrue(fixture.visits.isEmpty)
    }

    @MainActor
    func testShowSourceCancelsPendingNavigationAndRetainsOriginalResponse() async throws {
        let fixture = SessionFixture()
        defer { fixture.close() }
        let bytes = Data("# Original\n  exact source\n".utf8)
        await fixture.load(fixture.a, mime: "text/gemini", bytes: bytes)
        fixture.session.openLink(fixture.b)
        await fixture.source.waitForRequests(2)
        fixture.session.showPageSource()
        await fixture.source.waitForTermination(1)
        XCTAssertEqual(fixture.session.committedURL, ViewSourceURL.wrap(fixture.a))
        XCTAssertEqual(fixture.session.sourceBytes, bytes)
        fixture.source.send(1, status: 20, meta: "text/plain", chunks: [Data("late".utf8)])
        XCTAssertEqual(fixture.session.sourceBytes, bytes)
        XCTAssertFalse(fixture.session.canShowSource)
    }

    @MainActor
    func testRedirectsCommitAndRecordOnlyFinalDestination() async throws {
        let fixture = SessionFixture()
        defer { fixture.close() }
        fixture.session.openLink(fixture.a)
        await fixture.source.waitForRequests(1)
        fixture.source.send(0, status: 31, meta: fixture.b.absoluteString)
        await fixture.source.waitForRequests(2)
        fixture.source.send(1, status: 20, meta: "text/plain", chunks: [Data("destination".utf8)])
        await fixture.wait { !fixture.session.isLoading }
        XCTAssertEqual(fixture.session.restorationState.history, [fixture.b])
        XCTAssertEqual(fixture.visits.map(\.0), [fixture.b])
    }

    @MainActor
    func testEveryResponseTypeRestoresThroughHistoryWithoutRetrieval() async throws {
        for mime in ["text/gemini", "text/plain", "image/png", "application/pgp-keys"] {
            let fixture = SessionFixture()
            defer { fixture.close() }
            let bytes = Data("# Exact fixture for \(mime)\n".utf8)
            await fixture.load(fixture.a, mime: mime, bytes: bytes)
            await fixture.load(fixture.b, mime: "text/plain", bytes: Data("other".utf8))
            fixture.session.goBack()
            XCTAssertEqual(fixture.session.committedURL, fixture.a)
            XCTAssertEqual(fixture.session.sourceBytes, bytes)
            XCTAssertEqual(fixture.session.mimeType, mime)
            XCTAssertTrue(fixture.session.canGoForward)
            XCTAssertEqual(fixture.source.requestCount, 2)
            fixture.session.goForward()
            XCTAssertEqual(fixture.session.committedURL, fixture.b)
            XCTAssertEqual(fixture.source.requestCount, 2)
        }
    }

    @MainActor
    func testRestoringMidHistoryKeepsForwardEntriesZoomAndScrollWithoutRequest() async throws {
        let fixture = SessionFixture()
        defer { fixture.close() }
        await fixture.load(fixture.a, mime: "text/plain", bytes: Data("first".utf8))
        fixture.session.recordScrollPosition(240, from: fixture.session.activeWebDocumentURL)
        fixture.session.zoomIn()
        await fixture.load(fixture.b, mime: "text/plain", bytes: Data("second".utf8))
        fixture.session.goBack()
        let state = fixture.session.restorationState
        let restored = SessionFixture(restoredState: state)
        defer { restored.close() }
        restored.session.start()
        await restored.wait { restored.session.hasPresentedInitialDocument }
        XCTAssertEqual(restored.session.committedURL, fixture.a)
        XCTAssertEqual(restored.session.pageZoom, 1.1, accuracy: 0.0001)
        XCTAssertTrue(restored.session.canGoForward)
        XCTAssertEqual(restored.source.requestCount, 0)
        XCTAssertTrue(restored.surface.restoredOffsets.contains(240))
        restored.session.goForward()
        XCTAssertEqual(restored.session.committedURL, fixture.b)
    }

    @MainActor
    func testInputChallengeEndsRequestAndSubmissionStartsNormalQueryNavigation() async throws {
        let fixture = SessionFixture()
        defer { fixture.close() }
        fixture.session.openLink(fixture.a)
        await fixture.source.waitForRequests(1)
        fixture.source.send(0, status: 10, meta: "Fixture input")
        await fixture.wait { fixture.session.inputPrompt != nil }
        XCTAssertFalse(fixture.session.isLoading)
        XCTAssertNil(fixture.session.committedURL)
        let prompt = try XCTUnwrap(fixture.session.inputPrompt)
        fixture.session.submitInput("a b", for: prompt.id)
        await fixture.source.waitForRequests(2)
        XCTAssertEqual(fixture.source.targets.last?.url.query, "a%20b")
        fixture.source.send(1, status: 20, meta: "text/plain", chunks: [Data("answer".utf8)])
        await fixture.wait { !fixture.session.isLoading }
        XCTAssertNil(fixture.session.inputPrompt)
        XCTAssertEqual(fixture.session.restorationState.history.count, 1)
    }

    @MainActor
    func testStaleIdentityReplyCannotResumeReplacementNavigation() async throws {
        let fixture = SessionFixture()
        defer { fixture.close() }
        fixture.session.openLink(fixture.a)
        await fixture.source.waitForRequests(1)
        fixture.source.send(0, status: 60, meta: "Fixture identity")
        await fixture.wait { fixture.session.clientCertificatePrompt != nil }
        let prompt = try XCTUnwrap(fixture.session.clientCertificatePrompt)
        await fixture.load(fixture.b, mime: "text/plain", bytes: Data("replacement".utf8))
        fixture.session.resumeClientCertificatePrompt(id: prompt.id)
        XCTAssertEqual(fixture.source.requestCount, 2)
        XCTAssertEqual(fixture.session.committedURL, fixture.b)
    }

    @MainActor
    func testOldInputSheetCannotSubmitOrCancelReplacementPrompt() async throws {
        let fixture = SessionFixture()
        defer { fixture.close() }
        fixture.session.openLink(fixture.a)
        await fixture.source.waitForRequests(1)
        fixture.source.send(0, status: 10, meta: "First prompt")
        await fixture.wait { fixture.session.inputPrompt != nil }
        let oldPrompt = try XCTUnwrap(fixture.session.inputPrompt)
        fixture.session.openLink(fixture.b)
        await fixture.source.waitForRequests(2)
        fixture.source.send(1, status: 10, meta: "Replacement prompt")
        await fixture.wait { fixture.session.inputPrompt != nil }
        let current = try XCTUnwrap(fixture.session.inputPrompt)
        fixture.session.submitInput("stale response", for: oldPrompt.id)
        fixture.session.cancelInput(draft: "stale draft", for: oldPrompt.id)
        XCTAssertEqual(fixture.session.inputPrompt?.id, current.id)
        XCTAssertEqual(fixture.source.requestCount, 2)
        fixture.session.cancelInput(for: current.id)
        XCTAssertNil(fixture.session.inputPrompt)
    }

    @MainActor
    func testPendingBufferedResponseCannotReplaceDisplayedSourceBytes() async throws {
        for (mime, sourceView) in [("image/png", false), ("application/pgp-keys", false), ("text/gemini", true)] {
            let fixture = SessionFixture()
            defer { fixture.close() }
            let original = Data("# Displayed response\n".utf8)
            await fixture.load(fixture.a, mime: "text/plain", bytes: original)
            if sourceView {
                fixture.session.navigate(to: try GeminiRequestTarget(fixture.b.absoluteString),
                    disposition: .new, renderAsSource: true)
            } else { fixture.session.openLink(fixture.b) }
            await fixture.source.waitForRequests(2)
            fixture.source.send(1, status: 20, meta: mime, chunks: [Data("pending bytes".utf8)], completes: false)
            await fixture.wait { fixture.session.currentResponseMeta == mime && fixture.session.isLoading }
            XCTAssertEqual(fixture.session.committedURL, fixture.a)
            XCTAssertEqual(fixture.session.sourceBytes, original)
            fixture.session.stop()
            await fixture.source.waitForTermination(1)
            XCTAssertEqual(fixture.session.sourceBytes, original)
        }
    }

    @MainActor
    func testTrustDeclinedPreservesDisplayedPage() async throws {
        let fixture = SessionFixture()
        defer { fixture.close() }
        let bytes = Data("# Retained\n".utf8)
        await fixture.load(fixture.a, mime: "text/gemini", bytes: bytes)
        fixture.session.openLink(fixture.b)
        await fixture.source.waitForRequests(2)
        fixture.source.fail(1, GeminiTransportError.trustDeclined)
        await fixture.wait { !fixture.session.isLoading }
        XCTAssertEqual(fixture.session.committedURL, fixture.a)
        XCTAssertEqual(fixture.session.locationText, fixture.a.absoluteString)
        XCTAssertEqual(fixture.session.sourceBytes, bytes)
        XCTAssertEqual(fixture.session.restorationState.history, [fixture.a])
    }

    @MainActor
    func testHistoryPreviewHasIndependentSurfaceAndCommitsOnlyOnAcceptance() async throws {
        let fixture = SessionFixture()
        defer { fixture.close() }
        await fixture.load(fixture.a, mime: "text/gemini", bytes: Data("# First\n".utf8))
        await fixture.load(fixture.b, mime: "text/plain", bytes: Data("second".utf8))
        let document = fixture.session.activeWebDocumentURL
        let prepared = await fixture.session.prepareHistoryPreview(direction: .back)
        let token = try XCTUnwrap(prepared)
        XCTAssertEqual(fixture.session.activeWebDocumentURL, document)
        XCTAssertEqual(fixture.session.committedURL, fixture.b)
        XCTAssertEqual(fixture.source.requestCount, 2)
        fixture.session.cancelHistoryPreview()
        fixture.session.acceptHistoryPreview(id: token)
        XCTAssertEqual(fixture.session.committedURL, fixture.b)
        let preparedAgain = await fixture.session.prepareHistoryPreview(direction: .back)
        let accepted = try XCTUnwrap(preparedAgain)
        fixture.session.acceptHistoryPreview(id: accepted)
        XCTAssertEqual(fixture.session.committedURL, fixture.a)
        XCTAssertEqual(fixture.source.requestCount, 2)
    }

    @MainActor
    func testLatePresentationCompletionCannotRevealReplacementDocument() async throws {
        let fixture = SessionFixture()
        defer { fixture.close() }
        fixture.surface.holdsLoadCompletion = true
        await fixture.load(fixture.a, mime: "text/plain", bytes: Data("first".utf8))
        let oldDocument = try XCTUnwrap(fixture.session.activeWebDocumentURL)
        await fixture.surface.waitForHeldLoad(oldDocument)
        await fixture.load(fixture.b, mime: "text/plain", bytes: Data("second".utf8))
        let replacement = try XCTUnwrap(fixture.session.activeWebDocumentURL)
        await fixture.surface.waitForHeldLoad(replacement)
        fixture.surface.releaseLoad(oldDocument)
        await fixture.surface.waitForCompletedLoad(oldDocument)
        XCTAssertFalse(fixture.session.hasPresentedInitialDocument)
        XCTAssertEqual(fixture.session.activeWebDocumentURL, replacement)
        fixture.surface.releaseLoad(replacement)
        await fixture.wait { fixture.session.hasPresentedInitialDocument }
    }

    @MainActor
    func testLocalFilesDataImagesAndInternalPagesAllAbandonPendingRequest() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("fixture.gmi")
        let bytes = Data("# Local fixture\n".utf8)
        try bytes.write(to: file)
        for destination in [file, URL(string: "data:image/png;base64,AQID")!, InternalPage.allCases[0].url] {
            let fixture = SessionFixture()
            defer { fixture.close() }
            fixture.session.openLink(fixture.a)
            await fixture.source.waitForRequests(1)
            if let page = InternalPage.page(for: destination) { fixture.session.showInternalPage(page) }
            else { fixture.session.openLink(destination) }
            await fixture.source.waitForTermination(0)
            fixture.source.send(0, status: 20, meta: "text/plain", chunks: [Data("late".utf8)])
            XCTAssertEqual(fixture.session.committedURL, destination)
            XCTAssertEqual(fixture.session.restorationState.history, [destination])
            if destination == file { XCTAssertEqual(fixture.session.sourceBytes, bytes) }
        }
    }
}

@MainActor
private final class SessionFixture {
    let a = URL(string: "gemini://example.invalid/a")!
    let b = URL(string: "gemini://example.invalid/b")!
    let source = SessionEventSource()
    let surface = SessionPresentationSurface()
    let session: BrowserSession
    var visits: [(URL, String?)] = []

    init(restoredState: RestoredTabState? = nil) {
        let source = source
        let retriever = GeminiResourceRetriever<ClientTLSIdentity>(
            transportEvents: { target, identity, _, _ in
                XCTAssertNil(identity)
                return source.events(target)
            }, cache: nil, resolveIdentity: { _ in nil }, authorizeTrust: { _, _ in true }
        )
        var services = BrowserSessionServices(preferences: { BrowserPreferences() }, retriever: retriever)
        var record: ((URL, String?) -> Void)?
        services.recordVisit = { record?($0, $1) }
        session = BrowserSession(services: services, presentation: surface, restoredState: restoredState)
        record = { [weak self] in self?.visits.append(($0, $1)) }
    }

    func close() { session.stop(); source.finishAll(); surface.finishAll() }

    func load(_ url: URL, mime: String, bytes: Data) async {
        let count = source.requestCount + 1
        session.openLink(url)
        await source.waitForRequests(count)
        source.send(count - 1, status: 20, meta: mime, chunks: [bytes])
        await wait { !self.session.isLoading }
    }

    func wait(_ predicate: @escaping @MainActor () -> Bool) async {
        let reached = XCTestExpectation(description: "Session reached expected state")
        var fulfilled = false
        let check = {
            if !fulfilled, predicate() { fulfilled = true; reached.fulfill() }
        }
        let observation = session.objectWillChange.sink { _ in Task { @MainActor in check() } }
        check()
        let result = await XCTWaiter.fulfillment(of: [reached], timeout: 2)
        observation.cancel()
        XCTAssertEqual(result, .completed)
        XCTAssertTrue(predicate())
    }
}

@MainActor
private final class SessionPresentationSurface: BrowserPresentationSink {
    private var streams: [URL: AsyncThrowingStream<Data, any Error>] = [:]
    private var continuations: [AsyncThrowingStream<Data, any Error>.Continuation] = []
    var documents: [URL: Data] = [:]
    var previews: [Data] = []
    var restoredOffsets: [Double] = []
    var holdsLoadCompletion = false
    private var loadGates: [URL: AsyncStream<Void>.Continuation] = [:]
    private var heldLoads: Set<URL> = []
    private var completedLoads: Set<URL> = []
    private var loadObservers: [(URL, Bool, XCTestExpectation)] = []
    func createDocument() -> BrowserPresentationDocument {
        let stream = AsyncThrowingStream<Data, any Error>.makeStream()
        let url = URL(string: "fixture-document://document/\(UUID())")!
        streams[url] = stream.stream
        continuations.append(stream.continuation)
        return BrowserPresentationDocument(url: url, continuation: stream.continuation)
    }
    func invalidateDocument() {}
    func loadDocument(at url: URL) async throws {
        guard let stream = streams.removeValue(forKey: url) else { throw URLError(.resourceUnavailable) }
        for try await bytes in stream { documents[url, default: Data()].append(bytes) }
        if holdsLoadCompletion {
            let gate = AsyncStream<Void>.makeStream()
            loadGates[url] = gate.continuation
            heldLoads.insert(url)
            notifyLoads()
            for await _ in gate.stream {}
        }
        completedLoads.insert(url)
        notifyLoads()
    }
    func updateDocument(_ update: BrowserDocumentUpdate, at url: URL) async {
        if case .restoreScroll(let offset) = update { restoredOffsets.append(offset) }
    }
    func createImageResource() -> BrowserPresentationResource {
        BrowserPresentationResource(url: URL(string: "fixture-resource://image/\(UUID())")!, finish: { _ in })
    }
    func showHistoryPreview(_ data: Data, entry: BackForwardEntry) async throws { previews.append(data) }
    func discardHistoryPreview() { previews.removeAll() }
    func finishAll() {
        for continuation in continuations { continuation.finish() }
        for gate in loadGates.values { gate.finish() }
        streams.removeAll()
    }
    func releaseLoad(_ url: URL) { loadGates.removeValue(forKey: url)?.finish() }
    func waitForHeldLoad(_ url: URL) async { await waitForLoad(url, completed: false) }
    func waitForCompletedLoad(_ url: URL) async { await waitForLoad(url, completed: true) }
    private func waitForLoad(_ url: URL, completed: Bool) async {
        let reached = XCTestExpectation(description: "Presentation completion gate")
        loadObservers.append((url, completed, reached))
        notifyLoads()
        let result = await XCTWaiter.fulfillment(of: [reached], timeout: 2)
        XCTAssertEqual(result, .completed)
    }
    private func notifyLoads() {
        let ready = loadObservers.filter { $0.1 ? completedLoads.contains($0.0) : heldLoads.contains($0.0) }
        loadObservers.removeAll { $0.1 ? completedLoads.contains($0.0) : heldLoads.contains($0.0) }
        for (_, _, observer) in ready { observer.fulfill() }
    }
}

private final class SessionEventSource: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [(GeminiRequestTarget, AsyncThrowingStream<GeminiTransportEvent, any Error>.Continuation)] = []
    private var terminated = Set<Int>()
    private var requestWaiters: [(Int, XCTestExpectation)] = []
    private var terminationWaiters: [(Int, XCTestExpectation)] = []
    var requestCount: Int { lock.withLock { requests.count } }
    var targets: [GeminiRequestTarget] { lock.withLock { requests.map(\.0) } }
    func events(_ target: GeminiRequestTarget) -> AsyncThrowingStream<GeminiTransportEvent, any Error> {
        let stream = AsyncThrowingStream<GeminiTransportEvent, any Error>.makeStream()
        let index = lock.withLock {
            let index = requests.count
            requests.append((target, stream.continuation))
            let ready = requestWaiters.filter { requests.count >= $0.0 }
            requestWaiters.removeAll { requests.count >= $0.0 }
            for (_, waiter) in ready { waiter.fulfill() }
            return index
        }
        stream.continuation.onTermination = { [weak self] _ in
            guard let self else { return }
            lock.withLock {
                terminated.insert(index)
                let ready = terminationWaiters.filter { $0.0 == index }
                terminationWaiters.removeAll { $0.0 == index }
                for (_, waiter) in ready { waiter.fulfill() }
            }
        }
        return stream.stream
    }
    func send(_ index: Int, status: Int, meta: String, chunks: [Data] = [], completes: Bool = true) {
        guard let continuation = lock.withLock({ requests.indices.contains(index) ? requests[index].1 : nil }) else {
            XCTFail("Missing controlled request"); return
        }
        continuation.yield(.responseHeader(try! GeminiResponseHeader(status: status, meta: meta)))
        for chunk in chunks { continuation.yield(.body(chunk)) }
        if completes { continuation.yield(.completed); continuation.finish() }
    }
    func sendBody(_ index: Int, _ bytes: Data) { lock.withLock { requests[index].1 }.yield(.body(bytes)) }
    func fail(_ index: Int, _ error: any Error) { lock.withLock { requests[index].1 }.finish(throwing: error) }
    func finishAll() { for request in lock.withLock({ requests }) { request.1.finish() } }
    func waitForRequests(_ count: Int) async {
        let reached = XCTestExpectation(description: "Controlled requests: \(count)")
        lock.withLock {
            if requests.count >= count { reached.fulfill() } else { requestWaiters.append((count, reached)) }
        }
        let result = await XCTWaiter.fulfillment(of: [reached], timeout: 2)
        XCTAssertEqual(result, .completed)
    }
    func waitForTermination(_ index: Int) async {
        let reached = XCTestExpectation(description: "Controlled request terminated")
        lock.withLock {
            if terminated.contains(index) { reached.fulfill() } else { terminationWaiters.append((index, reached)) }
        }
        let result = await XCTWaiter.fulfillment(of: [reached], timeout: 2)
        XCTAssertEqual(result, .completed)
    }
}
