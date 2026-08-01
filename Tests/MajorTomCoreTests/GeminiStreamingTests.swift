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

    func testHTMLRendererEscapesCapsuleContentAndDestinations() {
        let renderer = HTMLDocumentStreamRenderer()
        let paragraph = String(decoding: renderer.render(.text("<script>&")), as: UTF8.self)
        let link = String(decoding: renderer.render(.link(destination: "x\" onmouseover=\"bad", label: "<Next>")), as: UTF8.self)

        XCTAssertEqual(paragraph, "<p>&lt;script&gt;&amp;</p>")
        XCTAssertFalse(link.contains("onmouseover=\"bad\""))
        XCTAssertTrue(link.contains("&lt;Next&gt;"))
        XCTAssertTrue(link.contains("&quot;"))
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
