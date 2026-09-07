import Foundation
import XCTest
@testable import MajorTomCore

final class GeminiFaviconTests: XCTestCase {
    func testASingleEmojiIsAccepted() {
        XCTAssertEqual(GeminiFavicon.parse("\u{1F346}"), "\u{1F346}")
    }

    /// "The document may optionally end in a newline… MUST be removed by the client."
    func testTrailingLineFeedIsRemoved() {
        XCTAssertEqual(GeminiFavicon.parse("\u{1F346}\n"), "\u{1F346}")
    }

    func testTrailingCRLFIsRemoved() {
        XCTAssertEqual(GeminiFavicon.parse("\u{1F346}\r\n"), "\u{1F346}")
    }

    /// Only one terminator is optional; a document with two is not conformant.
    func testTwoTrailingNewlinesAreRejected() {
        XCTAssertNil(GeminiFavicon.parse("\u{1F346}\n\n"))
    }

    func testSkinToneModifierCountsAsOneEmoji() {
        XCTAssertEqual(GeminiFavicon.parse("\u{1F44D}\u{1F3FD}"), "\u{1F44D}\u{1F3FD}")
    }

    /// A zero-width-joiner sequence is one grapheme cluster and one favicon.
    func testJoinedSequenceCountsAsOneEmoji() {
        let technologist = "\u{1F469}\u{200D}\u{1F4BB}"
        XCTAssertEqual(GeminiFavicon.parse(technologist), technologist)
    }

    func testFlagIsAccepted() {
        let flag = "\u{1F1FA}\u{1F1F8}"
        XCTAssertEqual(GeminiFavicon.parse(flag), flag)
    }

    /// A text-default symbol qualifies only with VARIATION SELECTOR-16.
    func testSymbolWithPresentationSelectorIsAccepted() {
        XCTAssertEqual(GeminiFavicon.parse("\u{2764}\u{FE0F}"), "\u{2764}\u{FE0F}")
    }

    // MARK: - Rejections

    func testMultipleEmojiAreRejected() {
        XCTAssertNil(GeminiFavicon.parse("\u{1F346}\u{1F680}"))
    }

    func testPlainTextIsRejected() {
        XCTAssertNil(GeminiFavicon.parse("hello"))
        XCTAssertNil(GeminiFavicon.parse("A"))
    }

    /// A digit is Emoji=Yes only as a keycap base, and must not render as a favicon.
    func testBareDigitIsRejected() {
        XCTAssertNil(GeminiFavicon.parse("1"))
        XCTAssertNil(GeminiFavicon.parse("#"))
        XCTAssertNil(GeminiFavicon.parse("*"))
    }

    func testEmptyDocumentIsRejected() {
        XCTAssertNil(GeminiFavicon.parse(""))
        XCTAssertNil(GeminiFavicon.parse("\n"))
    }

    func testWhitespaceIsNotStrippedAndSoIsRejected() {
        // Only a trailing newline is optional; a space is content, making this two
        // characters and non-conformant.
        XCTAssertNil(GeminiFavicon.parse(" \u{1F346}"))
        XCTAssertNil(GeminiFavicon.parse("\u{1F346} "))
    }

    func testPathIsAtTheServerRoot() {
        XCTAssertEqual(GeminiFavicon.path, "/favicon.txt")
    }

    func testCompleteSuccessfulPlainTextResponseIsValidated() {
        let response = ContentResponse(
            url: URL(string: "gemini://example.com/favicon.txt")!,
            status: 20,
            meta: Data("text/plain; charset=utf-8".utf8),
            mimeType: "text/plain",
            body: Data("🚀\n".utf8),
            receivedAt: Date()
        )
        XCTAssertEqual(GeminiFavicon.parse(response: response), "🚀")
    }

    func testResponseRequiresSuccessPlainTextAndUTF8() {
        let url = URL(string: "gemini://example.com/favicon.txt")!
        for response in [
            ContentResponse(url: url, status: 51, meta: Data(), mimeType: nil, body: Data(), receivedAt: Date()),
            ContentResponse(url: url, status: 20, meta: Data("image/png".utf8), mimeType: "image/png", body: Data("🚀".utf8), receivedAt: Date()),
            ContentResponse(url: url, status: 20, meta: Data("text/plain".utf8), mimeType: "text/plain", body: Data([0xFF]), receivedAt: Date())
        ] {
            XCTAssertNil(GeminiFavicon.parse(response: response))
        }
    }

    func testFaviconURLUsesEndpointAndOmitsDefaultPort() {
        XCTAssertEqual(
            GeminiFavicon.url(for: CapsuleEndpoint(host: "example.com", port: 1_965))?.absoluteString,
            "gemini://example.com/favicon.txt"
        )
        XCTAssertEqual(
            GeminiFavicon.url(for: CapsuleEndpoint(host: "example.com", port: 1_966))?.absoluteString,
            "gemini://example.com:1966/favicon.txt"
        )
    }

    func testNegativeResponseRepresentsNoAcceptableFavicon() {
        let url = URL(string: "gemini://example.com/favicon.txt")!
        let receivedAt = Date(timeIntervalSince1970: 1_000)
        let response = GeminiFavicon.negativeResponse(for: url, receivedAt: receivedAt)

        XCTAssertEqual(response.url, url)
        XCTAssertEqual(response.status, 51)
        XCTAssertTrue(response.meta.isEmpty)
        XCTAssertNil(response.mimeType)
        XCTAssertTrue(response.body.isEmpty)
        XCTAssertEqual(response.receivedAt, receivedAt)
    }
}
