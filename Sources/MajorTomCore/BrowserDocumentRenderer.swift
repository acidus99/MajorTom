import Foundation

public struct BrowserRenderedFragment {
    public let data: Data
    public let semantic: GemtextEvent?
    public let expandableLink: (identifier: String, url: URL)?

    init(_ data: Data, semantic: GemtextEvent? = nil, expandableLink: (String, URL)? = nil) {
        self.data = data
        self.semantic = semantic
        self.expandableLink = expandableLink
    }
}

/// One document's presentation state. It consumes semantic content and approved
/// resource addresses without performing navigation, retrieval, or persistence.
public final class BrowserDocumentRenderer {
    private let style: BrowserContentStyle
    private let html: HTMLDocumentStreamRenderer
    private var kind = BrowserContentKind.unsupported
    private var linkSequence = 0

    public init(style: BrowserContentStyle) {
        self.style = style
        self.html = HTMLDocumentStreamRenderer(contentPalette: style.palette)
    }

    public func start(kind: BrowserContentKind, at url: URL) -> Data {
        self.kind = kind
        let documentKind: HTMLDocumentKind
        switch kind {
        case .gemtext: documentKind = .gemtext
        case .plainText: documentKind = .plainText
        case .source: documentKind = .source
        case .image: documentKind = .image
        case .unsupported: documentKind = .message
        }
        var data = html.documentStart(themeCSS: style.css, baseURL: kind == .source ? nil : url,
            kind: documentKind, appearance: style.appearance)
        if kind == .plainText { data.append(html.beginPlainText()) }
        if kind == .source { data.append(Data(HTMLDocumentStreamRenderer.sourceStart.utf8)) }
        return data
    }

    public func render(_ event: BrowserBodyEvent, at url: URL, preferences: BrowserPreferences,
                       imagesPaused: Bool, isPreview: Bool = false) -> BrowserRenderedFragment {
        switch event {
        case .text(let text): return BrowserRenderedFragment(html.renderPlainTextChunk(text))
        case .gemtext(let semantic):
            var identifier: String?
            var expandable = false
            var loading = SameCapsuleImageLoading.off
            var link: (String, URL)?
            if case .link(let destination, _) = semantic {
                linkSequence += 1
                identifier = "mt-link-\(linkSequence)"
                expandable = GemtextLinkHint.isInlineImageCandidate(destination: destination, relativeTo: url)
                if expandable, let destination = URL(string: destination, relativeTo: url)?.absoluteURL, let identifier {
                    link = (identifier, destination)
                    if !isPreview, !imagesPaused, GemtextLinkHint.isSameCapsule(destination, url) {
                        loading = preferences.sameCapsuleImageLoading
                    }
                }
            }
            var data = html.render(semantic, options: preferences.renderingOptions, baseURL: url,
                linkIdentifier: identifier, isExpandableImage: expandable, imageLoading: loading)
            if !isPreview, preferences.automaticallyLoadsDataImages,
               case .link(let destination, let label) = semantic,
               let payload = InlineDataImagePayload.decode(destination), let dataURL = URL(string: destination) {
                let name = label ?? "Inline image"
                data.append(html.renderInlineImage(resourceURL: dataURL, linkURL: dataURL, altText: name,
                    figureIdentifier: "mt-inline-\(identifier ?? String(linkSequence))", fileName: name,
                    mimeType: payload.mimeType,
                    sizeDescription: ByteCountFormatter.string(fromByteCount: Int64(payload.data.count), countStyle: .file)))
            }
            return BrowserRenderedFragment(data, semantic: semantic, expandableLink: link)
        }
    }

    public func finish(message: String? = nil) -> Data {
        var data = Data()
        if kind == .plainText { data.append(html.endPlainText()) }
        if kind == .source { data.append(Data(HTMLDocumentStreamRenderer.sourceEnd.utf8)) }
        data.append(html.documentEnd(incompleteMessage: message))
        return data
    }

    /// Whole responses still emit fragments; only swipe previews collect a
    /// complete HTML value. Text uses the same parser and rendering route as live bytes.
    public func renderComplete(_ body: Data, mimeType: String, at url: URL, responseMeta: String? = nil,
                               preferences: BrowserPreferences, imagesPaused: Bool,
                               isPreview: Bool = false, completion: PageCompletionState = .complete, emit: (BrowserRenderedFragment) -> Void) {
        let kind = BrowserContentKind(mimeType: mimeType, url: url)
        emit(BrowserRenderedFragment(start(kind: kind, at: url)))
        switch kind {
        case .gemtext, .plainText:
            for event in BrowserResponseBody.events(for: body, kind: kind) {
                emit(render(event, at: url, preferences: preferences, imagesPaused: imagesPaused, isPreview: isPreview))
            }
        case .source:
            var batch = ""
            for line in SourceLineSplitter.lines(of: String(decoding: body, as: UTF8.self)) {
                batch += HTMLDocumentStreamRenderer.sourceLine(line)
                if batch.utf8.count >= 32 * 1_024 { emit(BrowserRenderedFragment(Data(batch.utf8))); batch = "" }
            }
            if !batch.isEmpty { emit(BrowserRenderedFragment(Data(batch.utf8))) }
        case .image:
            let source = URL(string: "data:\(mimeType);base64,\(body.base64EncodedString())")!
            emit(BrowserRenderedFragment(html.renderStandaloneImage(source: source)))
        case .unsupported:
            emit(BrowserRenderedFragment(html.renderMessage(title: "Unsupported Content",
                message: "Major Tom cannot display this response type yet. No file was downloaded.",
                details: "\(mimeType.isEmpty ? responseMeta ?? "" : mimeType)\n\(body.count) bytes")))
        }
        let message: String?
        switch completion {
        case .complete: message = nil
        case .stopped: message = "Loading was stopped."
        case .incomplete, .failed: message = "The response ended before it completed."
        }
        emit(BrowserRenderedFragment(finish(message: message)))
    }

    public func message(title: String, message: String, details: String, at url: URL,
                        archiveURL: URL?, preferences: BrowserPreferences) -> Data {
        var data = start(kind: .unsupported, at: url)
        data.append(html.renderMessage(title: title, message: message, details: details))
        if let archiveURL {
            data.append(html.render(.link(destination: archiveURL.absoluteString,
                label: "Check for previous versions of this page"), options: preferences.renderingOptions, baseURL: url))
        }
        data.append(finish())
        return data
    }

    public func historyPlaceholder(title: String, at url: URL) -> Data {
        var data = html.documentStart(themeCSS: style.css, baseURL: url, kind: .history, appearance: style.appearance)
        data.append(Data("<h1>\(HTMLDocumentStreamRenderer.escape(title))</h1>".utf8))
        data.append(html.documentEnd())
        return data
    }

    public func inlineImage(resourceURL: URL, linkURL: URL, figureIdentifier: String, fileName: String) -> String {
        String(decoding: html.renderInlineImage(resourceURL: resourceURL, linkURL: linkURL, altText: fileName,
            figureIdentifier: figureIdentifier, fileName: fileName, figureClass: "inline-image"), as: UTF8.self)
    }
}

