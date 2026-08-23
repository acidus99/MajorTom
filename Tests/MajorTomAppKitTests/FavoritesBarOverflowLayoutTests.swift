import XCTest
@testable import MajorTomAppKitSupport

final class FavoritesBarOverflowLayoutTests: XCTestCase {
    private let widths: [CGFloat] = [80, 100, 60]

    func testAllBookmarksFitAtTheRequiredWidth() {
        let width = FavoritesBarOverflowLayout.requiredWidth(itemWidths: widths)
        XCTAssertEqual(
            FavoritesBarOverflowLayout.visibleItemCount(
                itemWidths: widths,
                availableWidth: width
            ),
            3
        )
    }

    func testShrinkingMovesOnlyWholeTrailingBookmarksIntoOverflow() {
        XCTAssertEqual(
            FavoritesBarOverflowLayout.visibleItemCount(
                itemWidths: widths,
                availableWidth: 198
            ),
            2
        )
        XCTAssertEqual(
            FavoritesBarOverflowLayout.visibleItemCount(
                itemWidths: widths,
                availableWidth: 193
            ),
            1
        )
    }

    func testExpandingRestoresBookmarksToTheBar() {
        let widthsDuringResize: [CGFloat] = [120, 198, 258]
        XCTAssertEqual(
            widthsDuringResize.map {
                FavoritesBarOverflowLayout.visibleItemCount(
                    itemWidths: widths,
                    availableWidth: $0
                )
            },
            [1, 2, 3]
        )
    }

    func testNoPartialBookmarkIsShownWhenNothingFits() {
        XCTAssertEqual(
            FavoritesBarOverflowLayout.visibleItemCount(
                itemWidths: widths,
                availableWidth: 50
            ),
            0
        )
    }

    func testDraggingLastBookmarkToTheLeftMovesItFirst() {
        XCTAssertEqual(
            FavoritesBarOverflowLayout.insertionIndex(
                itemWidths: widths,
                sourceIndex: 2,
                translation: -220
            ),
            0
        )
    }

    func testDraggingFirstBookmarkToTheRightMovesItLast() {
        XCTAssertEqual(
            FavoritesBarOverflowLayout.insertionIndex(
                itemWidths: widths,
                sourceIndex: 0,
                translation: 220
            ),
            2
        )
    }

    func testBookmarkKeepsItsPositionWithoutHorizontalMovement() {
        for sourceIndex in widths.indices {
            XCTAssertEqual(
                FavoritesBarOverflowLayout.insertionIndex(
                    itemWidths: widths,
                    sourceIndex: sourceIndex,
                    translation: 0
                ),
                sourceIndex
            )
        }
    }
}
