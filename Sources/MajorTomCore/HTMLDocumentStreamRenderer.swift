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
    /// Applies the colors an ANSI SGR escape sets inside a preformatted block.
    ///
    /// The escape sequences are removed from the displayed text either way — they are
    /// control codes, not characters the author meant a reader to see, and leaving them
    /// in turns ANSI art into a field of `[38;5;208m`. Turning this off renders the
    /// block in the theme's own text color, which is the fallback a capsule should
    /// already read well in.
    public var rendersANSIColors: Bool
    /// Also applies ANSI background colors, on runs that set a foreground too.
    public var rendersANSIBackgroundColors: Bool

    public init(
        recognizesEmphasis: Bool = true,
        recognizesStrongEmphasis: Bool = true,
        recognizesInlineCode: Bool = true,
        collapsesConsecutiveQuotes: Bool = true,
        showsLinkHints: Bool = true,
        rendersANSIColors: Bool = true,
        rendersANSIBackgroundColors: Bool = true
    ) {
        self.recognizesEmphasis = recognizesEmphasis
        self.recognizesStrongEmphasis = recognizesStrongEmphasis
        self.recognizesInlineCode = recognizesInlineCode
        self.collapsesConsecutiveQuotes = collapsesConsecutiveQuotes
        self.showsLinkHints = showsLinkHints
        self.rendersANSIColors = rendersANSIColors
        self.rendersANSIBackgroundColors = rendersANSIBackgroundColors
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
        rendersANSIColors = try container.decodeIfPresent(Bool.self, forKey: .rendersANSIColors) ?? true
        rendersANSIBackgroundColors = try container
            .decodeIfPresent(Bool.self, forKey: .rendersANSIBackgroundColors) ?? true
    }
}

public enum HTMLDocumentKind: String, Sendable {
    case gemtext, source, plainText = "plain-text", image, message, history
}

/// One renderer owns one streamed document. Its small block state groups adjacent
/// list and quote events without buffering the response or depending on chunk sizes.
public final class HTMLDocumentStreamRenderer {
    private enum Block { case list, quote }
    private var block: Block?
    private var quoteParagraphIsOpen = false
    private var isPreformatted = false
    private var preformattedLineCount = 0
    private var plainTextIsAtStart = true
    private var plainTextIsOpen = false
    /// The colors the document is drawn in, needed because an ANSI foreground is
    /// adapted to the background it will actually sit on.
    private let contentPalette: ContentThemePalette

    public init(
        contentPalette: ContentThemePalette = .fallback
    ) {
        self.contentPalette = contentPalette
    }

    public func documentStart(
        themeCSS: String = ContentThemeStylesheets.base + ContentThemeStylesheets.print,
        baseURL: URL? = nil,
        kind: HTMLDocumentKind = .gemtext,
        appearance: ContentThemeAppearance = .dark
    ) -> Data {
        block = nil
        quoteParagraphIsOpen = false
        isPreformatted = false
        preformattedLineCount = 0
        plainTextIsAtStart = true
        plainTextIsOpen = false
        let base = baseURL.map {
            "<base href=\"\(Self.escapeAttribute($0.absoluteString))\">"
        } ?? ""
        let documentClass = " class=\"\(kind.rawValue)-page\""
        let html = """
        <!doctype html>
        <html data-appearance="\(appearance.rawValue)">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src data: majortom-resource:; style-src 'unsafe-inline'">
        \(base)
        <style id="majortom-theme">
        \(Self.escapedStylesheet(themeCSS))
        </style>
        </head>
        <body\(documentClass)>
        <main>

        """
        return Data(html.utf8)
    }

    private static func escapedStylesheet(_ css: String) -> String {
        css.replacingOccurrences(of: "</", with: "<\\/")
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
        isExpandableImage: Bool = false,
        imageLoading: SameCapsuleImageLoading = .off
    ) -> Data {
        var prefix = ""
        switch event {
        case .listItem:
            if block != .list {
                prefix = closeBlock() + "<ul>\n"
                block = .list
            }
        case .quote where options.collapsesConsecutiveQuotes:
            if block != .quote {
                prefix = closeBlock() + "<blockquote>"
                block = .quote
            }
        default:
            prefix = closeBlock()
        }
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
            var attributes = "href=\"\(Self.escapeAttribute(destination))\""
            if GemtextLinkHint.isInlineImageCandidate(destination: destination, relativeTo: baseURL) {
                attributes += " class=\"image-link\""
            }
            if let linkIdentifier {
                attributes += " id=\"\(Self.escapeAttribute(linkIdentifier))\""
            }
            if isExpandableImage {
                attributes += " data-mt-expandable=\"1\""
                if imageLoading != .off {
                    attributes += " data-mt-image-auto=\"\(imageLoading.rawValue)\""
                }
            }
            html = "<a \(attributes)>\(hintMarkup)\(Self.renderInline(visibleText, options: options))</a>"
        case .listItem(let text):
            html = "<li>\(Self.renderInline(text, options: options))</li>\n"
        case .quote(let text):
            if options.collapsesConsecutiveQuotes {
                if text.isEmpty {
                    html = quoteParagraphIsOpen ? "</p>\n" : ""
                    quoteParagraphIsOpen = false
                } else {
                    html = (quoteParagraphIsOpen ? "\n" : "<p>") + Self.renderInline(text, options: options)
                    quoteParagraphIsOpen = true
                }
            } else {
                html = "<blockquote><p>\(Self.renderInline(text, options: options))</p></blockquote>"
            }
        case .blank:
            html = "<br>\n"
        case .beginPreformatted(let altText):
            // <details>/<summary> is a native disclosure control needing no JavaScript,
            // which matters because the document's CSP is `default-src 'none'`.
            // Text on the opening fence is conventionally a description of the block —
            // most often ASCII art — so it is exactly what should remain visible when
            // the block is collapsed. Open by default.
            let summary = altText.map(Self.escape) ?? "Preformatted text"
            let unlabelled = altText == nil ? " class=\"is-unlabelled\"" : ""
            isPreformatted = true
            preformattedLineCount = 0
            let tooltip = altText.map {
                " title=\"\(Self.escapeAttribute($0))\""
            } ?? ""
            html = "<details open>\n<summary\(unlabelled)>\(summary)</summary>\n<pre\(tooltip)>"
        case .preformattedLine(let text):
            // HTML consumes a newline immediately after <pre>. Double only that
            // initial empty line so the DOM retains the author's first blank line.
            let rendered = renderPreformatted(text, options: options)
            let leadingNewline = preformattedLineCount == 0 && rendered.isEmpty ? "\n" : ""
            html = leadingNewline + rendered + "\n"
            preformattedLineCount += 1
        case .endPreformatted:
            isPreformatted = false
            html = "</pre>\n</details>"
        }
        let trailingNewline: String
        switch event {
        case .preformattedLine, .beginPreformatted, .quote, .blank: trailingNewline = ""
        default: trailingNewline = html.hasSuffix("\n") ? "" : "\n"
        }
        return Data((prefix + html + trailingNewline).utf8)
    }

    private func closeBlock() -> String {
        defer {
            block = nil
            quoteParagraphIsOpen = false
        }
        switch block {
        case .list: return "</ul>\n"
        case .quote: return (quoteParagraphIsOpen ? "</p>" : "") + "</blockquote>\n"
        case nil: return ""
        }
    }

    public func documentEnd(incompleteMessage: String? = nil) -> Data {
        var closing = closeBlock()
        if isPreformatted {
            closing += "</pre>\n</details>\n"
            isPreformatted = false
        }
        if plainTextIsOpen { closing += String(decoding: endPlainText(), as: UTF8.self) }
        if let incompleteMessage {
            closing += "<aside class=\"incomplete\" role=\"status\">\(Self.escape(incompleteMessage))</aside>\n"
        }
        return Data("\(closing)</main>\n</body>\n</html>\n".utf8)
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
        let html = "<figure id=\"\(Self.escapeAttribute(figureIdentifier))\"\(classAttribute)>\n"
            + "<a href=\"\(Self.escapeAttribute(linkURL.absoluteString))\">"
            + "<img src=\"\(Self.escapeAttribute(resourceURL.absoluteString))\""
            + " alt=\"\(Self.escapeAttribute(altText))\" loading=\"eager\""
            + " data-mt-inline-image=\"1\""
            + " data-mt-filename=\"\(Self.escapeAttribute(fileName))\""
            + mimeAttribute + sizeAttribute + "></a>\n"
            + "<figcaption>\(Self.escape(fileName))</figcaption>\n</figure>\n"
        return Data(html.utf8)
    }

    public static let sourceStart = "<h1>Page Source</h1>\n<ol>\n"
    public static let sourceEnd = "</ol>\n"

    public static func sourceLine(_ line: String) -> String {
        "<li>\(escape(line))</li>\n"
    }

    public func renderPlainText(_ text: String) -> Data {
        let leadingNewline = text.hasPrefix("\n") || text.hasPrefix("\r") ? "\n" : ""
        return Data("<pre>\(leadingNewline)\(Self.escape(text))</pre>\n".utf8)
    }

    public func renderPlainTextChunk(_ text: String) -> Data {
        guard !text.isEmpty else { return Data() }
        let leadingNewline = plainTextIsAtStart && (text.hasPrefix("\n") || text.hasPrefix("\r")) ? "\n" : ""
        plainTextIsAtStart = false
        return Data((leadingNewline + Self.escape(text)).utf8)
    }

    public func beginPlainText() -> Data {
        plainTextIsAtStart = true
        plainTextIsOpen = true
        return Data("<pre>".utf8)
    }

    public func endPlainText() -> Data {
        plainTextIsOpen = false
        return Data("</pre>\n".utf8)
    }

    public func renderMessage(title: String, message: String, details: String) -> Data {
        Data("""
        <h1>\(Self.escape(title))</h1>
        <p>\(Self.escape(message))</p>
        <pre>\(Self.escape(details))</pre>

        """.utf8)
    }

    public func renderStandaloneImage(source: URL) -> Data {
        Data("""
        <input class="image-toggle" type="checkbox" id="image-size" aria-label="Show image at natural size">
        <label class="image-frame" for="image-size"><img alt="" src="\(Self.escapeAttribute(source.absoluteString))"></label>

        """.utf8)
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

    /// Renders one preformatted line, applying the ANSI SGR attributes it carries.
    ///
    /// The line's own escape sequences never reach the document — they are control
    /// codes, and a client that shows them shows garbage. They stay in the received
    /// bytes, so View Source, Save Page As and the reader's own copy of the capsule
    /// are the author's text exactly as sent (spec 5.1).
    ///
    /// Each line is parsed on its own, so attributes reset at every newline. That is
    /// what ANSI art needs: authors set the color again on every line rather than
    /// trusting a client to carry state, and a block that ends mid-color cannot bleed
    /// into the rest of the page.
    func renderPreformatted(_ text: String, options: HTMLRenderingOptions) -> String {
        let runs = ANSISGRParser.runs(in: text)
        if runs.isEmpty { return "" }
        if runs.count == 1, runs[0].style.isPlain { return Self.escape(runs[0].text) }

        // Measured against the block's own surface, not the page background. Every
        // theme gives `pre` a tinted panel of its own, and on the light themes that
        // panel is the more demanding of the two.
        let resolver = ANSIStyleResolver(
            themeForeground: contentPalette.codeForeground,
            themeBackground: contentPalette.codeBackground,
            rendersBackgroundColors: options.rendersANSIBackgroundColors
        )
        var output = ""
        for run in runs {
            let style = options.rendersANSIColors ? resolver.resolve(run.style) : ResolvedANSIStyle()
            let css = style.css
            guard !css.isEmpty else {
                output += Self.escape(run.text)
                continue
            }
            output += "<span style=\"\(Self.escapeAttribute(css))\">\(Self.escape(run.text))</span>"
        }
        return output
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
            output += "<\(candidate.tag)>"
                + escape(String(remainder[candidate.range]))
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

    public static let defaultThemeCSS = ContentThemeStylesheets.base

    public static let printThemeCSS = ContentThemeStylesheets.print
}
