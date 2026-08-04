import Foundation
import XCTest
@testable import MajorTomCore

final class DeloreanArchiveTests: XCTestCase {
    func testCapturesLinkCarriesTheURLAsAnEncodedQuery() throws {
        let url = URL(string: "gemini://example.com/notes/page.gmi")!
        let captures = try XCTUnwrap(DeloreanArchive.captures(of: url))
        XCTAssertEqual(
            captures.absoluteString,
            "gemini://kennedy.gemi.dev/archive/history?gemini%3A%2F%2Fexample.com%2Fnotes%2Fpage.gmi"
        )
    }

    /// The looked-up URL must not be readable as further query parameters of the archive's
    /// own URL, which is why every reserved character is encoded.
    /// Reads `percentEncodedQuery`, because `URLComponents.query` hands back the *decoded*
    /// query and would make any encoding look absent.
    private func encodedQuery(of url: URL) throws -> String {
        let captures = try XCTUnwrap(DeloreanArchive.captures(of: url))
        return try XCTUnwrap(URLComponents(url: captures, resolvingAgainstBaseURL: false)?.percentEncodedQuery)
    }

    /// The looked-up URL must not be readable as further query parameters of the archive's
    /// own URL, which is why every reserved character is encoded.
    func testQueryOfTheLookedUpURLIsFullyEncoded() throws {
        let query = try encodedQuery(of: URL(string: "gemini://example.com/search?a=1&b=2")!)
        XCTAssertFalse(query.contains("&"))
        XCTAssertFalse(query.contains("="))
        XCTAssertTrue(query.contains("%26"))
        XCTAssertTrue(query.contains("%3D"))
    }

    /// Round-trips: what the archive receives is exactly the address that failed, including
    /// an address that itself contains percent-encoding, which must survive double-encoding.
    func testEncodedURLDecodesBackToTheOriginal() throws {
        let url = URL(string: "gemini://example.com/a path/with?query=1#frag")!
        let query = try encodedQuery(of: url)
        XCTAssertEqual(query.removingPercentEncoding, url.absoluteString)
    }

    /// The archive covers Geminispace, so a proxied web address is not offered.
    func testNonGeminiURLsAreNotOffered() {
        XCTAssertNil(DeloreanArchive.captures(of: URL(string: "https://example.com/")!))
        XCTAssertNil(DeloreanArchive.captures(of: URL(string: "file:///tmp/page.gmi")!))
        XCTAssertNil(DeloreanArchive.captures(of: URL(string: "view-source:gemini://example.com/")!))
    }

    func testSchemeComparisonIgnoresCase() throws {
        XCTAssertNotNil(DeloreanArchive.captures(of: URL(string: "GEMINI://example.com/")!))
    }

    /// 51 means the capsule answered and said the resource is gone, which is the case an
    /// archived copy answers.
    func testPermanentNotFoundIsWorthOffering() {
        XCTAssertTrue(DeloreanArchive.isWorthOffering(status: 51))
    }

    /// A temporary failure will likely resolve itself, and identity or input responses are
    /// not about the resource being missing.
    func testOtherStatusesAreNotWorthOffering() {
        for status in [10, 11, 20, 30, 31, 40, 41, 43, 44, 50, 52, 53, 59, 60, 61] {
            XCTAssertFalse(
                DeloreanArchive.isWorthOffering(status: status),
                "status \(status) should not offer the archive"
            )
        }
    }
}
