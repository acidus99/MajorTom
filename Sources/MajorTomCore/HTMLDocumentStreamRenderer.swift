import Foundation

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

    public func render(_ event: GemtextEvent) -> Data {
        let html: String
        switch event {
        case .text(let text):
            html = "<p>\(Self.escape(text))</p>"
        case .heading(let level, let text):
            html = "<h\(level)>\(Self.escape(text))</h\(level)>"
        case .link(let destination, let label):
            let visibleText = label ?? destination
            html = "<p class=\"link-line\"><a href=\"\(Self.escapeAttribute(destination))\">\(Self.escape(visibleText))</a></p>"
        case .listItem(let text):
            html = "<div class=\"list-item\"><span aria-hidden=\"true\">•</span><span>\(Self.escape(text))</span></div>"
        case .quote(let text):
            html = "<blockquote>\(Self.escape(text))</blockquote>"
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

    public static let defaultThemeCSS = """
    :root { color-scheme: light dark; font: 17px/1.55 -apple-system, BlinkMacSystemFont, sans-serif; }
    body { margin: 0; color: CanvasText; background: Canvas; }
    main { box-sizing: border-box; max-width: 48rem; margin: 0 auto; padding: 3rem 2rem 6rem; }
    h1, h2, h3 { line-height: 1.2; text-wrap: balance; }
    h1 { font-size: 2rem; } h2 { font-size: 1.5rem; } h3 { font-size: 1.2rem; }
    p { margin: .7rem 0; }
    a { color: LinkText; text-underline-offset: .15em; }
    .link-line { margin: .45rem 0; }
    .list-item { display: grid; grid-template-columns: 1.25rem 1fr; margin: .25rem 0; }
    blockquote { margin: 1rem 0; padding: .6rem 1rem; border-inline-start: .25rem solid AccentColor; }
    pre { overflow-x: auto; padding: 1rem; border-radius: .65rem; background: color-mix(in srgb, CanvasText 8%, Canvas); }
    .blank { height: .7rem; }
    .incomplete { margin-top: 2rem; padding: .8rem 1rem; border: 1px solid #d08a00; border-radius: .6rem; }
    .browser-generated main { max-width: 44rem; }
    .browser-generated .eyebrow { color: SecondaryLabelColor; font-size: .82rem; font-weight: 600; letter-spacing: .06em; text-transform: uppercase; }
    .browser-generated .details { padding: .85rem 1rem; border-radius: .65rem; background: color-mix(in srgb, CanvasText 7%, Canvas); font-family: ui-monospace, monospace; white-space: pre-wrap; }
    """
}
