import XCTest
@testable import MajorTomCore

final class BrowserPageTitleLabelTests: XCTestCase {
    /// Prevents the bug where a capsule publishing the same emoji its own titles begin
    /// with was labelled with it twice, as Kennedy was: it publishes 🔭 and titles its
    /// pages "🔭 Kennedy: Search Gemini Space".
    func testFaviconIsNotRepeatedWhenTheTitleAlreadyOpensWithIt() {
        XCTAssertEqual(
            BrowserPageTitle.labelled("🔭 Kennedy: Search Gemini Space", favicon: "🔭"),
            "🔭 Kennedy: Search Gemini Space"
        )
        // No separator between emoji and text, and leading whitespace, both still count
        // as the title already opening with the favicon.
        XCTAssertEqual(BrowserPageTitle.labelled("🔭Kennedy", favicon: "🔭"), "🔭Kennedy")
        XCTAssertEqual(BrowserPageTitle.labelled("  🔭 Kennedy", favicon: "🔭"), "  🔭 Kennedy")
    }

    func testFaviconLabelsATitleThatDoesNotCarryIt() {
        XCTAssertEqual(
            BrowserPageTitle.labelled("Gemi.dev Heavy Industries", favicon: "🏭"),
            "🏭  Gemi.dev Heavy Industries"
        )
    }

    /// A title opening with a *different* emoji is still labelled: the favicon is the
    /// capsule's identity and is not implied by whatever glyph the page chose.
    func testDifferentLeadingEmojiDoesNotSuppressTheFavicon() {
        XCTAssertEqual(
            BrowserPageTitle.labelled("🤨 Curiouser and Curiouser", favicon: "🏭"),
            "🏭  🤨 Curiouser and Curiouser"
        )
    }

    func testTitleIsUnchangedWithoutAFavicon() {
        XCTAssertEqual(BrowserPageTitle.labelled("Antenna", favicon: nil), "Antenna")
        XCTAssertEqual(BrowserPageTitle.labelled("Antenna", favicon: ""), "Antenna")
    }

    /// Flag emoji are regional-indicator pairs, so a prefix comparison must not match a
    /// half of one and drop the label.
    func testFlagFaviconIsComparedAsAWholeGlyph() {
        XCTAssertEqual(BrowserPageTitle.labelled("🇺🇸 MOZZ.US", favicon: "🇺🇸"), "🇺🇸 MOZZ.US")
        XCTAssertEqual(
            BrowserPageTitle.labelled("🇺🇸 MOZZ.US", favicon: "🐟"),
            "🐟  🇺🇸 MOZZ.US"
        )
    }
}
