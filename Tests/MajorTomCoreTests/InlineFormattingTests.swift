import Foundation
import XCTest
@testable import MajorTomCore

final class InlineFormattingTests: XCTestCase {
    // Delimiters stay visible, but only the enclosed text may receive formatting.
    func testFormattingMarkersRemainOutsideEveryFormattingElement() {
        for (marker, tag) in [("*", "em"), ("**", "strong"), ("`", "code"), ("_", "em")] {
            let html = HTMLDocumentStreamRenderer.renderInline("\(marker)foo\(marker)")
            XCTAssertTrue(html.hasPrefix(marker), html)
            XCTAssertTrue(html.hasSuffix(marker), html)
            XCTAssertTrue(html.contains("<\(tag)>foo</\(tag)>"), html)
        }
    }

    // Underscores use the same emphasis as asterisks while escaping capsule text.
    func testUnderscoresUseEmphasisAndPreserveEscapedText() {
        let html = HTMLDocumentStreamRenderer.renderInline("Before _<script>& text_ after")
        XCTAssertTrue(html.contains("<em>"))
        XCTAssertTrue(html.contains("</em>"))
        XCTAssertFalse(html.contains("<u>"))
        XCTAssertTrue(html.contains("&lt;script&gt;&amp; text"))
        XCTAssertFalse(html.contains("<script>"))
    }

    func testUnderscoreEmphasisCanBeDisabledWithoutDisablingOtherFormatting() {
        let html = HTMLDocumentStreamRenderer.renderInline(
            "_plain_ **strong** *emphasis* `code`",
            options: HTMLRenderingOptions(recognizesUnderscoreEmphasis: false)
        )
        XCTAssertFalse(html.contains("<u>"))
        XCTAssertTrue(html.contains("_plain_"))
        XCTAssertTrue(html.contains("<strong>"))
        XCTAssertTrue(html.contains("<em>"))
        XCTAssertTrue(html.contains("<code>"))
    }

    func testUnmatchedAndEmptyUnderscoresRemainPlainText() {
        for text in ["an _unmatched marker", "a trailing_ marker", "__"] {
            XCTAssertEqual(HTMLDocumentStreamRenderer.renderInline(text), text)
        }
    }

    func testUnderscoresInsideInlineCodeAreNotEmphasized() {
        let html = HTMLDocumentStreamRenderer.renderInline("`_code_`")
        XCTAssertTrue(html.contains("<code>"))
        XCTAssertTrue(html.contains("_code_"))
        XCTAssertFalse(html.contains("<em>"))
    }

    func testFormattingPreservesAllMarkersAndWhitespace() {
        let text = "  _one_ and _two words_\t**bold** *italic* `code` _unfinished"
        let html = HTMLDocumentStreamRenderer.renderInline(text)
        let visibleText = html.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        XCTAssertEqual(visibleText, text)
    }

    // Adding underscore recognition must not reset preferences saved by an older app.
    func testOlderPreferencesKeepTheirValuesAndDefaultUnderscoreEmphasisToEnabled() throws {
        var preferences = BrowserPreferences()
        preferences.homepage = "gemini://example.invalid/notes/"
        preferences.renderingOptions.recognizesEmphasis = false
        preferences.renderingOptions.recognizesInlineCode = false
        var payload = try XCTUnwrap(JSONSerialization.jsonObject(
            with: JSONEncoder().encode(preferences)
        ) as? [String: Any])
        var rendering = try XCTUnwrap(payload["renderingOptions"] as? [String: Any])
        rendering.removeValue(forKey: "recognizesUnderscoreEmphasis")
        payload["renderingOptions"] = rendering
        let decoded = try JSONDecoder().decode(BrowserPreferences.self,
                                              from: JSONSerialization.data(withJSONObject: payload))
        XCTAssertEqual(decoded, preferences)
        XCTAssertTrue(decoded.renderingOptions.recognizesUnderscoreEmphasis)
    }

    func testDisabledUnderscoreEmphasisPreferenceSurvivesSaving() throws {
        var preferences = BrowserPreferences()
        preferences.renderingOptions.recognizesUnderscoreEmphasis = false
        let decoded = try JSONDecoder().decode(BrowserPreferences.self,
                                              from: JSONEncoder().encode(preferences))
        XCTAssertEqual(decoded, preferences)
        XCTAssertFalse(decoded.renderingOptions.recognizesUnderscoreEmphasis)
    }
}
