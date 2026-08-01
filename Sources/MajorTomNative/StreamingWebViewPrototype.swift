import AppKit
import Combine
import Foundation
import MajorTomCore
import SwiftUI
import WebKit

@available(macOS 26.0, *)
@MainActor
final class BrowserModel: ObservableObject {
    enum HistoryDisposition {
        case new, reload, traversal
    }

    struct TrustPrompt: Identifiable {
        let id = UUID()
        let title: String
        let explanation: String
        let identity: PresentedServerIdentity
        let previousFingerprint: String?
    }

    struct InputPrompt: Identifiable {
        let id = UUID()
        let target: GeminiRequestTarget
        let message: String
        let isSensitive: Bool
    }

    @Published var locationText = "gemini://gemi.dev/"
    @Published private(set) var committedURL: URL?
    @Published private(set) var isLoading = false
    @Published private(set) var statusText = "Ready"
    @Published private(set) var canSavePage = false
    @Published private(set) var canShowSource = false
    @Published var validationMessage: String?
    @Published var trustPrompt: TrustPrompt?
    @Published var inputPrompt: InputPrompt?

    let page: WebPage

    private let documentStore: BrowserDocumentStore
    private let router: BrowserNavigationRouter
    private let transport = GeminiTransport()
    private let trustPolicy = ServerTrustPolicy()
    private let trustStore: TrustedIdentityStore?
    private let renderer = HTMLDocumentStreamRenderer()
    private let addressInterpreter = AddressInputInterpreter()

    private var navigationTask: Task<Void, Never>?
    private var documentContinuation: AsyncThrowingStream<Data, any Error>.Continuation?
    private var trustContinuation: CheckedContinuation<Bool, Never>?
    private var history: [URL] = []
    private var historyIndex = -1
    private var hasStarted = false
    private var trustWasDeclined = false
    private var currentSourceBytes = Data()
    private var currentMIMEType = ""

    init() {
        let documentStore = BrowserDocumentStore()
        let router = BrowserNavigationRouter()
        var configuration = WebPage.Configuration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.suppressesIncrementalRendering = false
        configuration.loadsSubresources = false
        configuration.defaultNavigationPreferences.allowsContentJavaScript = false
        configuration.urlSchemeHandlers = [
            URLScheme(BrowserDocumentSchemeHandler.scheme)!:
                BrowserDocumentSchemeHandler(store: documentStore)
        ]

        self.documentStore = documentStore
        self.router = router
        self.page = WebPage(
            configuration: configuration,
            navigationDecider: BrowserNavigationDecider(router: router)
        )
        self.trustStore = Self.makeTrustStore()

        router.openURL = { [weak self] url in
            self?.openLink(url)
        }
    }

    var canGoBack: Bool { historyIndex > 0 }
    var canGoForward: Bool { historyIndex >= 0 && historyIndex + 1 < history.count }

    func start() {
        guard !hasStarted else { return }
        hasStarted = true
        submitLocation()
    }

    func submitLocation() {
        validationMessage = nil
        do {
            switch try addressInterpreter.interpret(locationText) {
            case .gemini(let target):
                navigate(to: target, disposition: .new)
            case .external(let url):
                openExternalURL(url)
            }
        } catch AddressInputError.empty {
            validationMessage = "Enter a capsule address or search query."
        } catch AddressInputError.invalidGeminiURL {
            validationMessage = "That is not a valid Gemini address."
        } catch {
            validationMessage = "That address could not be opened."
        }
    }

    func reload() {
        guard let committedURL,
              let target = try? GeminiRequestTarget(committedURL.absoluteString) else { return }
        navigate(to: target, disposition: .reload)
    }

    func stop() {
        navigationTask?.cancel()
        navigationTask = nil
        trustContinuation?.resume(returning: false)
        trustContinuation = nil
        trustPrompt = nil
        finishCurrentDocument(message: "Loading was stopped.")
        isLoading = false
        statusText = "Stopped"
        if let committedURL { locationText = committedURL.absoluteString }
    }

    func goBack() {
        guard canGoBack else { return }
        historyIndex -= 1
        navigateHistory(to: history[historyIndex])
    }

    func goForward() {
        guard canGoForward else { return }
        historyIndex += 1
        navigateHistory(to: history[historyIndex])
    }

    func showPageSource() {
        guard canShowSource else { return }
        let source = String(decoding: currentSourceBytes, as: UTF8.self)
        let continuation = beginDocument(at: committedURL ?? URL(string: "gemini://source.invalid/")!)
        continuation.yield(renderer.documentStart(browserGenerated: true))
        continuation.yield(Data("<p class=\"eyebrow\">Page Source</p><div class=\"source\">".utf8))
        for (index, line) in source.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let html = "<div style=\"display:grid;grid-template-columns:4rem 1fr\"><span style=\"color:SecondaryLabelColor;text-align:right;padding-right:1rem;user-select:none\">\(index + 1)</span><code style=\"white-space:pre-wrap;overflow-wrap:anywhere\">\(HTMLDocumentStreamRenderer.escape(String(line)))</code></div>"
            continuation.yield(Data(html.utf8))
        }
        continuation.yield(Data("</div>".utf8))
        continuation.yield(renderer.documentEnd())
        continuation.finish()
        statusText = "Page source"
    }

    func savePage() async {
        guard canSavePage, let committedURL else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedFilename(for: committedURL, mimeType: currentMIMEType)
        panel.canCreateDirectories = true
        guard await panel.begin() == .OK, let destination = panel.url else { return }
        do {
            try currentSourceBytes.write(to: destination, options: .atomic)
            statusText = "Saved \(destination.lastPathComponent)"
        } catch {
            validationMessage = "The page could not be saved: \(error.localizedDescription)"
        }
    }

    func respondToTrust(allow: Bool) {
        trustPrompt = nil
        trustContinuation?.resume(returning: allow)
        trustContinuation = nil
    }

    func cancelInput() {
        inputPrompt = nil
        isLoading = false
        statusText = "Input cancelled"
        if let committedURL { locationText = committedURL.absoluteString }
    }

    func submitInput(_ value: String) {
        guard let prompt = inputPrompt else { return }
        inputPrompt = nil
        var components = URLComponents(url: prompt.target.url, resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: value, value: nil)]
        guard let url = components?.url,
              let target = try? GeminiRequestTarget(url.absoluteString) else {
            validationMessage = "That input would exceed the Gemini request limit."
            return
        }
        navigate(to: target, disposition: .new)
    }

    private func navigateHistory(to url: URL) {
        guard let target = try? GeminiRequestTarget(url.absoluteString) else { return }
        navigate(to: target, disposition: .traversal)
    }

    private func navigate(to target: GeminiRequestTarget, disposition: HistoryDisposition) {
        navigationTask?.cancel()
        trustContinuation?.resume(returning: false)
        trustContinuation = nil
        trustPrompt = nil
        inputPrompt = nil
        trustWasDeclined = false
        isLoading = true
        statusText = "Connecting to \(target.endpoint.host)…"
        locationText = target.url.absoluteString

        navigationTask = Task { [weak self] in
            guard let self else { return }
            await self.load(
                target: target,
                disposition: disposition,
                visited: [],
                redirectCount: 0
            )
        }
    }

    private func load(
        target: GeminiRequestTarget,
        disposition: HistoryDisposition,
        visited: Set<URL>,
        redirectCount: Int
    ) async {
        guard !Task.isCancelled else { return }
        guard redirectCount <= 10, !visited.contains(target.url) else {
            showGeneratedPage(
                title: "Too Many Redirects",
                message: "Major Tom stopped this navigation because the capsule redirected in a loop.",
                details: target.url.absoluteString,
                url: target.url,
                disposition: disposition
            )
            return
        }

        var nextVisited = visited
        nextVisited.insert(target.url)
        var responseHeader: GeminiResponseHeader?
        var mimeType = ""
        var sourceBytes = Data()
        var utf8Decoder = IncrementalUTF8Decoder()
        var gemtextParser = IncrementalGemtextParser()
        var contentStarted = false

        do {
            let events = transport.events(for: target) { [weak self] identity, _ in
                guard let self else { return false }
                return await self.authorize(identity)
            }

            for try await event in events {
                try Task.checkCancellation()
                switch event {
                case .connecting:
                    statusText = "Connecting securely…"
                case .serverIdentity:
                    statusText = "Verifying capsule identity…"
                case .responseHeader(let header):
                    responseHeader = header
                    statusText = "Response \(header.status)"

                    if header.isRedirect {
                        guard let redirectURL = URL(string: header.meta, relativeTo: target.url)?.absoluteURL,
                              let redirectTarget = try? GeminiRequestTarget(redirectURL.absoluteString) else {
                            showGeneratedPage(
                                title: "Invalid Redirect",
                                message: "The capsule returned a redirect that Major Tom could not understand.",
                                details: header.meta,
                                url: target.url,
                                disposition: disposition
                            )
                            return
                        }
                        locationText = redirectTarget.url.absoluteString
                        await load(
                            target: redirectTarget,
                            disposition: disposition,
                            visited: nextVisited,
                            redirectCount: redirectCount + 1
                        )
                        return
                    }

                    if header.isInput {
                        inputPrompt = InputPrompt(
                            target: target,
                            message: header.meta,
                            isSensitive: header.status == 11
                        )
                        isLoading = false
                        statusText = "Input required"
                        return
                    }

                    if header.isTemporaryFailure || header.isPermanentFailure || header.requiresClientCertificate {
                        let title = header.isTemporaryFailure
                            ? "Temporary Capsule Failure"
                            : header.isPermanentFailure
                                ? "Permanent Capsule Failure"
                                : "Client Identity Required"
                        let message = header.requiresClientCertificate
                            ? "This capsule requires a client certificate. Major Tom does not support client identities yet."
                            : header.meta
                        showGeneratedPage(
                            title: title,
                            message: message,
                            details: "Gemini status \(header.status)\n\(target.url.absoluteString)",
                            url: target.url,
                            disposition: disposition
                        )
                        return
                    }

                    guard header.isSuccess else {
                        showGeneratedPage(
                            title: "Unsupported Response",
                            message: "The capsule returned an unsupported Gemini response.",
                            details: "Status \(header.status): \(header.meta)",
                            url: target.url,
                            disposition: disposition
                        )
                        return
                    }

                    mimeType = header.meta.split(separator: ";", maxSplits: 1).first
                        .map { $0.trimmingCharacters(in: .whitespaces).lowercased() } ?? ""
                    if mimeType == "text/gemini" || mimeType.hasPrefix("text/") {
                        currentSourceBytes = Data()
                        currentMIMEType = mimeType
                        canSavePage = false
                        canShowSource = false
                        let continuation = beginDocument(at: target.url)
                        documentContinuation = continuation
                        continuation.yield(renderer.documentStart(baseURL: target.url))
                        if mimeType != "text/gemini" {
                            continuation.yield(Data("<pre><code>".utf8))
                        }
                        commit(target.url, disposition: disposition)
                        contentStarted = true
                        statusText = "Receiving \(mimeType)…"
                    }

                case .body(let data):
                    guard let header = responseHeader, header.isSuccess else { continue }
                    sourceBytes.append(data)
                    currentSourceBytes = sourceBytes
                    if mimeType == "text/gemini" {
                        let decoded = utf8Decoder.decode(data)
                        for parsedEvent in gemtextParser.receive(decoded) {
                            documentContinuation?.yield(renderer.render(parsedEvent))
                        }
                    } else if mimeType.hasPrefix("text/") {
                        let decoded = utf8Decoder.decode(data)
                        documentContinuation?.yield(Data(HTMLDocumentStreamRenderer.escape(decoded).utf8))
                    }

                case .completed:
                    guard let header = responseHeader, header.isSuccess else { return }
                    if mimeType == "text/gemini" {
                        let tail = utf8Decoder.finish()
                        let finalEvents = gemtextParser.receive(tail) + gemtextParser.finish()
                        for parsedEvent in finalEvents {
                            documentContinuation?.yield(renderer.render(parsedEvent))
                        }
                        finishCurrentDocument()
                    } else if mimeType.hasPrefix("text/") {
                        documentContinuation?.yield(Data(HTMLDocumentStreamRenderer.escape(utf8Decoder.finish()).utf8))
                        documentContinuation?.yield(Data("</code></pre>".utf8))
                        finishCurrentDocument()
                    } else if mimeType.hasPrefix("image/") {
                        showImagePage(data: sourceBytes, mimeType: mimeType, url: target.url, disposition: disposition)
                    } else {
                        showGeneratedPage(
                            title: "Unsupported Content",
                            message: "Major Tom cannot display this response type yet. No file was downloaded.",
                            details: "\(mimeType.isEmpty ? header.meta : mimeType)\n\(sourceBytes.count) bytes",
                            url: target.url,
                            disposition: disposition
                        )
                    }
                    isLoading = false
                    currentSourceBytes = sourceBytes
                    currentMIMEType = mimeType
                    canSavePage = true
                    canShowSource = mimeType.hasPrefix("text/")
                    statusText = "Loaded \(sourceBytes.count) bytes"
                    navigationTask = nil
                    return
                }
            }
        } catch is CancellationError {
            return
        } catch {
            if trustWasDeclined {
                isLoading = false
                statusText = "Connection cancelled"
                if let committedURL { locationText = committedURL.absoluteString }
                return
            }
            if contentStarted {
                for parsedEvent in gemtextParser.receive(utf8Decoder.finish()) + gemtextParser.finish() {
                    documentContinuation?.yield(renderer.render(parsedEvent))
                }
                finishCurrentDocument(message: "The connection ended before the response completed: \(friendly(error))")
                currentSourceBytes = sourceBytes
                currentMIMEType = mimeType
                canSavePage = !sourceBytes.isEmpty
                canShowSource = mimeType.hasPrefix("text/") && !sourceBytes.isEmpty
                isLoading = false
                statusText = "Incomplete response"
            } else {
                showGeneratedPage(
                    title: "Could Not Open Capsule",
                    message: friendly(error),
                    details: target.url.absoluteString,
                    url: target.url,
                    disposition: disposition
                )
            }
        }
    }

    private func authorize(_ identity: PresentedServerIdentity) async -> Bool {
        let locallyTrusted = await trustStore?.identity(for: identity.endpoint)
        let evaluation = trustPolicy.evaluate(
            presented: identity,
            locallyTrusted: locallyTrusted,
            seeds: []
        )

        switch evaluation {
        case .allowSilently:
            if let trustStore, locallyTrusted != nil {
                try? await trustStore.trust(identity, source: locallyTrusted?.source ?? .user)
            }
            return true
        case .requiresApproval(let challenge):
            if case .firstUse = challenge {
                do {
                    guard let trustStore else {
                        validationMessage = "Major Tom could not open its trusted-identity store."
                        return false
                    }
                    try await trustStore.trust(identity, source: .user)
                    statusText = "Trusted \(identity.endpoint.host) on first use"
                    return true
                } catch {
                    validationMessage = "Major Tom could not save this capsule's identity: \(error.localizedDescription)"
                    return false
                }
            }
            let prompt = Self.prompt(for: challenge)
            let approved = await withCheckedContinuation { continuation in
                trustContinuation = continuation
                trustPrompt = prompt
            }
            guard approved else {
                trustWasDeclined = true
                return false
            }
            try? await trustStore?.trust(identity, source: .user)
            return true
        }
    }

    private func openLink(_ url: URL) {
        if url.scheme?.lowercased() == "gemini",
           let target = try? GeminiRequestTarget(url.absoluteString) {
            navigate(to: target, disposition: .new)
        } else {
            openExternalURL(url)
        }
    }

    private func openExternalURL(_ url: URL) {
        let permitted = ["http", "https", "mailto"]
        guard let scheme = url.scheme?.lowercased(), permitted.contains(scheme) else {
            validationMessage = "Major Tom does not permit the \(url.scheme ?? "unknown") URL scheme."
            return
        }
        NSWorkspace.shared.open(url)
    }

    private func beginDocument(at sourceURL: URL) -> AsyncThrowingStream<Data, any Error>.Continuation {
        documentContinuation?.finish()
        let document = documentStore.createDocument()
        _ = page.load(document.url)
        return document.continuation
    }

    private func finishCurrentDocument(message: String? = nil) {
        guard let continuation = documentContinuation else { return }
        continuation.yield(renderer.documentEnd(incompleteMessage: message))
        continuation.finish()
        documentContinuation = nil
    }

    private func showGeneratedPage(
        title: String,
        message: String,
        details: String,
        url: URL,
        disposition: HistoryDisposition
    ) {
        let continuation = beginDocument(at: url)
        continuation.yield(renderer.documentStart(baseURL: url, browserGenerated: true))
        let html = """
        <p class="eyebrow">Major Tom</p>
        <h1>\(HTMLDocumentStreamRenderer.escape(title))</h1>
        <p>\(HTMLDocumentStreamRenderer.escape(message))</p>
        <div class="details">\(HTMLDocumentStreamRenderer.escape(details))</div>
        """
        continuation.yield(Data(html.utf8))
        continuation.yield(renderer.documentEnd())
        continuation.finish()
        commit(url, disposition: disposition)
        currentSourceBytes = Data()
        currentMIMEType = ""
        canSavePage = false
        canShowSource = false
        isLoading = false
        statusText = title
        navigationTask = nil
    }

    private func showImagePage(
        data: Data,
        mimeType: String,
        url: URL,
        disposition: HistoryDisposition
    ) {
        let continuation = beginDocument(at: url)
        continuation.yield(renderer.documentStart(baseURL: url))
        let source = "data:\(HTMLDocumentStreamRenderer.escapeAttribute(mimeType));base64,\(data.base64EncodedString())"
        continuation.yield(Data("<img alt=\"\" src=\"\(source)\" style=\"max-width:100%;height:auto\">".utf8))
        continuation.yield(renderer.documentEnd())
        continuation.finish()
        commit(url, disposition: disposition)
    }

    private func suggestedFilename(for url: URL, mimeType: String) -> String {
        var name = url.lastPathComponent
        if name.isEmpty { name = "untitled" }
        guard !name.contains(".") else { return name }
        switch mimeType {
        case "text/gemini": return name + ".gmi"
        case "text/plain": return name + ".txt"
        case "image/png": return name + ".png"
        case "image/jpeg": return name + ".jpg"
        case "image/gif": return name + ".gif"
        default: return name
        }
    }

    private func commit(_ url: URL, disposition: HistoryDisposition) {
        committedURL = url
        locationText = url.absoluteString
        switch disposition {
        case .new:
            if historyIndex + 1 < history.count {
                history.removeSubrange((historyIndex + 1)...)
            }
            if history.last != url {
                history.append(url)
                historyIndex = history.count - 1
            }
        case .reload, .traversal:
            break
        }
    }

    private func friendly(_ error: any Error) -> String {
        if let transportError = error as? GeminiTransportError {
            switch transportError {
            case .certificateUnavailable:
                return "The capsule did not provide a usable certificate."
            case .publicKeyFingerprintFailed:
                return "Major Tom could not identify the capsule's public key."
            case .trustDeclined:
                return "The capsule identity was not trusted."
            case .connectionFailed(let detail):
                return "The secure connection failed. \(detail)"
            case .responseFailed(let protocolError):
                return "The capsule returned an invalid Gemini response: \(protocolError)."
            }
        }
        return error.localizedDescription
    }

    private static func makeTrustStore() -> TrustedIdentityStore? {
        guard let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else { return nil }
        let file = applicationSupport
            .appendingPathComponent("Major Tom", isDirectory: true)
            .appendingPathComponent("trusted-identities.json")
        return try? TrustedIdentityStore(fileURL: file)
    }

    private static func prompt(for challenge: ServerTrustChallenge) -> TrustPrompt {
        switch challenge {
        case .firstUse(let presented):
            return TrustPrompt(
                title: "Trust This Capsule?",
                explanation: "This is the first time Major Tom has connected to this capsule. Confirm its identity before continuing.",
                identity: presented,
                previousFingerprint: nil
            )
        case .changed(let presented, let previous):
            return TrustPrompt(
                title: "Capsule Identity Changed",
                explanation: "The capsule is presenting a different public key. This can be legitimate, but it can also indicate an intercepted connection.",
                identity: presented,
                previousFingerprint: previous.publicKeySHA256
            )
        case .seedMismatch(let presented, let expected):
            return TrustPrompt(
                title: "Capsule Identity Does Not Match",
                explanation: "The presented public key does not match Major Tom's prior identity information.",
                identity: presented,
                previousFingerprint: expected.sorted().joined(separator: "\n")
            )
        case .invalidCertificateDates(let presented, let issue):
            let explanation: String
            switch issue {
            case .notYetValid(let date):
                explanation = "The capsule's certificate is not valid until \(date.formatted())."
            case .expired(let date):
                explanation = "The capsule's certificate expired on \(date.formatted())."
            }
            return TrustPrompt(
                title: "Certificate Date Warning",
                explanation: explanation,
                identity: presented,
                previousFingerprint: nil
            )
        }
    }
}

@available(macOS 26.0, *)
struct StreamingWebViewPrototype: View {
    @ObservedObject var browser: BrowserModel

    var body: some View {
        WebView(browser.page)
            .webViewTextSelection(.enabled)
            .webViewMagnificationGestures(.enabled)
    }
}

@available(macOS 26.0, *)
@MainActor
private final class BrowserNavigationRouter {
    var openURL: ((URL) -> Void)?
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
        if url.scheme == BrowserDocumentSchemeHandler.scheme { return .allow }
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
}

@available(macOS 26.0, *)
private struct BrowserDocumentSchemeHandler: URLSchemeHandler, Sendable {
    static let scheme = "majortom-document"
    let store: BrowserDocumentStore

    func reply(for request: URLRequest) -> AsyncThrowingStream<URLSchemeTaskResult, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                guard let url = request.url,
                      let stream = store.takeDocument(id: url.lastPathComponent) else {
                    throw URLError(.resourceUnavailable)
                }
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
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
