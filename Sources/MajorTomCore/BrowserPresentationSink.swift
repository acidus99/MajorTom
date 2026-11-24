import Foundation

public struct BrowserContentStyle: Sendable {
    public var css: String
    public var palette: ContentThemePalette
    public var appearance: ContentThemeAppearance

    public init(css: String, palette: ContentThemePalette, appearance: ContentThemeAppearance) {
        self.css = css
        self.palette = palette
        self.appearance = appearance
    }
}

public struct BrowserPresentationDocument {
    public let url: URL
    public let continuation: AsyncThrowingStream<Data, any Error>.Continuation

    public init(url: URL, continuation: AsyncThrowingStream<Data, any Error>.Continuation) {
        self.url = url
        self.continuation = continuation
    }
}

public enum BrowserDocumentUpdate {
    case theme(css: String, appearance: ContentThemeAppearance)
    case restoreScroll(Double)
    case reveal
    case collapsedSections([Int])
    case correctScrollAfterImages(Double)
    case imageViewport(Double)
    case stopImages([String])
    case removeImage(line: String)
    case imageState(line: String, state: GeminiImageLoader.State)
    case imageFailure(line: String, message: String)
}

/// A resource has an opaque address and accepts only approved response bytes.
@MainActor
public struct BrowserPresentationResource {
    public let url: URL
    public let finish: (Result<ContentResponse, any Error>) -> Void

    public init(url: URL, finish: @escaping (Result<ContentResponse, any Error>) -> Void) {
        self.url = url
        self.finish = finish
    }
}

/// The tab workflow supplies bytes and presentation intent. This seam contains no
/// WebKit, window, file-dialog, or native geometry objects.
@MainActor
public protocol BrowserPresentationSink: AnyObject {
    func createDocument() -> BrowserPresentationDocument
    func invalidateDocument()
    func loadDocument(at url: URL) async throws
    func updateDocument(_ update: BrowserDocumentUpdate, at url: URL) async
    /// Decode approved resource bytes before inserting any visible image or caption.
    func insertImage(_ figure: String, after line: String, at url: URL) async -> Bool
    func createImageResource() -> BrowserPresentationResource
    func showHistoryPreview(_ data: Data, entry: BackForwardEntry) async throws
    func discardHistoryPreview()
}

public enum BrowserHistoryDirection: Sendable {
    case back, forward
}
