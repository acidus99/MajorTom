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
    @Published private(set) var title = "New Tab"
    @Published private(set) var canSavePage = false
    @Published private(set) var canShowSource = false
    @Published var validationMessage: String?
    @Published var trustPrompt: TrustPrompt?
    @Published var inputPrompt: InputPrompt?
    @Published var inputValidationMessage: String?
    @Published private(set) var pageZoom = 1.0
    @Published private(set) var retryNotBefore: Date?

    let page: WebPage

    private let documentStore: BrowserDocumentStore
    private let resourceStore: BrowserResourceStore
    private let router: BrowserNavigationRouter
    private let transport = GeminiTransport()
    private let settings = BrowserSettingsStore.shared
    private let trustPolicy = ServerTrustPolicy()
    private let trustStore: TrustedIdentityStore?
    private let renderer = HTMLDocumentStreamRenderer()
    private var cancellables = Set<AnyCancellable>()

    private var navigationTask: Task<Void, Never>?
    private var documentContinuation: AsyncThrowingStream<Data, any Error>.Continuation?
    private var trustContinuation: CheckedContinuation<Bool, Never>?
    private var history: [URL] = []
    private var historyIndex = -1
    private var cachedPages: [URL: CachedPage] = [:]
    private var hasStarted = false
    private var trustWasDeclined = false
    private var currentSourceBytes = Data()
    private var currentMIMEType = ""
    private var imageTasks: [Task<Void, Never>] = []
    private let imageLimiter = AsyncSemaphore(limit: 4)
    private var slowDownTask: Task<Void, Never>?

    init(restoredState: RestoredTabState? = nil) {
        let documentStore = BrowserDocumentStore()
        let resourceStore = BrowserResourceStore()
        let router = BrowserNavigationRouter()
        var configuration = WebPage.Configuration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.suppressesIncrementalRendering = false
        configuration.loadsSubresources = true
        configuration.defaultNavigationPreferences.allowsContentJavaScript = false
        configuration.urlSchemeHandlers = [
            URLScheme(BrowserDocumentSchemeHandler.scheme)!:
                BrowserDocumentSchemeHandler(store: documentStore),
            URLScheme(BrowserResourceSchemeHandler.scheme)!:
                BrowserResourceSchemeHandler(store: resourceStore)
        ]

        self.documentStore = documentStore
        self.resourceStore = resourceStore
        self.router = router
        self.page = WebPage(
            configuration: configuration,
            navigationDecider: BrowserNavigationDecider(router: router)
        )
        self.trustStore = Self.makeTrustStore()
        if let restoredState {
            self.history = restoredState.history
            self.historyIndex = min(restoredState.historyIndex, restoredState.history.count - 1)
            self.cachedPages = Dictionary(uniqueKeysWithValues: restoredState.cachedPages.map { ($0.url, $0) })
            self.pageZoom = restoredState.zoom
            self.committedURL = self.history.indices.contains(self.historyIndex)
                ? self.history[self.historyIndex]
                : nil
            self.locationText = self.committedURL?.absoluteString ?? settings.preferences.homepage
        } else {
            self.locationText = settings.preferences.homepage
        }

        router.openURL = { [weak self] url in
            self?.openLink(url)
        }
        router.downloadURL = { [weak self] url in
            self?.download(url)
        }
        settings.$preferences
            .dropFirst()
            .sink { [weak self] _ in self?.preferencesChanged() }
            .store(in: &cancellables)
    }

    var canGoBack: Bool { historyIndex > 0 }
    var canGoForward: Bool { historyIndex >= 0 && historyIndex + 1 < history.count }
    var canReload: Bool {
        !isLoading && committedURL != nil && (retryNotBefore.map { Date() >= $0 } ?? true)
    }

    func start() {
        guard !hasStarted else { return }
        hasStarted = true
        if let committedURL, let cached = cachedPages[committedURL] {
            displayCachedPage(cached)
        } else {
            submitLocation()
        }
    }

    var restorationState: RestoredTabState {
        RestoredTabState(
            history: history,
            historyIndex: historyIndex,
            cachedPages: Array(cachedPages.values),
            zoom: pageZoom
        )
    }

    func submitLocation() {
        validationMessage = nil
        do {
            let preferences = settings.preferences
            let interpreter = AddressInputInterpreter(searchEndpoint:
                preferences.searchProvider.endpoint(customEndpoint: preferences.customSearchEndpoint)
            )
            switch try interpreter.interpret(locationText) {
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
        if let committedURL, !currentSourceBytes.isEmpty {
            cachedPages[committedURL] = CachedPage(
                url: committedURL,
                mimeType: currentMIMEType,
                body: currentSourceBytes,
                completion: .stopped,
                receivedAt: Date()
            )
        }
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

    func goHome() {
        locationText = settings.preferences.homepage
        submitLocation()
    }

    func goToCapsuleRoot() {
        guard let committedURL,
              var components = URLComponents(url: committedURL, resolvingAgainstBaseURL: false) else { return }
        components.path = "/"
        components.query = nil
        components.fragment = nil
        guard let url = components.url,
              let target = try? GeminiRequestTarget(url.absoluteString) else { return }
        navigate(to: target, disposition: .new)
    }

    func goUpOneLevel() {
        guard let committedURL,
              var components = URLComponents(url: committedURL, resolvingAgainstBaseURL: false) else { return }
        var parts = components.path.split(separator: "/")
        if !parts.isEmpty { parts.removeLast() }
        components.path = "/" + parts.joined(separator: "/") + (parts.isEmpty ? "" : "/")
        components.query = nil
        components.fragment = nil
        guard let url = components.url,
              let target = try? GeminiRequestTarget(url.absoluteString) else { return }
        navigate(to: target, disposition: .new)
    }

    func zoomIn() {
        pageZoom = min(3, pageZoom + 0.1)
        applyZoom()
    }

    func zoomOut() {
        pageZoom = max(0.5, pageZoom - 0.1)
        applyZoom()
    }

    func actualSize() {
        pageZoom = 1
        applyZoom()
    }

    func find(_ query: String, backwards: Bool = false) {
        guard !query.isEmpty else { return }
        Task {
            _ = try? await page.callJavaScript(
                "window.find(query, false, backwards, true, false, true, false)",
                arguments: ["query": query, "backwards": backwards]
            )
        }
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

    func download(_ url: URL) {
        statusText = "Downloading \(url.lastPathComponent)…"
        Task {
            do {
                let result: (Data, String)
                if url.scheme?.lowercased() == "gemini" {
                    result = try await retrieveGeminiResource(url)
                } else if ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
                    let (data, response) = try await URLSession.shared.data(from: url)
                    result = (data, response.mimeType ?? "application/octet-stream")
                } else {
                    throw URLError(.unsupportedURL)
                }
                let panel = NSSavePanel()
                panel.nameFieldStringValue = suggestedFilename(for: url, mimeType: result.1)
                panel.canCreateDirectories = true
                guard await panel.begin() == .OK, let destination = panel.url else {
                    statusText = "Download cancelled"
                    return
                }
                try result.0.write(to: destination, options: .atomic)
                statusText = "Downloaded \(destination.lastPathComponent)"
            } catch {
                validationMessage = "Download failed: \(friendly(error))"
                statusText = "Download failed"
            }
        }
    }

    func respondToTrust(allow: Bool) {
        trustPrompt = nil
        trustContinuation?.resume(returning: allow)
        trustContinuation = nil
    }

    func cancelInput() {
        inputPrompt = nil
        inputValidationMessage = nil
        isLoading = false
        statusText = "Input cancelled"
        if let committedURL { locationText = committedURL.absoluteString }
    }

    func submitInput(_ value: String) {
        guard let prompt = inputPrompt else { return }
        var components = URLComponents(url: prompt.target.url, resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: value, value: nil)]
        guard let url = components?.url,
              let target = try? GeminiRequestTarget(url.absoluteString) else {
            inputValidationMessage = "This response is too large for a Gemini request. Shorten it and try again."
            return
        }
        inputValidationMessage = nil
        inputPrompt = nil
        navigate(to: target, disposition: .new)
    }

    private func navigateHistory(to url: URL) {
        if let cached = cachedPages[url] {
            displayCachedPage(cached)
            return
        }
        guard let target = try? GeminiRequestTarget(url.absoluteString) else { return }
        navigate(to: target, disposition: .traversal)
    }

    private func navigate(to target: GeminiRequestTarget, disposition: HistoryDisposition) {
        navigationTask?.cancel()
        slowDownTask?.cancel()
        slowDownTask = nil
        retryNotBefore = nil
        imageTasks.forEach { $0.cancel() }
        imageTasks.removeAll()
        trustContinuation?.resume(returning: false)
        trustContinuation = nil
        trustPrompt = nil
        inputPrompt = nil
        inputValidationMessage = nil
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
            let events = transport.events(
                for: target,
                configuration: GeminiTransportConfiguration(proxy: settings.preferences.proxy)
            ) { [weak self] identity, _ in
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
                        var message = header.requiresClientCertificate
                            ? "This capsule requires a client certificate. Major Tom does not support client identities yet."
                            : header.meta
                        if header.status == 44 {
                            let seconds = max(0, Int(header.meta.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0)
                            retryNotBefore = Date().addingTimeInterval(TimeInterval(seconds))
                            message = "The capsule asked Major Tom to wait \(seconds) seconds before trying again."
                            slowDownTask?.cancel()
                            slowDownTask = Task { [weak self] in
                                try? await Task.sleep(for: .seconds(seconds))
                                guard !Task.isCancelled else { return }
                                self?.retryNotBefore = nil
                            }
                        }
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
                        continuation.yield(renderer.documentStart(
                            themeCSS: themeCSS,
                            baseURL: target.url
                        ))
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
                            emit(parsedEvent, baseURL: target.url)
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
                            emit(parsedEvent, baseURL: target.url)
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
                    cachedPages[target.url] = CachedPage(
                        url: target.url,
                        mimeType: mimeType,
                        body: sourceBytes,
                        completion: .complete,
                        receivedAt: Date(),
                        title: title
                    )
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
                    emit(parsedEvent, baseURL: target.url)
                }
                finishCurrentDocument(message: "The connection ended before the response completed: \(friendly(error))")
                currentSourceBytes = sourceBytes
                currentMIMEType = mimeType
                canSavePage = !sourceBytes.isEmpty
                canShowSource = mimeType.hasPrefix("text/") && !sourceBytes.isEmpty
                if let committedURL {
                    cachedPages[committedURL] = CachedPage(
                        url: committedURL,
                        mimeType: mimeType,
                        body: sourceBytes,
                        completion: .incomplete,
                        receivedAt: Date()
                    )
                }
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
        continuation.yield(renderer.documentStart(
            themeCSS: themeCSS,
            baseURL: url,
            browserGenerated: true
        ))
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
        continuation.yield(renderer.documentStart(themeCSS: themeCSS, baseURL: url))
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
        title = displayTitle(for: url)
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
            BrowsingHistoryStore.shared.record(url)
        case .reload, .traversal:
            break
        }
    }

    private func displayCachedPage(_ cached: CachedPage) {
        navigationTask?.cancel()
        isLoading = false
        committedURL = cached.url
        locationText = cached.url.absoluteString
        currentSourceBytes = cached.body
        currentMIMEType = cached.mimeType
        title = cached.title ?? displayTitle(for: cached.url)
        canSavePage = !cached.body.isEmpty
        canShowSource = cached.mimeType.hasPrefix("text/")
        renderCurrentContent()
        applyZoom()
        statusText = cached.completion == .complete
            ? "Cached • \(cached.body.count) bytes"
            : "Cached \(cached.completion.rawValue) response"
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
            case .timedOut:
                return "The capsule did not respond within 30 seconds."
            case .responseTooLarge(let limit):
                return "The response exceeded Major Tom's \(limit / 1_024 / 1_024) MB safety limit."
            }
        }
        return error.localizedDescription
    }

    private var themeCSS: String {
        let dark = NSApplication.shared.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return settings.preferences.contentTheme.css(effectiveDarkAppearance: dark)
    }

    private func preferencesChanged() {
        guard !isLoading, committedURL != nil, canSavePage else { return }
        renderCurrentContent()
    }

    private func applyZoom() {
        let zoom = pageZoom
        Task {
            _ = try? await page.callJavaScript(
                "document.documentElement.style.zoom = String(zoom)",
                arguments: ["zoom": zoom]
            )
        }
    }

    private func renderCurrentContent() {
        guard let committedURL else { return }
        if currentMIMEType == "text/gemini" {
            var decoder = IncrementalUTF8Decoder()
            var parser = IncrementalGemtextParser()
            let events = parser.receive(decoder.decode(currentSourceBytes) + decoder.finish()) + parser.finish()
            let continuation = beginDocument(at: committedURL)
            continuation.yield(renderer.documentStart(themeCSS: themeCSS, baseURL: committedURL))
            for event in events {
                documentContinuation = continuation
                emit(event, baseURL: committedURL)
            }
            documentContinuation = nil
            continuation.yield(renderer.documentEnd())
            continuation.finish()
        } else if currentMIMEType.hasPrefix("text/") {
            let continuation = beginDocument(at: committedURL)
            continuation.yield(renderer.documentStart(themeCSS: themeCSS, baseURL: committedURL))
            continuation.yield(Data("<pre><code>\(HTMLDocumentStreamRenderer.escape(String(decoding: currentSourceBytes, as: UTF8.self)))</code></pre>".utf8))
            continuation.yield(renderer.documentEnd())
            continuation.finish()
        } else if currentMIMEType.hasPrefix("image/") {
            showImagePage(data: currentSourceBytes, mimeType: currentMIMEType, url: committedURL, disposition: .reload)
        }
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

    private func emit(_ event: GemtextEvent, baseURL: URL) {
        if case .heading(level: 1, text: let heading) = event,
           title == displayTitle(for: baseURL) {
            let candidate = heading.trimmingCharacters(in: .whitespacesAndNewlines)
            if !candidate.isEmpty { title = candidate }
        }
        documentContinuation?.yield(renderer.render(
            event,
            options: settings.preferences.renderingOptions
        ))
        guard case .link(let destination, let label) = event else { return }

        if destination.lowercased().hasPrefix("data:image/"),
           settings.preferences.automaticallyLoadsDataImages,
           let dataURL = URL(string: destination) {
            documentContinuation?.yield(renderer.renderInlineImage(
                resourceURL: dataURL,
                altText: label ?? "Inline image"
            ))
            return
        }

        guard settings.preferences.automaticallyLoadsSameCapsuleImages,
              let url = URL(string: destination, relativeTo: baseURL)?.absoluteURL,
              isProbableImage(url),
              isSameCapsule(url, baseURL) else { return }

        let resource = resourceStore.createResource()
        documentContinuation?.yield(renderer.renderInlineImage(
            resourceURL: resource.url,
            altText: label ?? url.lastPathComponent
        ))
        let task = Task { [weak self] in
            guard let self else { return }
            await self.imageLimiter.acquire()
            await self.loadInlineImage(url, continuation: resource.continuation, redirects: 0)
            await self.imageLimiter.release()
        }
        imageTasks.append(task)
    }

    private func loadInlineImage(
        _ url: URL,
        continuation: AsyncThrowingStream<URLSchemeTaskResult, any Error>.Continuation,
        redirects: Int
    ) async {
        guard redirects <= 5,
              let target = try? GeminiRequestTarget(url.absoluteString) else {
            continuation.finish(throwing: URLError(.badURL))
            return
        }
        do {
            let events = transport.events(
                for: target,
                configuration: GeminiTransportConfiguration(
                    proxy: settings.preferences.proxy,
                    maximumResponseByteCount: 16 * 1_024 * 1_024
                )
            ) { [weak self] identity, _ in
                guard let self else { return false }
                return await self.authorize(identity)
            }
            var accepted = false
            for try await event in events {
                switch event {
                case .responseHeader(let header):
                    if header.isRedirect,
                       let redirected = URL(string: header.meta, relativeTo: url)?.absoluteURL,
                       isSameCapsule(redirected, url) {
                        await loadInlineImage(redirected, continuation: continuation, redirects: redirects + 1)
                        return
                    }
                    let mime = header.meta.split(separator: ";", maxSplits: 1).first
                        .map { $0.trimmingCharacters(in: .whitespaces).lowercased() } ?? ""
                    guard header.isSuccess, mime.hasPrefix("image/") else {
                        continuation.finish(throwing: URLError(.cannotDecodeContentData))
                        return
                    }
                    accepted = true
                    continuation.yield(.response(URLResponse(
                        url: url,
                        mimeType: mime,
                        expectedContentLength: -1,
                        textEncodingName: nil
                    )))
                case .body(let data) where accepted:
                    continuation.yield(.data(data))
                case .completed:
                    continuation.finish()
                default:
                    break
                }
            }
        } catch {
            continuation.finish(throwing: error)
        }
    }

    private func retrieveGeminiResource(_ url: URL) async throws -> (Data, String) {
        guard let target = try? GeminiRequestTarget(url.absoluteString) else {
            throw URLError(.badURL)
        }
        var body = Data()
        var mimeType = "application/octet-stream"
        let events = transport.events(
            for: target,
            configuration: GeminiTransportConfiguration(proxy: settings.preferences.proxy)
        ) { [weak self] identity, _ in
            guard let self else { return false }
            return await self.authorize(identity)
        }
        for try await event in events {
            switch event {
            case .responseHeader(let header):
                guard header.isSuccess else {
                    throw GeminiTransportError.connectionFailed("Gemini status \(header.status): \(header.meta)")
                }
                mimeType = header.meta.split(separator: ";", maxSplits: 1).first.map(String.init) ?? mimeType
            case .body(let data):
                body.append(data)
            default:
                break
            }
        }
        return (body, mimeType)
    }

    private func isProbableImage(_ url: URL) -> Bool {
        ["png", "jpg", "jpeg", "gif", "webp", "heic", "heif"]
            .contains(url.pathExtension.lowercased())
    }

    private func isSameCapsule(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.host?.lowercased() == rhs.host?.lowercased()
            && (lhs.port ?? Int(GeminiRequestTarget.defaultPort))
                == (rhs.port ?? Int(GeminiRequestTarget.defaultPort))
    }

    private func displayTitle(for url: URL) -> String {
        let filename = url.deletingPathExtension().lastPathComponent
        if !filename.isEmpty { return filename }
        return url.host ?? "Major Tom"
    }
}

private actor AsyncSemaphore {
    private let limit: Int
    private var active = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) { self.limit = max(1, limit) }

    func acquire() async {
        if active < limit {
            active += 1
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        if waiters.isEmpty { active = max(0, active - 1) }
        else { waiters.removeFirst().resume() }
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
    var downloadURL: ((URL) -> Void)?
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
        if action.shouldPerformDownload {
            router.downloadURL?(url)
            return .cancel
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
