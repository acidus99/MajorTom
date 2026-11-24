import AppKit
import Combine
import Foundation
import MajorTomAppKitSupport
import MajorTomCore
import os
import SwiftUI
import WebKit

/// Navigation, document loading, and Back/Forward traversal.
///
/// The category was "BackForwardGesture", which named one caller rather than the
/// messages: filtering the log by it returned every document load and custom-scheme
/// reply in the browser, and no gesture at all.
private let browserNavigationLogger = Logger(
    subsystem: "dev.gemi.major-tom",
    category: "Navigation"
)

fileprivate enum BrowserHistorySwipeDirection {
    case back
    case forward

    var sign: CGFloat { self == .back ? 1 : -1 }
}

@available(macOS 26.0, *)
@MainActor
private final class ContextMenuScriptHandler: NSObject, WKScriptMessageHandler {
    static let name = BrowserDocumentScript.contextMenuName

    static let userScript = BrowserDocumentScript.contextMenu

    weak var browser: BrowserModel?

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard browser?.acceptsDocumentMessage(message) == true else { return }
        let body = message.body as? [String: String]
        let link = body?["href"].flatMap { $0.isEmpty ? nil : URL(string: $0) }
        Task { @MainActor [weak browser] in
            guard browser?.acceptsDocumentMessage(message) == true else { return }
            browser?.showPendingContextMenu(
                link: link, imageLine: body?["imageLine"]
            )
        }
    }
}

/// Reports the destination of the link under the pointer, or focused by keyboard.
///
/// Runs in the `.defaultClient` content world, which is isolated from page script and
/// exempt from the document's `default-src 'none'` CSP. The script de-duplicates before
/// posting, because `mouseover` fires continuously as the pointer moves within one
/// anchor and each message would otherwise cross the process boundary and republish
/// SwiftUI state.
@available(macOS 26.0, *)
@MainActor
private final class LinkHoverScriptHandler: NSObject, WKScriptMessageHandler {
    static let name = BrowserDocumentScript.linkHoverName

    static let userScript = BrowserDocumentScript.linkHover

    weak var browser: BrowserModel?

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard browser?.acceptsDocumentMessage(message) == true else { return }
        Task { @MainActor [weak browser] in
            guard browser?.acceptsDocumentMessage(message) == true,
                  let payload = message.body as? [String: Any] else { return }
            var modifiers: LinkModifierKeys = []
            if payload["command"] as? Bool == true { modifiers.insert(.command) }
            if payload["shift"] as? Bool == true { modifiers.insert(.shift) }
            if payload["option"] as? Bool == true { modifiers.insert(.option) }
            if payload["control"] as? Bool == true { modifiers.insert(.control) }
            browser?.session.updateHoveredLink(payload["href"] as? String, modifiers: modifiers)
        }
    }
}

/// Keeps the current document's vertical offset on the native side of the WebKit
/// boundary. Major Tom owns navigation history itself, so WebKit cannot restore this
/// state for us when a cached response is rendered into a new document.
@available(macOS 26.0, *)
@MainActor
private final class ScrollPositionScriptHandler: NSObject, WKScriptMessageHandler {
    static let name = BrowserDocumentScript.scrollPositionName

    static let userScript = BrowserDocumentScript.scrollPosition

    weak var browser: BrowserModel?

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard browser?.acceptsDocumentMessage(message) == true,
              let offset = message.body as? Double, offset.isFinite else { return }
        browser?.session.recordScrollPosition(offset, from: message.frameInfo.request.url)
    }
}

/// Handles link activations whose modifier state is not reliably preserved in
/// WebKit's navigation action (notably Shift-Command-click and middle-click).
@available(macOS 26.0, *)
@MainActor
private final class LinkActivationScriptHandler: NSObject, WKScriptMessageHandler {
    static let name = BrowserDocumentScript.linkActivationName

    static let userScript = BrowserDocumentScript.linkActivation

    weak var browser: BrowserModel?

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard browser?.acceptsDocumentMessage(message) == true,
              let payload = message.body as? [String: Any],
              let href = payload["href"] as? String,
              let url = URL(string: href),
              let activation = payload["activation"] as? String else { return }
        Task { @MainActor [weak browser] in
            guard browser?.acceptsDocumentMessage(message) == true else { return }
            switch activation {
            case "newBackgroundTab":
                browser?.activateLink(url, activation: .newBackgroundTab)
            case "newForegroundTab":
                browser?.activateLink(url, activation: .newForegroundTab)
            default:
                break
            }
        }
    }
}

/// Intercepts clicks on links the renderer marked as expandable images.
///
/// Page script is disabled, so this runs in the `.defaultClient` world like the context
/// menu and hover handlers. It is the only way to learn *which* link element was clicked:
/// a navigation action reports a URL, and the same image can be linked from several lines.
///
/// Modified clicks are deliberately left alone so Command-click still opens a new tab.
@available(macOS 26.0, *)
@MainActor
private final class InlineImageScriptHandler: NSObject, WKScriptMessageHandler {
    static let name = "majorTomInlineImage"

    weak var browser: BrowserModel?

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard browser?.acceptsDocumentMessage(message) == true,
              let body = message.body as? [String: Any],
              let identifier = body["id"] as? String,
              let href = body["href"] as? String,
              let url = URL(string: href),
              let action = body["action"] as? String,
              let document = body["documentURL"] as? String,
              let documentURL = URL(string: document) else { return }
        Task { @MainActor [weak browser] in
            guard browser?.acceptsDocumentMessage(message) == true else { return }
            browser?.session.handleInlineImageMessage(
                lineIdentifier: identifier, url: url, action: action, documentURL: documentURL
            )
        }
    }
}

@available(macOS 26.0, *)
@MainActor
private final class PreformattedBlockStateScriptHandler: NSObject, WKScriptMessageHandler {
    static let name = BrowserDocumentScript.preformattedStateName

    static let userScript = BrowserDocumentScript.preformattedState

    weak var browser: BrowserModel?

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard browser?.acceptsDocumentMessage(message) == true,
              let payload = message.body as? [String: Any],
              let index = payload["index"] as? NSNumber,
              let collapsed = payload["collapsed"] as? NSNumber else { return }
        browser?.session.recordPreformattedState(
            index: index.intValue,
            collapsed: collapsed.boolValue,
            from: message.frameInfo.request.url
        )
    }
}

@available(macOS 26.0, *)
@MainActor
final class BrowserModel: ObservableObject {
    typealias InputPrompt = BrowserSession.InputPrompt
    typealias ClientCertificatePrompt = BrowserSession.ClientCertificatePrompt
    typealias HistoryDisposition = BrowserSession.HistoryDisposition
    fileprivate struct HistorySwipePresentation {
        let direction: BrowserHistorySwipeDirection
        let viewportWidth: CGFloat
        var offset: CGFloat
        var isReady: Bool
    }
    private struct PendingHistorySwipe { let id: UUID }
    let session: BrowserSession
    weak var hostWindow: NSWindow?
    private let presentation: BrowserWebPresentation
    var page: WebPage { presentation.page }
    var historySwipePage: WebPage { presentation.historySwipePage }
    @Published var pageInformation: PageInformation?
    @Published fileprivate var historySwipePresentation: HistorySwipePresentation?
    var isPresentingHistorySwipe: Bool { historySwipePresentation != nil }
    private var pendingHistorySwipe: PendingHistorySwipe?
    private var historySwipeGeneration = 0
    private let settings: BrowserSettingsStore
    private let themes: ContentThemeStore
    private let clientCertificates: ClientCertificateStore
    private let trustStore: TrustedIdentityStore?
    private var cancellables = Set<AnyCancellable>()
    private var downloadTask: Task<Void, Never>?
    private var downloadPanel: NSSavePanel?
    private var savePanels: [ObjectIdentifier: NSSavePanel] = [:]
    private var contextMenuTargets: [ContextMenuTarget] = []
    private weak var pendingContextMenuView: NSView?
    private var pendingContextMenuLocation: NSPoint?
    private var contextSharingPicker: NSSharingServicePicker?
    private let contextMenuScriptHandler: ContextMenuScriptHandler
    private let linkHoverScriptHandler: LinkHoverScriptHandler
    private let linkActivationScriptHandler: LinkActivationScriptHandler
    private let inlineImageScriptHandler: InlineImageScriptHandler
    private let scrollPositionScriptHandler: ScrollPositionScriptHandler
    private let preformattedStateScriptHandler: PreformattedBlockStateScriptHandler
    private var committedURL: URL? { session.committedURL }
    private var title: String { session.title }
    private var documentTitle: String? { session.documentTitle }
    private var canSavePage: Bool { session.canSavePage }
    private var canShowSource: Bool { session.canShowSource }
    private var canGoBack: Bool { session.canGoBack }
    private var canGoForward: Bool { session.canGoForward }
    private var canReload: Bool { session.canReload }
    private var canStop: Bool { session.canStop }
    private var canCheckArchive: Bool { session.canCheckArchive }
    private var validationMessage: String? { get { session.validationMessage } set { session.validationMessage = newValue } }
    private var clientCertificatePrompt: ClientCertificatePrompt? { get { session.clientCertificatePrompt } set { session.clientCertificatePrompt = newValue } }
    private var openInNewTab: ((URL, Bool) -> Void)? { get { session.openInNewTab } set { session.openInNewTab = newValue } }
    private var openInNewWindow: ((URL) -> Void)? { get { session.openInNewWindow } set { session.openInNewWindow = newValue } }
    private var statusText: String { get { session.statusText } set { session.reportNativeResult(status: newValue) } }
    private var activeWebDocumentURL: URL? { session.activeWebDocumentURL }

    init(services: BrowserSessionServices, settings: BrowserSettingsStore, themes: ContentThemeStore,
         clientCertificates: ClientCertificateStore, trustStore: TrustedIdentityStore?,
         restoredState: RestoredTabState?, initialURL: URL?) {
        self.settings = settings
        self.themes = themes
        self.clientCertificates = clientCertificates
        self.trustStore = trustStore
        let contextMenuScriptHandler = ContextMenuScriptHandler()
        let linkHoverScriptHandler = LinkHoverScriptHandler()
        let linkActivationScriptHandler = LinkActivationScriptHandler()
        let inlineImageScriptHandler = InlineImageScriptHandler()
        let scrollPositionScriptHandler = ScrollPositionScriptHandler()
        let preformattedStateScriptHandler = PreformattedBlockStateScriptHandler()
        let userContentController = WKUserContentController()
        userContentController.addUserScript(ContextMenuScriptHandler.userScript)
        userContentController.add(
            contextMenuScriptHandler,
            contentWorld: .defaultClient,
            name: ContextMenuScriptHandler.name
        )
        userContentController.addUserScript(LinkHoverScriptHandler.userScript)
        userContentController.add(
            linkHoverScriptHandler,
            contentWorld: .defaultClient,
            name: LinkHoverScriptHandler.name
        )
        userContentController.addUserScript(LinkActivationScriptHandler.userScript)
        userContentController.addUserScript(InlineImagePresentationScript.userScript)
        userContentController.addUserScript(PreformattedBlockPresentationScript.userScript)
        userContentController.addUserScript(PreformattedBlockStateScriptHandler.userScript)
        userContentController.add(
            preformattedStateScriptHandler,
            contentWorld: .defaultClient,
            name: PreformattedBlockStateScriptHandler.name
        )
        userContentController.add(
            linkActivationScriptHandler,
            contentWorld: .defaultClient,
            name: LinkActivationScriptHandler.name
        )
        userContentController.add(
            inlineImageScriptHandler,
            contentWorld: .defaultClient,
            name: InlineImageScriptHandler.name
        )
        userContentController.addUserScript(ScrollPositionScriptHandler.userScript)
        userContentController.add(
            scrollPositionScriptHandler,
            contentWorld: .defaultClient,
            name: ScrollPositionScriptHandler.name
        )
        let presentation = BrowserWebPresentation(userContentController: userContentController)
        self.presentation = presentation
        self.session = BrowserSession(services: services, presentation: presentation, restoredState: restoredState, initialURL: initialURL)
        self.contextMenuScriptHandler = contextMenuScriptHandler
        self.linkHoverScriptHandler = linkHoverScriptHandler
        self.linkActivationScriptHandler = linkActivationScriptHandler
        self.inlineImageScriptHandler = inlineImageScriptHandler
        self.scrollPositionScriptHandler = scrollPositionScriptHandler
        self.preformattedStateScriptHandler = preformattedStateScriptHandler
        contextMenuScriptHandler.browser = self
        linkHoverScriptHandler.browser = self
        linkActivationScriptHandler.browser = self
        inlineImageScriptHandler.browser = self
        scrollPositionScriptHandler.browser = self
        preformattedStateScriptHandler.browser = self
        let router = presentation.router
        router.openURL = { [weak session] in session?.openLink($0) }
        router.downloadURL = { [weak self] in self?.download($0) }
        router.openInNewTab = { [weak self] in self?.session.openInNewTab?($0, $1) }
        router.openInNewWindow = { [weak self] in self?.session.openInNewWindow?($0) }
        router.canOpenInApp = { [weak session] in session?.canOpenInApp($0) ?? false }
        session.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)
        presentation.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)
        themes.themeDidChange.sink { [weak session] in session?.contentThemeChanged() }.store(in: &cancellables)
        settings.preferencesDidChange.sink { [weak session] in session?.preferencesChanged(to: $0) }.store(in: &cancellables)
        ModifierFlagsMonitor.shared.flagsDidChange.sink { [weak self] in self?.updateHoveredLinkModifiers($0) }.store(in: &cancellables)
    }
    func stop() { session.stop(); cancelHistorySwipePreparation() }
    func cancelInteractiveHistorySwipe() { cancelHistorySwipePreparation() }
    func updateImageViewportTopInset(_ inset: CGFloat) { session.updateImageViewportTopInset(Double(inset)) }
    private func canOpenInApp(_ url: URL) -> Bool { session.canOpenInApp(url) }
    private func openLink(_ url: URL) { session.openLink(url) }
    private func retrieveGeminiResource(_ url: URL, proxy: GeminiProxyConfiguration?) async throws -> (data: Data, mimeType: String, finalURL: URL) { try await session.retrieveGeminiResource(url, proxy: proxy) }
    private func friendly(_ error: any Error) -> String { session.friendly(error) }

    fileprivate func acceptsDocumentMessage(_ message: WKScriptMessage) -> Bool {
        DocumentMessageFence.accepts(message, currentDocumentURL: activeWebDocumentURL)
    }

    fileprivate func activateLink(_ url: URL, activation: LinkActivation) {
        switch activation {
        case .newBackgroundTab:
            if canOpenInApp(url) {
                openInNewTab?(url, true)
            } else {
                openLink(url)
            }
        case .newForegroundTab:
            if canOpenInApp(url) {
                openInNewTab?(url, false)
            } else {
                openLink(url)
            }
        case .newWindow:
            if canOpenInApp(url) {
                openInNewWindow?(url)
            } else {
                openLink(url)
            }
        case .download:
            download(url)
        case .currentTab, .contextMenu:
            openLink(url)
        }
    }

    private func addContextMenuItem(
        _ title: String,
        systemImage: String,
        enabled: Bool,
        to menu: NSMenu,
        action: @escaping () -> Void
    ) {
        let target = ContextMenuTarget(action)
        contextMenuTargets.append(target)
        let item = NSMenuItem(title: title, action: #selector(ContextMenuTarget.performAction), keyEquivalent: "")
        item.target = target
        item.isEnabled = enabled
        item.image = NSImage(systemSymbolName: systemImage, accessibilityDescription: title)
        menu.addItem(item)
    }

    @discardableResult
    func close() -> Task<Void, Never> {
        let requestDrain = session.close()
        downloadTask?.cancel()
        downloadPanel?.cancel(nil)
        for panel in savePanels.values { panel.cancel(nil) }
        return Task {
            await cancelAndDrainNativeRequests()
            await requestDrain.value
        }
    }

    func cancelAndDrainNativeRequests() async {
        cancelHistorySwipePreparation()
        let task = downloadTask
        task?.cancel()
        downloadPanel?.cancel(nil)
        await task?.value
    }

    func download(_ url: URL) {
        guard !session.isClosed else { return }
        let proxy = settings.preferences.proxy
        statusText = "Downloading \(url.lastPathComponent)…"
        downloadTask?.cancel()
        downloadPanel?.cancel(nil)
        downloadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let fetched: (data: Data, mimeType: String, finalURL: URL)
                switch url.scheme?.lowercased() {
                case "gemini":
                    fetched = try await retrieveGeminiResource(url, proxy: proxy)
                case "http", "https":
                    if proxy != nil {
                        fetched = try await retrieveGeminiResource(url, proxy: proxy)
                    } else {
                        let (data, response) = try await URLSession.shared.data(from: url)
                        fetched = (data, (response.mimeType ?? "application/octet-stream").lowercased(), response.url ?? url)
                    }
                case "file":
                    fetched = (
                        try Data(contentsOf: url),
                        BrowserSession.mimeType(forPathExtension: url.pathExtension),
                        url
                    )
                default:
                    throw URLError(.unsupportedURL)
                }
                try Task.checkCancellation()

                let panel = NSSavePanel()
                downloadPanel = panel
                defer { if downloadPanel === panel { downloadPanel = nil } }
                // Name from the FINAL url, so a redirected download is not named after
                // the URL that redirected.
                panel.nameFieldStringValue = BrowserFilenameSuggestion.make(
                    for: fetched.finalURL,
                    mimeType: fetched.mimeType
                )
                panel.canCreateDirectories = true
                guard await panel.begin() == .OK, let destination = panel.url else {
                    statusText = "Download cancelled"
                    return
                }
                try Task.checkCancellation()
                try fetched.data.write(to: destination, options: .atomic)
                statusText = "Downloaded \(destination.lastPathComponent)"
            } catch is CancellationError {
                statusText = "Download cancelled"
            } catch {
                validationMessage = "Download failed: \(friendly(error))"
                statusText = "Download failed"
            }
        }
    }

    private static func findWebView(in view: NSView, documentURL: URL) -> WKWebView? {
        if let webView = view as? WKWebView, webView.url == documentURL { return webView }
        for subview in view.subviews {
            if let webView = findWebView(in: subview, documentURL: documentURL) { return webView }
        }
        return nil
    }

    func prepareContextMenu(at location: NSPoint, in view: NSView) {
        pendingContextMenuLocation = location
        pendingContextMenuView = view
    }

    func printPage() {
        guard let snapshot = session.pageSnapshot,
              let documentURL = activeWebDocumentURL,
              let window = hostWindow,
              let rootView = window.contentView,
              let webView = Self.findWebView(in: rootView, documentURL: documentURL),
              let info = NSPrintInfo.shared.copy() as? NSPrintInfo else {
            validationMessage = "Major Tom could not prepare this page for printing."
            return
        }
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        let operation = webView.printOperation(with: info)
        operation.jobTitle = snapshot.title
        operation.showsPrintPanel = true
        operation.showsProgressPanel = true
        operation.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
    }

    func releaseWebViewDragTypes() async {
        for _ in 0..<20 {
            if let window = hostWindow, let documentURL = activeWebDocumentURL,
               let root = window.contentView,
               let webView = Self.findWebView(in: root, documentURL: documentURL) {
                webView.unregisterDraggedTypes()
                return
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    func savePage() async {
        guard !session.isClosed, canSavePage, let snapshot = session.pageSnapshot else { return }
        // NSSavePanel.begin is modeless, so the user can keep browsing the window
        // behind it. Capture the bytes for the page that was on screen when Save was
        // invoked; re-reading the property after the await wrote the *new* page's
        // bytes into a file named after the old one.
        let bytes = snapshot.body
        let panel = NSSavePanel()
        let panelID = ObjectIdentifier(panel)
        savePanels[panelID] = panel
        defer { savePanels[panelID] = nil }
        panel.nameFieldStringValue = BrowserFilenameSuggestion.make(
            for: snapshot.url,
            mimeType: snapshot.mimeType,
            documentTitle: snapshot.documentTitle
        )
        panel.canCreateDirectories = true
        guard await panel.begin() == .OK, !session.isClosed, !Task.isCancelled,
              let destination = panel.url else { return }
        do {
            try bytes.write(to: destination, options: .atomic)
            statusText = "Saved \(destination.lastPathComponent)"
        } catch {
            validationMessage = "The page could not be saved: \(error.localizedDescription)"
        }
    }

    private func showLinkContextMenu(for url: URL, imageLine: String?, at location: NSPoint, in view: NSView?) {
        let menu = NSMenu()
        menu.autoenablesItems = false
        contextMenuTargets.removeAll()
        let opensInApp = canOpenInApp(url)
        if let documentURL = activeWebDocumentURL, let imageLine,
           let expanded = session.inlineImageIsExpanded(line: imageLine, url: url) {
            addContextMenuItem(expanded ? "Collapse Image" : "Load Image", systemImage: "photo", enabled: true, to: menu) { [weak self] in
                self?.session.toggleInlineImage(lineIdentifier: imageLine, url: url, documentURL: documentURL)
            }
            menu.addItem(.separator())
        }
        addContextMenuItem("Open Link in New Tab", systemImage: BrowserMenuIcon.newTab, enabled: opensInApp, to: menu) { [weak self] in
            self?.session.openInNewTab?(url, true)
        }
        addContextMenuItem("Open Link in New Window", systemImage: BrowserMenuIcon.newWindow, enabled: opensInApp, to: menu) { [weak self] in
            self?.session.openInNewWindow?(url)
        }
        menu.addItem(.separator())
        addContextMenuItem("Download Linked File As…", systemImage: BrowserMenuIcon.download, enabled: !url.isFileURL, to: menu) { [weak self] in self?.download(url) }
        menu.addItem(.separator())
        addContextMenuItem("Copy Link", systemImage: BrowserMenuIcon.copyLink, enabled: true, to: menu) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(url.absoluteString, forType: .string)
        }

        let sharingPicker = NSSharingServicePicker(items: [url])
        contextSharingPicker = sharingPicker
        menu.addItem(sharingPicker.standardShareMenuItem)

        menu.addItem(.separator())
        let servicesItem = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
        NSApp.servicesMenu?.update()
        servicesItem.submenu = (NSApp.servicesMenu?.copy() as? NSMenu) ?? NSMenu(title: "Services")
        menu.addItem(servicesItem)
        menu.popUp(positioning: nil, at: location, in: view)
    }

    func showPageContextMenu(at location: NSPoint, in view: NSView?) {
        let menu = NSMenu()
        // NSMenu.autoenablesItems defaults to true, under which NSMenuItem.isEnabled is
        // ignored and AppKit asks the target's validateMenuItem: instead. Because
        // ContextMenuTarget responds to the action selector but implements no
        // validation, every item validated as enabled: Back and Forward appeared
        // available on a fresh tab and did nothing when clicked (spec 18.3).
        menu.autoenablesItems = false
        contextMenuTargets.removeAll()
        addContextMenuItem("Back", systemImage: BrowserMenuIcon.back, enabled: canGoBack, to: menu) { [weak self] in self?.session.goBack() }
        addContextMenuItem("Forward", systemImage: BrowserMenuIcon.forward, enabled: canGoForward, to: menu) { [weak self] in self?.session.goForward() }
        menu.addItem(.separator())
        if canStop {
            addContextMenuItem("Stop Loading", systemImage: "xmark", enabled: true, to: menu) { [weak self] in self?.stop() }
        } else {
            addContextMenuItem("Reload Page", systemImage: BrowserMenuIcon.reload, enabled: canReload, to: menu) { [weak self] in self?.session.reload() }
        }
        menu.addItem(.separator())
        addContextMenuItem("Show Page Source", systemImage: BrowserMenuIcon.showSource, enabled: canShowSource, to: menu) { [weak self] in self?.session.showPageSource() }
        addContextMenuItem("Check for Previous Versions", systemImage: BrowserMenuIcon.archive, enabled: canCheckArchive, to: menu) { [weak self] in self?.session.openArchive() }
        addContextMenuItem("Save Page As…", systemImage: BrowserMenuIcon.save, enabled: canSavePage, to: menu) { [weak self] in Task { await self?.savePage() } }
        addContextMenuItem("Print Page…", systemImage: BrowserMenuIcon.print, enabled: true, to: menu) { [weak self] in self?.printPage() }
        menu.popUp(positioning: nil, at: location, in: view)
    }

    fileprivate func showPendingContextMenu(link: URL?, imageLine: String?) {
        guard let location = pendingContextMenuLocation,
              let view = pendingContextMenuView else { return }
        pendingContextMenuLocation = nil
        pendingContextMenuView = nil
        if let link {
            showLinkContextMenu(for: link, imageLine: imageLine, at: location, in: view)
        } else {
            showPageContextMenu(at: location, in: view)
        }
    }

    func stopUsingClientCertificateForCurrentPage() {
        guard let url = pageInformation?.url ?? committedURL else { return }
        let account = clientCertificates.accountToken
        Task { @MainActor [weak self] in
        guard let self, clientCertificates.accountToken == account,
              await clientCertificates.stopUsing(for: url), clientCertificates.accountToken == account,
              (pageInformation?.url ?? committedURL) == url else { return }
        if var information = pageInformation {
            information.clientCertificateAssociation = nil
            pageInformation = information
        }
        }
    }

    func stopUsingClientCertificateForPendingChallenge(id: UUID) {
        guard let prompt = clientCertificatePrompt, prompt.id == id else { return }
        let account = clientCertificates.accountToken
        Task { @MainActor [weak self] in
            guard let self, clientCertificates.accountToken == account,
                  await clientCertificates.stopUsing(for: prompt.target.url),
                  clientCertificates.accountToken == account else { return }
            session.cancelClientCertificatePrompt(id: id)
        }
    }

    private func updateHoveredLinkModifiers(_ flags: NSEvent.ModifierFlags) {
        guard let href = session.hoveredDestination else { return }
        var modifiers: LinkModifierKeys = []
        if flags.contains(.command) { modifiers.insert(.command) }
        if flags.contains(.shift) { modifiers.insert(.shift) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.control) { modifiers.insert(.control) }
        session.updateHoveredLink(href, modifiers: modifiers)
    }

    func useClientCertificate(_ certificateID: UUID, scope: ClientCertificateScopeChoice, for promptID: UUID) {
        guard let prompt = clientCertificatePrompt, prompt.id == promptID else { return }
        let account = clientCertificates.accountToken
        Task { [weak self] in
            guard let self, clientCertificates.accountToken == account,
                  await clientCertificates.associate(certificateID: certificateID, with: prompt.target.url, scope: scope),
                  clientCertificates.accountToken == account else { return }
            session.resumeClientCertificatePrompt(id: prompt.id)
        }
    }

    func showPageInformation() {
        guard let snapshot = session.pageSnapshot else { return }
        let resourceURL = ViewSourceURL.unwrap(snapshot.url) ?? snapshot.url
        var information = PageInformation(url: snapshot.url, status: snapshot.status, meta: snapshot.meta,
            byteCount: snapshot.body.count, mimeType: snapshot.mimeType, responseWasCached: snapshot.wasCached,
            responseReceivedAt: snapshot.receivedAt, identity: snapshot.serverIdentity, trusted: nil,
            clientCertificate: snapshot.clientCertificate,
            clientCertificateAssociation: snapshot.clientCertificate.flatMap { certificate in
                ClientCertificateAssociation.mostSpecific(matching: resourceURL,
                    in: clientCertificates.associations.filter { $0.certificateID == certificate.id })
            })
        Task {
            if let endpoint = CapsuleEndpoint(url: resourceURL) { information.trusted = await trustStore?.identity(for: endpoint) }
            pageInformation = information
        }
    }

    fileprivate func prepareHistorySwipe(direction: BrowserHistorySwipeDirection, viewportWidth: CGFloat, offset: CGFloat) async -> Bool {
        historySwipeGeneration &+= 1
        let generation = historySwipeGeneration
        historySwipePresentation = HistorySwipePresentation(direction: direction, viewportWidth: viewportWidth, offset: 0, isReady: false)
        guard let id = await session.prepareHistoryPreview(direction: direction == .back ? .back : .forward),
              generation == historySwipeGeneration else {
            if generation == historySwipeGeneration { historySwipePresentation = nil }
            return false
        }
        pendingHistorySwipe = PendingHistorySwipe(id: id)
        historySwipePresentation = HistorySwipePresentation(direction: direction, viewportWidth: viewportWidth,
            offset: direction.sign * min(abs(offset), viewportWidth), isReady: true)
        return true
    }

    fileprivate func updateHistorySwipe(offset: CGFloat) {
        guard var presentation = historySwipePresentation, presentation.isReady else { return }
        presentation.offset = presentation.direction.sign
            * min(max(0, presentation.direction.sign * offset), presentation.viewportWidth)
        historySwipePresentation = presentation
    }

    fileprivate func finishHistorySwipe(cancelled: Bool) {
        guard let pendingHistorySwipe, var presentation = historySwipePresentation else { return }
        let generation = historySwipeGeneration
        if !cancelled {
            session.acceptHistoryPreview(id: pendingHistorySwipe.id)
        }
        presentation.offset = cancelled ? 0 : presentation.direction.sign * presentation.viewportWidth
        withAnimation(.easeOut(duration: 0.22)) {
            historySwipePresentation = presentation
        }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(230))
            if !cancelled {
                for _ in 0..<20 where self?.session.isRestoringHistoryScroll == true {
                    try? await Task.sleep(for: .milliseconds(25))
                }
            }
            guard self?.historySwipeGeneration == generation else { return }
            self?.historySwipePresentation = nil
            self?.pendingHistorySwipe = nil
        }
    }

    fileprivate func cancelHistorySwipePreparation() {
        historySwipeGeneration += 1
        session.cancelHistoryPreview()
        pendingHistorySwipe = nil
        historySwipePresentation = nil
    }

    static func contentStyle(themes: ContentThemeStore, preferences: BrowserPreferences, zoom: Double, hides: Bool, inset: Double) -> BrowserContentStyle {
        var theme = themes.resolved?.css ?? ContentThemeStylesheets.base + ContentThemeStylesheets.print
        // This style arrives in the document's first HTML chunk, before WebKit can paint
        // its initial y=0 layout. restoreScrollPosition reveals it only after the saved
        // offset has crossed the compositor boundary, avoiding a one-frame top flash.
        if hides {
            theme += """

            /* A restored document remains hidden until its saved scroll offset is applied. */
            html {
              visibility: hidden !important;
            }

            """
        }
        theme += "\n" + preferences.contentWidth.css
        theme += "\n:root { --mt-content-top-inset: \(inset)px; --mt-image-pending-icon: \(InlineImagePresentationScript.pendingIconCSS); --mt-image-failed-icon: \(InlineImagePresentationScript.failureIconCSS); }"
        // Screen-only zoom survives navigation without overriding print's 100% scale.
        theme += """

        /* Screen zoom follows the reader's setting while printing stays at its own scale. */
        @media screen {
          /* Apply zoom to the complete document. */
          :root {
            zoom: \(zoom);
          }
        }

        """
        return BrowserContentStyle(css: theme, palette: themes.resolved?.palette ?? .fallback,
            appearance: themes.resolved?.appearance ?? .dark)
    }

}

// WKWebView adopts NSTextFinderClient but does not implement its optional
// `isEditable` property. AppKit treats an omitted value as true and therefore
// exposes Replace in the native Find bar for an otherwise read-only web page.
// Supplying the client value keeps AppKit's native Find behavior while limiting
// its operations to those a browser document actually supports.
extension WKWebView {
    @objc var isEditable: Bool { false }
}

@available(macOS 26.0, *)
struct StreamingWebViewPrototype: View {
    @ObservedObject var browser: BrowserModel
    /// Drives WebKit's native find bar, including its system matching, highlighting,
    /// match count, wrap behavior, and keyboard navigation.
    @Binding var findNavigatorIsPresented: Bool
    /// Content remains edge-to-edge, while the overlay scroller starts below Major
    /// Tom's custom navigation and Favorites chrome as it does for a system toolbar.
    let scrollerTopInset: CGFloat

    var body: some View {
        GeometryReader { geometry in
            let swipe = browser.historySwipePresentation
            let isBack = swipe?.direction == .back
            let activeOffset = isBack && swipe?.isReady == true
                ? max(0, swipe?.offset ?? 0)
                : 0
            let stagedOffset: CGFloat = {
                guard let swipe, swipe.isReady else { return geometry.size.width }
                return swipe.direction == .forward
                    ? geometry.size.width + min(0, swipe.offset)
                    : 0
            }()

            ZStack(alignment: .topLeading) {
                WebView(browser.historySwipePage)
                    .offset(x: stagedOffset)
                    .opacity(swipe == nil ? 0 : 1)
                    .shadow(
                        color: .black.opacity(swipe?.direction == .forward ? 0.28 : 0),
                        radius: 12,
                        x: -4
                    )
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                    .zIndex(swipe?.direction == .forward ? 2 : 0)

                WebView(browser.page)
                    .webViewTextSelection(.enabled)
                    .webViewMagnificationGestures(.enabled)
                    .findNavigator(isPresented: $findNavigatorIsPresented)
                    .offset(x: activeOffset)
                    .shadow(
                        color: .black.opacity(isBack ? 0.28 : 0),
                        radius: 12,
                        x: -4
                    )
                    .zIndex(isBack ? 2 : 1)
            }
            .clipped()
            .background(WebViewScrollerInsetAccessor(browser: browser, topInset: scrollerTopInset))
            .onChange(of: scrollerTopInset, initial: true) { _, inset in
                browser.updateImageViewportTopInset(inset)
            }
        }
    }
}

@available(macOS 26.0, *)
private struct WebViewScrollerInsetAccessor: NSViewRepresentable {
    let browser: BrowserModel
    let topInset: CGFloat

    @MainActor
    final class Coordinator {
        weak var scrollView: NSScrollView?
        weak var webView: WKWebView?
        weak var browser: BrowserModel?
        var eventMonitor: Any?
        var scrollObservation: NSObjectProtocol?
        var liveScrollObservation: NSObjectProtocol?
        var discoveryTask: Task<Void, Never>?
        var horizontalDelta: CGFloat = 0
        var verticalDelta: CGFloat = 0
        var lastHorizontalDelta: CGFloat = 0
        var claimedSwipe = false
        var navigationTriggered = false
        var isTrackingGesture = false
        var gestureEnded = false
        var gestureCancelled = false
        var preparationRequestID: UUID?
        var swipeDirection: BrowserHistorySwipeDirection?

        func installEventMonitorIfNeeded() {
            guard eventMonitor == nil else { return }
            eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { @MainActor [weak self] event in
                self?.handleScrollWheel(event) ?? event
            }
        }

        private func handleScrollWheel(_ event: NSEvent) -> NSEvent? {
            guard event.type == .scrollWheel,
                  let webView,
                  !webView.isHiddenOrHasHiddenAncestor,
                  event.window === webView.window,
                  webView.bounds.contains(webView.convert(event.locationInWindow, from: nil)) else {
                return event
            }

            if event.scrollingDeltaY != 0 {
                cancelFindIndicator(in: webView.window?.contentView)
            }

            // Only high-resolution trackpad events participate in horizontal history
            // navigation. A conventional mouse wheel still dismisses the indicator.
            guard event.hasPreciseScrollingDeltas else { return event }

            if !event.momentumPhase.isEmpty {
                // A single physical swipe commonly continues as several momentum events.
                // Keep consuming that whole stream so it cannot begin a second traversal.
                if event.momentumPhase.contains(.ended) || event.momentumPhase.contains(.cancelled) {
                    resetGesture()
                }
                return claimedSwipe ? nil : event
            }

            if event.phase.contains(.began) {
                resetGesture()
                isTrackingGesture = true
            } else if event.phase.contains(.mayBegin), !isTrackingGesture {
                resetGesture()
                isTrackingGesture = true
            } else if !isTrackingGesture {
                resetGesture()
                isTrackingGesture = true
            }
            horizontalDelta += event.scrollingDeltaX
            verticalDelta += event.scrollingDeltaY
            if event.scrollingDeltaX != 0 {
                lastHorizontalDelta = event.scrollingDeltaX
            }

            if !claimedSwipe,
               abs(horizontalDelta) >= 48,
               abs(horizontalDelta) > abs(verticalDelta) * 1.5 {
                let direction: BrowserHistorySwipeDirection = horizontalDelta > 0 ? .back : .forward
                let canNavigate = direction == .back
                    ? browser?.session.canGoBack == true
                    : browser?.session.canGoForward == true
                if canNavigate {
                    beginSwipe(direction: direction, in: webView)
                }
            }

            if navigationTriggered {
                browser?.updateHistorySwipe(offset: horizontalDelta)
            }

            let ended = event.phase.contains(.ended) || event.phase.contains(.cancelled)
            if ended {
                gestureEnded = true
                gestureCancelled = event.phase.contains(.cancelled) || !shouldCommitSwipe(in: webView)
                if navigationTriggered {
                    browser?.finishHistorySwipe(cancelled: gestureCancelled)
                }
            }
            return claimedSwipe ? nil : event
        }

        func observeScrolling(in scrollView: NSScrollView) {
            guard self.scrollView !== scrollView || scrollObservation == nil else { return }
            stopObservingScrolling()
            self.scrollView = scrollView
            scrollView.contentView.postsBoundsChangedNotifications = true
            scrollObservation = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification,
                object: scrollView.contentView,
                queue: .main
            ) { [weak self, weak scrollView] _ in
                MainActor.assumeIsolated {
                    guard let self, let scrollView else { return }
                    self.cancelFindIndicator(in: scrollView.window?.contentView)
                }
            }
            liveScrollObservation = NotificationCenter.default.addObserver(
                forName: NSScrollView.didLiveScrollNotification,
                object: scrollView,
                queue: .main
            ) { [weak self, weak scrollView] _ in
                MainActor.assumeIsolated {
                    guard let self, let scrollView else { return }
                    self.cancelFindIndicator(in: scrollView.window?.contentView)
                }
            }
        }

        func stopObservingScrolling() {
            if let scrollObservation {
                NotificationCenter.default.removeObserver(scrollObservation)
                self.scrollObservation = nil
            }
            if let liveScrollObservation {
                NotificationCenter.default.removeObserver(liveScrollObservation)
                self.liveScrollObservation = nil
            }
        }

        @discardableResult
        private func cancelFindIndicator(in view: NSView?) -> Bool {
            guard let view else { return false }
            // WebKit currently leaves AppKit's transient active-match indicator fixed
            // in window coordinates while its asynchronously scrolled content moves.
            // AppKit exposes cancellation for exactly this lifecycle transition. The
            // platform Find bar wraps its NSTextFinder, so route the documented action
            // through the bar control target that implements it.
            let action = #selector(NSTextFinder.cancelFindIndicator)
            if let target = (view as? NSControl)?.target as? NSObject,
               target.responds(to: action) {
                target.perform(action)
                return true
            }
            for subview in view.subviews {
                if cancelFindIndicator(in: subview) { return true }
            }
            return false
        }

        private func beginSwipe(direction: BrowserHistorySwipeDirection, in webView: WKWebView) {
            // Prepare the adjacent model entry without moving the model cursor. The cursor
            // changes only if the user releases beyond the commit threshold below.
            claimedSwipe = true
            swipeDirection = direction
            let requestID = UUID()
            preparationRequestID = requestID
            browserNavigationLogger.notice(
                "trackpad swipe recognized direction=\(direction == .back ? "back" : "forward", privacy: .public) deltaX=\(self.horizontalDelta) canBack=\(self.browser?.session.canGoBack ?? false) canForward=\(self.browser?.session.canGoForward ?? false)"
            )
            Task { @MainActor [weak self, weak webView] in
                guard let self, let webView, let browser = self.browser else { return }
                let prepared = await browser.prepareHistorySwipe(
                    direction: direction,
                    viewportWidth: webView.bounds.width,
                    offset: self.horizontalDelta
                )
                guard self.preparationRequestID == requestID, prepared else { return }
                self.navigationTriggered = true
                browser.updateHistorySwipe(offset: self.horizontalDelta)
                if self.gestureEnded {
                    browser.finishHistorySwipe(cancelled: self.gestureCancelled)
                }
            }
        }

        private func shouldCommitSwipe(in webView: WKWebView) -> Bool {
            guard let swipeDirection, webView.bounds.width > 0 else { return false }
            let progress = swipeDirection.sign * horizontalDelta / webView.bounds.width
            let releaseVelocity = swipeDirection.sign * lastHorizontalDelta
            return progress >= 0.22 || releaseVelocity >= 10
        }

        private func resetGesture() {
            if claimedSwipe, !navigationTriggered {
                browser?.cancelHistorySwipePreparation()
            }
            horizontalDelta = 0
            verticalDelta = 0
            lastHorizontalDelta = 0
            claimedSwipe = false
            navigationTriggered = false
            isTrackingGesture = false
            gestureEnded = false
            gestureCancelled = false
            preparationRequestID = nil
            swipeDirection = nil
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        context.coordinator.browser = browser
        context.coordinator.installEventMonitorIfNeeded()
        updateScroller(from: view, coordinator: context.coordinator)
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.browser = browser
        updateScroller(from: view, coordinator: context.coordinator)
    }

    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
        coordinator.discoveryTask?.cancel()
        coordinator.discoveryTask = nil
        coordinator.stopObservingScrolling()
        if let eventMonitor = coordinator.eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
            coordinator.eventMonitor = nil
        }
    }

    private func updateScroller(from view: NSView, coordinator: Coordinator) {
        let inset = max(0, topInset)
        coordinator.discoveryTask?.cancel()
        coordinator.discoveryTask = Task { @MainActor [weak view, weak coordinator] in
            for _ in 0..<20 {
                guard !Task.isCancelled, let view, let coordinator else { return }
                if coordinator.webView == nil {
                    let webViews = hostedWebViews(for: view)
                    for webView in webViews {
                        webView.allowsBackForwardNavigationGestures = false
                        if let scrollView = firstScrollView(in: webView) {
                            var insets = scrollView.scrollerInsets
                            insets.top = inset
                            scrollView.scrollerInsets = insets
                        }
                    }
                    // The active WebView is the latter Z-stack child; the staging view
                    // precedes it and is noninteractive even while it is visible.
                    coordinator.webView = webViews.last
                    if let webView = coordinator.webView {
                        if let scrollView = firstScrollView(in: webView) {
                            coordinator.observeScrolling(in: scrollView)
                        }
                        browserNavigationLogger.notice(
                            "installed model-owned trackpad history gesture webViews=\(webViews.count)"
                        )
                    }
                }
                if coordinator.scrollView == nil {
                    if let scrollView = enclosingScrollView(for: view) {
                        coordinator.observeScrolling(in: scrollView)
                    }
                }
                guard let scrollView = coordinator.scrollView else {
                    try? await Task.sleep(for: .milliseconds(50))
                    continue
                }
                var insets = scrollView.scrollerInsets
                if insets.top != inset {
                    insets.top = inset
                    scrollView.scrollerInsets = insets
                }
                if coordinator.webView != nil { return }
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
    }

    private func enclosingScrollView(for view: NSView) -> NSScrollView? {
        var ancestor = view.superview
        while let candidate = ancestor {
            if let scrollView = firstScrollView(in: candidate) { return scrollView }
            ancestor = candidate.superview
        }
        return nil
    }

    private func hostedWebViews(for view: NSView) -> [WKWebView] {
        guard !view.isHiddenOrHasHiddenAncestor,
              let root = view.window?.contentView else { return [] }
        return visibleWebViews(in: root)
    }

    private func visibleWebViews(in view: NSView) -> [WKWebView] {
        if let webView = view as? WKWebView,
           !webView.isHiddenOrHasHiddenAncestor {
            return [webView]
        }
        return view.subviews.flatMap(visibleWebViews(in:))
    }

    private func firstScrollView(in view: NSView) -> NSScrollView? {
        if let scrollView = view as? NSScrollView { return scrollView }
        for child in view.subviews {
            if let scrollView = firstScrollView(in: child) { return scrollView }
        }
        return nil
    }
}
