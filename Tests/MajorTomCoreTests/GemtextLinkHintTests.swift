import Foundation
import XCTest
@testable import MajorTomCore

final class GemtextLinkHintTests: XCTestCase {
    private let capsule = URL(string: "gemini://example.com/notes/")!

    // MARK: - Locality

    func testRelativeLinkStaysInTheCapsule() {
        XCTAssertEqual(
            GemtextLinkHint.classify(destination: "second.gmi", relativeTo: capsule),
            .sameCapsule
        )
    }

    func testAbsoluteLinkToTheSameHostStaysInTheCapsule() {
        XCTAssertEqual(
            GemtextLinkHint.classify(destination: "gemini://example.com/other", relativeTo: capsule),
            .sameCapsule
        )
    }

    func testHostComparisonIgnoresCase() {
        XCTAssertEqual(
            GemtextLinkHint.classify(destination: "gemini://EXAMPLE.COM/other", relativeTo: capsule),
            .sameCapsule
        )
    }

    /// The default port is implied by the scheme, so it must compare equal to an
    /// explicit :1965 rather than reading as a different server.
    func testExplicitDefaultPortIsStillTheSameCapsule() {
        XCTAssertEqual(
            GemtextLinkHint.classify(destination: "gemini://example.com:1965/x", relativeTo: capsule),
            .sameCapsule
        )
    }

    func testDifferentPortIsADifferentCapsule() {
        XCTAssertEqual(
            GemtextLinkHint.classify(destination: "gemini://example.com:1966/x", relativeTo: capsule),
            .otherCapsule
        )
    }

    func testDifferentHostIsADifferentCapsule() {
        XCTAssertEqual(
            GemtextLinkHint.classify(destination: "gemini://elsewhere.example/x", relativeTo: capsule),
            .otherCapsule
        )
    }

    /// Subdomains are distinct servers per the favicon RFC, and for trust purposes.
    func testSubdomainIsADifferentCapsule() {
        XCTAssertEqual(
            GemtextLinkHint.classify(destination: "gemini://foo.example.com/x", relativeTo: capsule),
            .otherCapsule
        )
    }

    func testAbsoluteGeminiLinkWithNoBaseIsReportedAsAJump() {
        XCTAssertEqual(
            GemtextLinkHint.classify(destination: "gemini://example.com/x", relativeTo: nil),
            .otherCapsule
        )
    }

    // MARK: - Scheme

    func testWebSchemesAreFlaggedAsLeavingGeminispace() {
        XCTAssertEqual(GemtextLinkHint.classify(destination: "http://example.com", relativeTo: capsule), .web)
        XCTAssertEqual(GemtextLinkHint.classify(destination: "https://example.com", relativeTo: capsule), .web)
    }

    /// Scheme outranks content: leaving Geminispace is the more consequential fact.
    func testWebImageReportsAsWebRatherThanImage() {
        XCTAssertEqual(
            GemtextLinkHint.classify(destination: "https://example.com/cat.png", relativeTo: capsule),
            .web
        )
    }

    func testMailtoIsEmail() {
        XCTAssertEqual(
            GemtextLinkHint.classify(destination: "mailto:someone@example.com", relativeTo: capsule),
            .email
        )
    }

    func testUnknownSchemeGetsNoHintRatherThanAMisleadingOne() {
        XCTAssertNil(GemtextLinkHint.classify(destination: "gopher://example.com/1", relativeTo: capsule))
        XCTAssertNil(GemtextLinkHint.classify(destination: "spartan://example.com/", relativeTo: capsule))
    }

    func testEmptyDestinationGetsNoHint() {
        XCTAssertNil(GemtextLinkHint.classify(destination: "", relativeTo: capsule))
        XCTAssertNil(GemtextLinkHint.classify(destination: "   ", relativeTo: capsule))
    }

    // MARK: - Images

    func testInCapsuleImageReportsAsImage() {
        XCTAssertEqual(
            GemtextLinkHint.classify(destination: "photo.jpg", relativeTo: capsule),
            .image
        )
    }

    func testImageExtensionMatchIgnoresCase() {
        XCTAssertEqual(
            GemtextLinkHint.classify(destination: "photo.PNG", relativeTo: capsule),
            .image
        )
    }

    func testDataImageURIReportsAsImage() {
        XCTAssertEqual(
            GemtextLinkHint.classify(destination: "data:image/png;base64,iVBORw0K", relativeTo: capsule),
            .image
        )
    }

    func testNonImageDataURIGetsNoHint() {
        XCTAssertNil(GemtextLinkHint.classify(destination: "data:text/plain,hello", relativeTo: capsule))
    }

    // MARK: - Endpoint derivation

    func testEndpointFromURLAppliesTheDefaultPortAndLowercasesTheHost() {
        let endpoint = CapsuleEndpoint(url: URL(string: "gemini://EXAMPLE.com/x")!)
        XCTAssertEqual(endpoint, CapsuleEndpoint(host: "example.com", port: 1_965))
    }

    func testEndpointFromURLWithoutAHostIsNil() {
        XCTAssertNil(CapsuleEndpoint(url: URL(string: "mailto:a@b.example")!))
    }

    // MARK: - Rendering

    func testRenderedLinkCarriesAnAriaHiddenHintGlyph() {
        let html = String(
            decoding: HTMLDocumentStreamRenderer().render(
                .link(destination: "second.gmi", label: "Second"),
                baseURL: capsule
            ),
            as: UTF8.self
        )
        XCTAssertTrue(html.contains("class=\"link-hint\" aria-hidden=\"true\""), html)
        XCTAssertTrue(html.contains("\u{2192}"), html)
        XCTAssertTrue(html.contains(">Second</a>"), html)
    }

    func testRenderedLinkToAnotherCapsuleUsesTheDoubleArrow() {
        let html = String(
            decoding: HTMLDocumentStreamRenderer().render(
                .link(destination: "gemini://elsewhere.example/", label: "Away"),
                baseURL: capsule
            ),
            as: UTF8.self
        )
        XCTAssertTrue(html.contains("\u{21D2}"), html)
    }

    func testHintsCanBeTurnedOff() {
        let html = String(
            decoding: HTMLDocumentStreamRenderer().render(
                .link(destination: "second.gmi", label: "Second"),
                options: HTMLRenderingOptions(showsLinkHints: false),
                baseURL: capsule
            ),
            as: UTF8.self
        )
        XCTAssertFalse(html.contains("link-hint"), html)
        XCTAssertFalse(html.contains("\u{2192}"), html)
    }

    /// Adding the option must not discard a stored preference blob that predates it.
    func testDecodingOptionsWithoutTheNewKeyDefaultsToShowingHints() throws {
        let json = Data(#"{"recognizesEmphasis":false}"#.utf8)
        let options = try JSONDecoder().decode(HTMLRenderingOptions.self, from: json)
        XCTAssertFalse(options.recognizesEmphasis)
        XCTAssertTrue(options.showsLinkHints)
    }
}
