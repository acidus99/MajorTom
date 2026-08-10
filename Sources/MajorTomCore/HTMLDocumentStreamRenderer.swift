import Foundation

public struct HTMLRenderingOptions: Equatable, Codable, Sendable {
    public var recognizesEmphasis: Bool
    public var recognizesStrongEmphasis: Bool
    public var recognizesInlineCode: Bool
    /// Renders a run of consecutive quote lines as one continuous quotation rather
    /// than as separate blocks with whitespace between them.
    public var collapsesConsecutiveQuotes: Bool
    /// Shows a glyph ahead of each link label indicating where the link leads.
    public var showsLinkHints: Bool

    public init(
        recognizesEmphasis: Bool = true,
        recognizesStrongEmphasis: Bool = true,
        recognizesInlineCode: Bool = true,
        collapsesConsecutiveQuotes: Bool = true,
        showsLinkHints: Bool = true
    ) {
        self.recognizesEmphasis = recognizesEmphasis
        self.recognizesStrongEmphasis = recognizesStrongEmphasis
        self.recognizesInlineCode = recognizesInlineCode
        self.collapsesConsecutiveQuotes = collapsesConsecutiveQuotes
        self.showsLinkHints = showsLinkHints
    }

    /// Decodes leniently so that adding an option cannot discard a user's settings.
    ///
    /// `BrowserPreferences` is loaded with `try?`, so one missing key would fail the
    /// whole decode and silently reset the homepage, search provider, proxy and
    /// trusted-appearance choices back to defaults.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        recognizesEmphasis = try container.decodeIfPresent(Bool.self, forKey: .recognizesEmphasis) ?? true
        recognizesStrongEmphasis = try container.decodeIfPresent(Bool.self, forKey: .recognizesStrongEmphasis) ?? true
        recognizesInlineCode = try container.decodeIfPresent(Bool.self, forKey: .recognizesInlineCode) ?? true
        collapsesConsecutiveQuotes = try container.decodeIfPresent(Bool.self, forKey: .collapsesConsecutiveQuotes) ?? true
        showsLinkHints = try container.decodeIfPresent(Bool.self, forKey: .showsLinkHints) ?? true
    }
}

public struct HTMLDocumentStreamRenderer: Sendable {
    public init() {}

    public func documentStart(
        themeCSS: String = Self.defaultThemeCSS + Self.printThemeCSS,
        baseURL: URL? = nil,
        browserGenerated: Bool = false
    ) -> Data {
        let base = baseURL.map {
            "<base href=\"\(Self.escapeAttribute($0.absoluteString))\">"
        } ?? ""
        let documentClass = browserGenerated ? " class=\"browser-generated\"" : ""
        let html = """
        <!doctype html><html><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width,initial-scale=1">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src data: majortom-resource:; style-src 'unsafe-inline'">
        \(base)<style id="majortom-theme">\(themeCSS)</style></head><body\(documentClass)><main>
        """
        return Data(html.utf8)
    }

    /// - Parameter baseURL: the document's own URL, used to tell a link that stays
    ///   inside the capsule from one that leaves it. Without it, link hints can still
    ///   report scheme but not locality.
    /// - Parameter linkIdentifier: an `id` for this link's line, so the host can find it
    ///   again to attach an expanded image beneath it.
    /// - Parameter isExpandableImage: marks the line as opting in to click-to-expand.
    ///   Only marked lines have their clicks intercepted, so ordinary links keep going
    ///   through the navigation decider untouched.
    public func render(
        _ event: GemtextEvent,
        options: HTMLRenderingOptions = HTMLRenderingOptions(),
        baseURL: URL? = nil,
        linkIdentifier: String? = nil,
        isExpandableImage: Bool = false
    ) -> Data {
        let html: String
        switch event {
        case .text(let text):
            html = "<p>\(Self.renderInline(text, options: options))</p>"
        case .heading(let level, let text):
            html = "<h\(level)>\(Self.renderInline(text, options: options))</h\(level)>"
        case .link(let destination, let label):
            let visibleText = label ?? destination
            let hint = options.showsLinkHints
                ? GemtextLinkHint.classify(destination: destination, relativeTo: baseURL)
                : nil
            // aria-hidden, because the glyph is shorthand for what the href already
            // states, and "rightwards double arrow" announced before every link is
            // noise rather than information.
            let hintMarkup = hint.map {
                "<span class=\"link-hint\" aria-hidden=\"true\">\(Self.escape($0.rawValue))</span>"
            } ?? ""
            var attributes = "class=\"link-line\""
            if let linkIdentifier {
                attributes += " id=\"\(Self.escapeAttribute(linkIdentifier))\""
            }
            if isExpandableImage {
                attributes += " data-mt-expandable=\"1\""
            }
            html = "<p \(attributes)>\(hintMarkup)<a href=\"\(Self.escapeAttribute(destination))\">\(Self.renderInline(visibleText, options: options))</a></p>"
        case .listItem(let text):
            html = "<div class=\"list-item\"><span aria-hidden=\"true\">•</span><span>\(Self.renderInline(text, options: options))</span></div>"
        case .quote(let text):
            html = "<blockquote>\(Self.renderInline(text, options: options))</blockquote>"
        case .blank:
            html = "<div class=\"blank\" aria-hidden=\"true\"></div>"
        case .beginPreformatted(let altText):
            // <details>/<summary> is a native disclosure control needing no JavaScript,
            // which matters because the document's CSP is `default-src 'none'`.
            // Text on the opening fence is conventionally a description of the block —
            // most often ASCII art — so it is exactly what should remain visible when
            // the block is collapsed. Open by default.
            let summary = altText.map(Self.escape) ?? "Preformatted text"
            let unlabelled = altText == nil ? " class=\"unlabelled\"" : ""
            html = "<details class=\"pre-block\" open><summary\(unlabelled)>\(summary)</summary><pre><code>"
        case .preformattedLine(let text):
            html = Self.escape(text) + "\n"
        case .endPreformatted:
            html = "</code></pre></details>"
        }
        return Data(html.utf8)
    }

    public func documentEnd(incompleteMessage: String? = nil) -> Data {
        let notice = incompleteMessage.map {
            "<aside class=\"incomplete\" role=\"status\">\(Self.escape($0))</aside>"
        } ?? ""
        return Data("\(notice)</main></body></html>".utf8)
    }

    public func renderInlineImage(
        resourceURL: URL,
        linkURL: URL,
        altText: String,
        figureIdentifier: String,
        fileName: String,
        mimeType: String? = nil,
        sizeDescription: String? = nil,
        figureClass: String? = nil
    ) -> Data {
        let classAttribute = figureClass.map {
            " class=\"\(Self.escapeAttribute($0))\""
        } ?? ""
        let mimeAttribute = mimeType.map {
            " data-mt-mime=\"\(Self.escapeAttribute($0))\""
        } ?? ""
        let sizeAttribute = sizeDescription.map {
            " data-mt-size=\"\(Self.escapeAttribute($0))\""
        } ?? ""
        let html = "<figure id=\"\(Self.escapeAttribute(figureIdentifier))\"\(classAttribute)>"
            + "<a href=\"\(Self.escapeAttribute(linkURL.absoluteString))\">"
            + "<img src=\"\(Self.escapeAttribute(resourceURL.absoluteString))\""
            + " alt=\"\(Self.escapeAttribute(altText))\" loading=\"eager\""
            + " data-mt-inline-image=\"1\""
            + " data-mt-filename=\"\(Self.escapeAttribute(fileName))\""
            + mimeAttribute + sizeAttribute + "></a>"
            + "<figcaption>\(Self.escape(fileName))</figcaption></figure>"
        return Data(html.utf8)
    }

    public static func escape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    public static func escapeAttribute(_ value: String) -> String {
        escape(value)
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }

    public static func renderInline(
        _ value: String,
        options: HTMLRenderingOptions = HTMLRenderingOptions()
    ) -> String {
        var output = ""
        var remainder = value[...]

        while !remainder.isEmpty {
            let candidates: [(range: Range<Substring.Index>, marker: String, tag: String)] = [
                options.recognizesStrongEmphasis ? paired("**", in: remainder).map { ($0, "**", "strong") } : nil,
                options.recognizesEmphasis ? paired("*", in: remainder, excludingDouble: true).map { ($0, "*", "em") } : nil,
                options.recognizesInlineCode ? paired("`", in: remainder).map { ($0, "`", "code") } : nil
            ].compactMap { $0 }

            guard let candidate = candidates.min(by: { $0.range.lowerBound < $1.range.lowerBound }) else {
                output += escape(String(remainder))
                break
            }

            output += escape(String(remainder[..<candidate.range.lowerBound]))
            let contentStart = remainder.index(candidate.range.lowerBound, offsetBy: candidate.marker.count)
            let contentEnd = remainder.index(candidate.range.upperBound, offsetBy: -candidate.marker.count)

            // The author's delimiters stay in the document. Major Tom adds styling; it
            // never removes characters the author typed (spec 3.4, 5.1). This also
            // makes over-matching harmless: `2*3 and 4*5` still reads as written, it
            // merely picks up an unwanted italic, instead of silently losing both
            // asterisks as it did when the delimiters were consumed.
            let delimiter = "<span class=\"delimiter\">\(escape(candidate.marker))</span>"
            output += "<\(candidate.tag)>"
                + delimiter
                + escape(String(remainder[contentStart..<contentEnd]))
                + delimiter
                + "</\(candidate.tag)>"
            remainder = remainder[candidate.range.upperBound...]
        }
        return output
    }

    private static func paired(
        _ marker: String,
        in value: Substring,
        excludingDouble: Bool = false
    ) -> Range<Substring.Index>? {
        var searchStart = value.startIndex
        while let opening = value.range(of: marker, range: searchStart..<value.endIndex) {
            if excludingDouble {
                let beforeIsStar = opening.lowerBound > value.startIndex
                    && value[value.index(before: opening.lowerBound)] == "*"
                let afterIsStar = opening.upperBound < value.endIndex
                    && value[opening.upperBound] == "*"
                if beforeIsStar || afterIsStar {
                    searchStart = opening.upperBound
                    continue
                }
            }
            guard let closing = value.range(of: marker, range: opening.upperBound..<value.endIndex),
                  closing.lowerBound != opening.upperBound else {
                searchStart = opening.upperBound
                continue
            }
            if excludingDouble,
               closing.upperBound < value.endIndex,
               value[closing.upperBound] == "*" {
                searchStart = opening.upperBound
                continue
            }
            return opening.lowerBound..<closing.upperBound
        }
        return nil
    }

    /// Joins a run of consecutive `<blockquote>` elements into one visual block.
    ///
    /// Done in CSS rather than by making the renderer stateful. Gemtext quotes one
    /// line at a time, so a multi-line quotation is a run of sibling blockquotes;
    /// dropping the margin and the corner rounding between adjacent siblings makes
    /// the shared left rule continuous. A blank line between quotes emits a
    /// `.blank` div, which breaks the adjacency and correctly keeps the two
    /// quotations apart. Purely presentational, so the source bytes, View Source and
    /// Save Page As are untouched (spec 5.1).
    public static let collapsedQuotesCSS = """

    blockquote + blockquote { margin-top: 0; padding-top: 0; }
    blockquote:has(+ blockquote) { margin-bottom: 0; padding-bottom: 0; }
    """

    public static let defaultThemeCSS = """
    :root { color-scheme: light dark; font: 17px/1.55 -apple-system, BlinkMacSystemFont, sans-serif; }
    body { margin: 0; padding-top: 7.25rem; color: CanvasText; background: Canvas; }
    main { box-sizing: border-box; max-width: 48rem; margin: 0 auto; padding: 3rem 2rem 6rem; }
    h1, h2, h3 { line-height: 1.2; }
    h1 { font-size: 2rem; } h2 { font-size: 1.5rem; } h3 { font-size: 1.2rem; }
    p { margin: .7rem 0; }
    a { color: LinkText; text-underline-offset: .15em; }
    .link-line { margin: .45rem 0; }
    /* A hinted link line becomes a two-column grid so every label starts at the same
       x position, whether its glyph is a narrow arrow or a full-width emoji. */
    .link-line:has(.link-hint) { display: grid; grid-template-columns: 1.6rem 1fr; align-items: baseline; }
    /* Grid items stretch across their cell by default, which made the visually blank
       space to the right of a label behave like part of the link. */
    .link-line:has(.link-hint) > a { justify-self: start; }
    .link-hint { opacity: .55; font-size: .9em; -webkit-user-select: none; user-select: none; }
    /* Spinner while an image link is being expanded in place. Attached to the anchor
       rather than the line so it sits inside the text column in both the hinted grid
       layout and the plain one. */
    @keyframes mt-spin { to { transform: rotate(360deg); } }
    .link-line.mt-loading > a::after {
      content: ""; display: inline-block; width: .72em; height: .72em; margin-left: .45em;
      border: .12em solid currentColor; border-right-color: transparent; border-radius: 50%;
      animation: mt-spin .75s linear infinite; opacity: .8; vertical-align: -.08em;
    }
    .list-item { display: grid; grid-template-columns: 1.25rem 1fr; margin: .25rem 0; }
    blockquote { margin: 1rem 0; padding: .6rem 1rem; border-inline-start: .25rem solid AccentColor; }
    pre { overflow-x: auto; padding: 1rem; border-radius: .65rem; background: color-mix(in srgb, CanvasText 8%, Canvas); }
    .pre-block { margin: 1rem 0; }
    .pre-block > summary { display: flex; align-items: center; gap: .4rem; cursor: pointer; list-style: none; color: SecondaryLabelColor; font-size: .82rem; padding: .1rem 0; }
    .pre-block > summary::-webkit-details-marker { display: none; }
    .pre-block > summary::before { content: "\\25BE"; font-size: .8em; line-height: 1; }
    .pre-block:not([open]) > summary::before { content: "\\25B8"; }
    .pre-block > summary.unlabelled { font-style: italic; opacity: .65; }
    .pre-block > summary:hover { color: CanvasText; }
    .pre-block > pre { margin: .3rem 0 0; }
    code { font-family: ui-monospace, SFMono-Regular, Menlo, monospace; font-size: .92em; background: color-mix(in srgb, CanvasText 8%, Canvas); border-radius: .25rem; padding: .08em .28em; }
    /* The author's * and ` characters, kept in the document but de-emphasised so the
       styled text still reads cleanly. Upright and regular weight inside em/strong. */
    .delimiter { opacity: .4; font-style: normal; font-weight: normal; }
    pre code { font-size: inherit; background: transparent; padding: 0; }
    img { display: block; max-width: 100%; height: auto; margin: 1rem 0; border-radius: .5rem; }
    figure { margin: 1rem 0; } figure a { display: inline-block; max-width: 100%; } figure img { margin-bottom: .35rem; } figcaption { color: SecondaryLabelColor; font-size: .82rem; }
    .blank { height: .7rem; }
    .incomplete { margin-top: 2rem; padding: .8rem 1rem; border: 1px solid #d08a00; border-radius: .6rem; }
    .browser-generated main { max-width: 44rem; }
    .browser-generated .eyebrow { color: SecondaryLabelColor; font-size: .82rem; font-weight: 600; letter-spacing: .06em; text-transform: uppercase; }
    .browser-generated .details { padding: .85rem 1rem; border-radius: .65rem; background: color-mix(in srgb, CanvasText 7%, Canvas); font-family: ui-monospace, monospace; white-space: pre-wrap; }
    """

    public static let printThemeCSS = """
    @page { margin: 0.65in; }
    @media print {
      /* body's top padding only exists to clear the floating browser chrome. */
      :root { color-scheme: light; zoom: 1 !important; font-size: 11pt; }
      body { padding-top: 0 !important; color: #000 !important; background: #fff !important; }
      main { max-width: none; margin: 0; padding: 0; }
      a { color: #000 !important; text-decoration: underline; }
      blockquote { color: #222 !important; border-color: #777 !important; }
      pre, code, .details { color: #000 !important; background: #f2f2f2 !important; }
      figcaption { color: #444 !important; }
      h1, h2, h3 { break-after: avoid-page; }
      pre, blockquote, figure { break-inside: avoid-page; }
      .source-line { break-inside: avoid-page; }
    }
    """
}
