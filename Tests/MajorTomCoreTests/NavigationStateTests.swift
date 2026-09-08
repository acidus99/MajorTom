import Foundation
import XCTest
@testable import MajorTomCore

final class NavigationStateTests: XCTestCase {
    private let one = URL(string: "gemini://example.com/one")!
    private let two = URL(string: "gemini://example.com/two")!
    private let three = URL(string: "gemini://example.com/three")!
    private let four = URL(string: "gemini://example.com/four")!
    private let epoch = Date(timeIntervalSince1970: 1_800_000_000)

    // MARK: - Committing

    func testFreshStateHasNoPositionAndNoTraversal() {
        let state = NavigationState()
        XCTAssertNil(state.committedURL)
        XCTAssertEqual(state.historyIndex, -1)
        XCTAssertFalse(state.canGoBack)
        XCTAssertFalse(state.canGoForward)
        XCTAssertTrue(state.isEmpty)
    }

    func testCommittingNewDestinationsBuildsHistory() {
        var state = NavigationState()
        XCTAssertTrue(state.commit(one, disposition: .new))
        XCTAssertTrue(state.commit(two, disposition: .new))

        XCTAssertEqual(state.history, [one, two])
        XCTAssertEqual(state.committedURL, two)
        XCTAssertTrue(state.canGoBack)
        XCTAssertFalse(state.canGoForward)
    }

    func testReloadAndTraversalLeaveHistoryUntouched() {
        var state = NavigationState()
        state.commit(one, disposition: .new)
        state.commit(two, disposition: .new)

        XCTAssertFalse(state.commit(two, disposition: .reload))
        XCTAssertFalse(state.commit(one, disposition: .traversal))
        XCTAssertEqual(state.history, [one, two])
        XCTAssertEqual(state.historyIndex, 1)
    }

    func testRecommittingTheCurrentEntryDoesNotGrowHistory() {
        // Following a link back to the page already on screen is not a new entry.
        var state = NavigationState()
        state.commit(one, disposition: .new)
        XCTAssertFalse(state.commit(one, disposition: .new))
        XCTAssertEqual(state.history, [one])
        XCTAssertEqual(state.historyIndex, 0)
    }

    func testNewDestinationTruncatesTheForwardBranch() {
        var state = NavigationState()
        state.commit(one, disposition: .new)
        state.commit(two, disposition: .new)
        state.commit(three, disposition: .new)
        _ = state.goBack()
        _ = state.goBack()

        state.commit(four, disposition: .new)

        XCTAssertEqual(state.history, [one, four])
        XCTAssertEqual(state.committedURL, four)
        XCTAssertFalse(state.canGoForward)
    }

    // MARK: - Traversal

    func testBackAndForwardWalkTheHistory() {
        var state = NavigationState()
        state.commit(one, disposition: .new)
        state.commit(two, disposition: .new)
        state.commit(three, disposition: .new)

        XCTAssertEqual(state.goBack(), two)
        XCTAssertEqual(state.goBack(), one)
        XCTAssertNil(state.goBack())
        XCTAssertEqual(state.committedURL, one)

        XCTAssertEqual(state.goForward(), two)
        XCTAssertEqual(state.goForward(), three)
        XCTAssertNil(state.goForward())
        XCTAssertEqual(state.committedURL, three)
    }

    func testTraversalOnEmptyHistoryIsRefused() {
        var state = NavigationState()
        XCTAssertNil(state.goBack())
        XCTAssertNil(state.goForward())
        XCTAssertEqual(state.historyIndex, -1)
    }

    func testHistoryMenuEntriesAreNearestFirstAndCanTraverseDirectly() {
        var state = NavigationState()
        state.commit(one, disposition: .new)
        state.updateCurrentMetadata(title: "One", favicon: "1️⃣")
        state.commit(two, disposition: .new)
        state.updateCurrentMetadata(title: "Two", favicon: "2️⃣")
        state.commit(three, disposition: .new)
        state.updateCurrentMetadata(title: "Three", favicon: "3️⃣")
        _ = state.goBack()

        XCTAssertEqual(state.backHistoryEntries.map(\.url), [one])
        XCTAssertEqual(state.forwardHistoryEntries.map(\.url), [three])
        XCTAssertEqual(state.backHistoryEntries.first?.title, "One")
        XCTAssertEqual(state.forwardHistoryEntries.first?.favicon, "3️⃣")

        // Regression: selecting a history-menu page must preserve the entries between
        // it and the former cursor as Forward history.
        XCTAssertEqual(state.go(toHistoryEntryWithID: state.backHistoryEntries[0].id), one)
        XCTAssertEqual(state.forwardHistoryEntries.map(\.url), [two, three])
    }

    // MARK: - Reading position

    func testScrollOffsetsAreKeyedByEntryNotByURL() {
        // Two visits to one address must be able to hold different positions.
        var state = NavigationState()
        state.commit(one, disposition: .new)
        state.recordScrollOffset(120)
        state.commit(two, disposition: .new)
        state.commit(one, disposition: .new)
        state.recordScrollOffset(940)

        XCTAssertEqual(state.scrollOffset(forHistoryIndex: 0), 120)
        XCTAssertEqual(state.scrollOffset(forHistoryIndex: 2), 940)
    }

    func testRepeatedURLVisitsKeepDifferentResponsesAndPresentationState() {
        var state = NavigationState()
        state.commit(one, disposition: .new)
        state.cache(page(url: one, bytes: 10))
        state.setImage(URL(string: "gemini://example.com/one.png")!, expanded: true)
        state.setPreformattedSection(3, collapsed: true)
        state.commit(two, disposition: .new)
        state.commit(one, disposition: .new)
        state.cache(page(url: one, bytes: 20))

        XCTAssertEqual(state.entries[0].page?.body.count, 10)
        XCTAssertEqual(state.entries[2].page?.body.count, 20)
        XCTAssertEqual(state.entries[0].presentation.collapsedPreformatted, [3])
        XCTAssertTrue(state.entries[2].presentation.collapsedPreformatted.isEmpty)
    }

    func testPresentationStateStoresOnlyExpandedImagesAndCollapsedPreformattedSections() {
        var state = NavigationState()
        let image = URL(string: "gemini://example.com/photo.png")!
        state.commit(one, disposition: .new)
        state.setImage(image, expanded: true)
        state.setImage(image, expanded: true)
        state.setPreformattedSection(1, collapsed: true)
        state.setPreformattedSection(3, collapsed: true)
        state.setPreformattedSection(1, collapsed: false)

        XCTAssertEqual(state.currentEntry?.presentation.expandedImages, [image])
        XCTAssertEqual(state.currentEntry?.presentation.collapsedPreformatted, [3])
    }

    func testPresentationStateDecodingSanitizesStoredValues() throws {
        let data = Data(#"{"version":1,"scrollY":-5,"expandedImages":["gemini://example.com/b.png","gemini://example.com/b.png","gemini://example.com/a.png"],"collapsedPreformatted":[3,-1,3,1]}"#.utf8)

        let state = try JSONDecoder().decode(HistoryPresentationState.self, from: data)

        XCTAssertEqual(state.scrollY, 0)
        XCTAssertEqual(state.expandedImages.map(\.lastPathComponent), ["a.png", "b.png"])
        XCTAssertEqual(state.collapsedPreformatted, [1, 3])
    }

    func testLegacyRestorationDataCreatesStableEntryModel() throws {
        let data = Data(#"{"history":["gemini://example.com/one"],"historyIndex":0,"cachedPages":[],"zoom":1,"title":"Old","scrollOffsets":{"0":42}}"#.utf8)

        let restored = try JSONDecoder().decode(RestoredTabState.self, from: data)

        XCTAssertEqual(restored.entries.map(\.url), [one])
        XCTAssertEqual(restored.entries[0].presentation.scrollY, 42)
        XCTAssertEqual(restored.title, "Old")
    }

    func testScrollOffsetIsClampedAtZero() {
        var state = NavigationState()
        state.commit(one, disposition: .new)
        state.recordScrollOffset(-50)
        XCTAssertEqual(state.scrollOffset, 0)
    }

    func testScrollOffsetIsIgnoredWithoutACommittedEntry() {
        var state = NavigationState()
        state.recordScrollOffset(300)
        XCTAssertEqual(state.scrollOffset, 0)
    }

    func testTruncatingTheForwardBranchDiscardsItsScrollOffsets() {
        var state = NavigationState()
        state.commit(one, disposition: .new)
        state.commit(two, disposition: .new)
        state.recordScrollOffset(500)
        _ = state.goBack()
        state.commit(three, disposition: .new)

        // Index 1 is now `three`, a page never scrolled. It must not inherit the offset
        // recorded for the `two` that used to occupy that slot.
        XCTAssertEqual(state.committedURL, three)
        XCTAssertEqual(state.scrollOffset, 0)
    }

    func testANewEntryStartsAtTheTop() {
        var state = NavigationState()
        state.commit(one, disposition: .new)
        state.recordScrollOffset(400)
        state.commit(two, disposition: .new)
        XCTAssertEqual(state.scrollOffset, 0)
    }

    // MARK: - Restoration

    func testRestoringClampsAnOutOfRangeIndex() {
        // A negative or oversized index from an older or corrupted blob used to leave
        // committedURL nil, which silently discarded the whole restored history.
        for badIndex in [-5, -1, 7, 99] {
            let state = NavigationState(restoring: RestoredTabState(
                history: [one, two, three],
                historyIndex: badIndex,
                cachedPages: [],
                zoom: 1
            ))
            XCTAssertEqual(state.history.count, 3, "index \(badIndex)")
            XCTAssertNotNil(state.committedURL, "index \(badIndex)")
            XCTAssertTrue(state.history.contains(state.committedURL!), "index \(badIndex)")
        }
    }

    func testRestoringAnEmptyHistoryLeavesNoPosition() {
        let state = NavigationState(restoring: RestoredTabState(
            history: [],
            historyIndex: 3,
            cachedPages: [],
            zoom: 1
        ))
        XCTAssertEqual(state.historyIndex, -1)
        XCTAssertNil(state.committedURL)
    }

    func testRestorationRoundTripsHistoryAndCache() {
        var state = NavigationState()
        state.commit(one, disposition: .new)
        state.cache(page(url: one, bytes: 10))
        state.commit(two, disposition: .new)
        state.cache(page(url: two, bytes: 20))

        let saved = state.restorationState(zoom: 1.3, title: "Two", documentTitle: "Two")
        let restored = NavigationState(restoring: saved)

        XCTAssertEqual(restored.history, [one, two])
        XCTAssertEqual(restored.committedURL, two)
        XCTAssertEqual(saved.zoom, 1.3)
        XCTAssertEqual(restored.entries[0].page?.body.count, 10)
        XCTAssertEqual(restored.entries[1].page?.body.count, 20)
    }

    func testRestorationRoundTripsScrollOffsetsByHistoryEntry() {
        var state = NavigationState()
        state.commit(one, disposition: .new)
        state.recordScrollOffset(125)
        state.commit(two, disposition: .new)
        state.recordScrollOffset(900)

        let restored = NavigationState(restoring: state.restorationState(
            zoom: 1,
            title: nil,
            documentTitle: nil
        ))

        XCTAssertEqual(restored.scrollOffset(forHistoryIndex: 0), 125)
        XCTAssertEqual(restored.scrollOffset(forHistoryIndex: 1), 900)
    }

    func testRestoringToleratesDuplicateCachedPages() {
        // Dictionary(uniqueKeysWithValues:) traps on a repeated key, and a session blob
        // is user data that may have been written by any earlier build.
        let state = NavigationState(restoring: RestoredTabState(
            history: [one],
            historyIndex: 0,
            cachedPages: [page(url: one, bytes: 5), page(url: one, bytes: 9)],
            zoom: 1
        ))
        XCTAssertNotNil(state.cachedPage(for: one))
    }

    // MARK: - Cache eviction

    func testCacheStaysWithinItsByteBudget() {
        var state = NavigationState(cacheByteBudget: 1_000)
        state.commit(one, disposition: .new)
        state.cache(page(url: one, bytes: 400, receivedAt: epoch))
        state.commit(two, disposition: .new)
        state.cache(page(url: two, bytes: 400, receivedAt: epoch.addingTimeInterval(1)))
        state.commit(three, disposition: .new)
        state.cache(page(url: three, bytes: 400, receivedAt: epoch.addingTimeInterval(2)))

        XCTAssertLessThanOrEqual(state.cachedByteCount, 1_000)
        // The oldest goes first.
        XCTAssertNil(state.cachedPage(for: one))
        XCTAssertNotNil(state.cachedPage(for: three))
    }

    func testThePageOnScreenIsNeverEvicted() {
        // Reload and the content-theme re-render both read the current entry back out of
        // the cache, so evicting it would blank the page in front of the reader.
        var state = NavigationState(cacheByteBudget: 100)
        state.commit(one, disposition: .new)
        state.cache(page(url: one, bytes: 5_000, receivedAt: epoch))

        XCTAssertNotNil(state.cachedPage(for: one))
        XCTAssertGreaterThan(state.cachedByteCount, 100)
    }

    func testAnUnboundedBudgetKeepsEverything() {
        var state = NavigationState()
        for (index, url) in [one, two, three, four].enumerated() {
            state.commit(url, disposition: .new)
            state.cache(page(url: url, bytes: 1_000, receivedAt: epoch.addingTimeInterval(Double(index))))
        }
        XCTAssertEqual(state.cachedPages.count, 4)
    }

    func testRemovingACachedPageLeavesHistoryIntact() {
        var state = NavigationState()
        state.commit(one, disposition: .new)
        state.cache(page(url: one, bytes: 10))
        state.removeCachedPage(for: one)

        XCTAssertNil(state.cachedPage(for: one))
        XCTAssertEqual(state.committedURL, one)
    }

    // MARK: - Helpers

    private func page(url: URL, bytes: Int, receivedAt: Date? = nil) -> CachedPage {
        CachedPage(
            url: url,
            mimeType: "text/gemini",
            body: Data(repeating: 0x41, count: bytes),
            completion: .complete,
            receivedAt: receivedAt ?? epoch,
            title: url.lastPathComponent
        )
    }
}
