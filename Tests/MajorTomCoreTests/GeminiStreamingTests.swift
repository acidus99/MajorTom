import Foundation
import XCTest
@testable import MajorTomCore

final class GeminiStreamingTests: XCTestCase {
    func testResponseDecoderIsInvariantAcrossEveryByteBoundary() throws {
        let response = Data("20 text/gemini; charset=utf-8\r\n# Hello\nBody 👨‍🚀\n".utf8)

        for boundary in 0...response.count {
            var decoder = GeminiResponseStreamDecoder()
            var events: [GeminiResponseStreamDecoder.Event] = []
            events += try decoder.receive(response.prefix(boundary))
            events += try decoder.receive(response.suffix(response.count - boundary))
            try decoder.finish()

            XCTAssertEqual(events.first, .header(try GeminiResponseHeader(status: 20, meta: "text/gemini; charset=utf-8")))
            let body = events.dropFirst().reduce(into: Data()) { result, event in
                if case .body(let bytes) = event { result.append(bytes) }
            }
            XCTAssertEqual(body, Data("# Hello\nBody 👨‍🚀\n".utf8), "Boundary \(boundary)")
        }
    }

    func testUTF8DecoderRetainsSplitScalarBytes() {
        let input = Data("A👨‍🚀Z".utf8)
        for boundary in 0...input.count {
            var decoder = IncrementalUTF8Decoder()
            let output = decoder.decode(input.prefix(boundary))
                + decoder.decode(input.suffix(input.count - boundary))
                + decoder.finish()
            XCTAssertEqual(output, "A👨‍🚀Z", "Boundary \(boundary)")
        }
    }

    func testGemtextParserIsInvariantAcrossEveryCharacterBoundary() {
        let source = "\u{FEFF}# Major Tom\nA quiet reader.\n=> /next Next page\n* Item\n> Quote\n```alt text\n# literal\n```\n"
        var baselineParser = IncrementalGemtextParser()
        let baseline = baselineParser.receive(source) + baselineParser.finish()

        for boundary in source.indices {
            var parser = IncrementalGemtextParser()
            let events = parser.receive(String(source[..<boundary]))
                + parser.receive(String(source[boundary...]))
                + parser.finish()
            XCTAssertEqual(events, baseline)
        }

        XCTAssertEqual(baseline, [
            .heading(level: 1, text: "Major Tom"),
            .text("A quiet reader."),
            .link(destination: "/next", label: "Next page"),
            .listItem("Item"),
            .quote("Quote"),
            .beginPreformatted(altText: "alt text"),
            .preformattedLine("# literal"),
            .endPreformatted
        ])
    }

    func testGemtextParserAcceptsCRAndCRLFLineEndingsAcrossChunks() {
        let variants = ["\r", "\r\n"]
        for ending in variants {
            let source = "=>/one One\(ending)=>/two Two\(ending)"
            for split in source.indices {
                var parser = IncrementalGemtextParser()
                let events = parser.receive(String(source[..<split]))
                    + parser.receive(String(source[split...]))
                    + parser.finish()
                XCTAssertEqual(events, [
                    .link(destination: "/one", label: "One"),
                    .link(destination: "/two", label: "Two")
                ], "\(ending.debugDescription), split \(source.distance(from: source.startIndex, to: split))")
            }
        }
    }

    func testHTMLRendererEscapesCapsuleContentAndDestinations() {
        let renderer = HTMLDocumentStreamRenderer()
        let paragraph = String(decoding: renderer.render(.text("<script>&")), as: UTF8.self)
        let link = String(decoding: renderer.render(.link(destination: "x\" onmouseover=\"bad", label: "<Next>")), as: UTF8.self)

        XCTAssertEqual(paragraph, "<p>&lt;script&gt;&amp;</p>")
        XCTAssertFalse(link.contains("onmouseover=\"bad\""))
        XCTAssertTrue(link.contains("&lt;Next&gt;"))
        XCTAssertTrue(link.contains("&quot;"))
    }

    func testDocumentThemeIsAddressableWithoutReplacingContent() {
        let document = String(decoding: HTMLDocumentStreamRenderer().documentStart(themeCSS: "body { color: red; }"), as: UTF8.self)
        XCTAssertTrue(document.contains("id=\"majortom-theme\""))
        XCTAssertTrue(document.contains("body { color: red; }"))
    }

    func testInlineEnhancementsAreConservativeAndEscaped() {
        let rendered = HTMLDocumentStreamRenderer.renderInline(
            "Use **strong**, *emphasis*, and `code <here>`; leave *unmatched visible"
        )
        XCTAssertEqual(
            rendered,
            "Use <strong>strong</strong>, <em>emphasis</em>, and <code>code &lt;here&gt;</code>; leave *unmatched visible"
        )
    }

    func testInlineEnhancementsCanBeDisabledIndependently() {
        let options = HTMLRenderingOptions(
            recognizesEmphasis: false,
            recognizesStrongEmphasis: true,
            recognizesInlineCode: false
        )
        XCTAssertEqual(
            HTMLDocumentStreamRenderer.renderInline("**yes** *no* `no`", options: options),
            "<strong>yes</strong> *no* `no`"
        )
    }

    func testBrowserPreferencesRoundTrip() throws {
        let original = BrowserPreferences(
            homepage: "gemini://example.com/",
            searchProvider: .custom,
            customSearchEndpoint: "gemini://search.example/query",
            applicationAppearance: .dark,
            contentTheme: .draculaLight,
            proxy: GeminiProxyConfiguration(host: "proxy.example", port: 8080),
            automaticallyLoadsSameCapsuleImages: false
        )
        let decoded = try JSONDecoder().decode(
            BrowserPreferences.self,
            from: JSONEncoder().encode(original)
        )
        XCTAssertEqual(decoded, original)
    }

    func testDirectorySaveFilenameUsesDocumentTitle() {
        XCTAssertEqual(
            BrowserFilenameSuggestion.make(
                for: URL(string: "gemini://kennedy.gemi.dev/archive/")!,
                mimeType: "text/gemini",
                documentTitle: "Kennedy Archive"
            ),
            "Kennedy Archive.gmi"
        )
        XCTAssertEqual(
            BrowserFilenameSuggestion.make(
                for: URL(string: "gemini://kennedy.gemi.dev/archive/")!,
                mimeType: "text/gemini"
            ),
            "untitled.gmi"
        )
    }

    func testFallbackPageTitlePreservesFilenameExtension() {
        XCTAssertEqual(
            BrowserPageTitle.fallback(for: URL(string: "gemini://gemi.dev/tests/markdown.md")!),
            "markdown.md"
        )
        XCTAssertEqual(
            BrowserPageTitle.fallback(for: URL(string: "gemini://gemi.dev/archive/")!),
            "archive"
        )
        XCTAssertEqual(
            BrowserPageTitle.fallback(for: URL(string: "gemini://gemi.dev/")!),
            "gemi.dev"
        )
    }

    func testGeminiRequestTargetNormalizesAndRemovesFragment() throws {
        let target = try GeminiRequestTarget("GEMINI://Example.COM/path?q=hello#section")
        XCTAssertEqual(target.endpoint, CapsuleEndpoint(host: "example.com", port: 1_965))
        XCTAssertEqual(target.url.absoluteString, "gemini://example.com/path?q=hello")
        XCTAssertEqual(String(decoding: target.requestData, as: UTF8.self), "gemini://example.com/path?q=hello\r\n")
    }

    func testGeminiRequestTargetAddsRootPath() throws {
        XCTAssertEqual(try GeminiRequestTarget("gemini://example.com").url.absoluteString, "gemini://example.com/")
    }

    func testGeminiRequestTargetRejectsUserInfoAndOversizedURLs() {
        XCTAssertThrowsError(try GeminiRequestTarget("gemini://user@example.com/"))
        XCTAssertThrowsError(try GeminiRequestTarget("gemini://example.com/" + String(repeating: "a", count: 1_100)))
    }

    func testGeminiRequestLimitIncludesTrailingCRLF() throws {
        let prefix = "gemini://example.com/"
        let validURL = prefix + String(
            repeating: "a",
            count: GeminiRequestTarget.maximumURLByteCount - prefix.utf8.count
        )
        let valid = try GeminiRequestTarget(validURL)
        XCTAssertEqual(valid.requestData.count, GeminiRequestTarget.maximumRequestByteCount)
        XCTAssertThrowsError(try GeminiRequestTarget(validURL + "a"))
    }

    func testGeminiQueryEncodingRoundTripsReservedCharacters() throws {
        let query = "C++ &/?:,;=#%"
        let encoded = GeminiQueryEncoding.encode(query)
        XCTAssertEqual(encoded, "C%2B%2B%20%26%2F%3F%3A%2C%3B%3D%23%25")
        let url = try XCTUnwrap(GeminiQueryEncoding.url(
            base: URL(string: "gemini://example.com/search?old")!,
            query: query
        ))
        XCTAssertEqual(url.absoluteString, "gemini://example.com/search?\(encoded)")
        XCTAssertEqual(url.query?.removingPercentEncoding, query)
    }

    func testUnicodeLineSeparatorsRemainGemtextContent() {
        for separator in ["\u{000B}", "\u{000C}", "\u{0085}", "\u{2028}", "\u{2029}"] {
            var parser = IncrementalGemtextParser()
            XCTAssertEqual(
                parser.receive("left\(separator)right\n") + parser.finish(),
                [.text("left\(separator)right")]
            )
        }
    }

    func testAddressInterpreterRecognizesExplicitAndImplicitCapsules() throws {
        let interpreter = AddressInputInterpreter()

        XCTAssertEqual(
            try interpreter.interpret("  gemini://Example.COM/docs#part  "),
            .gemini(try GeminiRequestTarget("gemini://example.com/docs"))
        )
        XCTAssertEqual(
            try interpreter.interpret("localhost:1966/testing"),
            .gemini(try GeminiRequestTarget("gemini://localhost:1966/testing"))
        )
        XCTAssertEqual(
            try interpreter.interpret("gemi.dev"),
            .gemini(try GeminiRequestTarget("gemini://gemi.dev/"))
        )
    }

    func testAddressInterpreterUsesSearchForOrdinaryText() throws {
        let interpreter = AddressInputInterpreter(
            searchEndpoint: URL(string: "gemini://search.example/query")!
        )
        let result = try interpreter.interpret("Gemini browsers")
        guard case .gemini(let target) = result else {
            return XCTFail("Expected Gemini search target")
        }
        XCTAssertEqual(target.url.absoluteString, "gemini://search.example/query?Gemini%20browsers")
    }

    func testAddressInterpreterReturnsExternalURLsAndRejectsInvalidGemini() throws {
        XCTAssertEqual(
            try AddressInputInterpreter().interpret("https://example.com/"),
            .external(URL(string: "https://example.com/")!)
        )
        XCTAssertThrowsError(try AddressInputInterpreter().interpret("gemini://"))
    }
}
