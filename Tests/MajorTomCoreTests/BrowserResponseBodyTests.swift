import XCTest
@testable import MajorTomCore

final class BrowserResponseBodyTests: XCTestCase {
    private let url = URL(string: "gemini://example.invalid/content")!

    func testContentDecisionPreservesSourceImageAndOpaqueDistinctions() {
        for (mime, expected) in [("Text/Gemini; charset=utf-8", BrowserContentKind.gemtext),
                                 ("text/plain", .plainText), ("image/png", .image),
                                 ("application/pgp-keys", .unsupported), ("", .unsupported)] {
            XCTAssertEqual(BrowserContentKind(mimeType: mime, url: url), expected)
        }
        XCTAssertEqual(BrowserContentKind(mimeType: "text/gemini", url: ViewSourceURL.wrap(url)!), .source)
        XCTAssertEqual(BrowserContentKind(mimeType: "text/plain", url: url, showsSource: true), .source)
        XCTAssertEqual(BrowserContentKind(mimeType: "image/png", url: url, showsSource: true), .image)
    }

    func testGemtextSemanticsAreIndependentOfEveryTwoPartByteSplit() {
        let bytes = Data("# Café 🚀\r\n\r\n``` art\r\n  🛰\r\n```\r\n=> /next Label\ntrailing".utf8)
        let expected: [BrowserBodyEvent] = [.gemtext(.heading(level: 1, text: "Café 🚀")), .gemtext(.blank),
            .gemtext(.beginPreformatted(altText: "art")), .gemtext(.preformattedLine("  🛰")),
            .gemtext(.endPreformatted), .gemtext(.link(destination: "/next", label: "Label")), .gemtext(.text("trailing"))]
        for split in 0...bytes.count {
            var body = BrowserResponseBody(kind: .gemtext)
            let actual = body.receive(bytes.prefix(split)) + body.receive(bytes.dropFirst(split)) + body.finish()
            XCTAssertEqual(actual, expected, "Split \(split)")
            XCTAssertTrue(body.finish().isEmpty)
        }
        XCTAssertEqual(BrowserResponseBody.events(for: bytes, kind: .gemtext), expected)
    }

    func testPlainTextKeepsWhitespaceAndCompletesTruncatedUTF8Once() {
        let bytes = Data("\n  Café\r\n".utf8) + Data([0xF0, 0x9F])
        for split in 0...bytes.count {
            var body = BrowserResponseBody(kind: .plainText)
            let events = body.receive(bytes.prefix(split)) + body.receive(bytes.dropFirst(split)) + body.finish()
            let text = events.compactMap { if case .text(let value) = $0 { return value }; return nil }.joined()
            XCTAssertEqual(text, "\n  Café\r\n�")
            XCTAssertTrue(body.receive(Data("late".utf8)).isEmpty)
            XCTAssertTrue(body.finish().isEmpty)
        }
    }

    func testOpaqueAndSourceBodiesNeverAcquireTextSemantics() {
        for kind in [BrowserContentKind.image, .unsupported, .source] {
            XCTAssertTrue(BrowserResponseBody.events(for: Data([0xFF, 0x00, 0x1B, 0x3C]), kind: kind).isEmpty)
        }
    }

    func testEmbeddedImageInterpretationPreservesBytesAndRejectsOtherSchemes() {
        let bytes = Data([0, 255, 1, 2])
        let encoded = "data:image/png;base64,\(bytes.base64EncodedString())"
        XCTAssertEqual(InlineDataImagePayload.decode(encoded)?.data, bytes)
        XCTAssertEqual(InlineDataImagePayload.decode(encoded)?.mimeType, "image/png")
        XCTAssertEqual(InlineDataImagePayload.decode("data:image/svg+xml,%3Csvg%3E%3C%2Fsvg%3E")?.data, Data("<svg></svg>".utf8))
        XCTAssertNil(InlineDataImagePayload.decode("data:text/html,<script>fixture</script>"))
        XCTAssertNil(InlineDataImagePayload.decode("gemini://example.invalid/image.png"))
    }
}
