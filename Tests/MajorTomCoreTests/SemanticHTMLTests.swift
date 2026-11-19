import Foundation
import XCTest
@testable import MajorTomCore

final class SemanticHTMLTests: XCTestCase {
    private func render(_ events: [GemtextEvent], options: HTMLRenderingOptions = HTMLRenderingOptions()) -> String {
        let renderer = HTMLDocumentStreamRenderer()
        var document = renderer.documentStart()
        for event in events { document.append(renderer.render(event, options: options)) }
        document.append(renderer.documentEnd())
        return String(decoding: document, as: UTF8.self)
    }

    func testAdjacentItemsFormNativeListsSeparatedByOtherContent() {
        // Prevents the old div/span bullets from losing native list structure.
        let html = render([.listItem("One"), .listItem("Two"), .blank, .listItem("Three"), .text("After")])
        XCTAssertEqual(html.components(separatedBy: "<ul>").count - 1, 2)
        XCTAssertEqual(html.components(separatedBy: "<li>").count - 1, 3)
        XCTAssertEqual(html.components(separatedBy: "</ul>").count - 1, 2)
        XCTAssertFalse(html.contains("•"))
        XCTAssertFalse(html.contains("<div"))
        XCTAssertTrue(html.range(of: "</ul>", options: .backwards)!.upperBound < html.range(of: "<p>After")!.lowerBound)
    }

    func testQuoteLinesShareOneQuotationAndEmptyQuotedLinesSeparateParagraphs() {
        // Prevents a single quotation becoming a collection of unrelated blockquotes.
        let html = render([.quote("First line"), .quote("Second line"), .quote(""), .quote("Another paragraph"), .blank, .text("After")])
        XCTAssertEqual(html.components(separatedBy: "<blockquote>").count - 1, 1)
        let quoted = html.components(separatedBy: "<blockquote>")[1].components(separatedBy: "</blockquote>")[0]
        XCTAssertEqual(quoted.components(separatedBy: "<p>").count - 1, 2)
        XCTAssertTrue(quoted.contains("First line\nSecond line"))
    }

    func testSeparateQuotationPreferenceRemainsAvailable() {
        let options = HTMLRenderingOptions(collapsesConsecutiveQuotes: false)
        let html = render([.quote("First"), .quote("Second")], options: options)
        XCTAssertEqual(html.components(separatedBy: "<blockquote>").count - 1, 2)
    }

    func testOrdinaryPreformattedTextPreservesWhitespace() {
        let html = render([.beginPreformatted(altText: "Art"), .preformattedLine("  +--+"), .preformattedLine("  |  |"), .endPreformatted])
        XCTAssertTrue(html.contains("  +--+\n  |  |\n"))
    }

    func testIncompleteNoticeFollowsClosedContentBlocks() {
        for event in [GemtextEvent.listItem("Item"), .quote("Quote"), .beginPreformatted(altText: nil)] {
            let renderer = HTMLDocumentStreamRenderer()
            var data = renderer.documentStart()
            data.append(renderer.render(event))
            data.append(renderer.documentEnd(incompleteMessage: "Interrupted"))
            let html = String(decoding: data, as: UTF8.self)
            let notice = html.range(of: "<aside")!.lowerBound
            let closing = event == .listItem("Item") ? "</ul>" : event == .quote("Quote") ? "</blockquote>" : "</details>"
            XCTAssertTrue(html.range(of: closing)!.upperBound < notice)
        }
    }

    func testGroupingIsInvariantAtEveryNetworkByteBoundary() {
        let bytes = Data("* One 👨‍🚀\n* Two\n\n> First\n> Second\n>\n> Third\n\n```art\n\n +--+\n```\nEnd\n".utf8)
        func streamed(_ chunks: [Data]) -> Data {
            let renderer = HTMLDocumentStreamRenderer()
            var decoder = IncrementalUTF8Decoder()
            var parser = IncrementalGemtextParser()
            var document = renderer.documentStart()
            for chunk in chunks {
                for event in parser.receive(decoder.decode(chunk)) { document.append(renderer.render(event)) }
            }
            for event in parser.receive(decoder.finish()) + parser.finish() { document.append(renderer.render(event)) }
            document.append(renderer.documentEnd())
            return document
        }
        let expected = streamed([bytes])
        for boundary in 0...bytes.count {
            XCTAssertEqual(streamed([Data(bytes.prefix(boundary)), Data(bytes.suffix(bytes.count - boundary))]), expected, "Boundary \(boundary)")
        }
    }

    func testInterruptedPlainTextClosesBeforeItsNotice() {
        let renderer = HTMLDocumentStreamRenderer()
        var data = renderer.documentStart(kind: .plainText)
        data.append(renderer.beginPlainText())
        data.append(renderer.renderPlainTextChunk("Received text"))
        data.append(renderer.documentEnd(incompleteMessage: "Interrupted"))
        let html = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(html.range(of: "</pre>")!.upperBound < html.range(of: "<aside")!.lowerBound)
    }
}
