import Foundation
import XCTest
@testable import MajorTomCore

final class BookmarkCollectionTests: XCTestCase {
    private let first = URL(string: "gemini://example.com/one")!
    private let second = URL(string: "gemini://example.com/two")!

    func testANewCollectionHasAFavoritesFolder() {
        let collection = BookmarkCollection()
        XCTAssertEqual(collection.folders.count, 1)
        XCTAssertEqual(collection.folders[0].name, BookmarkCollection.favoritesName)
        XCTAssertTrue(collection.favorites.bookmarks.isEmpty)
    }

    /// Favourites is what the Favourites bar shows, so it has to exist and has to be first
    /// even if a stored document says otherwise.
    func testFavoritesIsMovedToTheFrontWhenLoadedOutOfOrder() {
        let collection = BookmarkCollection(folders: [
            BookmarkFolder(name: "Reading"),
            BookmarkFolder(name: BookmarkCollection.favoritesName)
        ])
        XCTAssertEqual(collection.folders[0].name, BookmarkCollection.favoritesName)
        XCTAssertEqual(collection.folders.count, 2)
    }

    func testFavoritesIsSynthesisedWhenMissing() {
        let collection = BookmarkCollection(folders: [BookmarkFolder(name: "Reading")])
        XCTAssertEqual(collection.folders[0].name, BookmarkCollection.favoritesName)
        XCTAssertEqual(collection.folders.count, 2)
    }

    func testAddingFilesIntoFavoritesByDefault() {
        var collection = BookmarkCollection()
        collection.add(title: "One", url: first)
        XCTAssertEqual(collection.favorites.bookmarks.map(\.title), ["One"])
        XCTAssertTrue(collection.contains(url: first))
    }

    func testAddingIntoANamedFolder() {
        var collection = BookmarkCollection()
        let folder = collection.addFolder(named: "Reading")!
        collection.add(title: "One", url: first, toFolderWith: folder.id)
        XCTAssertTrue(collection.favorites.bookmarks.isEmpty)
        XCTAssertEqual(collection.folders[1].bookmarks.map(\.title), ["One"])
    }

    /// Bookmarking the same address twice should update the entry rather than duplicate it.
    func testRebookmarkingReplacesRatherThanDuplicating() {
        var collection = BookmarkCollection()
        collection.add(title: "Original", url: first)
        let folder = collection.addFolder(named: "Reading")!
        collection.add(title: "Renamed", url: first, toFolderWith: folder.id)

        XCTAssertEqual(collection.allBookmarks.count, 1)
        XCTAssertEqual(collection.allBookmarks[0].title, "Renamed")
        XCTAssertEqual(collection.folder(containing: collection.allBookmarks[0].id)?.name, "Reading")
    }

    /// The identity and original date survive a re-bookmark, so a reordered list does not
    /// jump around and "added" stays meaningful.
    func testRebookmarkingKeepsIdentityAndAddedDate() {
        var collection = BookmarkCollection()
        let original = collection.add(title: "One", url: first, at: Date(timeIntervalSince1970: 100))
        let updated = collection.add(title: "One Again", url: first, at: Date(timeIntervalSince1970: 900))
        XCTAssertEqual(updated.id, original.id)
        XCTAssertEqual(updated.addedAt, original.addedAt)
    }

    func testRemovingByIdentifier() {
        var collection = BookmarkCollection()
        let bookmark = collection.add(title: "One", url: first)
        collection.remove(bookmarkWith: bookmark.id)
        XCTAssertFalse(collection.contains(url: first))
    }

    func testRemovingByURL() {
        var collection = BookmarkCollection()
        collection.add(title: "One", url: first)
        collection.remove(urlsMatching: first)
        XCTAssertTrue(collection.allBookmarks.isEmpty)
    }

    func testRenaming() {
        var collection = BookmarkCollection()
        let bookmark = collection.add(title: "One", url: first)
        collection.rename(bookmarkWith: bookmark.id, to: "  Renamed  ")
        XCTAssertEqual(collection.bookmark(with: bookmark.id)?.title, "Renamed")
    }

    func testRenamingToBlankIsIgnored() {
        var collection = BookmarkCollection()
        let bookmark = collection.add(title: "One", url: first)
        collection.rename(bookmarkWith: bookmark.id, to: "   ")
        XCTAssertEqual(collection.bookmark(with: bookmark.id)?.title, "One")
    }

    func testMovingBetweenFolders() {
        var collection = BookmarkCollection()
        let bookmark = collection.add(title: "One", url: first)
        let folder = collection.addFolder(named: "Reading")!
        collection.move(bookmarkWith: bookmark.id, toFolderWith: folder.id)
        XCTAssertTrue(collection.favorites.bookmarks.isEmpty)
        XCTAssertEqual(collection.folder(containing: bookmark.id)?.id, folder.id)
    }

    func testMovingToAnUnknownFolderDoesNothing() {
        var collection = BookmarkCollection()
        let bookmark = collection.add(title: "One", url: first)
        collection.move(bookmarkWith: bookmark.id, toFolderWith: UUID())
        XCTAssertEqual(collection.folder(containing: bookmark.id)?.id, collection.favoritesID)
    }

    func testReordering() {
        var collection = BookmarkCollection()
        let one = collection.add(title: "One", url: first)
        let two = collection.add(title: "Two", url: second)
        collection.reorder(folderWith: collection.favoritesID, to: [two.id, one.id])
        XCTAssertEqual(collection.favorites.bookmarks.map(\.title), ["Two", "One"])
    }

    /// A reorder computed from a stale view must never drop bookmarks it did not mention.
    func testReorderingKeepsUnmentionedBookmarks() {
        var collection = BookmarkCollection()
        let one = collection.add(title: "One", url: first)
        collection.add(title: "Two", url: second)
        collection.reorder(folderWith: collection.favoritesID, to: [one.id])
        XCTAssertEqual(collection.favorites.bookmarks.count, 2)
        XCTAssertEqual(collection.favorites.bookmarks.first?.title, "One")
    }

    // MARK: - Folders

    func testFolderNamesAreTrimmedAndBlankOnesRefused() {
        var collection = BookmarkCollection()
        XCTAssertNotNil(collection.addFolder(named: "  Reading  "))
        XCTAssertNil(collection.addFolder(named: "   "))
        XCTAssertEqual(collection.folders.map(\.name), [BookmarkCollection.favoritesName, "Reading"])
    }

    func testRemovingAFolderTakesItsBookmarks() {
        var collection = BookmarkCollection()
        let folder = collection.addFolder(named: "Reading")!
        collection.add(title: "One", url: first, toFolderWith: folder.id)
        collection.removeFolder(with: folder.id)
        XCTAssertEqual(collection.folders.count, 1)
        XCTAssertFalse(collection.contains(url: first))
    }

    func testEditingAnAddressPreservesBookmarkIdentityTitleAndPosition() {
        var collection = BookmarkCollection()
        let bookmark = collection.add(title: "One", url: first)
        let secondBookmark = collection.add(title: "Two", url: second)
        let replacement = URL(string: "gemini://example.com/revised")!

        collection.updateAddress(bookmarkWith: bookmark.id, to: replacement)

        XCTAssertEqual(collection.favorites.bookmarks.map(\.id), [bookmark.id, secondBookmark.id])
        XCTAssertEqual(collection.favorites.bookmarks[0].title, "One")
        XCTAssertEqual(collection.favorites.bookmarks[0].url, replacement)
    }

    func testFavoritesCannotBeRemovedOrRenamed() {
        var collection = BookmarkCollection()
        collection.removeFolder(with: collection.favoritesID)
        collection.renameFolder(with: collection.favoritesID, to: "Something Else")
        XCTAssertEqual(collection.folders.count, 1)
        XCTAssertEqual(collection.folders[0].name, BookmarkCollection.favoritesName)
    }

    func testRenamingAFolder() {
        var collection = BookmarkCollection()
        let folder = collection.addFolder(named: "Reading")!
        collection.renameFolder(with: folder.id, to: "Later")
        XCTAssertEqual(collection.folders[1].name, "Later")
    }
}

final class BookmarkStoreTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MajorTomBookmarkTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeStore() -> BookmarkStore {
        BookmarkStore(fileURL: directory.appendingPathComponent("bookmarks.json"))
    }

    func testAnEmptyStoreStartsWithFavorites() async {
        let collection = await makeStore().collection()
        XCTAssertEqual(collection.folders.map(\.name), [BookmarkCollection.favoritesName])
    }

    func testUpdatesPersistAndReload() async throws {
        let url = URL(string: "gemini://example.com/page")!
        let store = makeStore()
        _ = try await store.update { $0.add(title: "Page", url: url) }

        let reopened = makeStore()
        let collection = await reopened.collection()
        XCTAssertTrue(collection.contains(url: url))
        XCTAssertEqual(collection.favorites.bookmarks.first?.title, "Page")
    }

    func testUpdateReturnsTheNewCollection() async throws {
        let store = makeStore()
        let updated = try await store.update { $0.addFolder(named: "Reading") }
        XCTAssertEqual(updated.folders.map(\.name), [BookmarkCollection.favoritesName, "Reading"])
    }

    func testFoldersAndOrderSurviveAReload() async throws {
        let store = makeStore()
        let one = URL(string: "gemini://example.com/one")!
        let two = URL(string: "gemini://example.com/two")!
        let collection = try await store.update {
            $0.add(title: "One", url: one)
            $0.add(title: "Two", url: two)
        }
        let ordered = [collection.favorites.bookmarks[1].id, collection.favorites.bookmarks[0].id]
        _ = try await store.update { $0.reorder(folderWith: $0.favoritesID, to: ordered) }

        let reopened = await makeStore().collection()
        XCTAssertEqual(reopened.favorites.bookmarks.map(\.title), ["Two", "One"])
    }
}

final class InternalPageTests: XCTestCase {
    func testBookmarksPageHasAnAboutAddress() {
        XCTAssertEqual(InternalPage.bookmarks.url.absoluteString, "about:bookmarks")
    }

    func testRoundTripFromURL() {
        XCTAssertEqual(InternalPage.page(for: InternalPage.bookmarks.url), .bookmarks)
    }

    func testClientCertificatesPageIsAddressable() throws {
        XCTAssertEqual(InternalPage.clientCertificates.url.absoluteString, "about:client-certs")
        let result = try AddressInputInterpreter().interpret("about:client-certs")
        guard case .internalPage(let page) = result else {
            return XCTFail("expected an internal page, got \(result)")
        }
        XCTAssertEqual(page, .clientCertificates)
    }

    func testRecognitionIgnoresCase() {
        XCTAssertEqual(InternalPage.page(for: URL(string: "ABOUT:Bookmarks")!), .bookmarks)
    }

    func testUnknownAboutPagesAreNotRecognised() {
        XCTAssertNil(InternalPage.page(for: URL(string: "about:config")!))
        XCTAssertNil(InternalPage.page(for: URL(string: "gemini://example.com/")!))
    }

    /// Typing the address must reach the page rather than being sent to a search engine.
    func testAddressBarRecognisesTheBookmarksPage() throws {
        let result = try AddressInputInterpreter().interpret("about:bookmarks")
        guard case .internalPage(let page) = result else {
            return XCTFail("expected an internal page, got \(result)")
        }
        XCTAssertEqual(page, .bookmarks)
    }

    func testAnUnknownAboutAddressIsStillTreatedAsASearch() throws {
        let result = try AddressInputInterpreter().interpret("about:config")
        guard case .gemini(let target) = result else {
            return XCTFail("expected a search, got \(result)")
        }
        XCTAssertTrue(target.url.absoluteString.contains("search"))
    }
}
