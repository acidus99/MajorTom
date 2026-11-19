import Foundation

/// Live composition supplies feature services. A session never obtains globals or
/// opens a store, and tests can exercise the production workflow without a window.
@MainActor
public struct BrowserSessionServices {
    public var preferences: () -> BrowserPreferences
    public var preparePresentation: () async -> Void = {}
    public var contentStyle: (_ zoom: Double, _ hidesUntilRestored: Bool, _ topInset: Double) -> BrowserContentStyle = { _, _, _ in
        BrowserContentStyle(css: ContentThemeStylesheets.base, palette: .fallback, appearance: .dark)
    }
    public var retriever: GeminiResourceRetriever<ClientTLSIdentity>
    public var faviconLoader: GeminiFaviconLoader?
    public var imageLoader: GeminiImageLoader?
    public var authorizeTrust: GeminiTransport.TrustAuthorization = { _, _ in false }
    public var backForwardCache: BackForwardCacheStore?
    public var recordVisit: (URL, String?) -> Void = { _, _ in }
    public var updateBookmarkFavicon: (String?, CapsuleEndpoint, Date) -> Void = { _, _, _ in }
    public var certificateDescriptor: (UUID) -> ClientCertificateDescriptor? = { _ in nil }
    public var inputDraft: (URL) -> String = { _ in "" }
    public var saveInputDraft: (String, URL) -> Void = { _, _ in }
    public var removeInputDraft: (URL) -> Void = { _ in }
    public var openExternalURL: (URL) -> Void = { _ in }
    public var now: () -> Date = { Date() }

    public init(preferences: @escaping () -> BrowserPreferences, retriever: GeminiResourceRetriever<ClientTLSIdentity>) {
        self.preferences = preferences
        self.retriever = retriever
    }
}
