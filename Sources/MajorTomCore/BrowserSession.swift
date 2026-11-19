import Combine
import Foundation
import os

private let browserNavigationLogger = Logger(subsystem: "dev.gemi.major-tom", category: "Navigation")

/// One owner for the complete per-tab workflow, independent of native surfaces.
@MainActor
public final class BrowserSession: ObservableObject {
    public enum HistoryDisposition: Equatable { case new, reload, traversal }
    private struct LoadedInlineImage { let mimeType: String; let byteCount: Int }
    public struct InputPrompt: Identifiable {
        public let id = UUID()
        public let target: GeminiRequestTarget
        public let message: String
        public let isSensitive: Bool
        /// Text kept from an earlier, cancelled attempt at this same prompt.
        public var initialText: String = ""
    }

    public struct ClientCertificatePrompt: Identifiable {
        public let id = UUID()
        public let target: GeminiRequestTarget
        public let status: Int
        public let message: String
        public let attemptedCertificate: ClientCertificateDescriptor?
        public let matchingCertificateIsUnavailable: Bool
        public let matchingCertificateIsInvalid: Bool
    }

    @Published public var locationText = "gemini://gemi.dev/"
    @Published public private(set) var committedURL: URL?
    @Published public private(set) var isLoading = false {
        didSet {
            if oldValue, !isLoading, themeNeedsANSIRefresh {
                themeNeedsANSIRefresh = false
                Task { @MainActor [weak self] in self?.contentThemeChanged() }
            }
        }
    }
    private var themeNeedsANSIRefresh = false
    @Published public private(set) var statusText = "Ready"
    /// Destination of the link under the pointer, or focused by keyboard (spec 18.4).
    @Published public private(set) var hoveredLinkURL: String?
    /// The unformatted destination retained so native modifier changes can refresh the
    /// hover message without requiring another mouse-move event from WebKit.
    private var hoveredLinkDestination: String?
    @Published public private(set) var title = "New Tab"
    @Published public private(set) var documentTitle: String?
    /// The current capsule's favicon emoji, when it offers one.
    @Published public private(set) var favicon: String?
    /// Set when the tab is showing one of Major Tom's own pages instead of a document.
    @Published public private(set) var internalPage: InternalPage?
    @Published public private(set) var canSavePage = false
    @Published public private(set) var canShowSource = false
    @Published public private(set) var canGoBack = false
    @Published public private(set) var canGoForward = false
    @Published public var validationMessage: String?
    @Published public var inputPrompt: InputPrompt?
    @Published public var clientCertificatePrompt: ClientCertificatePrompt?
    /// The identity presented by the capsule serving the current page, kept for Page Info.
    @Published public private(set) var serverIdentity: PresentedServerIdentity?
    /// The client identity actually offered for the request that produced this page.
    @Published public private(set) var usedClientCertificate: ClientCertificateDescriptor?
    private var responseStatus: Int?
    private var responseMeta = ""
    private var responseWasCached: Bool?
    private var responseReceivedAt: Date?
    @Published public var inputValidationMessage: String?
    @Published public private(set) var pageZoom = 1.0
    @Published public private(set) var retryNotBefore: Date?
    /// False until WebKit has completely presented this tab's first document. The view
    /// keeps WebKit transparent over a content-theme placeholder until then, preventing
    /// its default white/black backing from flashing during creation or restoration.
    @Published public private(set) var hasPresentedInitialDocument = false
    /// Keeps a history entry that needs a nonzero offset behind the same placeholder
    /// until WebKit has laid it out and the offset has been applied.
    @Published public private(set) var isRestoringHistoryScroll = false
    public var backHistoryEntries: [BackForwardEntry] { navigation.backHistoryEntries }
    public var forwardHistoryEntries: [BackForwardEntry] { navigation.forwardHistoryEntries }

    public var openInNewTab: ((URL, Bool) -> Void)?
    public var openInNewWindow: ((URL) -> Void)?
    public var downloadURL: ((URL) -> Void)?
    private let services: BrowserSessionServices
    private let presentation: any BrowserPresentationSink
    private var documentRenderer = BrowserDocumentRenderer(style: BrowserContentStyle(
        css: ContentThemeStylesheets.base, palette: .fallback, appearance: .dark
    ))
    private var lastPreferences: BrowserPreferences
    private var backForwardCache: BackForwardCacheStore? { services.backForwardCache }
    public private(set) var isClosed = false
    private var closingTask: Task<Void, Never>?
    private let requestLifetime = AcceptedLocalWork()
    private var faviconTask: Task<Void, Never>?
    private var navigationTask: Task<Void, Never>?
    private var documentContinuation: AsyncThrowingStream<Data, any Error>.Continuation?
    /// Rendered HTML waiting to be handed to WebKit. See `yieldToDocument`.
    private var documentBuffer = Data()
    private static let documentFlushByteCount = 16 * 1_024
    /// This tab's position in its own history, the pages it has kept, and the reading
    /// position in each of them. Owned by Core so those rules can be tested without
    /// WebKit; see `NavigationState`.
    private var navigation = NavigationState()
    private var backForwardDebounceTask: Task<Void, Never>?
    private var backForwardWriteTask: Task<Void, Never>?
    private var browsingDataGeneration: UInt64 = 0
    private var isClearingBrowsingData = false
    private var currentResponseCanBeCached = true
    private var discardedDraftPrompts = Set<UUID>()
    /// While a traversal's replacement document is loading, its initial scroll events
    /// must not overwrite the offset we are about to restore.
    private var pendingScrollRestoration: (historyIndex: Int, offset: Double)?
    /// Restored inline images load through WebKit after their document finishes. Keep
    /// track of their final layout so their added height can be corrected after the
    /// normal initial restoration has revealed the document.
    private var pendingRestoredInlineImageCount = 0
    private var pendingInlineImageScrollCorrection: (historyIndex: Int, offset: Double)?
    /// The opaque URL of the document currently hosted by WebKit. Script messages from
    /// a page being replaced can arrive just after the next entry commits; checking this
    /// identity prevents that late message from being filed under the new history entry.
    public private(set) var activeWebDocumentURL: URL?
    private var pendingHistoryPreview: (id: UUID, source: BackForwardEntry.ID, target: BackForwardEntry.ID)?
    private var historyPreviewGeneration = 0
    private var pendingClientCertificateChallenge: (
        target: GeminiRequestTarget,
        disposition: HistoryDisposition,
        renderAsSource: Bool
    )?
    private var hasStarted = false
    private var currentSourceBytes = Data()
    private var currentMIMEType = ""
    private var currentCompletion = PageCompletionState.complete
    private var streamingBody: BrowserResponseBody?
    /// Tracks what has named the current document while the opening Gemtext lines stream
    /// in. A heading can replace an earlier preformatted caption; discovery is limited to
    /// the first fifteen Gemtext lines.
    private var titleClaim = GemtextTitleClaim()
    @Published private var imageTasks: [String: Task<Void, Never>] = [:]
    private var automaticImagesPaused = false
    private var inlineImageURLs: [String: URL] = [:]
    private var imageViewportTopInset: Double = 0
    private var imagePageStartedAt = ContinuousClock.now
    private var expandedInlineImages: Set<String> = []
    private var expandableImageLines: [URL: String] = [:]
    private var slowDownTask: Task<Void, Never>?

    public init(services: BrowserSessionServices, presentation: any BrowserPresentationSink,
                restoredState: RestoredTabState? = nil, initialURL: URL? = nil) {
        self.services = services
        self.presentation = presentation
        self.lastPreferences = services.preferences()
        if let restoredState {
            // NavigationState clamps the index at both ends. A negative or out-of-range
            // value from an older or corrupted blob previously left committedURL nil,
            // silently discarding the whole restored history.
            self.navigation = NavigationState(restoring: restoredState)
            self.pageZoom = restoredState.zoom
            self.committedURL = self.navigation.committedURL
            let currentCachedPage = self.committedURL.flatMap { self.navigation.cachedPage(for: $0) }
            self.locationText = self.committedURL?.absoluteString ?? services.preferences().homepage
            self.title = restoredState.title
                ?? currentCachedPage?.title
                ?? self.committedURL.map(displayTitle)
                ?? "New Tab"
            self.documentTitle = restoredState.documentTitle
                ?? currentCachedPage?.documentTitle
            self.favicon = self.navigation.currentEntry?.favicon
        } else {
            self.locationText = initialURL?.absoluteString ?? services.preferences().homepage
        }
        updateNavigationAvailability()
    }

    public var canReload: Bool { !isLoading && committedURL != nil && (retryNotBefore.map { services.now() >= $0 } ?? true) }
    public var canStop: Bool { isLoading || !imageTasks.isEmpty }
    public var restorationState: RestoredTabState {
        navigation.updateCurrentMetadata(title: documentTitle ?? title, favicon: favicon)
        return navigation.restorationState(zoom: pageZoom, title: title, documentTitle: documentTitle)
    }
    public var pageSnapshot: BrowserPageSnapshot? {
        guard let url = committedURL, let entryID = navigation.currentEntryID else { return nil }
        return BrowserPageSnapshot(entryID: entryID, url: url, title: title, documentTitle: documentTitle,
            mimeType: currentMIMEType, body: currentSourceBytes, completion: currentCompletion,
            status: responseStatus, meta: responseMeta, wasCached: responseWasCached,
            receivedAt: responseReceivedAt, serverIdentity: serverIdentity, clientCertificate: usedClientCertificate)
    }

    private var displayedResponseMetadata: BrowserResponseMetadata {
        BrowserResponseMetadata(status: responseStatus, meta: responseMeta, wasCached: responseWasCached,
            receivedAt: responseReceivedAt, serverIdentity: serverIdentity, clientCertificate: usedClientCertificate)
    }

    private func applyResponseMetadata(_ metadata: BrowserResponseMetadata?) {
        responseStatus = metadata?.status
        responseMeta = metadata?.meta ?? ""
        responseWasCached = metadata?.wasCached
        responseReceivedAt = metadata?.receivedAt
        serverIdentity = metadata?.serverIdentity
        usedClientCertificate = metadata?.clientCertificate
    }

    public var sourceBytes: Data { currentSourceBytes }
    public var hoveredDestination: String? { hoveredLinkDestination }
    public func inlineImageIsExpanded(line: String, url: URL) -> Bool? {
        guard inlineImageURLs[line] == url else { return nil }
        return expandedInlineImages.contains(line) && imageTasks[line] == nil
    }
    public var mimeType: String { currentMIMEType }

    public func start() {
        guard !hasStarted, !isClosed else { return }
        hasStarted = true

        Task { @MainActor [weak self] in
            await self?.services.preparePresentation()
            // A location submitted while the first theme was resolving supersedes
            // launch restoration. Never replace that newer navigation with the homepage.
            guard let self, !isClosed, navigationTask == nil, activeWebDocumentURL == nil else { return }
            startInitialNavigation()
        }
    }

    private func startInitialNavigation() {
        if let committedURL, let cached = cachedPage(for: committedURL) {
            displayCachedPage(cached)
            return
        }

        // Restoring a tab is NOT a new navigation. Falling through to submitLocation()
        // committed with .new, and commit(.new) truncates the forward branch — so a
        // session saved mid-history lost every entry ahead of the cursor before the
        // user touched anything. Re-fetch as a traversal, which leaves history alone.
        if let committedURL, !navigation.isEmpty {
            if let page = InternalPage.page(for: committedURL) {
                showInternalPage(page, disposition: .traversal)
            } else if committedURL.isFileURL {
                openFile(committedURL, disposition: .traversal)
            } else if let target = makeTarget(for: committedURL) {
                navigate(to: target, disposition: .traversal)
            } else {
                submitLocation()
            }
            return
        }

        submitLocation()
    }

    public func submitLocation() {
        guard !isClosed else { return }
        validationMessage = nil
        do {
            let preferences = services.preferences()
            let interpreter = AddressInputInterpreter(searchEndpoint:
                preferences.searchProvider.endpoint(customEndpoint: preferences.customSearchEndpoint)
            )
            switch try interpreter.interpret(locationText) {
            case .gemini(let target):
                navigate(to: target, disposition: .new)
            case .viewSource(let target):
                navigate(to: target, disposition: .new, renderAsSource: true)
            case .internalPage(let page):
                showInternalPage(page)
            case .external(let url):
                openLink(url)
            }
        } catch AddressInputError.empty {
            validationMessage = "Enter a capsule address or search query."
        } catch AddressInputError.invalidGeminiURL {
            validationMessage = "That is not a valid Gemini address."
        } catch {
            validationMessage = "That address could not be opened."
        }
    }

    public func searchLocation(_ query: String) {
        let preferences = services.preferences()
        let endpoint = preferences.searchProvider.endpoint(customEndpoint: preferences.customSearchEndpoint)
        guard let url = GeminiQueryEncoding.url(base: endpoint, query: query),
              let target = try? GeminiRequestTarget(url.absoluteString) else {
            validationMessage = "The search endpoint is not a valid Gemini address."
            return
        }
        validationMessage = nil
        navigate(to: target, disposition: .new)
    }

    public func reload() {
        guard !isClosed else { return }
        if let internalPage {
            showInternalPage(internalPage, disposition: .reload)
            return
        }
        if let committedURL, ViewSourceURL.isViewSource(committedURL) {
            if let cached = cachedPage(for: committedURL) {
                displayCachedPage(cached)
                recordSuccessfulVisit(
                    committedURL,
                    title: cached.title ?? cached.documentTitle,
                    disposition: .reload
                )
                return
            }
            // No cached bytes, e.g. a session restored after the cache was cleared:
            // fetch the resource again and re-present it as source.
            if let resource = ViewSourceURL.unwrap(committedURL),
               let target = try? GeminiRequestTarget(resource.absoluteString) {
                navigate(to: target, disposition: .reload, renderAsSource: true)
            }
            return
        }
        if let committedURL, committedURL.isFileURL {
            openFile(committedURL, disposition: .reload)
            return
        }
        if let committedURL, InlineDataImagePayload.decode(committedURL.absoluteString) != nil {
            openDataImage(committedURL, disposition: .reload)
            return
        }
        guard let committedURL, let target = makeTarget(for: committedURL) else { return }
        navigate(to: target, disposition: .reload)
    }

    private func beginNavigation(
        disposition: HistoryDisposition,
        keepsFavicon: Bool = false
    ) {
        if case .traversal = disposition {
            // The caller moved the cursor only after persisting the page being left.
        } else {
            backForwardDebounceTask?.cancel()
            navigation.updateCurrentMetadata(title: documentTitle ?? title, favicon: favicon)
            persistCurrentBackForwardEntry()
        }
        abandonScrollRestoration(for: disposition)
        currentResponseCanBeCached = true

        navigationTask?.cancel()
        navigationTask = nil
        faviconTask?.cancel()
        faviconTask = nil
        imageTasks.values.forEach { $0.cancel() }
        imageTasks.removeAll()
        automaticImagesPaused = false
        imagePageStartedAt = .now
        slowDownTask?.cancel()
        slowDownTask = nil
        documentContinuation?.finish()
        documentContinuation = nil
        streamingBody = nil
        documentBuffer.removeAll(keepingCapacity: false)
        activeWebDocumentURL = nil
        presentation.invalidateDocument()

        inputPrompt = nil
        inputValidationMessage = nil
        clientCertificatePrompt = nil
        pendingClientCertificateChallenge = nil

        retryNotBefore = nil
        validationMessage = nil
        internalPage = nil
        // The document is going away, so its hover state is stale.
        updateHoveredLink(nil)
        if !keepsFavicon { favicon = nil }
        isLoading = false
    }

    public func openFile(_ url: URL, disposition: HistoryDisposition = .new) {
        guard !isClosed else { return }
        guard url.isFileURL else { return }
        beginNavigation(disposition: disposition)

        let mimeType = Self.mimeType(forPathExtension: url.pathExtension)

        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            showGeneratedPage(
                title: "Could Not Open File",
                message: "Major Tom could not read this file: \(error.localizedDescription)",
                details: url.path,
                url: url,
                disposition: disposition
            )
            return
        }

        guard mimeType.hasPrefix("text/") || mimeType.hasPrefix("image/") else {
            showGeneratedPage(
                title: "Unsupported File",
                message: "Major Tom cannot display this file type. No file was written.",
                details: "\(url.lastPathComponent)\n\(data.count) bytes",
                url: url,
                disposition: disposition
            )
            return
        }

        currentSourceBytes = data
        currentMIMEType = mimeType
        canSavePage = !data.isEmpty
        canShowSource = mimeType.hasPrefix("text/")

        // commit() first: it sets committedURL, which renderCurrentContent() reads, and
        // resets the title so an opening heading or preformatted caption can claim it.
        commit(url, disposition: disposition)
        renderCurrentContent()

        cache(CachedPage(
            url: url,
            mimeType: mimeType,
            body: data,
            completion: .complete,
            receivedAt: Date(),
            title: title,
            documentTitle: documentTitle
        ))
        recordSuccessfulVisit(url, title: documentTitle ?? title, disposition: disposition)
        statusText = "Local file • \(data.count) bytes"
    }

    public static func mimeType(forPathExtension pathExtension: String) -> String {
        switch pathExtension.lowercased() {
        case "gmi", "gemini": return "text/gemini"
        case "txt", "text", "md", "markdown", "log": return "text/plain"
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "heic": return "image/heic"
        default: return "application/octet-stream"
        }
    }

    public func stop() {
        let wasLoading = isLoading
        let stoppedImages = Array(imageTasks.keys)
        let documentURL = activeWebDocumentURL
        automaticImagesPaused = true
        // A document continuation only exists while a response is actively streaming
        // into the view, which is what distinguishes "stopped partway" from "stopped
        // before anything committed".
        let wasStreamingIntoDocument = documentContinuation != nil

        // Cancellation is unconditional: stop() is also how closing a tab releases its
        // work, and spec 9.2 requires that to cancel the network work it owns.
        navigationTask?.cancel()
        navigationTask = nil
        faviconTask?.cancel()
        faviconTask = nil
        imageTasks.values.forEach { $0.cancel() }
        imageTasks.removeAll()
        expandedInlineImages.subtract(stoppedImages)
        for identifier in stoppedImages {
            if let url = inlineImageURLs[identifier] { navigation.setImage(url, expanded: false) }
        }
        pendingRestoredInlineImageCount = 0
        pendingInlineImageScrollCorrection = nil
        if !stoppedImages.isEmpty { scheduleBackForwardPersistence() }
        if let documentURL {
            Task {
                guard activeWebDocumentURL == documentURL else { return }
                await presentation.updateDocument(.stopImages(stoppedImages), at: documentURL)
            }
        }
        slowDownTask?.cancel()
        slowDownTask = nil
        clientCertificatePrompt = nil
        pendingClientCertificateChallenge = nil

        // Stopping an idle page must not touch it. This previously rewrote the cache
        // entry of a fully loaded page as .stopped and dropped its title.
        guard wasLoading else { return }

        if let committedURL { finishStreamingBody(at: committedURL) }
        finishCurrentDocument(message: "Loading was stopped.")
        if wasStreamingIntoDocument, let committedURL, !currentSourceBytes.isEmpty {
            cache(CachedPage(
                url: committedURL,
                mimeType: currentMIMEType,
                body: currentSourceBytes,
                completion: .stopped,
                receivedAt: Date(),
                title: title,
                documentTitle: documentTitle,
                responseStatus: responseStatus,
                responseMeta: responseMeta,
                clientCertificateID: usedClientCertificate?.id
            ))
        }
        isLoading = false
        statusText = "Stopped"
        if let committedURL { locationText = committedURL.absoluteString }
    }

    public func cancelAndDrainRequests() async {
        let navigation = navigationTask
        let images = Array(imageTasks.values)
        let favicon = faviconTask
        let slowDown = slowDownTask
        stop()
        await navigation?.value
        for image in images { await image.value }
        await favicon?.value
        await slowDown?.value
        await requestLifetime.drain()
    }

    /// Closing is permanent, unlike Stop. Capture accepted requests before Stop
    /// releases their handles, then drain persistence after their final state.
    @discardableResult
    public func close() -> Task<Void, Never> {
        if let closingTask { return closingTask }
        isClosed = true
        let requests = [navigationTask, faviconTask, slowDownTask].compactMap { $0 } + Array(imageTasks.values)
        stop()
        cancelHistoryPreview()
        activeWebDocumentURL = nil
        presentation.invalidateDocument()
        let task = Task {
            await requestLifetime.closeAndDrain()
            for request in requests { await request.value }
            await flushBackForwardPersistence()
        }
        closingTask = task
        return task
    }

    public func goBack() {
        browserNavigationLogger.notice(
            "goBack requested modelIndex=\(self.navigation.historyIndex) canBack=\(self.navigation.canGoBack) current=\(self.committedURL?.absoluteString ?? "nil", privacy: .public)"
        )
        guard let entry = navigation.backHistoryEntries.first else { return }
        go(toHistoryEntryWithID: entry.id)
    }

    public func goForward() {
        browserNavigationLogger.notice(
            "goForward requested modelIndex=\(self.navigation.historyIndex) canForward=\(self.navigation.canGoForward) current=\(self.committedURL?.absoluteString ?? "nil", privacy: .public)"
        )
        guard let entry = navigation.forwardHistoryEntries.first else { return }
        go(toHistoryEntryWithID: entry.id)
    }

    public func go(toHistoryEntryWithID id: BackForwardEntry.ID) {
        guard !isClosed else { return }
        browserNavigationLogger.notice(
            "model traversal begin targetID=\(id.uuidString, privacy: .public) fromIndex=\(self.navigation.historyIndex)"
        )
        backForwardDebounceTask?.cancel()
        persistCurrentBackForwardEntry()
        guard let url = navigation.go(toHistoryEntryWithID: id) else {
            browserNavigationLogger.error("model traversal rejected targetID=\(id.uuidString, privacy: .public)")
            return
        }
        browserNavigationLogger.notice(
            "model cursor moved index=\(self.navigation.historyIndex) url=\(url.absoluteString, privacy: .public)"
        )
        // A navigation still waiting for its response is abandoned by this traversal.
        // Cancel it now rather than when the destination is displayed: reading the
        // destination from the durable store takes a moment, and a response arriving in
        // that gap used to commit as a new page from the destination entry, discarding
        // the history ahead of it.
        navigationTask?.cancel()
        navigationTask = nil
        faviconTask?.cancel()
        faviconTask = nil
        prepareScrollRestoration(for: navigation.historyIndex)
        updateNavigationAvailability()
        navigateHistory(to: url)
    }

    public func recordScrollPosition(_ offset: Double, from documentURL: URL?) {
        guard documentURL == activeWebDocumentURL,
              pendingScrollRestoration?.historyIndex != navigation.historyIndex else { return }
        navigation.recordScrollOffset(offset)
        scheduleBackForwardPersistence()
    }

    public func recordPreformattedState(index: Int, collapsed: Bool, from documentURL: URL?) {
        guard documentURL == activeWebDocumentURL else { return }
        navigation.setPreformattedSection(index, collapsed: collapsed)
        scheduleBackForwardPersistence()
    }

    public func flushBackForwardPersistence() async {
        backForwardDebounceTask?.cancel()
        backForwardDebounceTask = nil
        persistCurrentBackForwardEntry()
        await backForwardWriteTask?.value
    }

    public func prepareForClearing(_ action: BrowsingDataAction, since cutoff: Date?) {
        browsingDataGeneration &+= 1
        if action == .clearBrowsingData, let prompt = inputPrompt {
            discardedDraftPrompts.insert(prompt.id)
            inputPrompt = nil
            inputValidationMessage = nil
        }
        // Stop pre-clear network work without replacing the document being read.
        stop()
        cancelHistoryPreview()
        presentation.discardHistoryPreview()
        backForwardDebounceTask?.cancel()
        backForwardDebounceTask = nil
        isClearingBrowsingData = true
        currentResponseCanBeCached = false
        navigation.recordCurrentAccess()
        navigation.clearBrowsingData(action, since: cutoff)
        favicon = navigation.currentEntry?.favicon
        pendingScrollRestoration = nil
        pendingInlineImageScrollCorrection = nil
        pendingRestoredInlineImageCount = 0
        isRestoringHistoryScroll = false
        updateNavigationAvailability()
    }

    public func drainWritesForClearing() async {
        await backForwardWriteTask?.value
    }

    public func finishClearing() {
        isClearingBrowsingData = false
    }

    private func prepareScrollRestoration(for index: Int) {
        let offset = navigation.scrollOffset(forHistoryIndex: index)
        pendingScrollRestoration = (
            historyIndex: index,
            offset: offset
        )
        isRestoringHistoryScroll = navigation.presentationState(forHistoryIndex: index)
            .map(Self.needsPresentationRestoration) ?? false
        pendingRestoredInlineImageCount = 0
        pendingInlineImageScrollCorrection = nil
    }

    public func goHome() {
        locationText = services.preferences().homepage
        submitLocation()
    }

    public func goToCapsuleRoot() {
        guard let committedURL,
              var components = URLComponents(url: committedURL, resolvingAgainstBaseURL: false) else { return }
        components.path = "/"
        components.query = nil
        components.fragment = nil
        guard let url = components.url,
              let target = try? GeminiRequestTarget(url.absoluteString) else { return }
        navigate(to: target, disposition: .new)
    }

    public func goUpOneLevel() {
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

    public func zoomIn() {
        pageZoom = min(3, pageZoom + 0.1)
        applyZoom()
    }

    public func zoomOut() {
        pageZoom = max(0.5, pageZoom - 0.1)
        applyZoom()
    }

    public func actualSize() {
        pageZoom = 1
        applyZoom()
    }

    public func showPageSource() {
        guard !isClosed else { return }
        guard canShowSource,
              let resourceURL = committedURL,
              !ViewSourceURL.isViewSource(resourceURL) else { return }
        // A navigation that has not committed yet is abandoned in favour of the source
        // view. Cancel it here: `presentSource` clears `navigationTask` without
        // cancelling it, which used to leave that request running with Stop unavailable
        // until its response arrived and replaced the source view.
        navigationTask?.cancel()
        navigationTask = nil
        faviconTask?.cancel()
        faviconTask = nil
        presentSource(
            currentSourceBytes,
            of: resourceURL,
            mimeType: currentMIMEType,
            disposition: .new,
            responseMetadata: displayedResponseMetadata,
            receivedAt: responseReceivedAt ?? Date()
        )
    }

    private func presentSource(
        _ bytes: Data,
        of resourceURL: URL,
        mimeType: String,
        disposition: HistoryDisposition,
        responseMetadata: BrowserResponseMetadata? = nil,
        receivedAt: Date = Date()
    ) {
        guard let sourceURL = ViewSourceURL.wrap(resourceURL) else { return }
        abandonScrollRestoration(for: disposition)
        renderSourceDocument(bytes, at: sourceURL, mimeType: mimeType)
        let heading = "Source: \(displayTitle(for: resourceURL))"
        // commit() resets the title, so the heading is applied after it.
        commit(sourceURL, disposition: disposition, responseMetadata: responseMetadata)
        cache(CachedPage(
            url: sourceURL,
            mimeType: mimeType,
            body: bytes,
            completion: .complete,
            receivedAt: receivedAt,
            title: heading,
            responseStatus: responseStatus,
            responseMeta: responseMeta,
            clientCertificateID: usedClientCertificate?.id
        ))
        currentSourceBytes = bytes
        currentMIMEType = mimeType
        canSavePage = !bytes.isEmpty
        canShowSource = false
        title = heading
        recordSuccessfulVisit(sourceURL, title: heading, disposition: disposition)
        statusText = "Page source"
        isLoading = false
        navigationTask = nil
    }

    private func renderSourceDocument(_ bytes: Data, at sourceURL: URL, mimeType: String) {
        renderResponse(bytes, mimeType: mimeType, at: sourceURL)
    }

    public func updateHoveredLink(_ href: String?, modifiers: LinkModifierKeys = []) {
        guard let href, !href.isEmpty else {
            hoveredLinkDestination = nil
            hoveredLinkURL = nil
            return
        }
        hoveredLinkDestination = href
        hoveredLinkURL = LinkHoverText.text(for: href, modifiers: modifiers)
    }

    public func showInternalPage(_ page: InternalPage, disposition: HistoryDisposition = .new) {
        guard !isClosed else { return }
        beginNavigation(disposition: disposition)

        currentSourceBytes = Data()
        currentMIMEType = ""
        canSavePage = false
        canShowSource = false
        internalPage = page

        // Internal pages use native SwiftUI views, not the WebKit document whose scroll
        // reporter drives this state. A traversal to one therefore has nothing to
        // restore, which `beginNavigation` cannot assume for the other entry points.
        pendingScrollRestoration = nil
        isRestoringHistoryScroll = false

        commit(page.url, disposition: disposition)
        title = page.title
        statusText = page.title
    }

    public func cancelClientCertificatePrompt(id: UUID) {
        guard clientCertificatePrompt?.id == id else { return }
        clientCertificatePrompt = nil
        pendingClientCertificateChallenge = nil
        isLoading = false
        statusText = "Client identity not selected"
        if let committedURL { locationText = committedURL.absoluteString }
    }

    public func cancelInput(draft: String = "", for promptID: UUID) {
        guard inputPrompt?.id == promptID else { return }
        if let prompt = inputPrompt, !prompt.isSensitive {
            services.saveInputDraft(draft, prompt.target.url)
        }
        inputPrompt = nil
        inputValidationMessage = nil
        isLoading = false
        statusText = "Input cancelled"
        if let committedURL { locationText = committedURL.absoluteString }
    }

    public func preserveInputDraft(_ draft: String, for prompt: InputPrompt) {
        guard !discardedDraftPrompts.contains(prompt.id) else { return }
        services.saveInputDraft(draft, prompt.target.url)
    }

    public func submitInput(_ value: String, for promptID: UUID) {
        guard !isClosed else { return }
        guard let prompt = inputPrompt, prompt.id == promptID else { return }
        guard let url = GeminiQueryEncoding.url(base: prompt.target.url, query: value),
              let target = try? GeminiRequestTarget(url.absoluteString) else {
            inputValidationMessage = "This response is too large for a Gemini request. Shorten it and try again."
            return
        }
        services.removeInputDraft(prompt.target.url)
        inputValidationMessage = nil
        inputPrompt = nil
        navigate(to: target, disposition: .new)
    }

    private func navigateHistory(to url: URL) {
        browserNavigationLogger.notice(
            "navigateHistory url=\(url.absoluteString, privacy: .public) index=\(self.navigation.historyIndex) hotCache=\(self.cachedPage(for: url) != nil)"
        )
        if let page = InternalPage.page(for: url) {
            browserNavigationLogger.notice("navigateHistory route=internal")
            showInternalPage(page, disposition: .traversal)
            return
        }
        if let cached = cachedPage(for: url) {
            browserNavigationLogger.notice("navigateHistory route=hot-cache bytes=\(cached.body.count)")
            displayCachedPage(cached)
            return
        }
        if let entryID = navigation.currentEntryID, let backForwardCache {
            browserNavigationLogger.notice("navigateHistory route=durable-cache id=\(entryID.uuidString, privacy: .public)")
            let generation = browsingDataGeneration
            Task { [weak self] in
                let stored = try? await backForwardCache.entry(id: entryID)
                guard let self, self.browsingDataGeneration == generation,
                      self.navigation.currentEntryID == entryID else { return }
                if let page = stored?.page {
                    browserNavigationLogger.notice("durable-cache hit id=\(entryID.uuidString, privacy: .public) bytes=\(page.body.count)")
                    self.navigation.cache(page, for: entryID)
                    self.title = stored?.title ?? page.title ?? self.displayTitle(for: url)
                    self.favicon = stored?.favicon
                    self.displayCachedPage(page)
                } else {
                    browserNavigationLogger.notice("durable-cache miss id=\(entryID.uuidString, privacy: .public); reloading")
                    self.navigateHistoryWithoutCache(to: url)
                }
            }
            return
        }
        navigateHistoryWithoutCache(to: url)
    }

    private func navigateHistoryWithoutCache(to url: URL) {
        if url.isFileURL {
            openFile(url, disposition: .traversal)
            return
        }
        if InlineDataImagePayload.decode(url.absoluteString) != nil {
            openDataImage(url, disposition: .traversal)
            return
        }
        // A view-source entry whose cached bytes are gone. makeTarget cannot build a
        // request for the view-source scheme, so without this the entry would be
        // unreachable and Back would appear to do nothing.
        if let resource = ViewSourceURL.unwrap(url),
           let target = try? GeminiRequestTarget(resource.absoluteString) {
            navigate(to: target, disposition: .traversal, renderAsSource: true)
            return
        }
        guard let target = makeTarget(for: url) else { return }
        navigate(to: target, disposition: .traversal)
    }

    public func navigate(
        to target: GeminiRequestTarget,
        disposition: HistoryDisposition,
        renderAsSource: Bool = false
    ) {
        guard !isClosed else { return }
        // Keep the glyph while moving within one capsule, so it does not flicker
        // between pages of the same site.
        let staysWithinCapsule = CapsuleEndpoint(url: target.url)
            == committedURL.flatMap(CapsuleEndpoint.init(url:))
        beginNavigation(disposition: disposition, keepsFavicon: staysWithinCapsule)

        isLoading = true
        statusText = "Connecting to \(target.endpoint.host)…"
        locationText = target.url.absoluteString

        navigationTask = Task { [weak self] in
            guard let self, !isClosed, !Task.isCancelled else { return }
            try? await requestLifetime.perform {
                await load(target: target, disposition: disposition, renderAsSource: renderAsSource,
                    bypassesContentCache: disposition == .reload)
            }
        }
    }

    private func load(
        target initialTarget: GeminiRequestTarget,
        disposition: HistoryDisposition,
        renderAsSource: Bool = false,
        bypassesContentCache: Bool = false
    ) async {
        await services.preparePresentation()
        guard !Task.isCancelled else { return }
        var target = initialTarget
        var responseHeader: GeminiResponseHeader?
        var responseMetadata: BrowserResponseMetadata?
        var presentedIdentity: PresentedServerIdentity?
        var mimeType = ""
        var sourceBytes = Data()
        var bodyKind = BrowserContentKind.unsupported
        var contentStarted = false

        var sentClientCertificate: ClientCertificateDescriptor?
        var responseIsCached = false
        var receivedAt = Date()
        let events = services.retriever.events(
            for: target,
            proxy: services.preferences().proxy,
            bypassesCache: bypassesContentCache
        )

        do {
            for await event in events {
                try Task.checkCancellation()
                switch event {
                case .connecting:
                    statusText = "Connecting securely…"
                case .serverIdentity(let identity):
                    presentedIdentity = identity
                    statusText = "Verifying capsule identity…"
                case .redirect(let next):
                    presentedIdentity = nil
                    target = next
                    locationText = next.url.absoluteString
                case .loadingCachedResponse:
                    statusText = "Loading cached response…"
                case .response(let response):
                    target = response.target
                    let header = response.header
                    responseHeader = header
                    sentClientCertificate = response.offeredCertificate
                    responseIsCached = response.origin == .cache
                    receivedAt = response.receivedAt
                    responseMetadata = BrowserResponseMetadata(status: header.status, meta: header.meta,
                        wasCached: responseIsCached, receivedAt: receivedAt,
                        serverIdentity: responseIsCached ? nil : presentedIdentity,
                        clientCertificate: responseIsCached ? nil : sentClientCertificate)
                    statusText = "Response \(header.status)"

                    if header.isInput {
                        let isSensitive = header.status == 11
                        inputPrompt = InputPrompt(
                            target: target,
                            message: header.meta,
                            isSensitive: isSensitive,
                            initialText: isSensitive
                                ? ""
                                : services.inputDraft(target.url)
                        )
                        isLoading = false
                        statusText = "Input required"
                        return
                    }

                    if header.requiresClientCertificate {
                        guard target.url.scheme?.lowercased() == "gemini",
                              CapsuleEndpoint(url: target.url) == target.endpoint else {
                            showGeneratedPage(
                                title: "Proxy Requires an Identity",
                                message: "Major Tom does not send client certificates to Gemini proxies.",
                                details: header.meta, url: target.url, disposition: disposition, responseMetadata: responseMetadata
                            )
                            return
                        }
                        pendingClientCertificateChallenge = (
                            target: target,
                            disposition: disposition,
                            renderAsSource: renderAsSource
                        )
                        clientCertificatePrompt = ClientCertificatePrompt(
                            target: target,
                            status: header.status,
                            message: header.meta,
                            attemptedCertificate: sentClientCertificate,
                            matchingCertificateIsUnavailable:
                                response.matchedCertificate?.isValid() == true
                                    && response.offeredCertificate == nil,
                            matchingCertificateIsInvalid:
                                response.matchedCertificate?.isValid() == false
                        )
                        isLoading = false
                        statusText = header.status == 60
                            ? "Client identity required"
                            : "Client identity rejected"
                        return
                    }

                    if header.isTemporaryFailure || header.isPermanentFailure {
                        // 43 and 53 are the proxy-specific failures. Reported generically
                        // they read as "the capsule is broken", when in fact the proxy
                        // is misconfigured or unwilling — a very different fix.
                        let isProxied = target.url.scheme?.lowercased() != "gemini"
                        var title = header.isTemporaryFailure
                            ? "Temporary Capsule Failure"
                            : header.isPermanentFailure
                                ? "Permanent Capsule Failure"
                                : "Capsule Failure"
                        var message = header.meta
                        if header.status == 43 {
                            title = "Proxy Error"
                            message = header.meta.isEmpty
                                ? "The proxy could not fetch this resource from the remote host."
                                : header.meta
                        } else if header.status == 53 {
                            title = "Proxy Request Refused"
                            message = isProxied
                                ? "The configured proxy will not serve this URL. Check the proxy address in Settings ▸ Networking, and that it is a Gemini proxy willing to fetch \(target.url.scheme ?? "this scheme")."
                                : "That capsule does not serve this address and will not proxy the request."
                        }
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
                            disposition: disposition, responseMetadata: responseMetadata,
                            archiveURL: DeloreanArchive.isWorthOffering(status: header.status)
                                ? DeloreanArchive.captures(of: target.url)
                                : nil
                        )
                        return
                    }

                    guard header.isSuccess else {
                        showGeneratedPage(
                            title: "Unsupported Response",
                            message: "The capsule returned an unsupported Gemini response.",
                            details: "Status \(header.status): \(header.meta)",
                            url: target.url,
                            disposition: disposition, responseMetadata: responseMetadata
                        )
                        return
                    }

                    mimeType = response.mimeType
                    bodyKind = BrowserContentKind(mimeType: mimeType, url: target.url, showsSource: renderAsSource)
                    if renderAsSource {
                        // No document is begun and nothing is committed yet: the source
                        // view needs the complete text, so a fetch that fails partway
                        // leaves the page currently on screen untouched.
                        statusText = "Receiving source\u{2026}"
                    } else if bodyKind.streamsText {
                        currentSourceBytes = Data()
                        currentMIMEType = mimeType
                        currentCompletion = .complete
                        canSavePage = false
                        canShowSource = false
                        let continuation = beginDocument(at: target.url)
                        streamingBody = BrowserResponseBody(kind: bodyKind)
                        documentContinuation = continuation
                        continuation.yield(documentRenderer.start(kind: bodyKind, at: target.url))
                        commit(target.url, disposition: disposition, responseMetadata: responseMetadata)
                        contentStarted = true
                        statusText = "Receiving \(mimeType)…"
                    }

                case .body(let data):
                    guard let header = responseHeader, header.isSuccess else { continue }
                    sourceBytes.append(data)
                    // Buffered image, binary and source responses have not replaced
                    // the displayed visit. Save/Source still belong to that visit.
                    if contentStarted { currentSourceBytes = sourceBytes }
                    // Source view renders once, from the finished bytes.
                    guard !renderAsSource else { continue }
                    emit(streamingBody?.receive(data) ?? [], baseURL: target.url)
                    flushDocument()

                case .finished(let result):
                    switch result {
                    case .cancelled: return
                    case .trustDeclined: throw GeminiTransportError.trustDeclined
                    case .failed(let error, _): throw error
                    case .completed: break
                    }
                    guard let header = responseHeader, header.isSuccess else { return }
                    var displayedSuccessfulContent = false
                    if renderAsSource {
                        guard mimeType.hasPrefix("text/") else {
                            showGeneratedPage(
                                title: "Source Not Available",
                                message: "Major Tom can only show the source of a text response.",
                                details: "\(mimeType.isEmpty ? header.meta : mimeType)\n\(sourceBytes.count) bytes",
                                url: target.url,
                                disposition: disposition, responseMetadata: responseMetadata
                            )
                            return
                        }
                        presentSource(
                            sourceBytes,
                            of: target.url,
                            mimeType: mimeType,
                            disposition: disposition, responseMetadata: responseMetadata,
                            receivedAt: receivedAt
                        )
                        return
                    }
                    if bodyKind.streamsText {
                        displayedSuccessfulContent = true
                        finishStreamingBody(at: target.url)
                        finishCurrentDocument()
                    } else if bodyKind == .image {
                        displayedSuccessfulContent = true
                        showImagePage(data: sourceBytes, mimeType: mimeType, url: target.url, disposition: disposition, responseMetadata: responseMetadata)
                    } else {
                        showGeneratedPage(
                            title: "Unsupported Content",
                            message: "Major Tom cannot display this response type yet. No file was downloaded.",
                            details: "\(mimeType.isEmpty ? header.meta : mimeType)\n\(sourceBytes.count) bytes",
                            url: target.url,
                            disposition: disposition, responseMetadata: responseMetadata
                        )
                    }
                    isLoading = false
                    currentSourceBytes = sourceBytes
                    currentMIMEType = mimeType
                    canSavePage = true
                    canShowSource = mimeType.hasPrefix("text/")
                    cache(CachedPage(
                        url: target.url,
                        mimeType: mimeType,
                        body: sourceBytes,
                        completion: .complete,
                        receivedAt: receivedAt,
                        title: title,
                        documentTitle: documentTitle,
                        responseStatus: header.status,
                        responseMeta: header.meta,
                        clientCertificateID: sentClientCertificate?.id
                    ))
                    if displayedSuccessfulContent {
                        recordSuccessfulVisit(
                            target.url,
                            title: documentTitle ?? title,
                            disposition: disposition
                        )
                    }
                    statusText = responseIsCached
                        ? "Cached • \(sourceBytes.count) bytes"
                        : "Loaded \(sourceBytes.count) bytes"
                    // Only now, once the reader has actually landed on this capsule: the
                    // RFC forbids probing for a favicon any earlier.
                    scheduleFaviconRefresh(for: target.url)
                    navigationTask = nil
                    return
                }
            }
        } catch let error as GeminiRetrievalRedirectError {
            guard !Task.isCancelled else { return }
            switch error {
            case .loop(let url), .limit(let url):
                showGeneratedPage(
                    title: "Too Many Redirects",
                    message: "Major Tom stopped this navigation because the capsule redirected in a loop.",
                    details: url.absoluteString, url: url, disposition: disposition, responseMetadata: responseMetadata
                )
            case .invalid(let source, let meta):
                showGeneratedPage(
                    title: "Invalid Redirect",
                    message: "The capsule returned a redirect that Major Tom could not understand.",
                    details: meta, url: source, disposition: disposition, responseMetadata: responseMetadata
                )
            }
        } catch is CancellationError {
            return
        } catch GeminiTransportError.trustDeclined {
            // The reader refused this capsule's identity, so the navigation was
            // cancelled rather than failed. Leave the page that is on screen alone and
            // say so in the status area; an error page here would read as though
            // something had gone wrong.
            isLoading = false
            statusText = "Connection cancelled"
            if let committedURL { locationText = committedURL.absoluteString }
            return
        } catch {
            guard !Task.isCancelled else { return }
            if contentStarted {
                finishStreamingBody(at: target.url)
                finishCurrentDocument(message: "The connection ended before the response completed: \(friendly(error))")
                currentSourceBytes = sourceBytes
                currentMIMEType = mimeType
                canSavePage = !sourceBytes.isEmpty
                canShowSource = mimeType.hasPrefix("text/") && !sourceBytes.isEmpty
                if let committedURL {
                    cache(CachedPage(
                        url: committedURL,
                        mimeType: mimeType,
                        body: sourceBytes,
                        completion: .incomplete,
                        receivedAt: Date(),
                        responseStatus: responseHeader?.status,
                        responseMeta: responseHeader?.meta,
                        clientCertificateID: usedClientCertificate?.id
                    ))
                }
                isLoading = false
                statusText = "Incomplete response"
            } else {
                showGeneratedPage(
                    title: "Could Not Open Capsule",
                    message: friendly(error),
                    details: target.url.absoluteString,
                    url: target.url,
                    disposition: disposition, responseMetadata: responseMetadata,
                    archiveURL: offersArchive(after: error)
                        ? DeloreanArchive.captures(of: target.url)
                        : nil
                )
            }
        }
    }

    private func makeTarget(for url: URL) -> GeminiRequestTarget? {
        GeminiRequestTarget.navigationTarget(for: url, proxy: services.preferences().proxy)
    }

    public func canOpenInApp(_ url: URL) -> Bool {
        url.isFileURL
            || makeTarget(for: url) != nil
            || InlineDataImagePayload.decode(url.absoluteString) != nil
    }

    public func openLink(_ url: URL) {
        guard !isClosed else { return }
        if url.scheme?.lowercased() == "gemini",
           let target = try? GeminiRequestTarget(url.absoluteString) {
            navigate(to: target, disposition: .new)
        } else if url.isFileURL {
            // Relative links inside a local document resolve to file URLs.
            openFile(url)
        } else if InlineDataImagePayload.decode(url.absoluteString) != nil {
            openDataImage(url)
        } else {
            openExternalURL(url)
        }
    }

    private func openDataImage(
        _ url: URL,
        disposition: HistoryDisposition = .new
    ) {
        guard let decoded = InlineDataImagePayload.decode(url.absoluteString) else { return }
        beginNavigation(disposition: disposition)

        currentSourceBytes = decoded.data
        currentMIMEType = decoded.mimeType
        canSavePage = true
        canShowSource = false
        showImagePage(
            data: decoded.data,
            mimeType: decoded.mimeType,
            url: url,
            disposition: disposition
        )
        recordSuccessfulVisit(url, title: title, disposition: disposition)
        statusText = "Inline image • \(formattedByteCount(decoded.data.count))"
    }

    private func openExternalURL(_ url: URL) {
        let scheme = url.scheme?.lowercased() ?? ""

        // With a Gemini proxy configured, http/https stay inside Major Tom: the proxy
        // fetches the page and returns Gemtext. Without one they go to the default
        // browser as before.
        if ["http", "https"].contains(scheme), let target = makeTarget(for: url) {
            navigate(to: target, disposition: .new)
            return
        }

        let permitted = ["http", "https", "mailto"]
        guard permitted.contains(scheme) else {
            validationMessage = "Major Tom does not permit the \(url.scheme ?? "unknown") URL scheme."
            return
        }
        services.openExternalURL(url)
    }

    private func abandonScrollRestoration(for disposition: HistoryDisposition) {
        guard case .new = disposition else { return }
        pendingScrollRestoration = nil
        pendingRestoredInlineImageCount = 0
        pendingInlineImageScrollCorrection = nil
        isRestoringHistoryScroll = false
    }

    private func yieldToDocument(_ data: Data) {
        guard documentContinuation != nil else { return }
        documentBuffer.append(data)
        if documentBuffer.count >= Self.documentFlushByteCount {
            flushDocument()
        }
    }

    private func flushDocument() {
        guard !documentBuffer.isEmpty else { return }
        documentContinuation?.yield(documentBuffer)
        documentBuffer.removeAll(keepingCapacity: true)
    }

    private func finishStreamingBody(at url: URL) {
        guard var body = streamingBody else { return }
        streamingBody = nil
        emit(body.finish(), baseURL: url)
    }

    private func finishCurrentDocument(message: String? = nil) {
        guard let continuation = documentContinuation else { return }
        flushDocument()
        continuation.yield(documentRenderer.finish(message: message))
        continuation.finish()
        documentContinuation = nil
        documentBuffer.removeAll(keepingCapacity: false)
    }

    private func showGeneratedPage(
        title: String,
        message: String,
        details: String,
        url: URL,
        disposition: HistoryDisposition,
        responseMetadata: BrowserResponseMetadata? = nil,
        archiveURL: URL? = nil
    ) {
        currentCompletion = .complete
        let continuation = beginDocument(at: url)
        continuation.yield(documentRenderer.message(title: title, message: message, details: details,
            at: url, archiveURL: archiveURL, preferences: services.preferences()))
        continuation.finish()
        commit(url, disposition: disposition, responseMetadata: responseMetadata)
        currentSourceBytes = Data()
        currentMIMEType = ""
        canSavePage = false
        canShowSource = false
        isLoading = false
        statusText = title
        navigationTask = nil
    }

    private func showImagePage(data: Data, mimeType: String, url: URL, disposition: HistoryDisposition,
                               responseMetadata: BrowserResponseMetadata? = nil) {
        renderResponse(data, mimeType: mimeType, at: url)
        commit(url, disposition: disposition, responseMetadata: responseMetadata)
    }

    private func commit(_ url: URL, disposition: HistoryDisposition, responseMetadata: BrowserResponseMetadata? = nil) {
        applyResponseMetadata(responseMetadata)
        committedURL = url
        title = displayTitle(for: url)
        documentTitle = nil
        titleClaim = GemtextTitleClaim()
        locationText = url.absoluteString
        if case .new = disposition {
            // A new branch supersedes any Back/Forward restoration whose WebKit load
            // had not yet finished.
            pendingScrollRestoration = nil
            isRestoringHistoryScroll = false
        }
        navigation.commit(url, disposition: NavigationState.Disposition(disposition))
        updateNavigationAvailability()
    }

    private func recordSuccessfulVisit(
        _ url: URL,
        title: String?,
        disposition: HistoryDisposition
    ) {
        guard disposition != .traversal, InternalPage.page(for: url) == nil else { return }
        services.recordVisit(url, title)
    }

    private func updateNavigationAvailability() {
        canGoBack = navigation.canGoBack
        canGoForward = navigation.canGoForward
    }

    private func displayCachedPage(_ cached: CachedPage) {
        currentResponseCanBeCached = true
        navigation.recordCurrentAccess()
        browserNavigationLogger.notice(
            "displayCachedPage url=\(cached.url.absoluteString, privacy: .public) bytes=\(cached.body.count) modelIndex=\(self.navigation.historyIndex)"
        )
        navigationTask?.cancel()
        // Showing a retained page is a different visit from the one being left, so the
        // per-visit state that `beginNavigation` resets for a network load is reset here
        // too. Without this, pressing Stop once left automatic image loading paused on
        // every page reached by Back or Forward, and a "slow down" answer on one page
        // kept Reload disabled on the next.
        automaticImagesPaused = false
        slowDownTask?.cancel()
        slowDownTask = nil
        retryNotBefore = nil
        if pendingScrollRestoration == nil, navigation.currentEntry != nil {
            pendingScrollRestoration = (
                historyIndex: navigation.historyIndex,
                offset: navigation.scrollOffset
            )
            isRestoringHistoryScroll = (navigation.currentEntry?.presentation)
                .map(Self.needsPresentationRestoration) ?? false
        }
        internalPage = nil
        isLoading = false
        // A restored/cached page has no live TLS connection. Leaving the previous
        // identity here would make Page Info describe a different page's certificate.
        serverIdentity = nil
        usedClientCertificate = cached.clientCertificateID.flatMap(services.certificateDescriptor)
        committedURL = cached.url
        locationText = cached.url.absoluteString
        currentSourceBytes = cached.body
        currentMIMEType = cached.mimeType
        currentCompletion = cached.completion
        // Successful body-bearing cache entries from older releases predate persisted
        // headers. Gemini defines 20 as the ordinary success response, so retain useful
        // Page Info for those sessions while preserving exact 2x codes going forward.
        responseStatus = cached.responseStatus
            ?? (cached.url.scheme?.lowercased() == "gemini" ? 20 : nil)
        responseMeta = cached.responseMeta ?? (responseStatus == nil ? "" : cached.mimeType)
        responseWasCached = true
        responseReceivedAt = cached.receivedAt
        title = cached.title ?? displayTitle(for: cached.url)
        documentTitle = cached.documentTitle
        // Re-rendering a cached page replays its events, so seed the claim with the
        // title already known or a fence caption could displace a real heading.
        titleClaim = GemtextTitleClaim(existingTitle: cached.documentTitle)
        canSavePage = !cached.body.isEmpty
        canShowSource = cached.mimeType.hasPrefix("text/") && !ViewSourceURL.isViewSource(cached.url)
        if ViewSourceURL.isViewSource(cached.url) {
            renderSourceDocument(cached.body, at: cached.url, mimeType: cached.mimeType)
        } else {
            renderCurrentContent()
        }
        applyZoom()
        statusText = cached.completion == .complete
            ? "Cached • \(cached.body.count) bytes"
            : "Cached \(cached.completion.rawValue) response"
        scheduleFaviconRefresh(for: cached.url)
    }

    private func cache(_ page: CachedPage) {
        currentCompletion = page.completion
        guard currentResponseCanBeCached, !isClearingBrowsingData else { return }
        if page.clientCertificateID == nil {
            navigation.cache(page)
        } else {
            navigation.removeCurrentCachedPage()
        }
        navigation.updateCurrentMetadata(title: page.documentTitle ?? page.title, favicon: favicon)
        if page.clientCertificateID != nil,
           let backForwardCache, let entry = navigation.currentEntry {
            let tabID = navigation.tabID
            let position = navigation.historyIndex
            enqueueBackForwardWrite {
                try? await backForwardCache.removeResponse(id: entry.id)
                try? await backForwardCache.save(entry, tabID: tabID, position: position)
            }
            return
        }
        persistCurrentBackForwardEntry()
    }

    private func cachedPage(for url: URL) -> CachedPage? {
        navigation.cachedPage(for: url)
    }

    private func scheduleBackForwardPersistence() {
        backForwardDebounceTask?.cancel()
        backForwardDebounceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            self?.persistCurrentBackForwardEntry()
        }
    }

    private func persistCurrentBackForwardEntry() {
        guard !isClearingBrowsingData else { return }
        guard let backForwardCache, let entry = navigation.currentEntry else { return }
        let tabID = navigation.tabID
        let position = navigation.historyIndex
        enqueueBackForwardWrite {
            try? await backForwardCache.save(entry, tabID: tabID, position: position)
        }
    }

    private func enqueueBackForwardWrite(
        _ operation: @escaping @Sendable () async -> Void
    ) {
        let previous = backForwardWriteTask
        backForwardWriteTask = Task {
            await previous?.value
            guard !Task.isCancelled else { return }
            await operation()
        }
    }

    private static func needsPresentationRestoration(_ state: HistoryPresentationState) -> Bool {
        state.scrollY > 0 || !state.expandedImages.isEmpty || !state.collapsedPreformatted.isEmpty
    }

    private func offersArchive(after error: any Error) -> Bool {
        guard let transportError = error as? GeminiTransportError else { return false }
        switch transportError {
        case .connectionFailed, .connectionTimedOut, .responseTimedOut:
            return true
        case .certificateUnavailable, .publicKeyFingerprintFailed, .trustDeclined,
             .responseFailed, .responseTooLarge:
            return false
        }
    }

    public func openArchive() {
        guard let committedURL,
              let archiveURL = DeloreanArchive.captures(of: committedURL),
              let target = try? GeminiRequestTarget(archiveURL.absoluteString) else { return }
        navigate(to: target, disposition: .new)
    }

    public func friendly(_ error: any Error) -> String {
        if let error = error as? GeminiRetrievalError {
            switch error {
            case .responseStatus(let header): return "The capsule returned Gemini status \(header.status): \(header.meta)"
            case .incompleteResponse: return "The response ended before it completed."
            }
        }
        if let error = error as? GeminiRetrievalRedirectError {
            switch error {
            case .loop, .limit: return "The capsule redirected too many times or in a loop."
            case .invalid(_, let meta): return "The capsule returned a redirect Major Tom could not understand: \(meta)"
            }
        }
        if let transportError = error as? GeminiTransportError {
            switch transportError {
            case .certificateUnavailable:
                return "The capsule did not provide a usable certificate."
            case .publicKeyFingerprintFailed:
                return "Major Tom could not identify the capsule's public key."
            case .trustDeclined:
                return "The capsule identity was not trusted."
            case .connectionFailed(let failure):
                return failure.userFacingDescription
            case .responseFailed(let protocolError):
                return protocolError.userFacingDescription
            case .connectionTimedOut:
                return "The connection attempt timed out. The capsule may be offline or unreachable from this network."
            case .responseTimedOut:
                return "The capsule stopped responding for 30 seconds."
            case .responseTooLarge(let limit):
                return "The response exceeded Major Tom's \(limit / 1_024 / 1_024) MB safety limit."
            }
        }
        return error.localizedDescription
    }

    public func preferencesChanged(to preferences: BrowserPreferences) {
        guard !isClosed else { return }
        defer { lastPreferences = preferences }

        // Handled ahead of the guard below, which is about re-rendering a document:
        // turning favicons off should clear the glyph even on a page that cannot be
        // re-rendered, such as a generated error page.
        if preferences.showsFavicons != lastPreferences.showsFavicons {
            if preferences.showsFavicons {
                if let committedURL {
                    scheduleFaviconRefresh(for: committedURL)
                }
            } else {
                favicon = nil
            }
        }

        guard committedURL != nil else { return }

        if preferences.contentWidth != lastPreferences.contentWidth {
            applyThemeWithoutReload()
            return
        }

        guard canSavePage else { return }

        let renderingChanged = preferences.renderingOptions != lastPreferences.renderingOptions
            || preferences.sameCapsuleImageLoading != lastPreferences.sameCapsuleImageLoading
            || preferences.imageRequestInterval != lastPreferences.imageRequestInterval
            || preferences.automaticallyLoadsDataImages != lastPreferences.automaticallyLoadsDataImages
        guard renderingChanged, !isLoading else { return }
        renderCurrentContent()
    }

    public func contentThemeChanged() {
        guard !isClosed else { return }
        guard committedURL != nil else { return }
        if isLoading {
            // Finish the current stream before rebuilding ANSI runs from source bytes.
            themeNeedsANSIRefresh = true
            applyThemeWithoutReload()
        } else if usesANSIColors(with: services.preferences()) {
            prepareScrollRestoration(for: navigation.historyIndex)
            renderCurrentContent()
        } else {
            applyThemeWithoutReload()
        }
    }

    private func usesANSIColors(with preferences: BrowserPreferences) -> Bool {
        preferences.renderingOptions.rendersANSIColors
            && currentMIMEType == "text/gemini"
            && canSavePage
            && !isLoading
            && currentSourceBytes.contains(0x1B)
    }

    private func applyZoom() {
        applyThemeWithoutReload()
    }

    private func renderCurrentContent() {
        guard let url = committedURL else { return }
        renderResponse(currentSourceBytes, mimeType: currentMIMEType, at: url,
            responseMeta: responseMeta, completion: currentCompletion)
    }

    private func renderResponse(_ bytes: Data, mimeType: String, at url: URL,
                                responseMeta: String? = nil, completion: PageCompletionState = .complete) {
        currentCompletion = completion
        let continuation = beginDocument(at: url)
        documentContinuation = continuation
        documentRenderer.renderComplete(bytes, mimeType: mimeType, at: url, responseMeta: responseMeta,
            preferences: services.preferences(), imagesPaused: automaticImagesPaused, completion: completion) { fragment in
            consume(fragment)
        }
        flushDocument()
        continuation.finish()
        documentContinuation = nil
        documentBuffer.removeAll(keepingCapacity: false)
    }

    private func historySwipeDocument(_ cached: CachedPage?, entry: BackForwardEntry) -> Data {
        // Preview styling cannot inherit the active document's hidden restoration state.
        let renderer = BrowserDocumentRenderer(style: services.contentStyle(pageZoom, false, imageViewportTopInset))
        guard let cached else {
            return renderer.historyPlaceholder(title: entry.title ?? displayTitle(for: entry.url), at: entry.url)
        }
        var data = Data()
        renderer.renderComplete(cached.body, mimeType: cached.mimeType, at: cached.url,
            responseMeta: cached.responseMeta, preferences: services.preferences(), imagesPaused: true,
            isPreview: true, completion: cached.completion) { data.append($0.data) }
        return data
    }

    private func emit(_ events: [BrowserBodyEvent], baseURL: URL) {
        for event in events {
            consume(documentRenderer.render(event, at: baseURL, preferences: services.preferences(), imagesPaused: automaticImagesPaused))
        }
    }

    private func consume(_ fragment: BrowserRenderedFragment) {
        if let semantic = fragment.semantic, titleClaim.receive(semantic), let title = titleClaim.title {
            self.title = title
            documentTitle = title
        }
        if let link = fragment.expandableLink {
            expandableImageLines[link.url] = link.identifier
            inlineImageURLs[link.identifier] = link.url
        }
        yieldToDocument(fragment.data)
    }

    public func handleInlineImageMessage(lineIdentifier: String, url: URL, action: String, documentURL: URL) {
        guard activeWebDocumentURL == documentURL, inlineImageURLs[lineIdentifier] == url else { return }
        if action == "click" {
            toggleInlineImage(lineIdentifier: lineIdentifier, url: url, documentURL: documentURL)
        } else if action == "load", !automaticImagesPaused, services.preferences().sameCapsuleImageLoading != .off,
                  let committedURL, isSameCapsule(url, committedURL),
                  !expandedInlineImages.contains(lineIdentifier) {
            startInlineImage(lineIdentifier: lineIdentifier, url: url)
        }
    }

    public func toggleInlineImage(lineIdentifier: String, url: URL, documentURL: URL) {
        guard !isClosed else { return }
        guard activeWebDocumentURL == documentURL, inlineImageURLs[lineIdentifier] == url else { return }
        if imageTasks[lineIdentifier] != nil {
            Task { await services.imageLoader?.prioritize(url) }
            return
        }
        if expandedInlineImages.remove(lineIdentifier) != nil {
            navigation.setImage(url, expanded: false)
            scheduleBackForwardPersistence()
            Task { await removeInlineImage(lineIdentifier: lineIdentifier) }
            return
        }
        navigation.setImage(url, expanded: true)
        scheduleBackForwardPersistence()
        startInlineImage(lineIdentifier: lineIdentifier, url: url, prioritize: true)
    }

    private func startInlineImage(
        lineIdentifier: String, url: URL, prioritize: Bool = false, restoresScroll: Bool = false
    ) {
        guard imageTasks[lineIdentifier] == nil else { return }
        expandedInlineImages.insert(lineIdentifier)
        let documentURL = activeWebDocumentURL
        imageTasks[lineIdentifier] = Task { [weak self] in
            guard let self, !Task.isCancelled else { return }
            try? await requestLifetime.perform {
                await expandInlineImage(lineIdentifier: lineIdentifier, url: url,
                    completesScrollRestoration: restoresScroll, prioritize: prioritize)
            }
            if !Task.isCancelled, self.activeWebDocumentURL == documentURL {
                self.imageTasks[lineIdentifier] = nil
            }
        }
    }

    private func restoredInlineImageDidFinishLoading() async {
        guard pendingRestoredInlineImageCount > 0 else { return }
        pendingRestoredInlineImageCount -= 1
        guard pendingRestoredInlineImageCount == 0,
              let correction = pendingInlineImageScrollCorrection else { return }
        pendingInlineImageScrollCorrection = nil
        guard let documentURL = activeWebDocumentURL else { return }
        await presentation.updateDocument(.correctScrollAfterImages(correction.offset), at: documentURL)
    }

    private func inlineImageFileName(for url: URL, fallback: String?) -> String {
        if !url.lastPathComponent.isEmpty { return url.lastPathComponent }
        if let fallback, !fallback.isEmpty { return fallback }
        return url.host ?? "Image"
    }

    private func formattedByteCount(_ byteCount: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(byteCount), countStyle: .file)
    }

    private func scheduleFaviconRefresh(for url: URL) {
        faviconTask?.cancel()
        faviconTask = Task { [weak self] in
            guard let self, !isClosed, !Task.isCancelled else { return }
            try? await requestLifetime.perform { await refreshFavicon(forCapsuleAt: url) }
        }
    }

    private func refreshFavicon(forCapsuleAt url: URL) async {
        guard !isClearingBrowsingData else { return }
        let generation = browsingDataGeneration
        guard services.preferences().showsFavicons,
              url.scheme?.lowercased() == "gemini",
              let endpoint = CapsuleEndpoint(url: url) else {
            favicon = nil
            return
        }
        guard let loader = services.faviconLoader else { return }
        let observation = await loader.observation(for: endpoint)
        guard !Task.isCancelled, !isClosed, generation == browsingDataGeneration else { return }
        switch observation.kind {
        case .unknown:
            return
        case .found(let emoji):
            services.updateBookmarkFavicon(emoji, endpoint, observation.receivedAt)
            applyFaviconIfStillCurrent(emoji, endpoint: endpoint)
        case .absent:
            services.updateBookmarkFavicon(nil, endpoint, observation.receivedAt)
            applyFaviconIfStillCurrent(nil, endpoint: endpoint)
        }
    }

    private func applyFaviconIfStillCurrent(_ emoji: String?, endpoint: CapsuleEndpoint) {
        guard let current = committedURL.flatMap(CapsuleEndpoint.init(url:)),
              current == endpoint else { return }
        favicon = emoji
        navigation.updateCurrentMetadata(title: documentTitle ?? title, favicon: emoji)
        persistCurrentBackForwardEntry()
    }

    public func retrieveGeminiResource(
        _ url: URL, proxy: GeminiProxyConfiguration?
    ) async throws -> (data: Data, mimeType: String, finalURL: URL) {
        guard let target = GeminiRequestTarget.navigationTarget(for: url, proxy: proxy) else {
            throw URLError(.badURL)
        }
        let response = try await services.retriever.response(
            for: target, proxy: proxy, purpose: .download
        )
        return (response.body, response.mimeType ?? "application/octet-stream", response.url)
    }

    private func isProbableImage(_ url: URL) -> Bool {
        GemtextLinkHint.isProbableImage(url)
    }

    private func isSameCapsule(_ lhs: URL, _ rhs: URL) -> Bool {
        GemtextLinkHint.isSameCapsule(lhs, rhs)
    }

    private func displayTitle(for url: URL) -> String {
        BrowserPageTitle.fallback(for: url)
    }

    public var canCheckArchive: Bool {
        committedURL.map { DeloreanArchive.captures(of: $0) != nil } ?? false
    }

    public func resumeClientCertificatePrompt(id: UUID) {
        guard !isClosed else { return }
        guard clientCertificatePrompt?.id == id, let pending = pendingClientCertificateChallenge else { return }
        clientCertificatePrompt = nil
        pendingClientCertificateChallenge = nil
        navigate(to: pending.target, disposition: pending.disposition, renderAsSource: pending.renderAsSource)
    }

    public func reportNativeResult(status: String? = nil, error: String? = nil) {
        if let status { statusText = status }
        if let error { validationMessage = error }
    }

    public func prepareHistoryPreview(direction: BrowserHistoryDirection) async -> UUID? {
        guard !isClosed else { return nil }
        guard let source = navigation.currentEntryID,
              let entry = direction == .back ? navigation.backHistoryEntries.first : navigation.forwardHistoryEntries.first
        else { return nil }
        historyPreviewGeneration &+= 1
        let generation = historyPreviewGeneration
        let id = UUID()
        pendingHistoryPreview = (id, source, entry.id)
        var cached = entry.page
        if cached == nil { cached = try? await backForwardCache?.entry(id: entry.id)?.page }
        guard generation == historyPreviewGeneration, navigation.currentEntryID == source else { return nil }
        if let cached { navigation.cache(cached, for: entry.id) }
        do { try await presentation.showHistoryPreview(historySwipeDocument(cached, entry: entry), entry: entry) }
        catch { if generation == historyPreviewGeneration { pendingHistoryPreview = nil }; return nil }
        guard generation == historyPreviewGeneration, navigation.currentEntryID == source else { return nil }
        return id
    }

    public func acceptHistoryPreview(id: UUID) {
        guard let pending = pendingHistoryPreview, pending.id == id,
              navigation.currentEntryID == pending.source else { return }
        go(toHistoryEntryWithID: pending.target)
    }

    public func cancelHistoryPreview() {
        historyPreviewGeneration &+= 1
        pendingHistoryPreview = nil
    }

    private func beginDocument(at sourceURL: URL) -> AsyncThrowingStream<Data, any Error>.Continuation {
        updateHoveredLink(nil)
        imageTasks.values.forEach { $0.cancel() }
        imageTasks.removeAll()
        documentContinuation?.finish()
        streamingBody = nil
        documentRenderer = BrowserDocumentRenderer(style: contentStyle)
        documentContinuation = nil
        documentBuffer.removeAll(keepingCapacity: false)
        expandedInlineImages.removeAll()
        expandableImageLines.removeAll()
        inlineImageURLs.removeAll()
        let document = presentation.createDocument()
        activeWebDocumentURL = document.url
        let restoration = pendingScrollRestoration
        Task { [weak self, presentation] in
            do {
                try await presentation.loadDocument(at: document.url)
                guard let self, activeWebDocumentURL == document.url else { return }
                if let restoration { await restoreScrollPosition(restoration, documentURL: document.url) }
                guard activeWebDocumentURL == document.url else { return }
                hasPresentedInitialDocument = true
            } catch {
                guard let self, activeWebDocumentURL == document.url else { return }
                if let restoration, pendingScrollRestoration?.historyIndex == restoration.historyIndex {
                    pendingScrollRestoration = nil
                    isRestoringHistoryScroll = false
                }
            }
        }
        return document.continuation
    }

    private func restoreScrollPosition(_ restoration: (historyIndex: Int, offset: Double), documentURL: URL) async {
        guard activeWebDocumentURL == documentURL, navigation.historyIndex == restoration.historyIndex,
              pendingScrollRestoration?.historyIndex == restoration.historyIndex else { return }
        let restoredImageCount = await restorePresentationState(documentURL: documentURL)
        guard activeWebDocumentURL == documentURL else { return }
        if restoredImageCount > 0 { pendingInlineImageScrollCorrection = restoration }
        await presentation.updateDocument(.restoreScroll(restoration.offset), at: documentURL)
        guard activeWebDocumentURL == documentURL else { return }
        if pendingScrollRestoration?.historyIndex == restoration.historyIndex {
            pendingScrollRestoration = nil
            isRestoringHistoryScroll = false
        }
    }

    private func restorePresentationState(documentURL: URL) async -> Int {
        guard let entry = navigation.currentEntry else { return 0 }
        if !entry.presentation.collapsedPreformatted.isEmpty {
            await presentation.updateDocument(.collapsedSections(entry.presentation.collapsedPreformatted), at: documentURL)
        }
        guard activeWebDocumentURL == documentURL else { return 0 }
        var count = 0
        for url in entry.presentation.expandedImages {
            guard let line = expandableImageLines[url], !expandedInlineImages.contains(line) else { continue }
            expandedInlineImages.insert(line)
            count += 1
            startInlineImage(lineIdentifier: line, url: url, restoresScroll: true)
        }
        pendingRestoredInlineImageCount = count
        return count
    }

    private func applyThemeWithoutReload() {
        guard let documentURL = activeWebDocumentURL else { return }
        let style = contentStyle
        Task { [presentation] in await presentation.updateDocument(.theme(css: style.css, appearance: style.appearance), at: documentURL) }
    }

    public func updateImageViewportTopInset(_ inset: Double) {
        guard imageViewportTopInset != inset else { return }
        imageViewportTopInset = inset
        guard let documentURL = activeWebDocumentURL else { return }
        Task { [presentation] in await presentation.updateDocument(.imageViewport(inset), at: documentURL) }
    }

    private func expandInlineImage(lineIdentifier: String, url: URL,
                                   completesScrollRestoration: Bool = false, prioritize: Bool = false) async {
        guard let documentURL = activeWebDocumentURL else { return }
        let figure = "mt-inline-\(lineIdentifier)"
        let name = inlineImageFileName(for: url, fallback: nil)
        let resource = presentation.createImageResource()
        let html = documentRenderer.inlineImage(resourceURL: resource.url, linkURL: url,
            figureIdentifier: figure, fileName: name)
        await presentation.updateDocument(.insertImage(line: lineIdentifier, figure: html), at: documentURL)
        let metadata = await loadInlineImage(url, lineIdentifier: lineIdentifier, prioritize: prioritize, resource: resource)
        guard !Task.isCancelled, activeWebDocumentURL == documentURL else { return }
        if let metadata {
            await presentation.updateDocument(.imageMetadata(figure: figure, mimeType: metadata.mimeType,
                size: formattedByteCount(metadata.byteCount)), at: documentURL)
        } else {
            expandedInlineImages.remove(lineIdentifier)
            await presentation.updateDocument(.removeImage(line: lineIdentifier), at: documentURL)
        }
        if completesScrollRestoration { await restoredInlineImageDidFinishLoading() }
    }

    private func removeInlineImage(lineIdentifier: String) async {
        guard let documentURL = activeWebDocumentURL else { return }
        await presentation.updateDocument(.removeImage(line: lineIdentifier), at: documentURL)
    }

    private func loadInlineImage(_ url: URL, lineIdentifier: String, prioritize: Bool,
                                 resource: BrowserPresentationResource) async -> LoadedInlineImage? {
        guard let documentURL = activeWebDocumentURL, let loader = services.imageLoader else {
            resource.finish(.failure(URLError(.unsupportedURL))); return nil
        }
        let activity = AsyncStream<GeminiImageLoader.State>.makeStream()
        defer { activity.continuation.finish() }
        let activityTask = Task { [weak self, presentation] in
            for await state in activity.stream {
                guard !Task.isCancelled, self?.activeWebDocumentURL == documentURL else { return }
                await presentation.updateDocument(.imageState(line: lineIdentifier, state: state), at: documentURL)
            }
        }
        do {
            let authorize = services.authorizeTrust
            let response = try await withTaskCancellationHandler {
                try await loader.image(for: url, interval: services.preferences().imageRequestInterval,
                    pageStartedAt: imagePageStartedAt, prioritize: prioritize,
                    stateChanged: { activity.continuation.yield($0) }, authorize: authorize)
            } onCancel: { activityTask.cancel() }
            try Task.checkCancellation()
            resource.finish(.success(response))
            return LoadedInlineImage(mimeType: response.mimeType ?? "image/unknown", byteCount: response.body.count)
        } catch {
            if Task.isCancelled { activityTask.cancel() }
            resource.finish(.failure(error))
            return nil
        }
    }

    private var contentStyle: BrowserContentStyle {
        let hides = pendingScrollRestoration?.historyIndex == navigation.historyIndex
            && (navigation.currentEntry?.presentation).map(Self.needsPresentationRestoration) == true
        return services.contentStyle(pageZoom, hides, imageViewportTopInset)
    }
}

private extension NavigationState.Disposition {
    init(_ disposition: BrowserSession.HistoryDisposition) {
        switch disposition { case .new: self = .new; case .reload: self = .reload; case .traversal: self = .traversal }
    }
}
