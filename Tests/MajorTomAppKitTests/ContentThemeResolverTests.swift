import AppKit
import MajorTomCore
import WebKit
import XCTest
@testable import MajorTomAppKitSupport

final class ContentThemeResolverTests: XCTestCase {
    @MainActor
    func testBundledCSSResolvesAndANSIArtRemainsReadable() async throws {
        for theme in ContentTheme.bundled {
            let resolved = try await ContentThemeResolver().resolve(theme, appearance: theme.appearance)
            let palette = resolved.palette
            XCTAssertGreaterThanOrEqual(palette.foreground.contrastRatio(against: palette.background), 4.5, theme.name)
            for background in [palette.background, palette.codeBackground] {
                for index in 0...255 {
                    for bold in [false, true] {
                        let color = ANSIColor.palette(index).resolved(bold: bold)
                        XCTAssertGreaterThanOrEqual(
                            ANSIContrast.adapted(color, on: background).contrastRatio(against: background),
                            ANSIContrast.minimumRatio, theme.name
                        )
                    }
                }
            }
            // Every readable role must work in every bundled theme, including small captions.
            do {
                for role in ["foreground", "heading", "link", "strong", "emphasis", "muted"] {
                    let color = try XCTUnwrap(resolved.colors[role])
                    XCTAssertGreaterThanOrEqual(color.contrastRatio(against: palette.background), 4.5, "\(theme.name): \(role)")
                }
                XCTAssertGreaterThanOrEqual(try XCTUnwrap(resolved.colors["code"]).contrastRatio(against: XCTUnwrap(resolved.colors["codeSurface"])), 4.5)
                XCTAssertGreaterThanOrEqual(try XCTUnwrap(resolved.colors["quote"]).contrastRatio(against: XCTUnwrap(resolved.colors["quoteSurface"])), 4.5)
                // Source-number captions also appear over the hovered source-line surface.
                XCTAssertGreaterThanOrEqual(try XCTUnwrap(resolved.colors["muted"]).contrastRatio(against: palette.codeBackground), 4.5, theme.name)
            }
        }
    }

    @MainActor
    func testBothAppearancesUseTheAppChoiceAndResolveFullCSSCascade() async throws {
        let theme = try ContentTheme(id: "custom:test.css", css: """
        /*
        @name Both
        @appearance both
        */
        :root { --background: white; --foreground: black; --surface: var(--background); }
        :root[data-appearance="dark"] { --background: black; --foreground: white; }
        body { background: var(--background); }
        pre { background: color-mix(in srgb, var(--background) 80%, var(--foreground)); }
        pre { color: lime; }
        """)
        let light = try await ContentThemeResolver().resolve(theme, appearance: .light)
        let dark = try await ContentThemeResolver().resolve(theme, appearance: .dark)
        XCTAssertGreaterThan(light.palette.background.relativeLuminance, dark.palette.background.relativeLuminance)
        XCTAssertLessThan(light.palette.foreground.relativeLuminance, dark.palette.foreground.relativeLuminance)
        // Native and ANSI colors must reflect element overrides, not just root variables.
        XCTAssertNotEqual(light.palette.background, light.palette.codeBackground)
        XCTAssertNotEqual(dark.palette.background, dark.palette.codeBackground)
        XCTAssertNotEqual(dark.palette.codeForeground, dark.palette.foreground)
        XCTAssertGreaterThanOrEqual(light.palette.foreground.contrastRatio(against: light.palette.codeBackground), 4.5)
        XCTAssertGreaterThanOrEqual(dark.palette.foreground.contrastRatio(against: dark.palette.codeBackground), 4.5)
    }

    @MainActor
    func testEditingOnlyCSSChangesTheResolvedPalette() async throws {
        let header = "/*\n@name Editable\n@appearance dark\n*/\n"
        let first = try ContentTheme(id: "custom:editable.css", css: header + "body { background: navy; color: white; }")
        let edited = try ContentTheme(id: first.id, css: header + "body { background: maroon; color: white; }")
        let before = try await ContentThemeResolver().resolve(first, appearance: .dark)
        let after = try await ContentThemeResolver().resolve(edited, appearance: .dark)
        XCTAssertNotEqual(before.palette.background, after.palette.background)
        XCTAssertEqual(before.palette.foreground, after.palette.foreground)
    }

    @MainActor
    func testHintedLinksDoNotMakeTheBlankRemainderOfTheRowClickable() async throws {
        // Prevents CSS Grid stretching links into the blank space beside their label.
        let document = ThemeTestDocument()
        let renderer = HTMLDocumentStreamRenderer()
        let html = String(decoding: renderer.documentStart(), as: UTF8.self)
            + String(decoding: renderer.render(.link(destination: "gemini://example.invalid/", label: "Short")), as: UTF8.self)
            + String(decoding: renderer.documentEnd(), as: UTF8.self)
        try await document.load(html)
        let result = try await document.view.evaluateJavaScript("""
        (() => {
          const anchor = document.querySelector('.link-line > a');
          const row = anchor.parentElement.getBoundingClientRect();
          const bounds = anchor.getBoundingClientRect();
          const target = document.elementFromPoint(row.right - 5, bounds.y + bounds.height / 2);
          return [bounds.width, row.width, !!target?.closest('a')];
        })()
        """)
        let values = try XCTUnwrap(result as? [NSNumber])
        XCTAssertLessThan(values[0].doubleValue, values[1].doubleValue / 2)
        XCTAssertFalse(values[2].boolValue)
    }

    @MainActor
    func testClassicDraculaHasDistinctHeadingEmphasisAndCodeColors() async throws {
        // Prevents a review export silently substituting the older plain Dracula variant.
        let theme = try XCTUnwrap(ContentTheme.bundled.first { $0.id == "draculaClassic" })
        let resolved = try await ContentThemeResolver().resolve(theme, appearance: .dark)
        for role in ["heading", "strong", "emphasis", "code", "link"] {
            XCTAssertNotEqual(resolved.colors[role], resolved.colors["foreground"], role)
        }
    }

    @MainActor
    func testPreformattedWhitespaceAndNativeCollapseControlsSurviveStreaming() async throws {
        // Removing per-line spans must preserve the first blank line and multiline controls.
        let renderer = HTMLDocumentStreamRenderer()
        var html = renderer.documentStart()
        html.append(renderer.render(.beginPreformatted(altText: "Art")))
        html.append(renderer.render(.preformattedLine("")))
        html.append(renderer.render(.preformattedLine("  art  ")))
        html.append(renderer.render(.endPreformatted))
        html.append(renderer.render(.beginPreformatted(altText: "Single line")))
        html.append(renderer.render(.preformattedLine("one")))
        html.append(renderer.render(.endPreformatted))
        html.append(renderer.documentEnd())
        let document = ThemeTestDocument()
        try await document.load(String(decoding: html, as: UTF8.self))
        let result = try await document.view.evaluateJavaScript("""
        (() => {
          const pre = document.querySelector('pre');
          const block = pre.parentElement;
          return [pre.textContent, pre.children.length, block.classList.contains('is-multiline'),
                  pre.getAttribute('role'), pre.tabIndex];
        })()
        """)
        let values = try XCTUnwrap(result as? [Any])
        XCTAssertEqual(values[0] as? String, "\n  art  \n")
        XCTAssertEqual(values[1] as? Int, 0)
        XCTAssertEqual(values[2] as? Bool, true)
        XCTAssertEqual(values[3] as? String, "button")
        XCTAssertEqual(values[4] as? Int, 0)
        _ = try await document.view.evaluateJavaScript("document.querySelector('pre').append(document.createTextNode('third line\\n'))")
        let text = try await document.view.evaluateJavaScript("document.querySelector('pre').textContent")
        XCTAssertEqual(text as? String, "\n  art  \nthird line\n")
        let initiallyMultiline = try await document.view.evaluateJavaScript("document.querySelectorAll('pre')[1].parentElement.classList.contains('is-multiline')")
        XCTAssertEqual(initiallyMultiline as? Bool, false)
        _ = try await document.view.evaluateJavaScript("document.querySelectorAll('pre')[1].firstChild.appendData('two\\n')")
        let becameMultiline = try await document.view.evaluateJavaScript("document.querySelectorAll('pre')[1].parentElement.classList.contains('is-multiline')")
        XCTAssertEqual(becameMultiline as? Bool, true)
    }

    @MainActor
    func testSourceUsesNativeLineNumbersWithoutChangingSelectedText() async throws {
        let renderer = HTMLDocumentStreamRenderer()
        var html = renderer.documentStart(kind: .source)
        html.append(Data(HTMLDocumentStreamRenderer.sourceStart.utf8))
        for line in ["# Title", "", "  <source>&"] { html.append(Data(HTMLDocumentStreamRenderer.sourceLine(line).utf8)) }
        html.append(Data(HTMLDocumentStreamRenderer.sourceEnd.utf8))
        html.append(renderer.documentEnd())
        let document = ThemeTestDocument()
        try await document.load(String(decoding: html, as: UTF8.self))
        let result = try await document.view.evaluateJavaScript("""
        (() => {
          const list = document.querySelector('ol');
          const selection = window.getSelection();
          selection.selectAllChildren(list);
          return [list.children.length, selection.toString(), getComputedStyle(list).listStyleType];
        })()
        """)
        let values = try XCTUnwrap(result as? [Any])
        XCTAssertEqual(values[0] as? Int, 3)
        let selected = try XCTUnwrap(values[1] as? String)
        XCTAssertTrue(selected.contains("# Title"))
        XCTAssertTrue(selected.contains("  <source>&"))
        XCTAssertFalse(selected.contains("1."))
        XCTAssertEqual(values[2] as? String, "decimal")
    }

    @MainActor
    func testSystemMonospaceKeepsASCIICellsAndBrailleFallbackInternallyConsistent() async throws {
        // ASCII grids must align; the system Braille fallback may use a different cell width.
        let renderer = HTMLDocumentStreamRenderer()
        var html = renderer.documentStart()
        html.append(renderer.render(.beginPreformatted(altText: nil)))
        html.append(renderer.render(.preformattedLine(" M─█⠀⣿")))
        html.append(renderer.render(.endPreformatted))
        html.append(renderer.documentEnd())
        let document = ThemeTestDocument()
        try await document.load(String(decoding: html, as: UTF8.self))
        let result = try await document.view.callAsyncJavaScript("""
        const pre = document.querySelector('pre');
        const widths = Array.from(pre.textContent.trimEnd(), character => {
          const row = document.createElement('span');
          row.style.display = 'inline-block';
          row.textContent = character.repeat(64);
          pre.appendChild(row);
          const width = row.getBoundingClientRect().width / 64;
          row.remove();
          return width;
        });
        return widths;
        """, arguments: [:], in: nil, contentWorld: .page)
        let widths = try XCTUnwrap(result as? [Double])
        let cell = try XCTUnwrap(widths.first)
        XCTAssertGreaterThan(cell, 0)
        for width in widths.prefix(4) { XCTAssertEqual(width, cell, accuracy: 0.05) }
        XCTAssertGreaterThan(widths[4], 0)
        XCTAssertEqual(widths[4], widths[5], accuracy: 0.05)
    }

    @MainActor
    func testTextPitchAndConsecutiveBlankLinesPreserveSourceSpacing() async throws {
        // Prevents paragraph margins doubling the source's explicit blank-line spacing.
        let renderer = HTMLDocumentStreamRenderer()
        var html = renderer.documentStart()
        for event: GemtextEvent in [.text("First"), .text("Second"), .blank, .text("Third"), .blank, .blank, .text("Fourth")] {
            html.append(renderer.render(event))
        }
        html.append(renderer.documentEnd())
        for theme in ContentTheme.bundled {
            let document = ThemeTestDocument()
            let themedHTML = String(decoding: html, as: UTF8.self).replacingOccurrences(
                of: "</style>", with: theme.css + "</style>"
            )
            try await document.load(themedHTML)
            let result = try await document.view.evaluateJavaScript("""
            (() => {
              const p = [...document.querySelectorAll('main > p')];
              const pitch = parseFloat(getComputedStyle(p[0]).lineHeight);
              return [pitch, p[1].offsetTop - p[0].offsetTop, p[2].offsetTop - p[1].offsetTop, p[3].offsetTop - p[2].offsetTop];
            })()
            """)
            let values = try XCTUnwrap(result as? [Double], theme.name)
            XCTAssertEqual(values[1], values[0], accuracy: 1)
            XCTAssertEqual(values[2], values[0] * 2, accuracy: 1)
            XCTAssertEqual(values[3], values[0] * 3, accuracy: 1)
        }
    }

    @MainActor
    func testHeadingGapsDoNotAddMarginsToSourceBlankLines() async throws {
        // Prevents heading margins inflating the In-line Styles → Links → Gemini links gaps.
        let renderer = HTMLDocumentStreamRenderer()
        var html = renderer.documentStart()
        for event: GemtextEvent in [
            .heading(level: 2, text: "In-line Styles"), .blank, .text("Paragraph"),
            .blank, .blank, .heading(level: 2, text: "Links"),
            .blank, .blank, .heading(level: 3, text: "Gemini links")
        ] {
            html.append(renderer.render(event))
        }
        html.append(renderer.documentEnd())
        let document = ThemeTestDocument()
        try await document.load(String(decoding: html, as: UTF8.self))
        let result = try await document.view.evaluateJavaScript("""
        (() => {
          const headings = [...document.querySelectorAll('h2, h3')].map(h => h.getBoundingClientRect());
          const paragraph = document.querySelector('p');
          const p = paragraph.getBoundingClientRect();
          const pitch = parseFloat(getComputedStyle(paragraph).lineHeight);
          return [pitch, p.top - headings[0].bottom, headings[1].top - p.bottom,
                  headings[2].top - headings[1].bottom];
        })()
        """)
        let gaps = try XCTUnwrap(result as? [Double])
        XCTAssertEqual(gaps[1], gaps[0], accuracy: 1)
        XCTAssertEqual(gaps[2], gaps[0] * 2, accuracy: 1)
        XCTAssertEqual(gaps[3], gaps[0] * 2, accuracy: 1)
    }

    @MainActor
    func testCompactBlocksHaveGapsWithoutInflatingExplicitBlankLines() async throws {
        // Compact capsules need separation, while source breaks must never stack with margins.
        for kind in ["heading", "quote", "art"] {
            var measured: [Double] = []
            for blanks in 0...2 {
                let renderer = HTMLDocumentStreamRenderer()
                var html = renderer.documentStart()
                html.append(renderer.render(.text("Before")))
                for _ in 0..<blanks { html.append(renderer.render(.blank)) }
                if kind == "heading" {
                    html.append(renderer.render(.heading(level: 2, text: "Section")))
                } else if kind == "quote" {
                    html.append(renderer.render(.quote("Quotation")))
                } else {
                    html.append(renderer.render(.beginPreformatted(altText: nil)))
                    html.append(renderer.render(.preformattedLine("Art")))
                    html.append(renderer.render(.endPreformatted))
                }
                for _ in 0..<blanks { html.append(renderer.render(.blank)) }
                html.append(renderer.render(.text("After")))
                html.append(renderer.documentEnd())
                let document = ThemeTestDocument()
                try await document.load(String(decoding: html, as: UTF8.self))
                let result = try await document.view.evaluateJavaScript("""
                (() => {
                  const blocks = [...document.querySelector('main').children].filter(e => e.tagName !== 'BR');
                  const b = blocks.map(e => e.getBoundingClientRect());
                  const pitch = parseFloat(getComputedStyle(blocks[0]).lineHeight);
                  return [b[1].top - b[0].bottom, b[2].top - b[1].bottom, pitch];
                })()
                """)
                let gaps = try XCTUnwrap(result as? [Double])
                XCTAssertGreaterThan(gaps[0], 0, kind)
                XCTAssertGreaterThan(gaps[1], 0, kind)
                if blanks > 0 {
                    for gap in gaps.prefix(2) {
                        XCTAssertEqual(gap, gaps[2] * Double(blanks), accuracy: 1, kind)
                    }
                }
                measured.append(gaps[0])
            }
            XCTAssertEqual(measured[2], 2 * measured[1], accuracy: 1, kind)
        }
    }

    @MainActor
    func testReadingWidthsAndLargeTextContainLongLinksAndArt() async throws {
        // Long URL grid items and ASCII art must not force the entire page sideways.
        let renderer = HTMLDocumentStreamRenderer()
        var content = renderer.render(.text("Ordinary readable text."))
        content.append(renderer.render(.link(destination: "gemini://example.invalid/" + String(repeating: "long", count: 150), label: nil)))
        content.append(renderer.render(.beginPreformatted(altText: nil)))
        content.append(renderer.render(.preformattedLine(String(repeating: "M", count: 300))))
        content.append(renderer.render(.endPreformatted))
        var widths: [Double] = []
        for width in ContentWidth.allCases {
            let document = ThemeTestDocument()
            document.view.setFrameSize(NSSize(width: 1200, height: 700))
            var html = renderer.documentStart(themeCSS: ContentThemeStylesheets.base + width.css)
            html.append(content)
            html.append(renderer.documentEnd())
            try await document.load(String(decoding: html, as: UTF8.self))
            let size = try await document.view.evaluateJavaScript("document.querySelector('main').getBoundingClientRect().width")
            widths.append(try XCTUnwrap(size as? Double))
            for zoom in [1, 2, 3] {
                _ = try await document.view.evaluateJavaScript("document.documentElement.style.zoom = '\(zoom)'")
                let result = try await document.view.evaluateJavaScript("""
                (() => {
                  const pre = document.querySelector('pre');
                  const main = document.querySelector('main').getBoundingClientRect();
                  const link = document.querySelector('.link-line > a').getBoundingClientRect();
                  return [document.documentElement.scrollWidth - document.documentElement.clientWidth,
                          pre.scrollWidth - pre.clientWidth, link.right - main.right];
                })()
                """)
                let values = try XCTUnwrap(result as? [Double])
                XCTAssertLessThanOrEqual(values[0], 1, "\(width) at \(zoom)x")
                XCTAssertGreaterThan(values[1], 0)
                XCTAssertLessThanOrEqual(values[2], 1)
            }
        }
        XCTAssertLessThan(widths[0], widths[1])
        XCTAssertLessThan(widths[1], widths[2])
    }

    @MainActor
    func testTypographyVariablesControlBodyArtAndQuoteSpacingTogether() async throws {
        // Theme authors can change leading without leaving quote paragraph gaps at the old size.
        let renderer = HTMLDocumentStreamRenderer()
        var html = renderer.documentStart(themeCSS: ContentThemeStylesheets.base + """
        :root { --body-size: 20px; --body-leading: 1.8; --mono-size: 1rem; --mono-leading: 1.6; }
        """)
        for event: GemtextEvent in [.quote("First"), .quote(""), .quote("Second"), .blank,
            .beginPreformatted(altText: nil), .preformattedLine("Art"), .endPreformatted] {
            html.append(renderer.render(event))
        }
        html.append(renderer.documentEnd())
        let document = ThemeTestDocument()
        try await document.load(String(decoding: html, as: UTF8.self))
        let result = try await document.view.evaluateJavaScript("""
        (() => {
          const p = document.querySelectorAll('blockquote > p');
          const pitch = parseFloat(getComputedStyle(p[0]).lineHeight);
          return [pitch, p[1].getBoundingClientRect().top - p[0].getBoundingClientRect().bottom,
                  parseFloat(getComputedStyle(document.querySelector('pre')).fontSize),
                  parseFloat(getComputedStyle(document.body).fontSize)];
        })()
        """)
        let values = try XCTUnwrap(result as? [Double])
        XCTAssertEqual(values[1], values[0], accuracy: 1)
        XCTAssertEqual(values[2], values[3], accuracy: 0.1)
    }

    @MainActor
    func testPlainTextPreservesLeadingBlankLinesAcrossCRLFChunks() async throws {
        // HTML normalizes CRLF before suppressing the first newline after <pre>.
        for chunks in [["\n", "  text\n"], ["\r", "\n  text\r\n"]] {
            let renderer = HTMLDocumentStreamRenderer()
            var html = renderer.documentStart(kind: .plainText)
            html.append(renderer.beginPlainText())
            for chunk in chunks { html.append(renderer.renderPlainTextChunk(chunk)) }
            html.append(renderer.endPlainText())
            html.append(renderer.documentEnd())
            let document = ThemeTestDocument()
            try await document.load(String(decoding: html, as: UTF8.self))
            let text = try await document.view.evaluateJavaScript("document.querySelector('pre').textContent")
            XCTAssertEqual(text as? String, "\n  text\n")
        }
    }
}

@MainActor
private final class ThemeTestDocument: NSObject, WKNavigationDelegate {
    let view: WKWebView = {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.addUserScript(PreformattedBlockPresentationScript.userScript)
        return WKWebView(frame: NSRect(x: 0, y: 0, width: 900, height: 700), configuration: configuration)
    }()
    private var continuation: CheckedContinuation<Void, any Error>?

    func load(_ html: String) async throws {
        view.navigationDelegate = self
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            view.loadHTMLString(html, baseURL: nil)
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        continuation?.resume()
        continuation = nil
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        continuation?.resume(throwing: error)
        continuation = nil
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        continuation?.resume(throwing: error)
        continuation = nil
    }
}
