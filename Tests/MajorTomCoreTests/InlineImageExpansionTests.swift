import Foundation
import XCTest
@testable import MajorTomCore

final class InlineImageCandidateTests: XCTestCase {
    private let capsule = URL(string: "gemini://example.com/gallery/")!

    func testGeminiImageIsACandidate() {
        XCTAssertTrue(GemtextLinkHint.isInlineImageCandidate(
            destination: "photo.png",
            relativeTo: capsule
        ))
    }

    func testAbsoluteGeminiImageOnAnotherCapsuleIsACandidate() {
        XCTAssertTrue(GemtextLinkHint.isInlineImageCandidate(
            destination: "gemini://elsewhere.example/photo.jpg",
            relativeTo: capsule
        ))
    }

    func testNonImageGeminiLinkIsNotACandidate() {
        XCTAssertFalse(GemtextLinkHint.isInlineImageCandidate(
            destination: "page.gmi",
            relativeTo: capsule
        ))
    }

    /// Already inline in the document; expanding it again would duplicate it.
    func testDataImageIsNotACandidate() {
        XCTAssertFalse(GemtextLinkHint.isInlineImageCandidate(
            destination: "data:image/png;base64,iVBORw0K",
            relativeTo: capsule
        ))
    }

    /// Fetching this would leave Geminispace, which a plain click must not do.
    func testWebImageIsNotACandidate() {
        XCTAssertFalse(GemtextLinkHint.isInlineImageCandidate(
            destination: "https://example.com/photo.png",
            relativeTo: capsule
        ))
    }

    func testEmptyDestinationIsNotACandidate() {
        XCTAssertFalse(GemtextLinkHint.isInlineImageCandidate(destination: "  ", relativeTo: capsule))
    }
}

final class ExpandableLinkRenderingTests: XCTestCase {
    private let renderer = HTMLDocumentStreamRenderer()
    private let capsule = URL(string: "gemini://example.com/gallery/")!

    private func html(
        linkIdentifier: String? = nil,
        isExpandableImage: Bool = false,
        destination: String = "photo.png"
    ) -> String {
        String(
            decoding: renderer.render(
                .link(destination: destination, label: "A photo"),
                baseURL: capsule,
                linkIdentifier: linkIdentifier,
                isExpandableImage: isExpandableImage
            ),
            as: UTF8.self
        )
    }

    func testLinkIdentifierBecomesTheLineID() {
        XCTAssertTrue(html(linkIdentifier: "mt-link-7").contains("id=\"mt-link-7\""))
    }

    func testExpandableLinksAreMarkedForTheClickHandler() {
        XCTAssertTrue(html(linkIdentifier: "mt-link-1", isExpandableImage: true)
            .contains("data-mt-expandable=\"1\""))
    }

    /// Unmarked lines must stay unmarked, or every link click would be intercepted and
    /// ordinary navigation would stop working.
    func testOrdinaryLinksAreNotMarked() {
        let ordinary = html(linkIdentifier: "mt-link-1", destination: "page.gmi")
        XCTAssertFalse(ordinary.contains("data-mt-expandable"))
    }

    func testNoIdentifierMeansNoIDAttribute() {
        XCTAssertFalse(html().contains(" id="))
    }

    /// The identifier is interpolated into an attribute, so it must be escaped.
    func testIdentifierIsAttributeEscaped() {
        let injected = html(linkIdentifier: "a\"><script>")
        XCTAssertFalse(injected.contains("<script>"))
        XCTAssertTrue(injected.contains("&quot;"))
    }

    func testHintAndIdentifierCoexist() {
        let rendered = html(linkIdentifier: "mt-link-2", isExpandableImage: true)
        XCTAssertTrue(rendered.contains("link-hint"))
        // Compared against the enum's own value: the glyph is U+1F5BC followed by
        // VARIATION SELECTOR-16, and searching for the bare scalar would not match that
        // grapheme cluster.
        XCTAssertTrue(
            rendered.contains(GemtextLinkHint.image.rawValue),
            "an image link still shows the image hint"
        )
        XCTAssertTrue(rendered.contains("id=\"mt-link-2\""))
    }
}

final class InlineImageRenderingTests: XCTestCase {
    private let renderer = HTMLDocumentStreamRenderer()

    func testInlineImageIsLinkedToItsOriginalURLAndCarriesCaptionMetadata() {
        let resource = URL(string: "majortom-resource://image/1")!
        let destination = URL(string: "gemini://example.com/photos/launch.png")!
        let html = String(decoding: renderer.renderInlineImage(
            resourceURL: resource,
            linkURL: destination,
            altText: "Rocket launch",
            figureIdentifier: "mt-inline-1",
            fileName: "launch.png",
            mimeType: "image/png",
            sizeDescription: "1.2 MB"
        ), as: UTF8.self)

        XCTAssertTrue(html.contains("id=\"mt-inline-1\""))
        XCTAssertTrue(html.contains("href=\"gemini://example.com/photos/launch.png\""))
        XCTAssertTrue(html.contains("src=\"majortom-resource://image/1\""))
        XCTAssertTrue(html.contains("data-mt-inline-image=\"1\""))
        XCTAssertTrue(html.contains("data-mt-filename=\"launch.png\""))
        XCTAssertTrue(html.contains("data-mt-mime=\"image/png\""))
        XCTAssertTrue(html.contains("data-mt-size=\"1.2 MB\""))
        XCTAssertTrue(html.contains("<figcaption>launch.png</figcaption>"))
    }

    func testInlineImageAttributesAreEscaped() {
        let resource = URL(string: "majortom-resource://image/1")!
        let destination = URL(string: "gemini://example.com/photo.png")!
        let html = String(decoding: renderer.renderInlineImage(
            resourceURL: resource,
            linkURL: destination,
            altText: "<unsafe>",
            figureIdentifier: "image\" onclick=\"bad",
            fileName: "<photo>.png"
        ), as: UTF8.self)

        XCTAssertFalse(html.contains("<unsafe>"))
        XCTAssertFalse(html.contains("onclick=\"bad\""))
        XCTAssertTrue(html.contains("&lt;photo&gt;.png"))
    }
}
