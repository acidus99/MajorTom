import Foundation

public struct HTMLRenderingOptions: Equatable, Codable, Sendable {
    public var recognizesEmphasis: Bool
    public var recognizesStrongEmphasis: Bool
    public var recognizesInlineCode: Bool

    public init(
        recognizesEmphasis: Bool = true,
        recognizesStrongEmphasis: Bool = true,
        recognizesInlineCode: Bool = true
    ) {
        self.recognizesEmphasis = recognizesEmphasis
        self.recognizesStrongEmphasis = recognizesStrongEmphasis
        self.recognizesInlineCode = recognizesInlineCode
    }
}

public struct HTMLDocumentStreamRenderer: Sendable {
    public init() {}

    public func documentStart(
        themeCSS: String = Self.defaultThemeCSS,
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
        \(base)<style>\(themeCSS)</style></head><body\(documentClass)><main>
        """
        return Data(html.utf8)
    }

    public func render(
        _ event: GemtextEvent,
        options: HTMLRenderingOptions = HTMLRenderingOptions()
    ) -> Data {
        let html: String
        switch event {
        case .text(let text):
            html = "<p>\(Self.renderInline(text, options: options))</p>"
        case .heading(let level, let text):
            html = "<h\(level)>\(Self.renderInline(text, options: options))</h\(level)>"
        case .link(let destination, let label):
            let visibleText = label ?? destination
            html = "<p class=\"link-line\"><a href=\"\(Self.escapeAttribute(destination))\">\(Self.renderInline(visibleText, options: options))</a></p>"
        case .listItem(let text):
            html = "<div class=\"list-item\"><span aria-hidden=\"true\">•</span><span>\(Self.renderInline(text, options: options))</span></div>"
        case .quote(let text):
            html = "<blockquote>\(Self.renderInline(text, options: options))</blockquote>"
        case .blank:
            html = "<div class=\"blank\" aria-hidden=\"true\"></div>"
        case .beginPreformatted(let altText):
            let label = altText.map { " aria-label=\"\(Self.escapeAttribute($0))\"" } ?? ""
            html = "<pre\(label)><code>"
        case .preformattedLine(let text):
            html = Self.escape(text) + "\n"
        case .endPreformatted:
            html = "</code></pre>"
        }
        return Data(html.utf8)
    }

    public func documentEnd(incompleteMessage: String? = nil) -> Data {
        let notice = incompleteMessage.map {
            "<aside class=\"incomplete\" role=\"status\">\(Self.escape($0))</aside>"
        } ?? ""
        return Data("\(notice)</main></body></html>".utf8)
    }

    public func renderInlineImage(resourceURL: URL, altText: String) -> Data {
        Data("<figure><img src=\"\(Self.escapeAttribute(resourceURL.absoluteString))\" alt=\"\(Self.escapeAttribute(altText))\" loading=\"eager\"><figcaption>\(Self.escape(altText))</figcaption></figure>".utf8)
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
            output += "<\(candidate.tag)>\(escape(String(remainder[contentStart..<contentEnd])))</\(candidate.tag)>"
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

    public static let defaultThemeCSS = """
    :root { color-scheme: light dark; font: 17px/1.55 -apple-system, BlinkMacSystemFont, sans-serif; }
    body { margin: 0; padding-top: 7.25rem; color: CanvasText; background: Canvas; }
    main { box-sizing: border-box; max-width: 48rem; margin: 0 auto; padding: 3rem 2rem 6rem; }
    h1, h2, h3 { line-height: 1.2; text-wrap: balance; }
    h1 { font-size: 2rem; } h2 { font-size: 1.5rem; } h3 { font-size: 1.2rem; }
    p { margin: .7rem 0; }
    a { color: LinkText; text-underline-offset: .15em; }
    .link-line { margin: .45rem 0; }
    .list-item { display: grid; grid-template-columns: 1.25rem 1fr; margin: .25rem 0; }
    blockquote { margin: 1rem 0; padding: .6rem 1rem; border-inline-start: .25rem solid AccentColor; }
    pre { overflow-x: auto; padding: 1rem; border-radius: .65rem; background: color-mix(in srgb, CanvasText 8%, Canvas); }
    code { font-family: ui-monospace, SFMono-Regular, Menlo, monospace; font-size: .92em; background: color-mix(in srgb, CanvasText 8%, Canvas); border-radius: .25rem; padding: .08em .28em; }
    pre code { font-size: inherit; background: transparent; padding: 0; }
    img { display: block; max-width: 100%; height: auto; margin: 1rem 0; border-radius: .5rem; }
    figure { margin: 1rem 0; } figure img { margin-bottom: .35rem; } figcaption { color: SecondaryLabelColor; font-size: .82rem; }
    .blank { height: .7rem; }
    .incomplete { margin-top: 2rem; padding: .8rem 1rem; border: 1px solid #d08a00; border-radius: .6rem; }
    .browser-generated main { max-width: 44rem; }
    .browser-generated .eyebrow { color: SecondaryLabelColor; font-size: .82rem; font-weight: 600; letter-spacing: .06em; text-transform: uppercase; }
    .browser-generated .details { padding: .85rem 1rem; border-radius: .65rem; background: color-mix(in srgb, CanvasText 7%, Canvas); font-family: ui-monospace, monospace; white-space: pre-wrap; }
    """
}
