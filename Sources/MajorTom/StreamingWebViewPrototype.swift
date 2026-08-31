import AppKit
import Combine
import Foundation
import MajorTomCore
import SwiftUI
import WebKit

@available(macOS 26.0, *)
@MainActor
private final class ContextMenuScriptHandler: NSObject, WKScriptMessageHandler {
    static let name = "majorTomContextMenu"

    static let userScript = WKUserScript(
        source: """
        document.addEventListener('contextmenu', (event) => {
            const target = event.target instanceof Element ? event.target : event.target?.parentElement;
            const anchor = target?.closest('a[href]');
            const selection = window.getSelection();
            if (!anchor && selection && !selection.isCollapsed && selection.toString().trim() !== '') {
                // Preserve WebKit's native selected-text menu: Copy, Look Up,
                // Translate, Speech, and Services all depend on WebKit handling it.
                // A right-click can itself select/highlight link text before this event,
                // so a link under the pointer must take precedence over that selection.
                return;
            }
            event.preventDefault();
            window.webkit.messageHandlers.\(name).postMessage(anchor?.href ?? '');
        }, true);
        """,
        injectionTime: .atDocumentStart,
        forMainFrameOnly: true,
        in: .defaultClient
    )

    weak var browser: BrowserModel?

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        let href = message.body as? String
        Task { @MainActor [weak browser] in
            browser?.showPendingContextMenu(link: href.flatMap(URL.init(string:)))
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
    static let name = "majorTomLinkHover"

    static let userScript = WKUserScript(
        source: """
        (() => {
            var last = null;
            var hoveredAnchor = null;
            const post = (anchor, event) => {
                const href = anchor ? anchor.href : '';
                const value = href || '';
                const modifiers = event ? [event.metaKey, event.shiftKey, event.altKey, event.ctrlKey] : [false, false, false, false];
                const signature = value + '|' + modifiers.join(',');
                if (signature === last) { return; }
                last = signature;
                window.webkit.messageHandlers.\(name).postMessage({
                    href: value,
                    command: modifiers[0],
                    shift: modifiers[1],
                    option: modifiers[2],
                    control: modifiers[3]
                });
            };
            const anchorFor = (node) => {
                const element = node instanceof Element ? node : node?.parentElement;
                return element ? element.closest('a[href]') : null;
            };
            // `.href` is already absolute, resolved against the document's <base>.
            document.addEventListener('mouseover', (event) => {
                const anchor = anchorFor(event.target);
                hoveredAnchor = anchor;
                post(anchor, event);
            }, true);
            document.addEventListener('mousemove', (event) => {
                const anchor = anchorFor(event.target);
                if (anchor) { post(anchor, event); }
            }, true);
            document.addEventListener('mouseout', (event) => {
                if (!anchorFor(event.relatedTarget)) {
                    hoveredAnchor = null;
                    post(null, event);
                }
            }, true);
            document.addEventListener('keydown', (event) => {
                if (hoveredAnchor) { post(hoveredAnchor, event); }
            }, true);
            document.addEventListener('keyup', (event) => {
                if (hoveredAnchor) { post(hoveredAnchor, event); }
            }, true);
            // Spec 18.4 covers focus as well as hover.
            document.addEventListener('focusin', (event) => {
                const anchor = anchorFor(event.target);
                post(anchor, null);
            }, true);
            document.addEventListener('focusout', () => post(null, null), true);
            window.addEventListener('blur', () => post(null, null));
        })();
        """,
        injectionTime: .atDocumentStart,
        forMainFrameOnly: true,
        in: .defaultClient
    )

    weak var browser: BrowserModel?

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        Task { @MainActor [weak browser] in
            guard let payload = message.body as? [String: Any] else { return }
            var modifiers: LinkModifierKeys = []
            if payload["command"] as? Bool == true { modifiers.insert(.command) }
            if payload["shift"] as? Bool == true { modifiers.insert(.shift) }
            if payload["option"] as? Bool == true { modifiers.insert(.option) }
            if payload["control"] as? Bool == true { modifiers.insert(.control) }
            browser?.updateHoveredLink(payload["href"] as? String, modifiers: modifiers)
        }
    }
}

/// Keeps the current document's vertical offset on the native side of the WebKit
/// boundary. Major Tom owns navigation history itself, so WebKit cannot restore this
/// state for us when a cached response is rendered into a new document.
@available(macOS 26.0, *)
@MainActor
private final class ScrollPositionScriptHandler: NSObject, WKScriptMessageHandler {
    static let name = "majorTomScrollPosition"

    static let userScript = WKUserScript(
        source: """
        (() => {
          var scheduled = false;
          const report = () => {
            scheduled = false;
            window.webkit.messageHandlers.\(name).postMessage(Math.max(0, window.scrollY));
          };
          const schedule = () => {
            if (scheduled) { return; }
            scheduled = true;
            requestAnimationFrame(report);
          };
          addEventListener('scroll', schedule, { passive: true });
          addEventListener('pagehide', report);
          addEventListener('DOMContentLoaded', schedule);
        })();
        """,
        injectionTime: .atDocumentStart,
        forMainFrameOnly: true,
        in: .defaultClient
    )

    weak var browser: BrowserModel?

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard let offset = message.body as? Double, offset.isFinite else { return }
        browser?.recordScrollPosition(offset, from: message.frameInfo.request.url)
    }
}

/// Handles link activations whose modifier state is not reliably preserved in
/// WebKit's navigation action (notably Shift-Command-click and middle-click).
@available(macOS 26.0, *)
@MainActor
private final class LinkActivationScriptHandler: NSObject, WKScriptMessageHandler {
    static let name = "majorTomLinkActivation"

    static let userScript = WKUserScript(
        source: """
        (() => {
        let suppressNextClick = false;
        document.addEventListener('mousedown', (event) => {
            const target = event.target instanceof Element ? event.target : event.target?.parentElement;
            const anchor = target?.closest('a[href]');
            if (!anchor) { return; }
            // DOM button numbers are left=0, middle=1, right=2. Control-click is
            // deliberately left to the context-menu handler.
            const middle = event.button === 1;
            const foregroundTab = event.button === 0 && event.metaKey && event.shiftKey;
            if (!middle && !foregroundTab) { return; }
            event.preventDefault();
            event.stopPropagation();
            suppressNextClick = true;
            window.webkit.messageHandlers.\(name).postMessage({
                href: anchor.href,
                activation: middle ? 'newBackgroundTab' : 'newForegroundTab'
            });
        }, true);
        document.addEventListener('click', (event) => {
            if (!suppressNextClick && !(event.button === 0 && event.metaKey && event.shiftKey)) { return; }
            event.preventDefault();
            event.stopPropagation();
            suppressNextClick = false;
        }, true);
        document.addEventListener('auxclick', (event) => {
            if (event.button !== 1) { return; }
            event.preventDefault();
            event.stopPropagation();
            suppressNextClick = false;
        }, true);
        })();
        """,
        injectionTime: .atDocumentStart,
        forMainFrameOnly: true,
        in: .defaultClient
    )

    weak var browser: BrowserModel?

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard let payload = message.body as? [String: Any],
              let href = payload["href"] as? String,
              let url = URL(string: href),
              let activation = payload["activation"] as? String else { return }
        Task { @MainActor [weak browser] in
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

    static let userScript = WKUserScript(
        source: """
        document.addEventListener('click', (event) => {
            if (event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) { return; }
            if (event.button !== 0) { return; }
            const target = event.target instanceof Element ? event.target : event.target?.parentElement;
            const anchor = target?.closest('a[href]');
            if (!anchor) { return; }
            const line = anchor.closest('.link-line[data-mt-expandable]');
            if (!line || !line.id) { return; }
            event.preventDefault();
            event.stopPropagation();
            window.webkit.messageHandlers.\(name).postMessage({ id: line.id, href: anchor.href });
        }, true);
        """,
        injectionTime: .atDocumentStart,
        forMainFrameOnly: true,
        in: .defaultClient
    )

    weak var browser: BrowserModel?

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard let body = message.body as? [String: Any],
              let identifier = body["id"] as? String,
              let href = body["href"] as? String,
              let url = URL(string: href) else { return }
        Task { @MainActor [weak browser] in
            browser?.toggleInlineImage(lineIdentifier: identifier, url: url)
        }
    }
}

/// Enriches inline-image captions once WebKit has decoded the image and therefore knows
/// its intrinsic dimensions. Metadata supplied after a streamed Gemini response finishes
/// can call the same function, and the resize observer keeps the `scaled` marker accurate
/// when the window changes size.
@available(macOS 26.0, *)
@MainActor
private enum InlineImagePresentationScript {
    static let userScript = WKUserScript(
        source: """
        (() => {
          const enhance = (image) => {
            if (!(image instanceof HTMLImageElement) || !image.matches('[data-mt-inline-image]')) { return; }
            const figure = image.closest('figure');
            const caption = figure?.querySelector('figcaption');
            if (!figure || !caption) { return; }

            const update = () => {
              if (!image.naturalWidth || !image.naturalHeight) { return; }
              const parts = [image.dataset.mtFilename || image.alt || 'Image'];
              if (image.dataset.mtMime) { parts.push(image.dataset.mtMime); }
              if (image.dataset.mtSize) { parts.push(image.dataset.mtSize); }
              parts.push(`${image.naturalWidth} x ${image.naturalHeight}`);
              const rendered = image.getBoundingClientRect();
              if (rendered.width + 0.5 < image.naturalWidth || rendered.height + 0.5 < image.naturalHeight) {
                parts.push('scaled');
              }
              caption.textContent = parts.join(' - ');
            };

            if (image.complete) { update(); }
            image.decode?.().then(update).catch(() => {});
            if (!image._majorTomResizeObserver && typeof ResizeObserver !== 'undefined') {
              image._majorTomResizeObserver = new ResizeObserver(update);
              image._majorTomResizeObserver.observe(image);
            }
          };

          window.majorTomEnhanceInlineImage = enhance;
          document.addEventListener('load', (event) => enhance(event.target), true);
          new MutationObserver((records) => {
            for (const record of records) {
              for (const node of record.addedNodes) {
                if (!(node instanceof Element)) { continue; }
                if (node.matches?.('[data-mt-inline-image]')) { enhance(node); }
                node.querySelectorAll?.('[data-mt-inline-image]').forEach(enhance);
              }
            }
          }).observe(document, { childList: true, subtree: true });
        })();
        """,
        injectionTime: .atDocumentStart,
        forMainFrameOnly: true,
        in: .defaultClient
    )
}

/// Makes only multiline preformatted blocks collapsible.
///
/// The document itself contains no executable script. This runs in WebKit's isolated
/// client world, outside capsule content and its CSP, and progressively enhances the
/// native details/summary markup as streamed lines arrive.
@available(macOS 26.0, *)
@MainActor
private enum PreformattedBlockPresentationScript {
    static let userScript = WKUserScript(
        source: """
        (() => {
          const enhance = (block) => {
            if (!(block instanceof HTMLDetailsElement) || !block.matches('.pre-block')) { return; }
            const pre = block.querySelector(':scope > pre');
            if (!pre) { return; }
            const multiline = block.querySelectorAll('.pre-line').length > 1;
            block.classList.toggle('multiline', multiline);
            if (multiline) {
              pre.tabIndex = 0;
              pre.setAttribute('role', 'button');
              pre.setAttribute('aria-label', 'Collapse preformatted text');
            } else {
              pre.removeAttribute('tabindex');
              pre.removeAttribute('role');
              pre.removeAttribute('aria-label');
            }
          };

          const containingBlocks = (node) => {
            if (!(node instanceof Element)) { return []; }
            const blocks = Array.from(node.querySelectorAll?.('.pre-block') || []);
            const containing = node.closest?.('.pre-block');
            if (containing) { blocks.push(containing); }
            return blocks;
          };

          new MutationObserver((records) => {
            const blocks = new Set();
            for (const record of records) {
              containingBlocks(record.target).forEach((block) => blocks.add(block));
              for (const node of record.addedNodes) {
                containingBlocks(node).forEach((block) => blocks.add(block));
              }
            }
            blocks.forEach(enhance);
          }).observe(document, { childList: true, subtree: true });

          document.addEventListener('DOMContentLoaded', () => {
            document.querySelectorAll('.pre-block').forEach(enhance);
          });

          const expandedMultilineBlockFor = (target) => {
            const element = target instanceof Element ? target : target?.parentElement;
            const pre = element?.closest('pre');
            const block = pre?.parentElement;
            return block?.matches('details.pre-block.multiline[open]') ? block : null;
          };

          const collapse = (block) => {
            block.open = false;
            block.querySelector(':scope > summary')?.focus({ preventScroll: true });
          };

          document.addEventListener('click', (event) => {
            if (event.button !== 0 || event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) { return; }
            const block = expandedMultilineBlockFor(event.target);
            if (!block || !window.getSelection()?.isCollapsed) { return; }
            collapse(block);
          }, true);

          document.addEventListener('keydown', (event) => {
            if (event.key !== 'Enter' && event.key !== ' ') { return; }
            const block = expandedMultilineBlockFor(event.target);
            if (!block) { return; }
            event.preventDefault();
            collapse(block);
          }, true);
        })();
        """,
        injectionTime: .atDocumentStart,
        forMainFrameOnly: true,
        in: .defaultClient
    )
}

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

    private struct LoadedInlineImage {
        let mimeType: String
        let byteCount: Int
    }

    private struct DecodedDataImage {
        let data: Data
        let mimeType: String
    }

    struct InputPrompt: Identifiable {
        let id = UUID()
        let target: GeminiRequestTarget
        let message: String
        let isSensitive: Bool
        /// Text kept from an earlier, cancelled attempt at this same prompt.
        var initialText: String = ""
    }

    struct ClientCertificatePrompt: Identifiable {
        let id = UUID()
        let target: GeminiRequestTarget
        let status: Int
        let message: String
        let attemptedCertificate: ClientCertificateDescriptor?
        let matchingCertificateIsUnavailable: Bool
        let matchingCertificateIsInvalid: Bool
    }

    @Published var locationText = "gemini://gemi.dev/"
    @Published private(set) var committedURL: URL?
    @Published private(set) var isLoading = false
    @Published private(set) var statusText = "Ready"
    /// Destination of the link under the pointer, or focused by keyboard (spec 18.4).
    @Published private(set) var hoveredLinkURL: String?
    /// The unformatted destination retained so native modifier changes can refresh the
    /// hover message without requiring another mouse-move event from WebKit.
    private var hoveredLinkDestination: String?
    @Published private(set) var title = "New Tab"
    @Published private(set) var documentTitle: String?
    /// The current capsule's favicon emoji, when it offers one.
    @Published private(set) var favicon: String?
    /// Set when the tab is showing one of Major Tom's own pages instead of a document.
    @Published private(set) var internalPage: InternalPage?
    @Published private(set) var canSavePage = false
    @Published private(set) var canShowSource = false
    @Published private(set) var canGoBack = false
    @Published private(set) var canGoForward = false
    @Published var validationMessage: String?
    @Published var trustPrompt: TrustPrompt?
    @Published var inputPrompt: InputPrompt?
    @Published var clientCertificatePrompt: ClientCertificatePrompt?
    /// Set to present the Page Info panel; cleared when it is dismissed.
    @Published var pageInformation: PageInformation?
    /// The identity presented by the capsule serving the current page, kept for Page Info.
    @Published private(set) var serverIdentity: PresentedServerIdentity?
    /// The client identity actually offered for the request that produced this page.
    @Published private(set) var usedClientCertificate: ClientCertificateDescriptor?
    private var responseStatus: Int?
    private var responseMeta = ""
    @Published var inputValidationMessage: String?
    @Published private(set) var pageZoom = 1.0
    @Published private(set) var retryNotBefore: Date?
    /// False until WebKit has completely presented this tab's first document. The view
    /// keeps WebKit transparent over a content-theme placeholder until then, preventing
    /// its default white/black backing from flashing during creation or restoration.
    @Published private(set) var hasPresentedInitialDocument = false
    /// Keeps a history entry that needs a nonzero offset behind the same placeholder
    /// until WebKit has laid it out and the offset has been applied.
    @Published private(set) var isRestoringHistoryScroll = false

    let page: WebPage

    /// Set by the owning window session. A tab cannot create tabs or windows itself.
    var openInNewTab: ((URL, _ inBackground: Bool) -> Void)?
    var openInNewWindow: ((URL) -> Void)?

    private let documentStore: BrowserDocumentStore
    private let resourceStore: BrowserResourceStore
    private let router: BrowserNavigationRouter
    private let transport = GeminiTransport()
    private let settings = BrowserSettingsStore.shared
    private let clientCertificates = ClientCertificateStore.shared
    private let trustPolicy = ServerTrustPolicy()
    private let trustStore: TrustedIdentityStore?
    private let renderer = HTMLDocumentStreamRenderer()
    private var cancellables = Set<AnyCancellable>()

    private var navigationTask: Task<Void, Never>?
    private var documentContinuation: AsyncThrowingStream<Data, any Error>.Continuation?
    private var trustContinuation: CheckedContinuation<Bool, Never>?
    private var history: [URL] = []
    private var historyIndex = -1
    /// Session-only page offsets, keyed by history entry rather than URL so two visits to
    /// the same address can retain different reading positions. Deliberately excluded
    /// from `RestoredTabState`: quitting the app starts these positions over at the top.
    private var historyScrollPositions: [Int: Double] = [:]
    /// While a traversal's replacement document is loading, its initial scroll events
    /// must not overwrite the offset we are about to restore.
    private var pendingScrollRestoration: (historyIndex: Int, offset: Double)?
    /// The opaque URL of the document currently hosted by WebKit. Script messages from
    /// a page being replaced can arrive just after the next entry commits; checking this
    /// identity prevents that late message from being filed under the new history entry.
    private var activeWebDocumentURL: URL?
    private var cachedPages: [URL: CachedPage] = [:]
    /// Answers typed but not submitted, so cancelling a prompt and returning to it does
    /// not lose the work. Sensitive prompts are deliberately never recorded here.
    private var inputDrafts: [URL: String] = [:]
    private var pendingClientCertificateChallenge: (
        target: GeminiRequestTarget,
        disposition: HistoryDisposition,
        renderAsSource: Bool
    )?
    private var hasStarted = false
    private var trustWasDeclined = false
    private var currentSourceBytes = Data()
    private var currentMIMEType = ""
    /// Tracks what has named the current document while the opening Gemtext lines stream
    /// in. A heading can replace an earlier preformatted caption; discovery is limited to
    /// the first fifteen Gemtext lines.
    private var titleClaim = GemtextTitleClaim()
    private var imageTasks: [Task<Void, Never>] = []
    private let imageLimiter = AsyncSemaphore(limit: 4)
    private var slowDownTask: Task<Void, Never>?
    private var downloadTask: Task<Void, Never>?
    private var contextMenuTargets: [ContextMenuTarget] = []
    private weak var pendingContextMenuView: NSView?
    private var pendingContextMenuLocation: NSPoint?
    private let contextMenuScriptHandler: ContextMenuScriptHandler
    private let linkHoverScriptHandler: LinkHoverScriptHandler
    private let linkActivationScriptHandler: LinkActivationScriptHandler
    private let inlineImageScriptHandler: InlineImageScriptHandler
    private let scrollPositionScriptHandler: ScrollPositionScriptHandler
    /// Numbers link lines within the current document so an expanded image can be
    /// attached to the exact line that was clicked.
    private var linkSequence = 0
    /// Line identifiers whose image is currently expanded, for toggling back off.
    private var expandedInlineImages: Set<String> = []
    private var contextSharingPicker: NSSharingServicePicker?
    private var lastPreferences: BrowserPreferences

    init(restoredState: RestoredTabState? = nil, initialURL: URL? = nil) {
        let documentStore = BrowserDocumentStore()
        let resourceStore = BrowserResourceStore()
        let router = BrowserNavigationRouter()
        let contextMenuScriptHandler = ContextMenuScriptHandler()
        let linkHoverScriptHandler = LinkHoverScriptHandler()
        let linkActivationScriptHandler = LinkActivationScriptHandler()
        let inlineImageScriptHandler = InlineImageScriptHandler()
        let scrollPositionScriptHandler = ScrollPositionScriptHandler()
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
        userContentController.add(
            linkActivationScriptHandler,
            contentWorld: .defaultClient,
            name: LinkActivationScriptHandler.name
        )
        userContentController.addUserScript(InlineImageScriptHandler.userScript)
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
        var configuration = WebPage.Configuration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController = userContentController
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
        self.contextMenuScriptHandler = contextMenuScriptHandler
        self.linkHoverScriptHandler = linkHoverScriptHandler
        self.linkActivationScriptHandler = linkActivationScriptHandler
        self.inlineImageScriptHandler = inlineImageScriptHandler
        self.scrollPositionScriptHandler = scrollPositionScriptHandler
        self.page = WebPage(
            configuration: configuration,
            navigationDecider: BrowserNavigationDecider(router: router)
        )
        self.trustStore = SharedTrustedIdentityStore.shared
        self.lastPreferences = settings.preferences
        if let restoredState {
            self.history = restoredState.history
            // Clamp at both ends. A negative or out-of-range index from an older or
            // corrupted blob previously left committedURL nil, silently discarding the
            // whole restored history.
            self.historyIndex = restoredState.history.isEmpty
                ? -1
                : min(max(restoredState.historyIndex, 0), restoredState.history.count - 1)
            self.cachedPages = Dictionary(uniqueKeysWithValues: restoredState.cachedPages.map { ($0.url, $0) })
            self.pageZoom = restoredState.zoom
            self.committedURL = self.history.indices.contains(self.historyIndex)
                ? self.history[self.historyIndex]
                : nil
            let currentCachedPage = self.committedURL.flatMap { self.cachedPages[$0] }
            self.locationText = self.committedURL?.absoluteString ?? settings.preferences.homepage
            self.title = restoredState.title
                ?? currentCachedPage?.title
                ?? self.committedURL.map(displayTitle)
                ?? "New Tab"
            self.documentTitle = restoredState.documentTitle
                ?? currentCachedPage?.documentTitle
        } else {
            self.locationText = initialURL?.absoluteString ?? settings.preferences.homepage
        }
        contextMenuScriptHandler.browser = self
        linkHoverScriptHandler.browser = self
        linkActivationScriptHandler.browser = self
        inlineImageScriptHandler.browser = self
        scrollPositionScriptHandler.browser = self

        router.openURL = { [weak self] url in
            self?.openLink(url)
        }
        router.downloadURL = { [weak self] url in
            self?.download(url)
        }
        router.openInNewTab = { [weak self] url, background in
            self?.openInNewTab?(url, background)
        }
        router.openInNewWindow = { [weak self] url in
            self?.openInNewWindow?(url)
        }
        router.canOpenInApp = { [weak self] url in
            self?.canOpenInApp(url) ?? false
        }
        settings.preferencesDidChange
            .sink { [weak self] preferences in self?.preferencesChanged(to: preferences) }
            .store(in: &cancellables)
        ModifierFlagsMonitor.shared.flagsDidChange
            .sink { [weak self] flags in self?.updateHoveredLinkModifiers(flags) }
            .store(in: &cancellables)
        updateNavigationAvailability()
    }

    var canReload: Bool {
        !isLoading && committedURL != nil && (retryNotBefore.map { Date() >= $0 } ?? true)
    }

    func start() {
        guard !hasStarted else { return }
        hasStarted = true

        if let committedURL, let cached = cachedPages[committedURL] {
            displayCachedPage(cached)
            return
        }

        // Restoring a tab is NOT a new navigation. Falling through to submitLocation()
        // committed with .new, and commit(.new) truncates the forward branch — so a
        // session saved mid-history lost every entry ahead of the cursor before the
        // user touched anything. Re-fetch as a traversal, which leaves history alone.
        if let committedURL, !history.isEmpty {
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

    var restorationState: RestoredTabState {
        RestoredTabState(
            history: history,
            historyIndex: historyIndex,
            cachedPages: Array(cachedPages.values),
            zoom: pageZoom,
            title: title,
            documentTitle: documentTitle
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

    func reload() {
        if let internalPage {
            showInternalPage(internalPage, disposition: .reload)
            return
        }
        if let committedURL, ViewSourceURL.isViewSource(committedURL) {
            if let cached = cachedPages[committedURL] {
                displayCachedPage(cached)
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
        if let committedURL, decodedDataImage(committedURL.absoluteString) != nil {
            openDataImage(committedURL, disposition: .reload)
            return
        }
        guard let committedURL, let target = makeTarget(for: committedURL) else { return }
        navigate(to: target, disposition: .reload)
    }

    /// Opens a local file, e.g. a `.gmi` dragged onto the window or opened from Finder.
    ///
    /// Local files go through the same document pipeline, cache and history as capsule
    /// responses, so View Source, Save Page As, Back/Forward and the content theme all
    /// behave identically. Nothing is fetched over the network.
    func openFile(_ url: URL, disposition: HistoryDisposition = .new) {
        guard url.isFileURL else { return }
        abandonScrollRestoration(for: disposition)

        navigationTask?.cancel()
        navigationTask = nil
        imageTasks.forEach { $0.cancel() }
        imageTasks.removeAll()
        slowDownTask?.cancel()
        slowDownTask = nil
        retryNotBefore = nil
        isLoading = false
        validationMessage = nil
        internalPage = nil
        clientCertificatePrompt = nil
        pendingClientCertificateChallenge = nil
        serverIdentity = nil
        usedClientCertificate = nil
        responseStatus = nil
        responseMeta = ""

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

        cachedPages[url] = CachedPage(
            url: url,
            mimeType: mimeType,
            body: data,
            completion: .complete,
            receivedAt: Date(),
            title: title,
            documentTitle: documentTitle
        )
        statusText = "Local file • \(data.count) bytes"
    }

    private static func mimeType(forPathExtension pathExtension: String) -> String {
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

    func stop() {
        let wasLoading = isLoading
        // A document continuation only exists while a response is actively streaming
        // into the view, which is what distinguishes "stopped partway" from "stopped
        // before anything committed".
        let wasStreamingIntoDocument = documentContinuation != nil

        // Cancellation is unconditional: stop() is also how closing a tab releases its
        // work, and spec 9.2 requires that to cancel the network work it owns.
        navigationTask?.cancel()
        navigationTask = nil
        imageTasks.forEach { $0.cancel() }
        imageTasks.removeAll()
        slowDownTask?.cancel()
        slowDownTask = nil
        trustContinuation?.resume(returning: false)
        trustContinuation = nil
        trustPrompt = nil
        clientCertificatePrompt = nil
        pendingClientCertificateChallenge = nil

        // Stopping an idle page must not touch it. This previously rewrote the cache
        // entry of a fully loaded page as .stopped and dropped its title.
        guard wasLoading else { return }

        finishCurrentDocument(message: "Loading was stopped.")
        if wasStreamingIntoDocument, let committedURL, !currentSourceBytes.isEmpty {
            cachedPages[committedURL] = CachedPage(
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
            )
        }
        isLoading = false
        statusText = "Stopped"
        if let committedURL { locationText = committedURL.absoluteString }
    }

    func goBack() {
        guard canGoBack else { return }
        prepareScrollRestoration(for: historyIndex - 1)
        historyIndex -= 1
        updateNavigationAvailability()
        navigateHistory(to: history[historyIndex])
    }

    func goForward() {
        guard canGoForward else { return }
        prepareScrollRestoration(for: historyIndex + 1)
        historyIndex += 1
        updateNavigationAvailability()
        navigateHistory(to: history[historyIndex])
    }

    fileprivate func recordScrollPosition(_ offset: Double, from documentURL: URL?) {
        guard history.indices.contains(historyIndex),
              documentURL == activeWebDocumentURL,
              pendingScrollRestoration?.historyIndex != historyIndex else { return }
        historyScrollPositions[historyIndex] = max(0, offset)
    }

    private func prepareScrollRestoration(for index: Int) {
        let offset = historyScrollPositions[index] ?? 0
        pendingScrollRestoration = (
            historyIndex: index,
            offset: offset
        )
        isRestoringHistoryScroll = offset > 0
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

    /// Prints the current document.
    ///
    /// `WebPage.exported(as: .pdf())` captures the entire scrollable document as one
    /// PDF page. Printing that PDF then shrinks a long article to a single sheet. The
    /// hosted `WKWebView` has a public macOS print operation that performs real page
    /// layout and applies `@media print`, so use it directly.
    func printPage() {
        guard committedURL != nil,
              let window = NSApplication.shared.keyWindow,
              let rootView = window.contentView,
              let webView = Self.findWebView(in: rootView),
              let info = NSPrintInfo.shared.copy() as? NSPrintInfo else {
            validationMessage = "Major Tom could not prepare this page for printing."
            return
        }
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        let operation = webView.printOperation(with: info)
        operation.jobTitle = title
        operation.showsPrintPanel = true
        operation.showsProgressPanel = true
        operation.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
    }

    /// Stops the hosted `WKWebView` from claiming dragged files.
    ///
    /// WKWebView registers for dragged types itself and consumes a drop before it can
    /// reach SwiftUI's drop destination, so dropping a `.gmi` or an image on a tab appeared
    /// to do nothing at all. Unregistering lets the drag fall through to the handler that
    /// opens the file. Nothing is lost by it: the document is not editable, so there was no
    /// legitimate drop for the web view to handle.
    ///
    /// The view does not exist until after the first layout pass, hence the bounded wait
    /// rather than a single attempt.
    func releaseWebViewDragTypes() async {
        for _ in 0..<20 {
            if let window = NSApplication.shared.keyWindow ?? NSApplication.shared.windows.first,
               let root = window.contentView,
               let webView = Self.findWebView(in: root) {
                webView.unregisterDraggedTypes()
                return
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    private static func findWebView(in view: NSView) -> WKWebView? {
        if let webView = view as? WKWebView { return webView }
        for subview in view.subviews {
            if let webView = findWebView(in: subview) { return webView }
        }
        return nil
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
        addContextMenuItem("Back", systemImage: BrowserMenuIcon.back, enabled: canGoBack, to: menu) { [weak self] in self?.goBack() }
        addContextMenuItem("Forward", systemImage: BrowserMenuIcon.forward, enabled: canGoForward, to: menu) { [weak self] in self?.goForward() }
        menu.addItem(.separator())
        addContextMenuItem("Reload Page", systemImage: BrowserMenuIcon.reload, enabled: canReload, to: menu) { [weak self] in self?.reload() }
        menu.addItem(.separator())
        addContextMenuItem("Show Page Source", systemImage: BrowserMenuIcon.showSource, enabled: canShowSource, to: menu) { [weak self] in self?.showPageSource() }
        addContextMenuItem("Check for Previous Versions", systemImage: BrowserMenuIcon.archive, enabled: canCheckArchive, to: menu) { [weak self] in self?.openArchive() }
        addContextMenuItem("Save Page As…", systemImage: BrowserMenuIcon.save, enabled: canSavePage, to: menu) { [weak self] in Task { await self?.savePage() } }
        addContextMenuItem("Print Page…", systemImage: BrowserMenuIcon.print, enabled: true, to: menu) { [weak self] in self?.printPage() }
        menu.popUp(positioning: nil, at: location, in: view)
    }

    func prepareContextMenu(at location: NSPoint, in view: NSView) {
        pendingContextMenuLocation = location
        pendingContextMenuView = view
    }

    fileprivate func showPendingContextMenu(link: URL?) {
        guard let location = pendingContextMenuLocation,
              let view = pendingContextMenuView else { return }
        pendingContextMenuLocation = nil
        pendingContextMenuView = nil
        if let link {
            showLinkContextMenu(for: link, at: location, in: view)
        } else {
            showPageContextMenu(at: location, in: view)
        }
    }

    private func showLinkContextMenu(for url: URL, at location: NSPoint, in view: NSView?) {
        let menu = NSMenu()
        menu.autoenablesItems = false
        contextMenuTargets.removeAll()
        let opensInApp = canOpenInApp(url)
        addContextMenuItem("Open Link in New Tab", systemImage: BrowserMenuIcon.newTab, enabled: opensInApp, to: menu) { [weak self] in
            self?.openInNewTab?(url, true)
        }
        addContextMenuItem("Open Link in New Window", systemImage: BrowserMenuIcon.newWindow, enabled: opensInApp, to: menu) { [weak self] in
            self?.openInNewWindow?(url)
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

    func showPageSource() {
        guard canShowSource,
              let resourceURL = committedURL,
              !ViewSourceURL.isViewSource(resourceURL) else { return }
        presentSource(
            currentSourceBytes,
            of: resourceURL,
            mimeType: currentMIMEType,
            disposition: .new
        )
    }

    /// Presents `bytes` as the source of `resourceURL`, committed at its `view-source:`
    /// URL so it has its own history entry and can be revisited.
    ///
    /// Shared by Show Page Source, which already holds the bytes, and by a
    /// `view-source:` address typed into the location field, which has just fetched
    /// them. The cache entry records the *resource's* MIME type rather than text/plain,
    /// so Save Page As suggests .gmi for Gemtext source whether the page is fresh or
    /// restored from cache — the source of a .gmi document is that .gmi document.
    private func presentSource(
        _ bytes: Data,
        of resourceURL: URL,
        mimeType: String,
        disposition: HistoryDisposition
    ) {
        guard let sourceURL = ViewSourceURL.wrap(resourceURL) else { return }
        abandonScrollRestoration(for: disposition)
        renderSourceDocument(bytes, at: sourceURL)
        let heading = "Source: \(displayTitle(for: resourceURL))"
        // commit() resets the title, so the heading is applied after it.
        commit(sourceURL, disposition: disposition)
        cachedPages[sourceURL] = CachedPage(
            url: sourceURL,
            mimeType: mimeType,
            body: bytes,
            completion: .complete,
            receivedAt: Date(),
            title: heading,
            responseStatus: responseStatus,
            responseMeta: responseMeta,
            clientCertificateID: usedClientCertificate?.id
        )
        currentSourceBytes = bytes
        currentMIMEType = mimeType
        canSavePage = !bytes.isEmpty
        canShowSource = false
        title = heading
        statusText = "Page source"
        isLoading = false
        navigationTask = nil
    }

    private func renderSourceDocument(_ bytes: Data, at sourceURL: URL) {
        let source = String(decoding: bytes, as: UTF8.self)
        let continuation = beginDocument(at: sourceURL)
        continuation.yield(renderer.documentStart(themeCSS: themeCSS, browserGenerated: true))
        continuation.yield(Data(Self.sourceViewPrologue.utf8))

        // Batch lines so a large source is a few dozen scheme-handler writes rather
        // than one per line, while still streaming.
        var batch = ""
        for line in SourceLineSplitter.lines(of: source) {
            batch += "<div class=\"source-line\"><code>"
                + HTMLDocumentStreamRenderer.escape(line)
                + "</code></div>"
            if batch.utf8.count >= 32 * 1_024 {
                continuation.yield(Data(batch.utf8))
                batch = ""
            }
        }
        if !batch.isEmpty { continuation.yield(Data(batch.utf8)) }

        continuation.yield(Data("</div>".utf8))
        continuation.yield(renderer.documentEnd())
        continuation.finish()
    }

    /// Safari-style source gutter. The line number is generated content, so it is
    /// never part of the selection and never lands in the clipboard, and a wrapped
    /// long line keeps exactly one number.
    private static let sourceViewPrologue = """
    <style>
    .source { counter-reset: source-line; margin-top: 1rem; }
    .source-line { display: grid; grid-template-columns: 3.5rem 1fr; column-gap: 1rem; }
    .source-line:hover { background: color-mix(in srgb, CanvasText 6%, transparent); }
    .source-line::before {
      counter-increment: source-line;
      content: counter(source-line);
      text-align: right;
      color: SecondaryLabelColor;
      font: .82rem/1.5 ui-monospace, SFMono-Regular, Menlo, monospace;
      padding: .05rem .75rem 0 0;
      border-inline-end: 1px solid color-mix(in srgb, CanvasText 15%, transparent);
      -webkit-user-select: none;
      user-select: none;
    }
    .source-line code {
      font: .86rem/1.5 ui-monospace, SFMono-Regular, Menlo, monospace;
      white-space: pre-wrap;
      overflow-wrap: anywhere;
      background: transparent;
      padding: 0;
      border-radius: 0;
    }
    </style>
    <p class="eyebrow">Page Source</p><div class="source">
    """

    func savePage() async {
        guard canSavePage, let committedURL else { return }
        // NSSavePanel.begin is modeless, so the user can keep browsing the window
        // behind it. Capture the bytes for the page that was on screen when Save was
        // invoked; re-reading the property after the await wrote the *new* page's
        // bytes into a file named after the old one.
        let bytes = currentSourceBytes
        let panel = NSSavePanel()
        panel.nameFieldStringValue = BrowserFilenameSuggestion.make(
            for: committedURL,
            mimeType: currentMIMEType,
            documentTitle: documentTitle
        )
        panel.canCreateDirectories = true
        guard await panel.begin() == .OK, let destination = panel.url else { return }
        do {
            try bytes.write(to: destination, options: .atomic)
            statusText = "Saved \(destination.lastPathComponent)"
        } catch {
            validationMessage = "The page could not be saved: \(error.localizedDescription)"
        }
    }

    func download(_ url: URL) {
        statusText = "Downloading \(url.lastPathComponent)…"
        downloadTask?.cancel()
        downloadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let fetched: (data: Data, mimeType: String, finalURL: URL)
                switch url.scheme?.lowercased() {
                case "gemini":
                    fetched = try await retrieveGeminiResource(url)
                case "http", "https":
                    let (data, response) = try await URLSession.shared.data(from: url)
                    fetched = (
                        data,
                        (response.mimeType ?? "application/octet-stream").lowercased(),
                        response.url ?? url
                    )
                case "file":
                    fetched = (
                        try Data(contentsOf: url),
                        Self.mimeType(forPathExtension: url.pathExtension),
                        url
                    )
                default:
                    throw URLError(.unsupportedURL)
                }
                try Task.checkCancellation()

                let panel = NSSavePanel()
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

    fileprivate func updateHoveredLink(_ href: String?, modifiers: LinkModifierKeys = []) {
        guard let href, !href.isEmpty else {
            hoveredLinkDestination = nil
            hoveredLinkURL = nil
            return
        }
        hoveredLinkDestination = href
        hoveredLinkURL = LinkHoverText.text(for: href, modifiers: modifiers)
    }

    private func updateHoveredLinkModifiers(_ flags: NSEvent.ModifierFlags) {
        guard let href = hoveredLinkDestination else { return }
        var modifiers: LinkModifierKeys = []
        if flags.contains(.command) { modifiers.insert(.command) }
        if flags.contains(.shift) { modifiers.insert(.shift) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.control) { modifiers.insert(.control) }
        hoveredLinkURL = LinkHoverText.text(for: href, modifiers: modifiers)
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

    /// Shows one of Major Tom's own pages, such as the bookmark manager.
    ///
    /// Committed like any other address so it takes part in history, Back and Forward. The
    /// tab replaces the web view with a native view while one of these is showing, because
    /// the document pipeline forbids script and could not host an interactive manager.
    func showInternalPage(_ page: InternalPage, disposition: HistoryDisposition = .new) {
        navigationTask?.cancel()
        navigationTask = nil
        imageTasks.forEach { $0.cancel() }
        imageTasks.removeAll()
        slowDownTask?.cancel()
        slowDownTask = nil
        documentContinuation?.finish()
        documentContinuation = nil
        retryNotBefore = nil
        isLoading = false
        validationMessage = nil
        hoveredLinkURL = nil
        favicon = nil
        serverIdentity = nil
        usedClientCertificate = nil
        clientCertificatePrompt = nil
        pendingClientCertificateChallenge = nil
        responseStatus = nil
        responseMeta = ""
        currentSourceBytes = Data()
        currentMIMEType = ""
        canSavePage = false
        canShowSource = false
        internalPage = page
        activeWebDocumentURL = nil

        // Internal pages use native SwiftUI views, not the WebKit document whose scroll
        // reporter drives this state. There is therefore nothing to restore here.
        pendingScrollRestoration = nil
        isRestoringHistoryScroll = false

        commit(page.url, disposition: disposition)
        title = page.title
        statusText = page.title
    }

    /// Gathers what is known about the current page and presents the Page Info panel.
    ///
    /// The trusted record is read from the store rather than remembered, so the panel
    /// reports the pinned key and sighting count even for a page served from cache, where
    /// no live certificate was seen.
    func showPageInformation() {
        guard let committedURL else { return }
        Task {
            var trusted: TrustedServerIdentity?
            if let endpoint = CapsuleEndpoint(url: committedURL) {
                trusted = await trustStore?.identity(for: endpoint)
            }
            pageInformation = PageInformation(
                url: committedURL,
                status: responseStatus,
                meta: responseMeta,
                byteCount: currentSourceBytes.count,
                mimeType: currentMIMEType,
                identity: serverIdentity,
                trusted: trusted,
                clientCertificate: usedClientCertificate,
                clientCertificateAssociation: usedClientCertificate.flatMap { certificate in
                    ClientCertificateAssociation.mostSpecific(
                        matching: committedURL,
                        in: clientCertificates.associations.filter {
                            $0.certificateID == certificate.id
                        }
                    )
                }
            )
        }
    }

    func useClientCertificate(_ certificateID: UUID, scope: ClientCertificateScopeChoice) {
        guard let pending = pendingClientCertificateChallenge else { return }
        clientCertificates.associate(
            certificateID: certificateID,
            with: pending.target.url,
            scope: scope
        )
        clientCertificatePrompt = nil
        pendingClientCertificateChallenge = nil
        navigate(
            to: pending.target,
            disposition: pending.disposition,
            renderAsSource: pending.renderAsSource
        )
    }

    func cancelClientCertificatePrompt() {
        clientCertificatePrompt = nil
        pendingClientCertificateChallenge = nil
        isLoading = false
        statusText = "Client identity not selected"
        if let committedURL { locationText = committedURL.absoluteString }
    }

    func stopUsingClientCertificateForCurrentPage() {
        guard let url = pageInformation?.url ?? committedURL else { return }
        guard clientCertificates.stopUsing(for: url) else { return }
        if var information = pageInformation {
            information.clientCertificateAssociation = nil
            pageInformation = information
        }
    }

    func stopUsingClientCertificateForPendingChallenge() {
        guard let prompt = clientCertificatePrompt else { return }
        _ = clientCertificates.stopUsing(for: prompt.target.url)
        cancelClientCertificatePrompt()
    }

    func respondToTrust(allow: Bool) {
        trustPrompt = nil
        trustContinuation?.resume(returning: allow)
        trustContinuation = nil
    }

    /// - Parameter draft: whatever had been typed, kept so returning to the same prompt
    ///   offers it again. A sensitive prompt's text is discarded rather than stored.
    func cancelInput(draft: String = "") {
        if let prompt = inputPrompt, !prompt.isSensitive {
            if draft.isEmpty {
                inputDrafts.removeValue(forKey: prompt.target.url)
            } else {
                inputDrafts[prompt.target.url] = draft
            }
        }
        inputPrompt = nil
        inputValidationMessage = nil
        isLoading = false
        statusText = "Input cancelled"
        if let committedURL { locationText = committedURL.absoluteString }
    }

    func submitInput(_ value: String) {
        guard let prompt = inputPrompt else { return }
        inputDrafts.removeValue(forKey: prompt.target.url)
        guard let url = GeminiQueryEncoding.url(base: prompt.target.url, query: value),
              let target = try? GeminiRequestTarget(url.absoluteString) else {
            inputValidationMessage = "This response is too large for a Gemini request. Shorten it and try again."
            return
        }
        inputValidationMessage = nil
        inputPrompt = nil
        navigate(to: target, disposition: .new)
    }

    private func navigateHistory(to url: URL) {
        if let page = InternalPage.page(for: url) {
            showInternalPage(page, disposition: .traversal)
            return
        }
        if let cached = cachedPages[url] {
            displayCachedPage(cached)
            return
        }
        if url.isFileURL {
            openFile(url, disposition: .traversal)
            return
        }
        if decodedDataImage(url.absoluteString) != nil {
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

    private func navigate(
        to target: GeminiRequestTarget,
        disposition: HistoryDisposition,
        renderAsSource: Bool = false
    ) {
        abandonScrollRestoration(for: disposition)
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
        // Leaving one of Major Tom's own pages for a real document.
        internalPage = nil
        // Belongs to the page being replaced, and a stale identity in Page Info would
        // describe the wrong capsule.
        serverIdentity = nil
        usedClientCertificate = nil
        clientCertificatePrompt = nil
        pendingClientCertificateChallenge = nil
        responseStatus = nil
        responseMeta = ""
        // The document is going away, so its hover state is stale.
        hoveredLinkURL = nil
        // Drop the glyph only when leaving the capsule, so it does not flicker while
        // moving between pages of the one capsule.
        if CapsuleEndpoint(url: target.url) != committedURL.flatMap(CapsuleEndpoint.init(url:)) {
            favicon = nil
        }
        isLoading = true
        statusText = "Connecting to \(target.endpoint.host)…"
        locationText = target.url.absoluteString

        navigationTask = Task { [weak self] in
            guard let self else { return }
            await self.load(
                target: target,
                disposition: disposition,
                visited: [],
                redirectCount: 0,
                renderAsSource: renderAsSource
            )
        }
    }

    private func load(
        target: GeminiRequestTarget,
        disposition: HistoryDisposition,
        visited: Set<URL>,
        redirectCount: Int,
        renderAsSource: Bool = false
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

        let resolvedClientCertificate = clientCertificates.resolvedCertificate(for: target.url)
        let sentClientCertificate = resolvedClientCertificate?.tlsIdentity == nil
            ? nil
            : resolvedClientCertificate?.descriptor

        do {
            let events = transport.events(
                for: target,
                clientIdentity: resolvedClientCertificate?.tlsIdentity,
                configuration: GeminiTransportConfiguration()
            ) { [weak self] identity, _ in
                guard let self else { return false }
                return await self.authorize(identity)
            }

            for try await event in events {
                try Task.checkCancellation()
                switch event {
                case .connecting:
                    statusText = "Connecting securely…"
                case .serverIdentity(let identity):
                    serverIdentity = identity
                    statusText = "Verifying capsule identity…"
                case .responseHeader(let header):
                    responseHeader = header
                    responseStatus = header.status
                    responseMeta = header.meta
                    statusText = "Response \(header.status)"

                    if header.isRedirect {
                        // Resolved against target.url, which for a proxied request is the
                        // original http:// resource, so a proxy's relative redirect lands
                        // on the right host and is re-proxied by makeTarget.
                        guard let redirectURL = URL(
                            string: header.meta.trimmingCharacters(in: .whitespacesAndNewlines),
                            relativeTo: target.url
                        )?.absoluteURL,
                              let redirectTarget = makeTarget(for: redirectURL) else {
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
                            redirectCount: redirectCount + 1,
                            renderAsSource: renderAsSource
                        )
                        return
                    }

                    if header.isInput {
                        let isSensitive = header.status == 11
                        inputPrompt = InputPrompt(
                            target: target,
                            message: header.meta,
                            isSensitive: isSensitive,
                            initialText: isSensitive ? "" : (inputDrafts[target.url] ?? "")
                        )
                        isLoading = false
                        statusText = "Input required"
                        return
                    }

                    if header.requiresClientCertificate {
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
                                resolvedClientCertificate != nil
                                    && resolvedClientCertificate?.descriptor.isValid() == true
                                    && resolvedClientCertificate?.tlsIdentity == nil,
                            matchingCertificateIsInvalid:
                                resolvedClientCertificate?.descriptor.isValid() == false
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
                            disposition: disposition,
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
                            disposition: disposition
                        )
                        return
                    }

                    usedClientCertificate = sentClientCertificate

                    mimeType = header.meta.split(separator: ";", maxSplits: 1).first
                        .map { $0.trimmingCharacters(in: .whitespaces).lowercased() } ?? ""
                    if renderAsSource {
                        // No document is begun and nothing is committed yet: the source
                        // view needs the complete text, so a fetch that fails partway
                        // leaves the page currently on screen untouched.
                        statusText = "Receiving source\u{2026}"
                    } else if mimeType == "text/gemini" || mimeType.hasPrefix("text/") {
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
                    // Source view renders once, from the finished bytes.
                    guard !renderAsSource else { continue }
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
                    if renderAsSource {
                        guard mimeType.hasPrefix("text/") else {
                            showGeneratedPage(
                                title: "Source Not Available",
                                message: "Major Tom can only show the source of a text response.",
                                details: "\(mimeType.isEmpty ? header.meta : mimeType)\n\(sourceBytes.count) bytes",
                                url: target.url,
                                disposition: disposition
                            )
                            return
                        }
                        presentSource(
                            sourceBytes,
                            of: target.url,
                            mimeType: mimeType,
                            disposition: disposition
                        )
                        return
                    }
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
                        title: title,
                        documentTitle: documentTitle,
                        responseStatus: header.status,
                        responseMeta: header.meta,
                        clientCertificateID: sentClientCertificate?.id
                    )
                    statusText = "Loaded \(sourceBytes.count) bytes"
                    // Only now, once the reader has actually landed on this capsule: the
                    // RFC forbids probing for a favicon any earlier.
                    Task { await refreshFavicon(forCapsuleAt: target.url) }
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
                        receivedAt: Date(),
                        responseStatus: responseHeader?.status,
                        responseMeta: responseHeader?.meta,
                        clientCertificateID: usedClientCertificate?.id
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
                    disposition: disposition,
                    archiveURL: offersArchive(after: error)
                        ? DeloreanArchive.captures(of: target.url)
                        : nil
                )
            }
        }
    }

    private func authorize(_ identity: PresentedServerIdentity) async -> Bool {
        let locallyTrusted = await trustStore?.identity(for: identity.endpoint)
        let evaluation = trustPolicy.evaluate(
            presented: identity,
            locallyTrusted: locallyTrusted,
            seeds: SharedSeedIdentities.all
        )

        switch evaluation {
        case .allowSilently(let source):
            // Recorded for a seed match too, not only for an already-trusted identity:
            // pinning it locally means a later key substitution is a change to warn
            // about rather than another silent seed acceptance.
            if let trustStore {
                try? await trustStore.trust(identity, source: source)
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

    /// Builds a request target for `url`, routing http/https through the configured
    /// Gemini proxy when there is one.
    ///
    /// Every place that turns a URL into a request goes through here, so navigation,
    /// reload, history traversal and redirect following all agree about whether the
    /// proxy applies.
    private func makeTarget(for url: URL) -> GeminiRequestTarget? {
        switch url.scheme?.lowercased() {
        case "gemini":
            return try? GeminiRequestTarget(url.absoluteString)
        case "http", "https":
            guard let proxy = settings.preferences.proxy else { return nil }
            return try? GeminiRequestTarget(proxying: url, through: proxy)
        default:
            return nil
        }
    }

    private func canOpenInApp(_ url: URL) -> Bool {
        url.isFileURL
            || makeTarget(for: url) != nil
            || decodedDataImage(url.absoluteString) != nil
    }

    private func openLink(_ url: URL) {
        if url.scheme?.lowercased() == "gemini",
           let target = try? GeminiRequestTarget(url.absoluteString) {
            navigate(to: target, disposition: .new)
        } else if url.isFileURL {
            // Relative links inside a local document resolve to file URLs.
            openFile(url)
        } else if decodedDataImage(url.absoluteString) != nil {
            openDataImage(url)
        } else {
            openExternalURL(url)
        }
    }

    private func openDataImage(
        _ url: URL,
        disposition: HistoryDisposition = .new
    ) {
        guard let decoded = decodedDataImage(url.absoluteString) else { return }
        abandonScrollRestoration(for: disposition)

        navigationTask?.cancel()
        navigationTask = nil
        imageTasks.forEach { $0.cancel() }
        imageTasks.removeAll()
        slowDownTask?.cancel()
        slowDownTask = nil
        retryNotBefore = nil
        validationMessage = nil
        internalPage = nil
        clientCertificatePrompt = nil
        pendingClientCertificateChallenge = nil
        serverIdentity = nil
        usedClientCertificate = nil
        responseStatus = nil
        responseMeta = ""
        isLoading = false
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
        NSWorkspace.shared.open(url)
    }

    private func beginDocument(at sourceURL: URL) -> AsyncThrowingStream<Data, any Error>.Continuation {
        documentContinuation?.finish()
        // Line numbering restarts with each document, and no expansion survives it.
        linkSequence = 0
        expandedInlineImages.removeAll()
        let document = documentStore.createDocument()
        activeWebDocumentURL = document.url
        let navigation = page.load(document.url)
        let restoration = pendingScrollRestoration
        Task { @MainActor [weak self] in
            do {
                for try await event in navigation where event == .finished {
                    if let restoration {
                        await self?.restoreScrollPosition(restoration)
                    }
                    if self?.hasPresentedInitialDocument == false {
                        self?.hasPresentedInitialDocument = true
                    }
                    break
                }
            } catch {
                // A superseding navigation owns both the placeholder and any pending
                // restoration. Its own beginDocument call will handle the new document.
                if let restoration,
                   self?.pendingScrollRestoration?.historyIndex == restoration.historyIndex {
                    self?.pendingScrollRestoration = nil
                    self?.isRestoringHistoryScroll = false
                }
            }
        }
        return document.continuation
    }

    private func restoreScrollPosition(
        _ restoration: (historyIndex: Int, offset: Double)
    ) async {
        guard historyIndex == restoration.historyIndex,
              pendingScrollRestoration?.historyIndex == restoration.historyIndex else { return }
        do {
            _ = try await page.callJavaScript(
                """
                window.scrollTo(0, \(restoration.offset));
                await new Promise(resolve => {
                    requestAnimationFrame(() => requestAnimationFrame(resolve));
                });
                document.documentElement.style.setProperty('visibility', 'visible', 'important');
                await new Promise(resolve => {
                    requestAnimationFrame(() => requestAnimationFrame(resolve));
                });
                """
            )
        } catch {
            // Never leave a document permanently hidden if WebKit accepted the load but
            // rejected or interrupted the restoration script.
            _ = try? await page.callJavaScript(
                "document.documentElement.style.setProperty('visibility', 'visible', 'important');"
            )
        }
        if pendingScrollRestoration?.historyIndex == restoration.historyIndex {
            pendingScrollRestoration = nil
            isRestoringHistoryScroll = false
        }
    }

    private func abandonScrollRestoration(for disposition: HistoryDisposition) {
        guard case .new = disposition else { return }
        pendingScrollRestoration = nil
        isRestoringHistoryScroll = false
    }

    private func finishCurrentDocument(message: String? = nil) {
        guard let continuation = documentContinuation else { return }
        continuation.yield(renderer.documentEnd(incompleteMessage: message))
        continuation.finish()
        documentContinuation = nil
    }

    /// - Parameter archiveURL: when present, the page offers a link to past captures of
    ///   the address that failed.
    private func showGeneratedPage(
        title: String,
        message: String,
        details: String,
        url: URL,
        disposition: HistoryDisposition,
        archiveURL: URL? = nil
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
        // Rendered through the ordinary link renderer, so it looks and behaves like any
        // other Gemtext link: the navigation decider handles the click with no extra
        // machinery, and it picks up the usual hint glyph.
        if let archiveURL {
            continuation.yield(renderer.render(
                .link(
                    destination: archiveURL.absoluteString,
                    label: "Check for previous versions of this page"
                ),
                options: settings.preferences.renderingOptions,
                baseURL: url
            ))
        }
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
        let imageDocument = """
        <style>
        body { height: 100vh; box-sizing: border-box; overflow: hidden; }
        main { box-sizing: border-box; max-width: none; height: 100%; padding: 0; }
        .image-toggle { position: absolute; opacity: 0; pointer-events: none; }
        .image-frame { display: flex; box-sizing: border-box; width: 100%; height: 100%; align-items: center; justify-content: center; overflow: hidden; cursor: zoom-in; }
        .image-frame img { display: block; max-width: 100%; max-height: 100%; width: auto; height: auto; margin: 0; border-radius: 0; }
        .image-toggle:focus-visible + .image-frame { outline: 3px solid AccentColor; outline-offset: -3px; }
        .image-toggle:checked + .image-frame { display: block; overflow: auto; cursor: zoom-out; }
        .image-toggle:checked + .image-frame img { max-width: none; max-height: none; }
        </style>
        <input class="image-toggle" type="checkbox" id="image-size" aria-label="Show image at natural size">
        <label class="image-frame" for="image-size"><img alt="" src="\(source)"></label>
        """
        continuation.yield(Data(imageDocument.utf8))
        continuation.yield(renderer.documentEnd())
        continuation.finish()
        commit(url, disposition: disposition)
    }

    private func commit(_ url: URL, disposition: HistoryDisposition) {
        committedURL = url
        title = displayTitle(for: url)
        documentTitle = nil
        titleClaim = GemtextTitleClaim()
        locationText = url.absoluteString
        switch disposition {
        case .new:
            // A new branch supersedes any Back/Forward restoration whose WebKit load
            // had not yet finished.
            pendingScrollRestoration = nil
            isRestoringHistoryScroll = false
            if historyIndex + 1 < history.count {
                history.removeSubrange((historyIndex + 1)...)
                historyScrollPositions = historyScrollPositions.filter { $0.key <= historyIndex }
            }
            if history.last != url {
                history.append(url)
                historyIndex = history.count - 1
                historyScrollPositions[historyIndex] = 0
            }
            BrowsingHistoryStore.shared.record(url)
        case .reload, .traversal:
            break
        }
        updateNavigationAvailability()
    }

    private func updateNavigationAvailability() {
        canGoBack = historyIndex > 0
        canGoForward = historyIndex >= 0 && historyIndex + 1 < history.count
    }

    private func displayCachedPage(_ cached: CachedPage) {
        navigationTask?.cancel()
        internalPage = nil
        isLoading = false
        // A restored/cached page has no live TLS connection. Leaving the previous
        // identity here would make Page Info describe a different page's certificate.
        serverIdentity = nil
        usedClientCertificate = cached.clientCertificateID.flatMap(clientCertificates.descriptor(id:))
        committedURL = cached.url
        locationText = cached.url.absoluteString
        currentSourceBytes = cached.body
        currentMIMEType = cached.mimeType
        // Successful body-bearing cache entries from older releases predate persisted
        // headers. Gemini defines 20 as the ordinary success response, so retain useful
        // Page Info for those sessions while preserving exact 2x codes going forward.
        responseStatus = cached.responseStatus
            ?? (cached.url.scheme?.lowercased() == "gemini" ? 20 : nil)
        responseMeta = cached.responseMeta ?? (responseStatus == nil ? "" : cached.mimeType)
        title = cached.title ?? displayTitle(for: cached.url)
        documentTitle = cached.documentTitle
        // Re-rendering a cached page replays its events, so seed the claim with the
        // title already known or a fence caption could displace a real heading.
        titleClaim = GemtextTitleClaim(existingTitle: cached.documentTitle)
        canSavePage = !cached.body.isEmpty
        canShowSource = cached.mimeType.hasPrefix("text/") && !ViewSourceURL.isViewSource(cached.url)
        if ViewSourceURL.isViewSource(cached.url) {
            renderSourceDocument(cached.body, at: cached.url)
        } else {
            renderCurrentContent()
        }
        applyZoom()
        statusText = cached.completion == .complete
            ? "Cached • \(cached.body.count) bytes"
            : "Cached \(cached.completion.rawValue) response"
        Task { await refreshFavicon(forCapsuleAt: cached.url) }
    }

    /// Whether a failed connection is one where an archived copy might help.
    ///
    /// Only failures to reach the capsule at all — DNS, TCP, or the TLS handshake, and a
    /// capsule that stopped answering. Anything about identity is excluded on purpose: a
    /// changed key or a declined trust decision is a security signal, and offering to read
    /// the page from somewhere else instead would undercut the warning rather than help.
    private func offersArchive(after error: any Error) -> Bool {
        guard let transportError = error as? GeminiTransportError else { return false }
        switch transportError {
        case .connectionFailed, .timedOut:
            return true
        case .certificateUnavailable, .publicKeyFingerprintFailed, .trustDeclined,
             .responseFailed, .responseTooLarge:
            return false
        }
    }

    /// Whether the current address is one the archive could hold captures of.
    var canCheckArchive: Bool {
        committedURL.flatMap(DeloreanArchive.captures(of:)) != nil
    }

    /// Opens Delorean's list of captures for the current address.
    func openArchive() {
        guard let committedURL,
              let archiveURL = DeloreanArchive.captures(of: committedURL),
              let target = try? GeminiRequestTarget(archiveURL.absoluteString) else { return }
        navigate(to: target, disposition: .new)
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
        var theme = settings.preferences.contentTheme.css(effectiveDarkAppearance: dark)
        if settings.preferences.renderingOptions.collapsesConsecutiveQuotes {
            theme += HTMLDocumentStreamRenderer.collapsedQuotesCSS
        }
        // This style arrives in the document's first HTML chunk, before WebKit can paint
        // its initial y=0 layout. restoreScrollPosition reveals it only after the saved
        // offset has crossed the compositor boundary, avoiding a one-frame top flash.
        if pendingScrollRestoration?.historyIndex == historyIndex,
           pendingScrollRestoration?.offset ?? 0 > 0 {
            theme += "\nhtml { visibility: hidden !important; }"
        }
        theme += "\n" + settings.preferences.contentWidth.css
        // Screen-only zoom survives navigation without overriding print's 100% scale.
        return theme + "\n@media screen { :root { zoom: \(pageZoom); } }"
    }

    private func preferencesChanged(to preferences: BrowserPreferences) {
        defer { lastPreferences = preferences }

        // Handled ahead of the guard below, which is about re-rendering a document:
        // turning favicons off should clear the glyph even on a page that cannot be
        // re-rendered, such as a generated error page.
        if preferences.showsFavicons != lastPreferences.showsFavicons {
            if preferences.showsFavicons {
                if let committedURL {
                    Task { await refreshFavicon(forCapsuleAt: committedURL) }
                }
            } else {
                favicon = nil
            }
        }

        guard committedURL != nil else { return }

        if preferences.contentTheme != lastPreferences.contentTheme
            || preferences.contentWidth != lastPreferences.contentWidth {
            applyThemeWithoutReload()
            return
        }

        guard canSavePage else { return }

        let renderingChanged = preferences.renderingOptions != lastPreferences.renderingOptions
            || preferences.automaticallyLoadsSameCapsuleImages != lastPreferences.automaticallyLoadsSameCapsuleImages
            || preferences.automaticallyLoadsDataImages != lastPreferences.automaticallyLoadsDataImages
        guard renderingChanged, !isLoading else { return }
        renderCurrentContent()
    }

    private func applyThemeWithoutReload() {
        let css = themeCSS
        guard let cssData = try? JSONEncoder().encode(css),
              let cssLiteral = String(data: cssData, encoding: .utf8) else { return }
        Task {
            _ = try? await page.callJavaScript(
                """
                const theme = document.getElementById('majortom-theme');
                if (theme) { theme.textContent = \(cssLiteral); }
                """
            )
        }
    }

    /// Zoom now lives in `themeCSS`, so re-applying the stylesheet is all that is
    /// needed. Previously this set an inline style on the document element, which a
    /// subsequent navigation discarded along with the document, silently resetting
    /// every page to 100% while `pageZoom` still read 1.3.
    private func applyZoom() {
        applyThemeWithoutReload()
    }

    private func renderCurrentContent() {
        guard let committedURL else { return }
        if ViewSourceURL.isViewSource(committedURL) {
            renderSourceDocument(currentSourceBytes, at: committedURL)
            return
        }
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
        if titleClaim.receive(event), let claimed = titleClaim.title {
            title = claimed
            documentTitle = claimed
        }
        var linkIdentifier: String?
        var isExpandableImage = false
        if case .link(let destination, _) = event {
            linkSequence += 1
            linkIdentifier = "mt-link-\(linkSequence)"
            // Offered only where automatic loading will not already have inlined the
            // image, so a single link is never both auto-inlined and click-expandable.
            isExpandableImage = !willAutoInline(destination: destination, baseURL: baseURL)
                && GemtextLinkHint.isInlineImageCandidate(destination: destination, relativeTo: baseURL)
        }

        documentContinuation?.yield(renderer.render(
            event,
            options: settings.preferences.renderingOptions,
            baseURL: baseURL,
            linkIdentifier: linkIdentifier,
            isExpandableImage: isExpandableImage
        ))
        guard case .link(let destination, let label) = event,
              willAutoInline(destination: destination, baseURL: baseURL) else { return }

        if destination.lowercased().hasPrefix("data:image/"),
           let dataURL = URL(string: destination) {
            let fileName = label ?? "Inline image"
            let metadata = inlineDataImageMetadata(destination)
            documentContinuation?.yield(renderer.renderInlineImage(
                resourceURL: dataURL,
                linkURL: dataURL,
                altText: fileName,
                figureIdentifier: "mt-inline-\(linkIdentifier ?? String(linkSequence))",
                fileName: fileName,
                mimeType: metadata?.mimeType,
                sizeDescription: metadata.map { formattedByteCount($0.byteCount) }
            ))
            return
        }

        guard let url = URL(string: destination, relativeTo: baseURL)?.absoluteURL else { return }

        let figureIdentifier = "mt-inline-\(linkIdentifier ?? String(linkSequence))"
        let fileName = inlineImageFileName(for: url, fallback: label)
        let resource = resourceStore.createResource()
        documentContinuation?.yield(renderer.renderInlineImage(
            resourceURL: resource.url,
            linkURL: url,
            altText: label ?? fileName,
            figureIdentifier: figureIdentifier,
            fileName: fileName
        ))
        let task = Task { [weak self] in
            guard let self else { return }
            await self.imageLimiter.acquire()
            let metadata = await self.loadInlineImage(
                url,
                continuation: resource.continuation,
                redirects: 0
            )
            await self.imageLimiter.release()
            if let metadata {
                await self.updateInlineImageMetadata(
                    figureIdentifier: figureIdentifier,
                    metadata: metadata
                )
            }
        }
        imageTasks.append(task)
    }

    /// Whether this link's image will be loaded automatically, per the two Quality of
    /// Life preferences.
    ///
    /// Click-to-expand consults the same predicate, so the two features can never both
    /// claim the same link and stack two copies of one image.
    private func willAutoInline(destination: String, baseURL: URL) -> Bool {
        if destination.lowercased().hasPrefix("data:image/") {
            return settings.preferences.automaticallyLoadsDataImages
        }
        guard settings.preferences.automaticallyLoadsSameCapsuleImages,
              let url = URL(string: destination, relativeTo: baseURL)?.absoluteURL else {
            return false
        }
        return isProbableImage(url) && isSameCapsule(url, baseURL)
    }

    /// Expands the image linked from one line beneath it, or collapses it again.
    ///
    /// Clicking the link a second time removes the image, which makes the gesture its own
    /// undo and keeps a long page of image links from growing without bound.
    func toggleInlineImage(lineIdentifier: String, url: URL) {
        if expandedInlineImages.remove(lineIdentifier) != nil {
            Task { await removeInlineImage(lineIdentifier: lineIdentifier) }
            return
        }

        expandedInlineImages.insert(lineIdentifier)
        let figureIdentifier = "mt-inline-\(lineIdentifier)"
        let fileName = inlineImageFileName(for: url, fallback: nil)
        let resource = resourceStore.createResource()
        let task = Task { [weak self] in
            guard let self else { return }
            // Markup first: the image element has to exist for WebKit to request the
            // resource URL that the fetch below streams into.
            await self.insertInlineImage(
                lineIdentifier: lineIdentifier,
                resourceURL: resource.url,
                linkURL: url,
                figureIdentifier: figureIdentifier,
                fileName: fileName
            )
            await self.imageLimiter.acquire()
            let metadata = await self.loadInlineImage(
                url,
                continuation: resource.continuation,
                redirects: 0
            )
            await self.imageLimiter.release()
            if let metadata {
                await self.updateInlineImageMetadata(
                    figureIdentifier: figureIdentifier,
                    metadata: metadata
                )
            }
            await self.setLineLoading(lineIdentifier: lineIdentifier, isLoading: false)
        }
        imageTasks.append(task)
    }

    private func insertInlineImage(
        lineIdentifier: String,
        resourceURL: URL,
        linkURL: URL,
        figureIdentifier: String,
        fileName: String
    ) async {
        let figure = String(decoding: renderer.renderInlineImage(
            resourceURL: resourceURL,
            linkURL: linkURL,
            altText: fileName,
            figureIdentifier: figureIdentifier,
            fileName: fileName,
            figureClass: "mt-inline"
        ), as: UTF8.self)
        await runScript("""
        (() => {
          const line = document.getElementById(\(jsLiteral(lineIdentifier)));
          if (!line) { return; }
          line.classList.add('mt-loading');
          if (!line.nextElementSibling?.classList.contains('mt-inline')) {
            line.insertAdjacentHTML('afterend', \(jsLiteral(figure)));
          }
        })();
        """)
    }

    private func removeInlineImage(lineIdentifier: String) async {
        await runScript("""
        (() => {
          const line = document.getElementById(\(jsLiteral(lineIdentifier)));
          if (!line) { return; }
          line.classList.remove('mt-loading');
          const figure = line.nextElementSibling;
          if (figure?.classList.contains('mt-inline')) { figure.remove(); }
        })();
        """)
    }

    private func setLineLoading(lineIdentifier: String, isLoading: Bool) async {
        let method = isLoading ? "add" : "remove"
        await runScript(
            "document.getElementById(\(jsLiteral(lineIdentifier)))?.classList.\(method)('mt-loading');"
        )
    }

    private func updateInlineImageMetadata(
        figureIdentifier: String,
        metadata: LoadedInlineImage
    ) async {
        let size = formattedByteCount(metadata.byteCount)
        await runScript("""
        (() => {
          const image = document.getElementById(\(jsLiteral(figureIdentifier)))
            ?.querySelector('img[data-mt-inline-image]');
          if (!image) { return; }
          image.dataset.mtMime = \(jsLiteral(metadata.mimeType));
          image.dataset.mtSize = \(jsLiteral(size));
          window.majorTomEnhanceInlineImage?.(image);
        })();
        """)
    }

    private func inlineImageFileName(for url: URL, fallback: String?) -> String {
        if !url.lastPathComponent.isEmpty { return url.lastPathComponent }
        if let fallback, !fallback.isEmpty { return fallback }
        return url.host ?? "Image"
    }

    private func formattedByteCount(_ byteCount: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(byteCount), countStyle: .file)
    }

    private func inlineDataImageMetadata(_ source: String) -> LoadedInlineImage? {
        guard let decoded = decodedDataImage(source) else { return nil }
        return LoadedInlineImage(mimeType: decoded.mimeType, byteCount: decoded.data.count)
    }

    private func decodedDataImage(_ source: String) -> DecodedDataImage? {
        guard let comma = source.firstIndex(of: ",") else { return nil }
        let header = String(source[..<comma])
        guard header.lowercased().hasPrefix("data:image/") else { return nil }
        let mimeType = header.dropFirst("data:".count).split(separator: ";", maxSplits: 1)
            .first.map(String.init)?.lowercased() ?? "image/*"
        let payload = String(source[source.index(after: comma)...])
        let data: Data?
        if header.lowercased().contains(";base64") {
            data = Data(base64Encoded: payload, options: .ignoreUnknownCharacters)
        } else {
            data = payload.removingPercentEncoding?.data(using: .utf8)
        }
        guard let data else { return nil }
        return DecodedDataImage(data: data, mimeType: mimeType)
    }

    private func runScript(_ source: String) async {
        _ = try? await page.callJavaScript(source)
    }

    /// Encodes a Swift string as a JavaScript string literal, so page content can never
    /// break out of the script being evaluated.
    private func jsLiteral(_ value: String) -> String {
        guard let data = try? JSONEncoder().encode(value),
              let literal = String(data: data, encoding: .utf8) else { return "\"\"" }
        return literal
    }

    private enum FaviconProbe {
        case found(String)
        /// The capsule answered, but not with a conforming favicon.
        case absent
        /// The probe never got an answer, so nothing may be concluded or cached.
        case failed
    }

    /// Brings `favicon` up to date for the capsule just navigated to, fetching
    /// `favicon.txt` only when nothing fresh is cached.
    ///
    /// The RFC forbids prefetching: a client may not ask for a favicon until the user has
    /// navigated to that server. This is called after a page commits, which is exactly
    /// that moment.
    private func refreshFavicon(forCapsuleAt url: URL) async {
        guard settings.preferences.showsFavicons else {
            favicon = nil
            return
        }
        // Only real capsules. A proxied http page is fetched over a connection to the
        // proxy, and the proxy's favicon is not the site's.
        guard url.scheme?.lowercased() == "gemini",
              let endpoint = CapsuleEndpoint(url: url),
              let store = SharedFaviconStore.shared else {
            favicon = nil
            return
        }

        switch await store.favicon(for: endpoint) {
        case .known(let emoji):
            favicon = emoji
            return
        case .absent:
            favicon = nil
            return
        case .unknown:
            favicon = nil
        }

        guard let probeTarget = try? GeminiRequestTarget(
            "gemini://\(endpoint.host):\(endpoint.port)\(GeminiFavicon.path)"
        ) else { return }

        let probe = await self.probeFavicon(probeTarget)
        switch probe {
        case .failed:
            // A connection that never answered says nothing about whether a favicon
            // exists, and caching that as "absent" would hide it for a week.
            return
        case .found(let emoji):
            try? await store.record(emoji, for: endpoint)
            applyFaviconIfStillCurrent(emoji, endpoint: endpoint)
        case .absent:
            try? await store.record(nil, for: endpoint)
            applyFaviconIfStillCurrent(nil, endpoint: endpoint)
        }
    }

    /// The probe outlives the navigation that started it, so a slow answer must not
    /// decorate a page the reader has since left.
    private func applyFaviconIfStillCurrent(_ emoji: String?, endpoint: CapsuleEndpoint) {
        guard let current = committedURL.flatMap(CapsuleEndpoint.init(url:)),
              current == endpoint else { return }
        favicon = emoji
    }

    private func probeFavicon(_ target: GeminiRequestTarget) async -> FaviconProbe {
        var body = Data()
        var accepted = false
        do {
            let events = transport.events(
                for: target,
                // A favicon is one emoji. A capsule that answers this path with a large
                // body is misbehaving, and there is no reason to read it.
                configuration: GeminiTransportConfiguration(
                    idleTimeout: .seconds(10),
                    maximumResponseByteCount: 4 * 1_024
                )
            ) { [weak self] identity, _ in
                guard let self else { return false }
                return await self.authorize(identity)
            }
            for try await event in events {
                switch event {
                case .responseHeader(let header):
                    // The RFC requires status 20 with a text/plain MIME type. Anything
                    // else — most often 51 — means the capsule simply has no favicon,
                    // which the RFC is explicit is not an error.
                    let mime = header.meta.split(separator: ";", maxSplits: 1).first
                        .map { $0.trimmingCharacters(in: .whitespaces).lowercased() } ?? ""
                    guard header.isSuccess, mime == "text/plain" else { return .absent }
                    accepted = true
                case .body(let data):
                    body.append(data)
                default:
                    break
                }
            }
        } catch {
            return .failed
        }
        guard accepted else { return .failed }
        guard let emoji = GeminiFavicon.parse(String(decoding: body, as: UTF8.self)) else {
            return .absent
        }
        return .found(emoji)
    }

    private func loadInlineImage(
        _ url: URL,
        continuation: AsyncThrowingStream<URLSchemeTaskResult, any Error>.Continuation,
        redirects: Int
    ) async -> LoadedInlineImage? {
        guard redirects <= 5,
              let target = try? GeminiRequestTarget(url.absoluteString) else {
            continuation.finish(throwing: URLError(.badURL))
            return nil
        }
        do {
            let events = transport.events(
                for: target,
                configuration: GeminiTransportConfiguration(
                    maximumResponseByteCount: 16 * 1_024 * 1_024
                )
            ) { [weak self] identity, _ in
                guard let self else { return false }
                return await self.authorize(identity)
            }
            var accepted = false
            var mimeType = ""
            var byteCount = 0
            for try await event in events {
                switch event {
                case .responseHeader(let header):
                    if header.isRedirect,
                       let redirected = URL(string: header.meta, relativeTo: url)?.absoluteURL,
                       isSameCapsule(redirected, url) {
                        return await loadInlineImage(
                            redirected,
                            continuation: continuation,
                            redirects: redirects + 1
                        )
                    }
                    let mime = header.meta.split(separator: ";", maxSplits: 1).first
                        .map { $0.trimmingCharacters(in: .whitespaces).lowercased() } ?? ""
                    guard header.isSuccess, mime.hasPrefix("image/") else {
                        continuation.finish(throwing: URLError(.cannotDecodeContentData))
                        return nil
                    }
                    accepted = true
                    mimeType = mime
                    continuation.yield(.response(URLResponse(
                        url: url,
                        mimeType: mime,
                        expectedContentLength: -1,
                        textEncodingName: nil
                    )))
                case .body(let data) where accepted:
                    byteCount += data.count
                    continuation.yield(.data(data))
                case .completed:
                    continuation.finish()
                    return accepted
                        ? LoadedInlineImage(mimeType: mimeType, byteCount: byteCount)
                        : nil
                default:
                    break
                }
            }
            continuation.finish()
            return accepted
                ? LoadedInlineImage(mimeType: mimeType, byteCount: byteCount)
                : nil
        } catch {
            continuation.finish(throwing: error)
            return nil
        }
    }

    private func retrieveGeminiResource(
        _ url: URL,
        redirects: Int = 0
    ) async throws -> (data: Data, mimeType: String, finalURL: URL) {
        guard redirects <= 5 else {
            throw GeminiTransportError.connectionFailed("The capsule redirected too many times.")
        }
        guard let target = try? GeminiRequestTarget(url.absoluteString) else {
            throw URLError(.badURL)
        }
        var body = Data()
        var mimeType = "application/octet-stream"
        let events = transport.events(
            for: target,
            configuration: GeminiTransportConfiguration()
        ) { [weak self] identity, _ in
            guard let self else { return false }
            return await self.authorize(identity)
        }
        for try await event in events {
            switch event {
            case .responseHeader(let header):
                // A download that redirects previously died with "Gemini status 31".
                if header.isRedirect {
                    let meta = header.meta.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard let next = URL(string: meta, relativeTo: url)?.absoluteURL else {
                        throw GeminiTransportError.connectionFailed(
                            "The capsule returned a redirect Major Tom could not understand: \(header.meta)"
                        )
                    }
                    return try await retrieveGeminiResource(next, redirects: redirects + 1)
                }
                guard header.isSuccess else {
                    throw GeminiTransportError.connectionFailed("Gemini status \(header.status): \(header.meta)")
                }
                // Trim and lowercase, or the charset parameter and stray whitespace
                // defeat BrowserFilenameSuggestion's extension mapping.
                mimeType = header.meta.split(separator: ";", maxSplits: 1).first
                    .map { $0.trimmingCharacters(in: .whitespaces).lowercased() } ?? mimeType
            case .body(let data):
                body.append(data)
            default:
                break
            }
        }
        return (body, mimeType, url)
    }

    // Both defined once in MajorTomCore, so link hints and inline-image loading can
    // never disagree about what counts as an image or as the same capsule.
    private func isProbableImage(_ url: URL) -> Bool {
        GemtextLinkHint.isProbableImage(url)
    }

    private func isSameCapsule(_ lhs: URL, _ rhs: URL) -> Bool {
        GemtextLinkHint.isSameCapsule(lhs, rhs)
    }

    private func displayTitle(for url: URL) -> String {
        BrowserPageTitle.fallback(for: url)
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
    /// Drives WebKit's native find bar, including its system matching, highlighting,
    /// match count, wrap behavior, and keyboard navigation.
    @Binding var findNavigatorIsPresented: Bool

    var body: some View {
        WebView(browser.page)
            .webViewTextSelection(.enabled)
            .webViewMagnificationGestures(.enabled)
            .findNavigator(isPresented: $findNavigatorIsPresented)
    }
}

@available(macOS 26.0, *)
@MainActor
private final class BrowserNavigationRouter {
    var openURL: ((URL) -> Void)?
    var downloadURL: ((URL) -> Void)?
    var openInNewTab: ((URL, _ inBackground: Bool) -> Void)?
    var openInNewWindow: ((URL) -> Void)?
    var canOpenInApp: ((URL) -> Bool)?
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
