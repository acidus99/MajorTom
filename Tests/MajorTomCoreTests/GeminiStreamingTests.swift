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

    func testGemtextParserEmitsEveryLineOfALargeSingleChunk() {
        // The parser used to remove each line from the front of its buffer as it was
        // parsed, and rescan from the front for the next line ending. A single network
        // chunk carrying a thousand lines therefore did on the order of a thousand
        // shifts over a shrinking buffer. This pins the behaviour that replaced it.
        let lineCount = 2_000
        let source = (0..<lineCount).map { "=> /page/\($0) Page \($0)" }.joined(separator: "\r\n") + "\r\n"

        var parser = IncrementalGemtextParser()
        let events = parser.receive(source) + parser.finish()

        XCTAssertEqual(events.count, lineCount)
        XCTAssertEqual(events.first, .link(destination: "/page/0", label: "Page 0"))
        XCTAssertEqual(events.last, .link(destination: "/page/\(lineCount - 1)", label: "Page \(lineCount - 1)"))
    }

    func testGemtextParserIsInvariantAcrossChunkCountForTheSameSource() {
        let source = "# One\r\nTwo\n=> /three Three\r\n* Four\n> Five\r\n"
        var baselineParser = IncrementalGemtextParser()
        let baseline = baselineParser.receive(source) + baselineParser.finish()

        // Same bytes, delivered in every possible number of equal-sized pieces.
        for chunkLength in 1...source.count {
            var parser = IncrementalGemtextParser()
            var events: [GemtextEvent] = []
            var index = source.startIndex
            while index < source.endIndex {
                let end = source.index(index, offsetBy: chunkLength, limitedBy: source.endIndex)
                    ?? source.endIndex
                events += parser.receive(String(source[index..<end]))
                index = end
            }
            events += parser.finish()
            XCTAssertEqual(events, baseline, "chunk length \(chunkLength)")
        }
    }

    func testGemtextParserHoldsBackABareTrailingCarriageReturn() {
        // A trailing CR may be the first half of a CRLF split across chunks. Emitting
        // the line early would produce two events where the source has one line.
        var parser = IncrementalGemtextParser()
        XCTAssertEqual(parser.receive("Only line\r"), [])
        XCTAssertEqual(parser.receive("\nSecond\n"), [.text("Only line"), .text("Second")])
    }

    func testGemtextParserTreatsABareCarriageReturnAtEndOfResponseAsALineEnding() {
        var parser = IncrementalGemtextParser()
        let events = parser.receive("Only line\r") + parser.finish()
        XCTAssertEqual(events, [.text("Only line")])
    }

    func testGemtextParserKeepsTrailingUnterminatedContentUntilFinish() {
        var parser = IncrementalGemtextParser()
        XCTAssertEqual(parser.receive("# Heading\nno newline here"), [.heading(level: 1, text: "Heading")])
        XCTAssertEqual(parser.finish(), [.text("no newline here")])
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

    func testDefaultThemeLetsHeadingsWrapAtTheAvailableWidth() {
        XCTAssertFalse(HTMLDocumentStreamRenderer.defaultThemeCSS.contains("text-wrap: balance"))
    }

    func testDefaultThemeRendersBlockQuotesInItalics() {
        XCTAssertTrue(
            HTMLDocumentStreamRenderer.defaultThemeCSS.contains(
                "blockquote { margin: 1rem 0; padding: .6rem 1rem; border-inline-start: .25rem solid AccentColor; font-style: italic; }"
            )
        )
    }

    func testPreformattedLinesCarryStreamingMultilineMarkers() {
        let renderer = HTMLDocumentStreamRenderer()
        let first = String(decoding: renderer.render(.preformattedLine("one")), as: UTF8.self)
        let second = String(decoding: renderer.render(.preformattedLine("<two>")), as: UTF8.self)

        XCTAssertEqual(first, "<span class=\"pre-line\">one</span>\n")
        XCTAssertEqual(second, "<span class=\"pre-line\">&lt;two&gt;</span>\n")
    }

    func testExpandedPreformattedBlocksHideTheirPlaceholder() {
        XCTAssertTrue(
            HTMLDocumentStreamRenderer.defaultThemeCSS.contains(
                ".pre-block[open] > summary { display: none; }"
            )
        )
    }

    func testPreformattedAltTextBecomesAnEscapedHoverTooltip() {
        let renderer = HTMLDocumentStreamRenderer()
        let labelled = String(
            decoding: renderer.render(.beginPreformatted(altText: "diagram \"one\" <wide>")),
            as: UTF8.self
        )
        let unlabelled = String(
            decoding: renderer.render(.beginPreformatted(altText: nil)),
            as: UTF8.self
        )

        XCTAssertTrue(labelled.contains("<pre title=\"diagram &quot;one&quot; &lt;wide&gt;\">"))
        XCTAssertFalse(unlabelled.contains("<pre title="))
    }

    func testContentThemePaletteSelectionDoesNotDependOnUIThemeForExplicitThemes() {
        XCTAssertFalse(ContentTheme.draculaLight.usesDarkPalette(effectiveDarkAppearance: true))
        XCTAssertTrue(ContentTheme.draculaDark.usesDarkPalette(effectiveDarkAppearance: false))
        XCTAssertTrue(ContentTheme.draculaClassic.usesDarkPalette(effectiveDarkAppearance: false))
        XCTAssertTrue(ContentTheme.ocean.usesDarkPalette(effectiveDarkAppearance: false))
        XCTAssertTrue(ContentTheme.forest.usesDarkPalette(effectiveDarkAppearance: false))
        XCTAssertFalse(ContentTheme.creamsicle.usesDarkPalette(effectiveDarkAppearance: true))
        XCTAssertFalse(ContentTheme.sandDunes.usesDarkPalette(effectiveDarkAppearance: true))
    }

    func testAutomaticThemePreferenceMigratesToDraculaDark() throws {
        let decoded = try JSONDecoder().decode(
            BrowserPreferences.self,
            from: Data(#"{"contentTheme":"automatic"}"#.utf8)
        )
        XCTAssertEqual(decoded.contentTheme, .draculaDark)
    }

    func testBrowserPreferencesUseMajorTomHomepageAndDraculaDarkByDefault() {
        let preferences = BrowserPreferences()
        XCTAssertEqual(preferences.homepage, "gemini://gemi.dev/major-tom/")
        XCTAssertEqual(preferences.contentTheme, .draculaDark)
        XCTAssertFalse(preferences.automaticallyLoadsSameCapsuleImages)
    }

    func testDraculaClassicMapsSemanticTextAndLineRoles() {
        let css = ContentTheme.draculaClassic.css(effectiveDarkAppearance: false)

        XCTAssertTrue(css.contains("--theme-selection: #44475a"))
        XCTAssertTrue(css.contains("h1, h2, h3 { color: var(--theme-heading); }"))
        XCTAssertTrue(css.contains("a:hover, a:focus { color: var(--theme-link-hover); }"))
        XCTAssertTrue(css.contains("strong { color: var(--theme-strong); }"))
        XCTAssertTrue(css.contains("em { color: var(--theme-emphasis); }"))
        XCTAssertTrue(css.contains("code { color: var(--theme-code); }"))
        XCTAssertTrue(css.contains("pre, code { background: var(--theme-surface); }"))
        XCTAssertTrue(css.contains(".list-item > span[aria-hidden=\"true\"] { color: var(--theme-accent); }"))
        XCTAssertTrue(css.contains("background: var(--theme-surface)"))
        XCTAssertTrue(css.contains(".browser-generated h1 { color: var(--theme-danger); }"))
        XCTAssertTrue(css.contains("blockquote { background: transparent !important; }"))
    }

    func testGeneratedSemanticThemesExposeTheirDistinctCorePalettes() {
        let expected: [(ContentTheme, String, String, String)] = [
            (.ocean, "#071a2b", "#38d6c8", "#69c7ff"),
            (.forest, "#2b3d29", "#c3e7d2", "#a9d6bb"),
            (.creamsicle, "#fff7ed", "#c2410c", "#006477"),
            (.sandDunes, "#f6e7c8", "#a84e32", "#006b6b")
        ]

        for (theme, background, heading, link) in expected {
            let css = theme.css(effectiveDarkAppearance: false)
            XCTAssertTrue(css.contains("--theme-background: \(background)"))
            XCTAssertTrue(css.contains("--theme-heading: \(heading)"))
            XCTAssertTrue(css.contains("--theme-link: \(link)"))
            XCTAssertTrue(css.contains("--theme-selection:"))
        }
    }

    func testForestAndCreamsicleRetainTheirReferencePaletteAnchors() {
        let forest = ContentTheme.forest.css(effectiveDarkAppearance: false)
        XCTAssertTrue(forest.contains("--theme-background: #2b3d29"))
        XCTAssertTrue(forest.contains("--theme-surface: #3a5a3c"))
        XCTAssertTrue(forest.contains("--theme-muted: #a9d6bb"))
        XCTAssertTrue(forest.contains("--theme-accent: #6a9a6d"))

        let creamsicle = ContentTheme.creamsicle.css(effectiveDarkAppearance: true)
        XCTAssertTrue(creamsicle.contains("--theme-surface: #ffcc80"))
        XCTAssertTrue(creamsicle.contains("--theme-selection: #ffad42"))
        XCTAssertTrue(creamsicle.contains("--theme-accent: #ff8c00"))
    }

    func testAdaptedForestAndCreamsicleTextRolesMeetAccessibleContrast() throws {
        for theme in [ContentTheme.forest, .creamsicle] {
            let palette = try XCTUnwrap(theme.semanticPalette)
            let pageTextColors = [
                palette.foreground, palette.muted, palette.heading, palette.link,
                palette.linkHover, palette.strong, palette.emphasis, palette.danger
            ]

            for color in pageTextColors {
                XCTAssertGreaterThanOrEqual(
                    contrastRatio(color, palette.background),
                    4.5,
                    "\(theme.rawValue): \(color.cssHex) on \(palette.background.cssHex)"
                )
            }
            XCTAssertGreaterThanOrEqual(contrastRatio(palette.code, palette.surface), 4.5)
            XCTAssertGreaterThanOrEqual(contrastRatio(palette.foreground, palette.surface), 4.5)
            XCTAssertGreaterThanOrEqual(contrastRatio(palette.foreground, palette.selection), 4.5)
        }
    }

    func testExistingDraculaDarkDoesNotGainClassicSemanticMapping() {
        let css = ContentTheme.draculaDark.css(effectiveDarkAppearance: true)
        XCTAssertFalse(css.contains("--theme-selection:"))
        XCTAssertFalse(css.contains("strong { color: var(--theme-strong); }"))
    }

    private func contrastRatio(_ first: ContentThemeColor, _ second: ContentThemeColor) -> Double {
        let firstLuminance = relativeLuminance(first)
        let secondLuminance = relativeLuminance(second)
        return (max(firstLuminance, secondLuminance) + 0.05)
            / (min(firstLuminance, secondLuminance) + 0.05)
    }

    private func relativeLuminance(_ color: ContentThemeColor) -> Double {
        func linearize(_ component: UInt8) -> Double {
            let value = Double(component) / 255
            return value <= 0.04045
                ? value / 12.92
                : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linearize(color.red)
            + 0.7152 * linearize(color.green)
            + 0.0722 * linearize(color.blue)
    }

    func testContentThemeCSSUsesItsResolvedPaletteBackground() {
        for theme in ContentTheme.allCases {
            for effectiveDarkAppearance in [false, true] {
                let palette = theme.palette(effectiveDarkAppearance: effectiveDarkAppearance)
                let css = theme.css(effectiveDarkAppearance: effectiveDarkAppearance)
                XCTAssertTrue(css.contains("--background: \(palette.background.cssHex)"))
            }
        }
    }

    func testPrintThemeOverridesDarkScreenTheme() {
        let css = ContentTheme.draculaDark.css(effectiveDarkAppearance: true)
        guard let darkBody = css.range(of: "body { color: var(--foreground); background: var(--background); }"),
              let printBody = css.range(of: "body { padding-top: 0 !important; color: #000 !important; background: #fff !important; }") else {
            return XCTFail("Expected both screen and print body styles")
        }

        XCTAssertLessThan(darkBody.lowerBound, printBody.lowerBound)
        XCTAssertTrue(css.contains("@page { margin: 0.65in; }"))
        XCTAssertTrue(css.contains(":root { color-scheme: light; zoom: 1 !important; font-size: 11pt; }"))
    }

    func testInlineEnhancementsAreConservativeAndEscaped() {
        let rendered = HTMLDocumentStreamRenderer.renderInline(
            "Use **strong**, *emphasis*, and `code <here>`; leave *unmatched visible"
        )
        XCTAssertEqual(
            rendered,
            "Use <strong><span class=\"delimiter\">**</span>strong<span class=\"delimiter\">**</span></strong>, "
                + "<em><span class=\"delimiter\">*</span>emphasis<span class=\"delimiter\">*</span></em>, and "
                + "<code><span class=\"delimiter\">`</span>code &lt;here&gt;<span class=\"delimiter\">`</span></code>; "
                + "leave *unmatched visible"
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
            "<strong><span class=\"delimiter\">**</span>yes<span class=\"delimiter\">**</span></strong> *no* `no`"
        )
    }

    /// The author's characters must survive rendering even when recognition fires where
    /// it should not. Stripping the tags must give back exactly the input.
    func testInlineEnhancementsNeverRemoveAuthorCharacters() {
        for input in [
            "2*3 and 4*5",
            "C:\\*.txt and *.md",
            "See note* and other* thing",
            "take `foo.bmp` and move it",
            "**bold** and *italic* together"
        ] {
            let rendered = HTMLDocumentStreamRenderer.renderInline(input)
            let stripped = rendered.replacingOccurrences(
                of: "<[^>]+>",
                with: "",
                options: .regularExpression
            )
            XCTAssertEqual(stripped, input, "delimiters were lost rendering \(input.debugDescription)")
        }
    }

    /// A proxied request connects to the proxy but asks for the original web URL.
    func testProxiedRequestTargetsProxyButRequestsOriginalURL() throws {
        let proxy = GeminiProxyConfiguration(host: "localhost", port: 1_994)
        let target = try GeminiRequestTarget(
            proxying: URL(string: "https://example.com/a/b?q=1")!,
            through: proxy
        )

        // Connection goes to the proxy, so TOFU pins the proxy's identity.
        XCTAssertEqual(target.endpoint, CapsuleEndpoint(host: "localhost", port: 1_994))
        // The request line is the original URL, not a gemini:// one.
        XCTAssertEqual(
            String(decoding: target.requestData, as: UTF8.self),
            "https://example.com/a/b?q=1\r\n"
        )
        // History and the address field show what the user asked for.
        XCTAssertEqual(target.url.absoluteString, "https://example.com/a/b?q=1")
    }

    func testProxiedRequestRejectsUnusableInput() {
        let proxy = GeminiProxyConfiguration(host: "localhost", port: 1_994)
        XCTAssertThrowsError(
            try GeminiRequestTarget(proxying: URL(string: "relative/path")!, through: proxy)
        )
        XCTAssertThrowsError(
            try GeminiRequestTarget(
                proxying: URL(string: "https://example.com/")!,
                through: GeminiProxyConfiguration(host: "  ", port: 1_994)
            )
        )
        // The 1024-byte request limit still applies to the proxied request line.
        let long = "https://example.com/" + String(repeating: "a", count: 1_100)
        XCTAssertThrowsError(
            try GeminiRequestTarget(proxying: URL(string: long)!, through: proxy)
        )
    }

    func testBrowserPreferencesRoundTrip() throws {
        let original = BrowserPreferences(
            homepage: "gemini://example.com/",
            searchProvider: .custom,
            customSearchEndpoint: "gemini://search.example/query",
            applicationAppearance: .dark,
            contentTheme: .draculaLight,
            contentWidth: .wide,
            proxy: GeminiProxyConfiguration(host: "proxy.example", port: 8080),
            automaticallyLoadsSameCapsuleImages: false
        )
        let decoded = try JSONDecoder().decode(
            BrowserPreferences.self,
            from: JSONEncoder().encode(original)
        )
        XCTAssertEqual(decoded, original)
    }

    func testContentWidthCSSUsesExpectedScreenWidths() {
        XCTAssertTrue(ContentWidth.narrow.css.contains("max-width: 48rem"))
        XCTAssertTrue(ContentWidth.wide.css.contains("max-width: 56rem"))
        XCTAssertTrue(ContentWidth.full.css.contains("max-width: none"))
        XCTAssertTrue(ContentWidth.full.css.hasPrefix("@media screen"))
    }

    func testMissingContentWidthDecodesAsNarrow() throws {
        let decoded = try JSONDecoder().decode(
            BrowserPreferences.self,
            from: Data("{}".utf8)
        )
        XCTAssertEqual(decoded.contentWidth, .narrow)
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
