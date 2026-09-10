import XCTest
@testable import MajorTomCore

final class BrowserFilenameSuggestionTests: XCTestCase {
    private func suggestion(
        _ address: String,
        _ mimeType: String = "text/gemini",
        title: String? = nil
    ) -> String {
        BrowserFilenameSuggestion.make(
            for: URL(string: address)!,
            mimeType: mimeType,
            documentTitle: title
        )
    }

    /// Prevents the bug where a period anywhere in a document title was mistaken for a
    /// file extension, so Save Page As offered a name macOS would not open again. It
    /// fired on Major Tom's own homepage, whose title is "🏭 Gemi.dev Heavy Industries".
    func testTitleContainingAPeriodStillReceivesItsExtension() {
        XCTAssertEqual(
            suggestion("gemini://gemi.dev/", title: "Gemi.dev Heavy Industries"),
            "Gemi.dev Heavy Industries.gmi"
        )
        XCTAssertEqual(
            suggestion("gemini://gemi.dev/", title: "Release notes for v2.0"),
            "Release notes for v2.0.gmi"
        )
        XCTAssertEqual(
            suggestion("gemini://gemi.dev/", title: "Chapter 1. Beginnings"),
            "Chapter 1. Beginnings.gmi"
        )
    }

    func testTitleAlreadyEndingInTheExtensionIsNotDoubled() {
        XCTAssertEqual(suggestion("gemini://gemi.dev/", title: "notes.gmi"), "notes.gmi")
        XCTAssertEqual(
            suggestion("gemini://gemi.dev/", "text/plain", title: "notes.TXT"),
            "notes.TXT"
        )
    }

    func testFilenameFromThePathKeepsItsOwnExtension() {
        XCTAssertEqual(suggestion("gemini://example.org/a/page.gmi"), "page.gmi")
        // The capsule's extension wins over the response's type.
        XCTAssertEqual(suggestion("gemini://example.org/a/notes.md"), "notes.md")
    }

    func testExtensionlessPathComponentTakesTheResponseType() {
        XCTAssertEqual(suggestion("gemini://example.org/page"), "page.gmi")
        XCTAssertEqual(suggestion("gemini://example.org/photo", "image/png"), "photo.png")
        XCTAssertEqual(suggestion("gemini://example.org/scan", "image/jpeg"), "scan.jpg")
    }

    func testDirectoryURLUsesTheTitleAndFallsBackToUntitled() {
        XCTAssertEqual(suggestion("gemini://example.org/archive/", title: "Archive"), "Archive.gmi")
        XCTAssertEqual(suggestion("gemini://example.org/", "text/plain"), "untitled.txt")
    }

    /// A leading period would hide the saved file in the Finder.
    func testLeadingPeriodsAreNotAllowedToHideTheFile() {
        XCTAssertEqual(suggestion("gemini://example.org/", title: ".plan"), "plan.gmi")
        XCTAssertEqual(suggestion("gemini://example.org/", title: "..hidden"), "hidden.gmi")
        XCTAssertEqual(suggestion("gemini://example.org/", title: "."), "untitled.gmi")
    }

    func testPathSeparatorsAndControlCharactersAreRemoved() {
        XCTAssertEqual(
            suggestion("gemini://example.org/", title: "line one\nline two"),
            "line one-line two.gmi"
        )
        XCTAssertEqual(suggestion("gemini://example.org/", title: "a/b:c"), "a-b-c.gmi")
        // Colons reach the name from the path too, where they used to go unsanitized.
        XCTAssertEqual(suggestion("gemini://example.org/a:b"), "a-b.gmi")
    }

    func testUnknownTypeYieldsNoExtension() {
        XCTAssertEqual(
            suggestion("gemini://example.org/", "application/octet-stream", title: "Blob"),
            "Blob"
        )
    }

    func testMediaTypeCaseAndSpacingDoNotLoseTheExtension() {
        XCTAssertEqual(suggestion("gemini://example.org/", " Text/Gemini ", title: "Notes"), "Notes.gmi")
    }
}
