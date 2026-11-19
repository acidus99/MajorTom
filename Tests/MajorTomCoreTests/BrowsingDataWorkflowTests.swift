import Foundation
import XCTest
@testable import MajorTomCore

final class BrowsingDataWorkflowTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let url = URL(string: "gemini://example.invalid/page")!

    @MainActor
    func testContentClearScrubsSessionsAndRejectsLateReusableWritesWithoutDeletingHistory() async throws {
        let cache = ContentCache(database: try ContentCacheDatabase(inMemory: ()))
        let response = ContentResponse(url: url, status: 20, meta: Data("image/png".utf8), mimeType: "image/png",
            body: Data([1, 2, 3]), receivedAt: now)
        try await cache.store(response, resourceType: .image, lifetime: 60, now: now)
        let generation = await cache.writeGeneration
        let session = makeSession()
        let probe = ClearingProbe()
        var services = services(probe)
        services.clearReusableResponses = { cutoff in
            probe.steps.append("cache")
            try await cache.removeResponses(since: cutoff)
        }
        services.persistLiveSession = {
            probe.steps.append("session")
            XCTAssertNil(session.restorationState.entries.first?.page)
        }
        let workflow = BrowsingDataWorkflow(services: services)
        workflow.register(session)
        try await workflow.clear(.emptyCaches, range: .everything)
        XCTAssertEqual(probe.steps, ["cache", "session", "visits"])
        XCTAssertEqual(session.restorationState.history, [url])
        XCTAssertEqual(session.restorationState.entries.first?.presentation.scrollY, 240)
        let late = try await cache.store(response, resourceType: .image, lifetime: 60, now: now, generation: generation)
        XCTAssertEqual(late, .discarded)
        let retained = try await cache.freshResponse(for: url, now: now)
        XCTAssertNil(retained)
        XCTAssertFalse(workflow.isClearing)
    }

    @MainActor
    func testBrowsingClearUsesOneCapturedCutoffAndIncludesHistoryAndDrafts() async throws {
        let probe = ClearingProbe()
        let workflow = BrowsingDataWorkflow(services: services(probe))
        try await workflow.clear(.clearBrowsingData, range: .last24Hours)
        XCTAssertEqual(probe.steps, ["cache", "session", "visits", "history", "drafts"])
        XCTAssertEqual(probe.cutoffs.count, 4)
        XCTAssertTrue(probe.cutoffs.allSatisfy { $0 == now.addingTimeInterval(-86_400) })
    }

    @MainActor
    func testSessionRegisteredDuringSuspendedClearCannotRestoreOldBytes() async throws {
        let probe = ClearingProbe()
        let gate = AsyncStream<Void>.makeStream()
        defer { gate.continuation.finish() }
        let entered = expectation(description: "Sanitized session write entered")
        var dependencies = services(probe)
        dependencies.persistLiveSession = {
            entered.fulfill()
            for await _ in gate.stream {}
        }
        let workflow = BrowsingDataWorkflow(services: dependencies)
        let first = makeSession()
        workflow.register(first)
        let clearing = Task { try await workflow.clear(.emptyCaches, range: .everything) }
        defer { clearing.cancel() }
        let ready = await XCTWaiter.fulfillment(of: [entered], timeout: 2)
        XCTAssertEqual(ready, .completed)
        let openedDuringClear = makeSession()
        XCTAssertNotNil(openedDuringClear.restorationState.entries.first?.page)
        workflow.register(openedDuringClear)
        XCTAssertNil(openedDuringClear.restorationState.entries.first?.page)
        do {
            try await workflow.clear(.emptyCaches, range: .everything)
            XCTFail("A second operation must not report success while the first is running")
        } catch BrowsingDataWorkflowError.operationInProgress {}
        gate.continuation.finish()
        try await value(clearing)
        XCTAssertFalse(workflow.isClearing)
        let later = makeSession()
        workflow.register(later)
        XCTAssertNotNil(later.restorationState.entries.first?.page, "The boundary ends with the confirmed operation")
    }

    @MainActor
    func testFailureReportsItsStageAndAlwaysReleasesSessionBoundary() async throws {
        let probe = ClearingProbe()
        var dependencies = services(probe)
        dependencies.clearHistory = { _ in probe.steps.append("history"); throw FixtureFailure.refused }
        let workflow = BrowsingDataWorkflow(services: dependencies)
        let session = makeSession()
        workflow.register(session)
        do {
            try await workflow.clear(.clearBrowsingData, range: .everything)
            XCTFail("A partial clear must report failure")
        } catch BrowsingDataWorkflowError.failed(stage: .history, underlying: let error) {
            XCTAssertTrue(error is FixtureFailure)
        }
        XCTAssertEqual(probe.steps, ["cache", "session", "visits", "history"])
        XCTAssertFalse(workflow.isClearing)
        let later = makeSession()
        workflow.register(later)
        XCTAssertNotNil(later.restorationState.entries.first?.page)
    }

    @MainActor
    private func services(_ probe: ClearingProbe) -> BrowsingDataServices {
        let now = now
        return BrowsingDataServices(
            clearReusableResponses: { probe.steps.append("cache"); probe.cutoffs.append($0) },
            persistLiveSession: { probe.steps.append("session") },
            clearSavedVisits: { _, cutoff in probe.steps.append("visits"); probe.cutoffs.append(cutoff) },
            clearHistory: { probe.steps.append("history"); probe.cutoffs.append($0) },
            clearInputDrafts: { probe.steps.append("drafts"); probe.cutoffs.append($0) }, now: { now }
        )
    }

    @MainActor
    private func makeSession() -> BrowserSession {
        let page = CachedPage(url: url, mimeType: "text/plain", body: Data("retained fixture".utf8),
            completion: .complete, receivedAt: now)
        let state = RestoredTabState(history: [url], historyIndex: 0, cachedPages: [page], zoom: 1.2,
            scrollOffsets: [0: 240])
        let retriever = GeminiResourceRetriever<ClientTLSIdentity>(transportEvents: { _, _, _, _ in
            AsyncThrowingStream { $0.finish() }
        }, cache: nil, resolveIdentity: { _ in nil }, authorizeTrust: { _, _ in false })
        return BrowserSession(services: BrowserSessionServices(preferences: { BrowserPreferences() }, retriever: retriever),
            presentation: ClearingPresentation(), restoredState: state)
    }

    @MainActor
    private func value(_ task: Task<Void, any Error>) async throws {
        let finished = expectation(description: "Confirmed clear finished")
        let observer = Task { _ = await task.result; finished.fulfill() }
        let result = await XCTWaiter.fulfillment(of: [finished], timeout: 2)
        if result != .completed { task.cancel() }
        XCTAssertEqual(result, .completed)
        _ = await observer.value
        try await task.value
    }
}

@MainActor
private final class ClearingProbe {
    var steps: [String] = []
    var cutoffs: [Date?] = []
}

private enum FixtureFailure: Error { case refused }

@MainActor
private final class ClearingPresentation: BrowserPresentationSink {
    func createDocument() -> BrowserPresentationDocument {
        let stream = AsyncThrowingStream<Data, any Error>.makeStream()
        stream.continuation.finish()
        return BrowserPresentationDocument(url: URL(string: "fixture-document://unused")!, continuation: stream.continuation)
    }
    func invalidateDocument() {}
    func loadDocument(at url: URL) async throws {}
    func updateDocument(_ update: BrowserDocumentUpdate, at url: URL) async {}
    func createImageResource() -> BrowserPresentationResource {
        BrowserPresentationResource(url: URL(string: "fixture-resource://unused")!, finish: { _ in })
    }
    func showHistoryPreview(_ data: Data, entry: BackForwardEntry) async throws {}
    func discardHistoryPreview() {}
}
