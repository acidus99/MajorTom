import Foundation
import XCTest
@testable import MajorTomCore

final class OmnibarIndexTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func visit(_ address: String, title: String = "Page", daysAgo: Double = 0, count: Int = 1) -> BrowsingHistoryEntry {
        BrowsingHistoryEntry(url: URL(string: address)!, title: title,
                             visitedAt: now.addingTimeInterval(-daysAgo * 86_400), visitCount: count)
    }

    private func index(_ history: [BrowsingHistoryEntry], bookmarks: BookmarkCollection = BookmarkCollection(), tabs: [OmnibarTab] = []) -> OmnibarIndex {
        OmnibarIndex(history: history, bookmarks: bookmarks, tabs: tabs)
    }

    func testAddressQualityOutranksPopularityAndBookmarkBoost() {
        let exact = visit("gemini://garden.example/", daysAgo: 200)
        let prefix = visit("gemini://garden.example.net/", count: 50)
        let title = visit("gemini://other.example/", title: "garden.example Tips", count: 10_000)
        let result = index([title, prefix, exact]).search("garden.example", now: now)
        XCTAssertEqual(result.destinations.map(\.url), [exact.url, prefix.url, title.url])
        XCTAssertEqual(result.completedDestination?.url, exact.url)
    }

    func testAllWordsMatchAcrossTitleAndAddressRegardlessOfOrder() {
        let matching = visit("gemini://example.org/recipes/", title: "Gardening Notes")
        let incomplete = visit("gemini://elsewhere.org/", title: "Gardening")
        let result = index([matching, incomplete]).search("RECI gardening", now: now)
        XCTAssertEqual(result.destinations.map(\.url), [matching.url])
        XCTAssertNil(result.completion)
    }

    func testCaseAndAccentInsensitiveTitleMatchingDoesNotBecomeCompletion() {
        let entry = visit("gemini://example.org/", title: "Café Gardening")
        let result = index([entry]).search("CAFE", now: now)
        XCTAssertEqual(result.destinations.first?.url, entry.url)
        XCTAssertNil(result.completion)
    }

    func testAddressCompletionPreservesTypedPrefixAndScheme() {
        let search = index([visit("gemini://kennedy.gemi.dev/search")])
        XCTAssertEqual(search.search("KeNN", now: now).completion, "KeNNedy.gemi.dev/search")
        XCTAssertEqual(search.search("gemini://kenn", now: now).completion, "gemini://kennedy.gemi.dev/search")
        XCTAssertNil(search.search("https://kenn", now: now).completion)
        XCTAssertNil(search.search("kenn edy", now: now).completion)
        XCTAssertNil(search.search("gemi", now: now).completion)
    }

    func testExplicitPathsAndQueriesAreCaseSensitiveForCompletion() {
        // Prevent completion from changing a case-sensitive Gemini resource or query.
        let search = index([visit("gemini://example.org/Notes?Apple")])
        XCTAssertEqual(search.search("example.org/No", now: now).completion, "example.org/Notes?Apple")
        XCTAssertNil(search.search("example.org/no", now: now).completion)
        XCTAssertNil(search.search("example.org/Notes?a", now: now).completion)
        XCTAssertNil(search.search("example.org/Other", now: now).completion)
    }

    func testAnOpenTabAloneDoesNotCauseInlineCompletion() {
        let tab = OmnibarTab(id: UUID(), url: URL(string: "gemini://example.org/")!, title: "Example")
        let result = index([], tabs: [tab]).search("exam", now: now)
        XCTAssertEqual(result.destinations.first?.tabID, tab.id)
        XCTAssertNil(result.completion)
    }

    func testCurrentTabRetainsBookmarkAndHistoryWithoutOfferingASwitch() throws {
        // Prevents the omnibar from offering Switch to Tab for the tab being edited.
        let url = URL(string: "gemini://example.org/")!
        let tab = OmnibarTab(id: UUID(), url: url, title: "Current Page")
        let bookmarks = BookmarkCollection(folders: [BookmarkFolder(name: "Favorites", bookmarks: [
            Bookmark(title: "Saved Page", url: url)
        ])])
        let search = index([visit(url.absoluteString)], bookmarks: bookmarks, tabs: [tab])
        for query in ["", "exam", "saved"] {
            let result = search.search(query, excludingTabID: tab.id, now: now)
            let destination = try XCTUnwrap(result.destinations.first)
            XCTAssertEqual(destination.url, url)
            XCTAssertTrue(destination.isFavorite)
            XCTAssertNotNil(destination.visitedAt)
            XCTAssertNil(destination.tabID)
            XCTAssertNil(result.completedDestination?.tabID)
        }
        XCTAssertEqual(search.search("exam", excludingTabID: tab.id, now: now).completion, "example.org/")
    }

    func testCurrentTabAloneDoesNotProduceASuggestionWithoutOtherSources() {
        // A current-only internal or unfinished page is neither a switch nor history.
        let tab = OmnibarTab(id: UUID(), url: URL(string: "gemini://example.org/")!, title: "Current Page")
        let search = index([], tabs: [tab])
        XCTAssertTrue(search.search("exam", excludingTabID: tab.id, now: now).destinations.isEmpty)
        XCTAssertEqual(search.search("exam", now: now).destinations.first?.tabID, tab.id)
    }

    func testDuplicateURLCanSwitchToAnotherTabFromEitherField() {
        // Prevents fixing self-switches by hiding a URL that is also open elsewhere.
        let url = URL(string: "gemini://example.org/")!
        let first = OmnibarTab(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, url: url, title: "First")
        let second = OmnibarTab(id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!, url: url, title: "Second")
        let search = index([visit(url.absoluteString)], tabs: [second, first])
        for query in ["", "exam"] {
            let fromFirst = search.search(query, excludingTabID: first.id, now: now)
            let fromSecond = search.search(query, excludingTabID: second.id, now: now)
            XCTAssertEqual(fromFirst.destinations.count, 1)
            XCTAssertEqual(fromSecond.destinations.count, 1)
            XCTAssertEqual(fromFirst.destinations.first?.tabID, second.id)
            XCTAssertEqual(fromSecond.destinations.first?.tabID, first.id)
            if !query.isEmpty {
                XCTAssertEqual(fromFirst.completedDestination?.tabID, second.id)
                XCTAssertEqual(fromSecond.completedDestination?.tabID, first.id)
            }
        }
        XCTAssertEqual(search.search("exam", now: now).destinations.first?.tabID, first.id)
    }

    func testBookmarkAloneCanCompleteAndMatchesItsCustomTitle() {
        let bookmark = Bookmark(title: "My Garden", url: URL(string: "gemini://example.org/garden")!)
        let bookmarks = BookmarkCollection(folders: [BookmarkFolder(name: "Favorites", bookmarks: [bookmark])])
        let search = index([], bookmarks: bookmarks)
        XCTAssertEqual(search.search("example", now: now).completedDestination?.url, bookmark.url)
        XCTAssertEqual(search.search("my garden", now: now).destinations.first?.title, bookmark.title)
        XCTAssertTrue(search.search("my garden", now: now).destinations.first?.isFavorite == true)
    }

    func testSameDestinationCombinesSourcesWithoutLosingQueriesOrPathCase() {
        let url = URL(string: "gemini://example.org/Notes?q=one")!
        let bookmark = Bookmark(title: "Saved Name", url: url)
        let bookmarks = BookmarkCollection(folders: [BookmarkFolder(name: "Favorites", bookmarks: [bookmark])])
        let tab = OmnibarTab(id: UUID(), url: url, title: "Tab Name")
        let result = index([
            visit(url.absoluteString),
            visit("gemini://example.org/Notes?q=two"),
            visit("gemini://example.org/notes?q=one")
        ], bookmarks: bookmarks, tabs: [tab]).search("example", now: now)
        XCTAssertEqual(result.destinations.count, 3)
        let combined = result.destinations.first { $0.url == url }
        XCTAssertEqual(combined?.title, "Saved Name")
        XCTAssertEqual(combined?.tabID, tab.id)
        XCTAssertEqual(combined?.visitCount, 1)
        XCTAssertTrue(combined?.isBookmark == true)
    }

    func testRecencyFrequencyAndFavoritesInfluenceComparableMatches() {
        let old = visit("gemini://example.org/old", daysAgo: 200)
        let recent = visit("gemini://example.org/recent")
        let frequent = visit("gemini://example.org/frequent", count: 20)
        let result = index([old, recent, frequent]).search("example", now: now)
        XCTAssertEqual(result.destinations.map(\.url), [frequent.url, recent.url, old.url])

        let bookmark = Bookmark(title: "Favorite", url: recent.url)
        let bookmarks = BookmarkCollection(folders: [BookmarkFolder(name: "Favorites", bookmarks: [bookmark])])
        let tied = visit("gemini://example.org/aaa")
        XCTAssertEqual(index([recent, tied], bookmarks: bookmarks).search("example", now: now).destinations.first?.url, recent.url)
    }

    func testEmptyInputShowsAtMostSixFavoritesAndRecentDestinations() {
        let history = (0..<20).map { visit("gemini://example.org/\($0)", daysAgo: Double($0)) }
        let favorite = Bookmark(title: "Favorite", url: URL(string: "gemini://favorite.org/")!)
        let bookmarks = BookmarkCollection(folders: [BookmarkFolder(name: "Favorites", bookmarks: [favorite])])
        let result = index(history, bookmarks: bookmarks).search("  ", now: now)
        XCTAssertEqual(result.destinations.count, 6)
        XCTAssertEqual(result.destinations.first?.url, favorite.url)
        XCTAssertEqual(result.destinations.dropFirst().first?.url, history[0].url)
        XCTAssertNil(result.completion)
    }

    func testLimitAndOrderingAreIndependentOfSourceEnumeration() {
        let history = (0..<30).map { visit("gemini://example.org/\($0)") }
        let forward = index(history).search("example", now: now)
        let backward = index(history.reversed()).search("example", now: now)
        XCTAssertEqual(forward.destinations.count, 7)
        XCTAssertEqual(forward.destinations.map(\.id), backward.destinations.map(\.id))
        XCTAssertEqual(index(history).search("example", now: now, limit: 0).destinations.count, 0)
    }

    func testRebuildingAfterDeletionCannotReturnDeletedHistory() {
        let entry = visit("gemini://example.org/")
        XCTAssertNotNil(index([entry]).search("exam", now: now).completion)
        let rebuilt = index([]).search("exam", now: now)
        XCTAssertTrue(rebuilt.destinations.isEmpty)
        XCTAssertNil(rebuilt.completion)
    }

    func testLargeHistorySearchPerformance() {
        let history = (0..<50_000).map {
            visit("gemini://capsule\($0).example/notes/", title: "Gardening Notes \($0)", daysAgo: Double($0 % 365))
        }
        let search = index(history)
        measure {
            let results = search.search("garden", now: now)
            XCTAssertEqual(results.destinations.count, 7)
            XCTAssertNil(results.completion)
        }
    }
}
