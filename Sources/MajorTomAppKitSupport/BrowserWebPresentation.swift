import AppKit
import Combine
import Foundation
import MajorTomCore
import os
import SwiftUI
import WebKit

private let browserNavigationLogger = Logger(subsystem: "dev.gemi.major-tom", category: "Navigation")

@available(macOS 26.0, *)
@MainActor
public final class BrowserWebPresentation: ObservableObject, BrowserPresentationSink {
    public let page: WebPage
    @Published public private(set) var historySwipePage: WebPage
    public let router: BrowserNavigationRouter
    private let configuration: WebPage.Configuration
    private let documentStore = BrowserDocumentStore()
    private let resourceStore = BrowserResourceStore()
    private var activeDocumentURL: URL?

    public init(userContentController: WKUserContentController) {
        let router = BrowserNavigationRouter()
        var configuration = WebPage.Configuration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController = userContentController
        configuration.suppressesIncrementalRendering = false
        configuration.loadsSubresources = true
        configuration.defaultNavigationPreferences.allowsContentJavaScript = false
        configuration.urlSchemeHandlers = [
            URLScheme(BrowserDocumentSchemeHandler.scheme)!: BrowserDocumentSchemeHandler(store: documentStore),
            URLScheme(BrowserResourceSchemeHandler.scheme)!: BrowserResourceSchemeHandler(store: resourceStore)
        ]
        self.configuration = configuration
        self.router = router
        self.page = WebPage(configuration: configuration, navigationDecider: BrowserNavigationDecider(router: router))
        self.historySwipePage = WebPage(configuration: configuration, navigationDecider: BrowserNavigationDecider(router: router))
    }

    public func createDocument() -> BrowserPresentationDocument {
        invalidateDocument()
        let document = documentStore.createDocument()
        activeDocumentURL = document.url
        return BrowserPresentationDocument(url: document.url, continuation: document.continuation)
    }

    public func invalidateDocument() {
        if let url = activeDocumentURL { documentStore.discardDocument(id: url.lastPathComponent) }
        activeDocumentURL = nil
    }

    public func loadDocument(at url: URL) async throws {
        guard activeDocumentURL == url else { throw CancellationError() }
        for try await event in page.load(url) {
            guard activeDocumentURL == url else { throw CancellationError() }
            if event == .finished { return }
        }
        throw CancellationError()
    }

    public func updateDocument(_ update: BrowserDocumentUpdate, at url: URL) async {
        guard activeDocumentURL == url else { return }
        let source: String
        let world: WKContentWorld
        switch update {
        case .theme(let css, let appearance): source = BrowserDocumentScript.themeUpdate(css: css, appearance: appearance.rawValue); world = .page
        case .restoreScroll(let offset): source = BrowserDocumentScript.restoreScroll(offset: offset); world = .page
        case .reveal: source = BrowserDocumentScript.revealDocument; world = .page
        case .collapsedSections(let indices): source = BrowserDocumentScript.restoreCollapsed(indices: indices); world = .page
        case .correctScrollAfterImages(let offset): source = BrowserDocumentScript.correctScrollAfterImages(offset: offset); world = .page
        case .imageViewport(let inset): source = BrowserDocumentScript.imageViewport(topInset: inset); world = .defaultClient
        case .stopImages(let identifiers): source = InlineImagePresentationScript.stopScript(identifiers: identifiers, documentURL: url); world = .defaultClient
        case .removeImage(let line): source = BrowserDocumentScript.removeImage(lineIdentifier: line); world = .defaultClient
        case .imageState(let line, let state): source = InlineImagePresentationScript.stateUpdateScript(identifier: line, state: state, documentURL: url); world = .defaultClient
        case .imageFailure(let line, let message): source = InlineImagePresentationScript.failureUpdateScript(identifier: line, message: message); world = .defaultClient
        }
        do {
            _ = try await page.callJavaScript(BrowserDocumentScript.scoped(source, to: url), contentWorld: world)
        } catch {
            if case .restoreScroll = update, activeDocumentURL == url {
                _ = try? await page.callJavaScript(BrowserDocumentScript.scoped(BrowserDocumentScript.revealDocument, to: url))
            }
        }
    }

    public func insertImage(_ figure: String, after line: String, at url: URL) async -> Bool {
        guard activeDocumentURL == url, !Task.isCancelled else { return false }
        let source = BrowserDocumentScript.insertImage(lineIdentifier: line, figure: figure)
        let result = try? await page.callJavaScript(BrowserDocumentScript.scoped(source, to: url), contentWorld: .defaultClient)
        return activeDocumentURL == url && !Task.isCancelled && (result as? Bool == true)
    }

    public func createImageResource() -> BrowserPresentationResource {
        let resource = resourceStore.createResource()
        return BrowserPresentationResource(url: resource.url) { result in
            switch result {
            case .success(let response):
                resource.continuation.yield(.response(URLResponse(url: response.url, mimeType: response.mimeType,
                    expectedContentLength: response.body.count, textEncodingName: nil)))
                resource.continuation.yield(.data(response.body))
                resource.continuation.finish()
            case .failure(let error): resource.continuation.finish(throwing: error)
            }
        }
    }

    public func showHistoryPreview(_ data: Data, entry: BackForwardEntry) async throws {
        let document = documentStore.createDocument()
        let navigation = historySwipePage.load(document.url)
        document.continuation.yield(data)
        document.continuation.finish()
        for try await event in navigation where event == .finished { break }
        _ = try? await historySwipePage.callJavaScript(BrowserDocumentScript.scoped(
            BrowserDocumentScript.restorePreview(collapsed: entry.presentation.collapsedPreformatted,
                offset: entry.presentation.scrollY), to: document.url))
    }

    public func discardHistoryPreview() {
        historySwipePage = WebPage(configuration: configuration, navigationDecider: BrowserNavigationDecider(router: router))
    }
}

@available(macOS 26.0, *)
@MainActor
public final class BrowserNavigationRouter {
    public var openURL: ((URL) -> Void)?
    public var downloadURL: ((URL) -> Void)?
    public var openInNewTab: ((URL, _ inBackground: Bool) -> Void)?
    public var openInNewWindow: ((URL) -> Void)?
    public var canOpenInApp: ((URL) -> Bool)?
}

@available(macOS 26.0, *)
private struct BrowserNavigationDecider: WebPage.NavigationDeciding {
    let router: BrowserNavigationRouter

    @MainActor
    func decidePolicy(
        for action: WebPage.NavigationAction,
        preferences: inout WebPage.NavigationPreferences
    ) async -> WKNavigationActionPolicy {
        guard let url = action.request.url else { return .cancel }
        preferences.allowsContentJavaScript = false
        if action.navigationType == .backForward {
            browserNavigationLogger.error(
                "cancelled unexpected WebKit-owned BackForward destination=\(url.absoluteString, privacy: .public)"
            )
            return .cancel
        }
        if url.scheme == BrowserDocumentSchemeHandler.scheme { return .allow }
        let modifiers = action.modifierFlags
        var linkModifiers: LinkModifierKeys = []
        if modifiers.contains(.command) { linkModifiers.insert(.command) }
        if modifiers.contains(.shift) { linkModifiers.insert(.shift) }
        if modifiers.contains(.option) { linkModifiers.insert(.option) }
        if modifiers.contains(.control) { linkModifiers.insert(.control) }

        var activation = LinkActivationPolicy.activation(
            buttonNumber: action.buttonNumber,
            modifiers: linkModifiers
        )
        if action.shouldPerformDownload, activation == .currentTab {
            activation = .download
        }
        switch activation {
        case .contextMenu:
            // The injected contextmenu handler presents the native link menu.
            return .cancel
        case .download:
            router.downloadURL?(url)
            return .cancel
        case .newBackgroundTab:
            guard router.canOpenInApp?(url) == true else { break }
            router.openInNewTab?(url, true)
            return .cancel
        case .newForegroundTab:
            guard router.canOpenInApp?(url) == true else { break }
            router.openInNewTab?(url, false)
            return .cancel
        case .newWindow:
            guard router.canOpenInApp?(url) == true else { break }
            router.openInNewWindow?(url)
            return .cancel
        case .currentTab:
            break
        }

        router.openURL?(url)
        return .cancel
    }
}

@available(macOS 26.0, *)
private final class BrowserDocumentStore: @unchecked Sendable {
    struct Document {
        let url: URL
        let continuation: AsyncThrowingStream<Data, any Error>.Continuation
    }

    private let lock = NSLock()
    private var streams: [String: AsyncThrowingStream<Data, any Error>] = [:]

    func createDocument() -> Document {
        let id = UUID().uuidString
        var capturedContinuation: AsyncThrowingStream<Data, any Error>.Continuation!
        let stream = AsyncThrowingStream<Data, any Error> { continuation in
            capturedContinuation = continuation
        }
        lock.withLock { streams[id] = stream }
        let url = URL(string: "\(BrowserDocumentSchemeHandler.scheme)://document/\(id)")!
        return Document(url: url, continuation: capturedContinuation)
    }

    func takeDocument(id: String) -> AsyncThrowingStream<Data, any Error>? {
        lock.withLock { streams.removeValue(forKey: id) }
    }

    func discardDocument(id: String) {
        lock.withLock { _ = streams.removeValue(forKey: id) }
    }
}

@available(macOS 26.0, *)
private struct BrowserDocumentSchemeHandler: URLSchemeHandler, Sendable {
    static let scheme = "majortom-document"
    let store: BrowserDocumentStore

    func reply(for request: URLRequest) -> AsyncThrowingStream<URLSchemeTaskResult, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard let url = request.url,
                          let stream = store.takeDocument(id: url.lastPathComponent) else {
                        browserNavigationLogger.error(
                            "scheme reply unavailable url=\(request.url?.absoluteString ?? "nil", privacy: .public)"
                        )
                        throw URLError(.resourceUnavailable)
                    }
                    browserNavigationLogger.notice("scheme reply start url=\(url.absoluteString, privacy: .public)")
                    continuation.yield(.response(URLResponse(
                        url: url,
                        mimeType: "text/html",
                        expectedContentLength: -1,
                        textEncodingName: "utf-8"
                    )))
                    for try await data in stream {
                        try Task.checkCancellation()
                        continuation.yield(.data(data))
                    }
                    browserNavigationLogger.notice("scheme reply finish url=\(url.absoluteString, privacy: .public)")
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { termination in
                browserNavigationLogger.notice(
                    "scheme reply terminated url=\(request.url?.absoluteString ?? "nil", privacy: .public) state=\(String(describing: termination), privacy: .public)"
                )
                task.cancel()
            }
        }
    }
}

@available(macOS 26.0, *)
private final class BrowserResourceStore: @unchecked Sendable {
    struct Resource {
        let url: URL
        let continuation: AsyncThrowingStream<URLSchemeTaskResult, any Error>.Continuation
    }

    private let lock = NSLock()
    private var streams: [String: AsyncThrowingStream<URLSchemeTaskResult, any Error>] = [:]

    func createResource() -> Resource {
        let id = UUID().uuidString
        var captured: AsyncThrowingStream<URLSchemeTaskResult, any Error>.Continuation!
        let stream = AsyncThrowingStream<URLSchemeTaskResult, any Error> { captured = $0 }
        lock.withLock { streams[id] = stream }
        return Resource(
            url: URL(string: "\(BrowserResourceSchemeHandler.scheme)://resource/\(id)")!,
            continuation: captured
        )
    }

    func takeResource(id: String) -> AsyncThrowingStream<URLSchemeTaskResult, any Error>? {
        lock.withLock { streams.removeValue(forKey: id) }
    }
}

@available(macOS 26.0, *)
private struct BrowserResourceSchemeHandler: URLSchemeHandler, Sendable {
    static let scheme = "majortom-resource"
    let store: BrowserResourceStore

    func reply(for request: URLRequest) -> AsyncThrowingStream<URLSchemeTaskResult, any Error> {
        guard let id = request.url?.lastPathComponent,
              let stream = store.takeResource(id: id) else {
            return AsyncThrowingStream { $0.finish(throwing: URLError(.resourceUnavailable)) }
        }
        return stream
    }
}
