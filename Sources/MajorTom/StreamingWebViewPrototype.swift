import AppKit
import Combine
import Foundation
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
private final class PreformattedBlockStateScriptHandler: NSObject, WKScriptMessageHandler {
    static let name = "majorTomPreformattedState"

    static let userScript = WKUserScript(
        source: """
        (() => {
          const report = (block) => {
            if (!(block instanceof HTMLDetailsElement) || !block.matches('.pre-block.multiline')) { return; }
            const blocks = Array.from(document.querySelectorAll('.pre-block'));
            const index = blocks.indexOf(block);
            if (index < 0) { return; }
            window.webkit.messageHandlers.\(name).postMessage({ index: index + 1, collapsed: !block.open });
          };

          // WebKit does not reliably deliver a details element's `toggle` event to a
          // document-level listener. Observing the `open` attribute catches both ways a
          // block changes: clicking its summary and Major Tom's click-to-collapse code.
          new MutationObserver((records) => {
            for (const record of records) {
              if (record.type === 'attributes' && record.attributeName === 'open') {
                report(record.target);
              }
            }
          }).observe(document, { attributes: true, attributeFilter: ['open'], subtree: true });
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
              let index = payload["index"] as? NSNumber,
              let collapsed = payload["collapsed"] as? NSNumber else { return }
        browser?.recordPreformattedState(
            index: index.intValue,
            collapsed: collapsed.boolValue,
            from: message.frameInfo.request.url
        )
    }
}

@available(macOS 26.0, *)
@MainActor
final class BrowserModel: ObservableObject {
    fileprivate struct HistorySwipePresentation {
        let direction: BrowserHistorySwipeDirection
        let viewportWidth: CGFloat
        var offset: CGFloat
        var isReady: Bool
    }

    private struct PendingHistorySwipe {
        let sourceEntryID: BackForwardEntry.ID
        let targetEntryID: BackForwardEntry.ID
        let direction: BrowserHistorySwipeDirection
    }

    enum HistoryDisposition: Equatable {
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
    private var responseWasCached: Bool?
    private var responseReceivedAt: Date?
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
    @Published fileprivate var historySwipePresentation: HistorySwipePresentation?
    var isPresentingHistorySwipe: Bool { historySwipePresentation != nil }

    /// Snapshots used to build the native click-and-hold history menus. The navigation
    /// state remains the source of truth; these are deliberately ordered nearest first.
    var backHistoryEntries: [BackForwardEntry] { navigation.backHistoryEntries }
    var forwardHistoryEntries: [BackForwardEntry] { navigation.forwardHistoryEntries }

    let page: WebPage
    let historySwipePage: WebPage

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
    private let contentCache = SharedContentCache.shared
    private let cacheDecider = GeminiCacheDecider()
    /// Rebuilt per access rather than stored, so a document rendered after the reader
    /// changes content theme resolves its ANSI colors against the new background.
    private var renderer: HTMLDocumentStreamRenderer {
        HTMLDocumentStreamRenderer(contentPalette: contentPalette)
    }
    private var cancellables = Set<AnyCancellable>()

    private var navigationTask: Task<Void, Never>?
    private var documentContinuation: AsyncThrowingStream<Data, any Error>.Continuation?
    /// Rendered HTML waiting to be handed to WebKit. See `yieldToDocument`.
    private var documentBuffer = Data()
    private var trustContinuation: CheckedContinuation<Bool, Never>?
    /// This tab's position in its own history, the pages it has kept, and the reading
    /// position in each of them. Owned by Core so those rules can be tested without
    /// WebKit; see `NavigationState`.
    private var navigation = NavigationState()
    private let backForwardCache = SharedBackForwardCacheStore.shared
    private var backForwardDebounceTask: Task<Void, Never>?
    private var backForwardWriteTask: Task<Void, Never>?
    private var contentCacheWriteTask: Task<Void, Never>?
    private var bypassesContentCacheForPage = false
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
    private var activeWebDocumentURL: URL?
    private var pendingHistorySwipe: PendingHistorySwipe?
    private var historySwipeGeneration = 0
    private var pendingClientCertificateChallenge: (
        target: GeminiRequestTarget,
        disposition: HistoryDisposition,
        renderAsSource: Bool
    )?
    private var hasStarted = false
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
    private let preformattedStateScriptHandler: PreformattedBlockStateScriptHandler
    /// Numbers link lines within the current document so an expanded image can be
    /// attached to the exact line that was clicked.
    private var linkSequence = 0
    /// Line identifiers whose image is currently expanded, for toggling back off.
    private var expandedInlineImages: Set<String> = []
    private var expandableImageLines: [URL: String] = [:]
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
        self.preformattedStateScriptHandler = preformattedStateScriptHandler
        self.page = WebPage(
            configuration: configuration,
            navigationDecider: BrowserNavigationDecider(router: router)
        )
        self.historySwipePage = WebPage(
            configuration: configuration,
            navigationDecider: BrowserNavigationDecider(router: router)
        )
        self.trustStore = SharedTrustedIdentityStore.shared
        self.lastPreferences = settings.preferences
        if let restoredState {
            // NavigationState clamps the index at both ends. A negative or out-of-range
            // value from an older or corrupted blob previously left committedURL nil,
            // silently discarding the whole restored history.
            self.navigation = NavigationState(restoring: restoredState)
            self.pageZoom = restoredState.zoom
            self.committedURL = self.navigation.committedURL
            let currentCachedPage = self.committedURL.flatMap { self.navigation.cachedPage(for: $0) }
            self.locationText = self.committedURL?.absoluteString ?? settings.preferences.homepage
            self.title = restoredState.title
                ?? currentCachedPage?.title
                ?? self.committedURL.map(displayTitle)
                ?? "New Tab"
            self.documentTitle = restoredState.documentTitle
                ?? currentCachedPage?.documentTitle
            self.favicon = self.navigation.currentEntry?.favicon
        } else {
            self.locationText = initialURL?.absoluteString ?? settings.preferences.homepage
        }
        contextMenuScriptHandler.browser = self
        linkHoverScriptHandler.browser = self
        linkActivationScriptHandler.browser = self
        inlineImageScriptHandler.browser = self
        scrollPositionScriptHandler.browser = self
        preformattedStateScriptHandler.browser = self

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

    var restorationState: RestoredTabState {
        navigation.updateCurrentMetadata(title: documentTitle ?? title, favicon: favicon)
        return navigation.restorationState(
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
        if let committedURL, decodedDataImage(committedURL.absoluteString) != nil {
            openDataImage(committedURL, disposition: .reload)
            return
        }
        guard let committedURL, let target = makeTarget(for: committedURL) else { return }
        navigate(to: target, disposition: .reload)
    }

    /// Tears down everything belonging to the page being replaced.
    ///
    /// Every entry point into a new page needs this: a capsule navigation, a local file,
    /// a `data:` image, and one of Major Tom's own pages. All four used to do it by hand
    /// and had drifted apart. Only `showInternalPage` finished the abandoned document
    /// stream and cleared the favicon, the hovered link and `activeWebDocumentURL`, so
    /// dropping a local file onto a tab left the previous capsule's glyph in the toolbar
    /// and on the native tab title, and left a stale continuation that made `stop()`
    /// believe the *previous* page had been interrupted partway.
    ///
    /// - Parameter keepsFavicon: true while moving between pages of one capsule, so the
    ///   glyph does not flicker on every navigation within a site.
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

        navigationTask?.cancel()
        navigationTask = nil
        imageTasks.forEach { $0.cancel() }
        imageTasks.removeAll()
        slowDownTask?.cancel()
        slowDownTask = nil
        documentContinuation?.finish()
        documentContinuation = nil
        documentBuffer.removeAll(keepingCapacity: false)
        activeWebDocumentURL = nil

        // A prompt still on screen belongs to the request being abandoned. Resuming the
        // continuation releases the transport that is waiting on the reader's answer.
        trustContinuation?.resume(returning: false)
        trustContinuation = nil
        trustPrompt = nil
        inputPrompt = nil
        inputValidationMessage = nil
        clientCertificatePrompt = nil
        pendingClientCertificateChallenge = nil

        retryNotBefore = nil
        validationMessage = nil
        internalPage = nil
        // Belongs to the page being replaced. A stale identity in Page Info would
        // describe a different capsule's certificate.
        serverIdentity = nil
        usedClientCertificate = nil
        responseStatus = nil
        responseMeta = ""
        responseWasCached = nil
        responseReceivedAt = nil
        bypassesContentCacheForPage = false
        // The document is going away, so its hover state is stale.
        hoveredLinkURL = nil
        if !keepsFavicon { favicon = nil }
        isLoading = false
    }

    /// Opens a local file, e.g. a `.gmi` dragged onto the window or opened from Finder.
    ///
    /// Local files go through the same document pipeline, cache and history as capsule
    /// responses, so View Source, Save Page As, Back/Forward and the content theme all
    /// behave identically. Nothing is fetched over the network.
    func openFile(_ url: URL, disposition: HistoryDisposition = .new) {
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

    func goBack() {
        browserNavigationLogger.notice(
            "goBack requested modelIndex=\(self.navigation.historyIndex) canBack=\(self.navigation.canGoBack) current=\(self.committedURL?.absoluteString ?? "nil", privacy: .public)"
        )
        guard let entry = navigation.backHistoryEntries.first else { return }
        go(toHistoryEntryWithID: entry.id)
    }

    func goForward() {
        browserNavigationLogger.notice(
            "goForward requested modelIndex=\(self.navigation.historyIndex) canForward=\(self.navigation.canGoForward) current=\(self.committedURL?.absoluteString ?? "nil", privacy: .public)"
        )
        guard let entry = navigation.forwardHistoryEntries.first else { return }
        go(toHistoryEntryWithID: entry.id)
    }

    func go(toHistoryEntryWithID id: BackForwardEntry.ID) {
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
        prepareScrollRestoration(for: navigation.historyIndex)
        updateNavigationAvailability()
        navigateHistory(to: url)
    }

    fileprivate func prepareHistorySwipe(
        direction: BrowserHistorySwipeDirection,
        viewportWidth: CGFloat,
        offset: CGFloat
    ) async -> Bool {
        guard let sourceEntryID = navigation.currentEntryID,
              let destination = direction == .back
                ? navigation.backHistoryEntries.first
                : navigation.forwardHistoryEntries.first else { return false }

        historySwipeGeneration += 1
        let generation = historySwipeGeneration
        pendingHistorySwipe = PendingHistorySwipe(
            sourceEntryID: sourceEntryID,
            targetEntryID: destination.id,
            direction: direction
        )
        historySwipePresentation = HistorySwipePresentation(
            direction: direction,
            viewportWidth: viewportWidth,
            offset: 0,
            isReady: false
        )

        var cached = destination.page
        if cached == nil, let backForwardCache {
            cached = try? await backForwardCache.entry(id: destination.id)?.page
        }
        guard generation == historySwipeGeneration,
              navigation.currentEntryID == sourceEntryID,
              pendingHistorySwipe?.targetEntryID == destination.id else { return false }

        if let cached {
            navigation.cache(cached, for: destination.id)
        }
        do {
            try await renderHistorySwipeDestination(cached, entry: destination)
        } catch {
            browserNavigationLogger.error(
                "history swipe staging failed targetID=\(destination.id.uuidString, privacy: .public) error=\(String(describing: error), privacy: .public)"
            )
            pendingHistorySwipe = nil
            historySwipePresentation = nil
            return false
        }
        guard generation == historySwipeGeneration,
              navigation.currentEntryID == sourceEntryID,
              var presentation = historySwipePresentation else { return false }
        presentation.isReady = true
        presentation.offset = direction.sign * min(abs(offset), viewportWidth)
        historySwipePresentation = presentation
        browserNavigationLogger.notice(
            "history swipe staging ready targetID=\(destination.id.uuidString, privacy: .public) cached=\(cached != nil)"
        )
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
            go(toHistoryEntryWithID: pendingHistorySwipe.targetEntryID)
        }
        presentation.offset = cancelled ? 0 : presentation.direction.sign * presentation.viewportWidth
        withAnimation(.easeOut(duration: 0.22)) {
            historySwipePresentation = presentation
        }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(230))
            if !cancelled {
                for _ in 0..<20 where self?.isRestoringHistoryScroll == true {
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
        pendingHistorySwipe = nil
        historySwipePresentation = nil
    }

    fileprivate func recordScrollPosition(_ offset: Double, from documentURL: URL?) {
        guard documentURL == activeWebDocumentURL,
              pendingScrollRestoration?.historyIndex != navigation.historyIndex else { return }
        navigation.recordScrollOffset(offset)
        scheduleBackForwardPersistence()
    }

    fileprivate func recordPreformattedState(index: Int, collapsed: Bool, from documentURL: URL?) {
        guard documentURL == activeWebDocumentURL else { return }
        navigation.setPreformattedSection(index, collapsed: collapsed)
        scheduleBackForwardPersistence()
    }

    /// Flushes this tab's coalesced presentation state before the shared database closes.
    func flushBackForwardPersistence() async {
        backForwardDebounceTask?.cancel()
        backForwardDebounceTask = nil
        persistCurrentBackForwardEntry()
        await backForwardWriteTask?.value
    }

    func flushContentCacheWrites() async {
        await contentCacheWriteTask?.value
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
            disposition: .new,
            receivedAt: responseReceivedAt ?? Date()
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
        disposition: HistoryDisposition,
        receivedAt: Date = Date()
    ) {
        guard let sourceURL = ViewSourceURL.wrap(resourceURL) else { return }
        abandonScrollRestoration(for: disposition)
        renderSourceDocument(bytes, at: sourceURL)
        let heading = "Source: \(displayTitle(for: resourceURL))"
        // commit() resets the title, so the heading is applied after it.
        commit(sourceURL, disposition: disposition)
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
                responseWasCached: responseWasCached,
                responseReceivedAt: responseReceivedAt,
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
            GeminiInputDraftStore.shared.save(draft, for: prompt.target.url)
        }
        inputPrompt = nil
        inputValidationMessage = nil
        isLoading = false
        statusText = "Input cancelled"
        if let committedURL { locationText = committedURL.absoluteString }
    }

    /// Keeps an unanswered prompt's text so returning to the same address offers it back.
    ///
    /// Separate from `cancelInput` because the prompt may be going away for a reason that
    /// has nothing to do with the reader answering it — navigating elsewhere, or closing
    /// the window. In that case the status area, the loading state and the address field
    /// belong to whatever replaced the prompt, and `cancelInput` would overwrite all
    /// three. It also cannot read `inputPrompt`, which the navigation has already
    /// cleared, so the target is passed in.
    ///
    /// A sensitive prompt's text never reaches here; the sheet does not report one.
    func preserveInputDraft(_ draft: String, for target: GeminiRequestTarget) {
        GeminiInputDraftStore.shared.save(draft, for: target.url)
    }

    func submitInput(_ value: String) {
        guard let prompt = inputPrompt else { return }
        guard let url = GeminiQueryEncoding.url(base: prompt.target.url, query: value),
              let target = try? GeminiRequestTarget(url.absoluteString) else {
            inputValidationMessage = "This response is too large for a Gemini request. Shorten it and try again."
            return
        }
        GeminiInputDraftStore.shared.remove(for: prompt.target.url)
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
            Task { [weak self] in
                let stored = try? await backForwardCache.entry(id: entryID)
                guard let self, self.navigation.currentEntryID == entryID else { return }
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
        // Keep the glyph while moving within one capsule, so it does not flicker
        // between pages of the same site.
        let staysWithinCapsule = CapsuleEndpoint(url: target.url)
            == committedURL.flatMap(CapsuleEndpoint.init(url:))
        beginNavigation(disposition: disposition, keepsFavicon: staysWithinCapsule)
        bypassesContentCacheForPage = disposition == .reload

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
                renderAsSource: renderAsSource,
                bypassesContentCache: disposition == .reload
            )
        }
    }

    private func load(
        target: GeminiRequestTarget,
        disposition: HistoryDisposition,
        visited: Set<URL>,
        redirectCount: Int,
        renderAsSource: Bool = false,
        bypassesContentCache: Bool = false
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

        if bypassesContentCache {
            try? await contentCache?.removeResponse(for: target.url)
        }
        let cachedResponse = bypassesContentCache
            ? nil
            : try? await contentCache?.freshResponse(for: target.url)
        let responseIsCached = cachedResponse != nil
        var receivedAt = cachedResponse?.receivedAt ?? Date()

        let resolvedClientCertificate = await clientCertificates.resolvedCertificate(for: target.url)
        let sentClientCertificate = resolvedClientCertificate?.tlsIdentity == nil
            ? nil
            : resolvedClientCertificate?.descriptor

        do {
            let events: AsyncThrowingStream<GeminiTransportEvent, any Error>
            if let cachedResponse {
                statusText = "Loading cached response…"
                events = GeminiResponseReplay.events(for: cachedResponse)
            } else {
                events = transport.events(
                    for: target,
                    clientIdentity: resolvedClientCertificate?.tlsIdentity,
                    configuration: GeminiTransportConfiguration()
                ) { [weak self] identity, _ in
                    guard let self else { return false }
                    return await self.authorize(identity)
                }
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
                    if !responseIsCached { receivedAt = Date() }
                    responseHeader = header
                    responseStatus = header.status
                    responseMeta = header.meta
                    responseWasCached = responseIsCached
                    responseReceivedAt = receivedAt
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
                            renderAsSource: renderAsSource,
                            bypassesContentCache: bypassesContentCache
                        )
                        return
                    }

                    if header.isInput {
                        let isSensitive = header.status == 11
                        inputPrompt = InputPrompt(
                            target: target,
                            message: header.meta,
                            isSensitive: isSensitive,
                            initialText: isSensitive
                                ? ""
                                : GeminiInputDraftStore.shared.text(for: target.url)
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

                    usedClientCertificate = responseIsCached ? nil : sentClientCertificate

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
                        // One write per network chunk, not one per line.
                        flushDocument()
                    } else if mimeType.hasPrefix("text/") {
                        let decoded = utf8Decoder.decode(data)
                        yieldToDocument(Data(HTMLDocumentStreamRenderer.escape(decoded).utf8))
                        flushDocument()
                    }

                case .completed:
                    guard let header = responseHeader, header.isSuccess else { return }
                    var displayedSuccessfulContent = false
                    if !responseIsCached {
                        let response = ContentResponse(
                            url: target.url,
                            status: header.status,
                            meta: Data(header.meta.utf8),
                            mimeType: mimeType,
                            body: sourceBytes,
                            receivedAt: receivedAt
                        )
                        storeInContentCacheIfNeeded(response, for: target)
                    }
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
                            disposition: disposition,
                            receivedAt: receivedAt
                        )
                        return
                    }
                    if mimeType == "text/gemini" {
                        displayedSuccessfulContent = true
                        let tail = utf8Decoder.finish()
                        let finalEvents = gemtextParser.receive(tail) + gemtextParser.finish()
                        for parsedEvent in finalEvents {
                            emit(parsedEvent, baseURL: target.url)
                        }
                        finishCurrentDocument()
                    } else if mimeType.hasPrefix("text/") {
                        displayedSuccessfulContent = true
                        yieldToDocument(Data(HTMLDocumentStreamRenderer.escape(utf8Decoder.finish()).utf8))
                        yieldToDocument(Data("</code></pre>".utf8))
                        finishCurrentDocument()
                    } else if mimeType.hasPrefix("image/") {
                        displayedSuccessfulContent = true
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
                    Task { await refreshFavicon(forCapsuleAt: target.url) }
                    navigationTask = nil
                    return
                }
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
            seeds: []
        )

        switch evaluation {
        case .allowSilently(let source):
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
            guard approved else { return false }
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
        NSWorkspace.shared.open(url)
    }

    private func beginDocument(at sourceURL: URL) -> AsyncThrowingStream<Data, any Error>.Continuation {
        browserNavigationLogger.notice(
            "beginDocument source=\(sourceURL.absoluteString, privacy: .public) replacing=\(self.activeWebDocumentURL?.absoluteString ?? "nil", privacy: .public) modelIndex=\(self.navigation.historyIndex)"
        )
        documentContinuation?.finish()
        // Whatever was buffered belongs to the document just abandoned. Only a caller
        // that streams sets `documentContinuation` again; the one-shot pages that render
        // straight into their own continuation deliberately leave it nil.
        documentContinuation = nil
        documentBuffer.removeAll(keepingCapacity: false)
        // Line numbering restarts with each document, and no expansion survives it.
        linkSequence = 0
        expandedInlineImages.removeAll()
        expandableImageLines.removeAll()
        let document = documentStore.createDocument()
        activeWebDocumentURL = document.url
        browserNavigationLogger.notice(
            "page.load start document=\(document.url.absoluteString, privacy: .public) source=\(sourceURL.absoluteString, privacy: .public)"
        )
        let navigation = page.load(document.url)
        let restoration = pendingScrollRestoration
        Task { @MainActor [weak self] in
            do {
                for try await event in navigation {
                    browserNavigationLogger.notice(
                        "page.load event document=\(document.url.absoluteString, privacy: .public) event=\(String(describing: event), privacy: .public)"
                    )
                    guard event == .finished else { continue }
                    if let restoration {
                        await self?.restoreScrollPosition(restoration)
                    }
                    if self?.hasPresentedInitialDocument == false {
                        self?.hasPresentedInitialDocument = true
                    }
                    break
                }
            } catch {
                browserNavigationLogger.error(
                    "page.load failed document=\(document.url.absoluteString, privacy: .public) error=\(String(describing: error), privacy: .public)"
                )
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
        guard navigation.historyIndex == restoration.historyIndex,
              pendingScrollRestoration?.historyIndex == restoration.historyIndex else { return }
        let restoredImageCount = await restorePresentationState()
        if restoredImageCount > 0 {
            pendingInlineImageScrollCorrection = restoration
        }
        await applyScrollRestoration(restoration)
    }

    private func applyScrollRestoration(
        _ restoration: (historyIndex: Int, offset: Double)
    ) async {
        guard navigation.historyIndex == restoration.historyIndex,
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

    private func restorePresentationState() async -> Int {
        guard let entry = navigation.currentEntry else { return 0 }
        let collapsed = entry.presentation.collapsedPreformatted
        if !collapsed.isEmpty {
            let indices = collapsed.map(String.init).joined(separator: ",")
            _ = try? await page.callJavaScript(
                """
                (() => {
                  const collapsed = new Set([\(indices)]);
                  document.querySelectorAll('.pre-block').forEach((block, index) => {
                    if (collapsed.has(index + 1)) { block.open = false; }
                  });
                })();
                """
            )
        }
        var restoredImageCount = 0
        for url in entry.presentation.expandedImages {
            guard let lineIdentifier = expandableImageLines[url],
                  !expandedInlineImages.contains(lineIdentifier) else { continue }
            expandedInlineImages.insert(lineIdentifier)
            restoredImageCount += 1
            let task = Task { [weak self] in
                guard let self else { return }
                await self.expandInlineImage(
                    lineIdentifier: lineIdentifier,
                    url: url,
                    completesScrollRestoration: true
                )
            }
            imageTasks.append(task)
        }
        pendingRestoredInlineImageCount = restoredImageCount
        return restoredImageCount
    }

    private func abandonScrollRestoration(for disposition: HistoryDisposition) {
        guard case .new = disposition else { return }
        pendingScrollRestoration = nil
        pendingRestoredInlineImageCount = 0
        pendingInlineImageScrollCorrection = nil
        isRestoringHistoryScroll = false
    }

    /// Buffers rendered HTML for the document currently streaming.
    ///
    /// Every yield is a separate `Data` crossing the custom `majortom-document` scheme
    /// handler into WebKit's networking process, and the renderer produces one per
    /// Gemtext event — five thousand of them for a five-thousand-line page. The source
    /// view already batches for exactly this reason.
    ///
    /// The buffer is flushed once per network chunk as well as on this threshold, so a
    /// page still renders visibly incrementally: content arrives no less often than the
    /// capsule sends it, just not in fragments smaller than the network delivered.
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

    private static let documentFlushByteCount = 16 * 1_024

    private func finishCurrentDocument(message: String? = nil) {
        guard let continuation = documentContinuation else { return }
        flushDocument()
        continuation.yield(renderer.documentEnd(incompleteMessage: message))
        continuation.finish()
        documentContinuation = nil
        documentBuffer.removeAll(keepingCapacity: false)
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
        BrowsingHistoryStore.shared.record(url, title: title)
    }

    private func updateNavigationAvailability() {
        canGoBack = navigation.canGoBack
        canGoForward = navigation.canGoForward
    }

    private func displayCachedPage(_ cached: CachedPage) {
        browserNavigationLogger.notice(
            "displayCachedPage url=\(cached.url.absoluteString, privacy: .public) bytes=\(cached.body.count) modelIndex=\(self.navigation.historyIndex)"
        )
        navigationTask?.cancel()
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

    /// Keeps a small hot set in the tab while the durable cache owns the global limits.
    private func cache(_ page: CachedPage) {
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

    /// Back/Forward first checks the tab's hot set, then its entry in the standalone cache.
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

    private func storeInContentCacheIfNeeded(
        _ response: ContentResponse,
        for target: GeminiRequestTarget
    ) {
        guard let contentCache else { return }
        guard case .store(let resourceType, let lifetime) = cacheDecider.decision(
            for: target,
            response: response
        ) else { return }
        enqueueContentCacheWrite {
            _ = try? await contentCache.store(
                response,
                resourceType: resourceType,
                lifetime: lifetime
            )
        }
    }

    private func enqueueContentCacheWrite(
        _ operation: @escaping @Sendable () async -> Void
    ) {
        let previous = contentCacheWriteTask
        contentCacheWriteTask = Task {
            await previous?.value
            guard !Task.isCancelled else { return }
            await operation()
        }
    }

    private static func needsPresentationRestoration(_ state: HistoryPresentationState) -> Bool {
        state.scrollY > 0 || !state.expandedImages.isEmpty || !state.collapsedPreformatted.isEmpty
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
        case .connectionFailed, .connectionTimedOut, .responseTimedOut:
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

    private var effectiveDarkAppearance: Bool {
        NSApplication.shared.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    private var contentPalette: ContentThemePalette {
        settings.preferences.contentTheme.palette(effectiveDarkAppearance: effectiveDarkAppearance)
    }

    private var themeCSS: String {
        var theme = settings.preferences.contentTheme.css(
            effectiveDarkAppearance: effectiveDarkAppearance
        )
        if settings.preferences.renderingOptions.collapsesConsecutiveQuotes {
            theme += HTMLDocumentStreamRenderer.collapsedQuotesCSS
        }
        // This style arrives in the document's first HTML chunk, before WebKit can paint
        // its initial y=0 layout. restoreScrollPosition reveals it only after the saved
        // offset has crossed the compositor boundary, avoiding a one-frame top flash.
        if pendingScrollRestoration?.historyIndex == navigation.historyIndex,
           (navigation.currentEntry?.presentation).map(Self.needsPresentationRestoration) == true {
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
            // An ANSI foreground is resolved against the theme background while the
            // document is built and written into the markup as an inline color, so a
            // document carrying one needs rendering again rather than a new stylesheet.
            if preferences.contentTheme != lastPreferences.contentTheme,
               usesANSIColors(with: preferences) {
                renderCurrentContent()
            } else {
                applyThemeWithoutReload()
            }
            return
        }

        guard canSavePage else { return }

        let renderingChanged = preferences.renderingOptions != lastPreferences.renderingOptions
            || preferences.automaticallyLoadsSameCapsuleImages != lastPreferences.automaticallyLoadsSameCapsuleImages
            || preferences.automaticallyLoadsDataImages != lastPreferences.automaticallyLoadsDataImages
        guard renderingChanged, !isLoading else { return }
        renderCurrentContent()
    }

    /// Whether the document on screen may have ANSI colors baked into it.
    ///
    /// Read from the received bytes rather than tracked while rendering: an escape
    /// character anywhere in a gemtext response is enough to make re-rendering the
    /// cheaper answer than being wrong about it.
    private func usesANSIColors(with preferences: BrowserPreferences) -> Bool {
        preferences.renderingOptions.rendersANSIColors
            && currentMIMEType == "text/gemini"
            && canSavePage
            && !isLoading
            && currentSourceBytes.contains(0x1B)
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
            // Set once, before emitting: `emit` writes through this property, and
            // reassigning it inside the loop was routing rather than expressing state.
            documentContinuation = continuation
            continuation.yield(renderer.documentStart(themeCSS: themeCSS, baseURL: committedURL))
            for event in events {
                emit(event, baseURL: committedURL)
            }
            finishCurrentDocument()
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

    /// Renders an adjacent model-history entry into the noninteractive transition
    /// WebView. This never changes the tab cursor and never initiates a network request.
    private func renderHistorySwipeDestination(
        _ cached: CachedPage?,
        entry: BackForwardEntry
    ) async throws {
        let document = documentStore.createDocument()
        let navigation = historySwipePage.load(document.url)
        document.continuation.yield(historySwipeDocument(cached, entry: entry))
        document.continuation.finish()
        for try await event in navigation where event == .finished { break }

        let collapsed = entry.presentation.collapsedPreformatted
            .map(String.init)
            .joined(separator: ",")
        _ = try? await historySwipePage.callJavaScript(
            """
            (() => {
              const collapsed = new Set([\(collapsed)]);
              document.querySelectorAll('.pre-block').forEach((block, index) => {
                if (collapsed.has(index + 1)) { block.open = false; }
              });
              window.scrollTo(0, \(entry.presentation.scrollY));
            })();
            """
        )
    }

    private func historySwipeDocument(_ cached: CachedPage?, entry: BackForwardEntry) -> Data {
        let renderer = HTMLDocumentStreamRenderer()
        guard let cached else {
            var document = renderer.documentStart(
                themeCSS: themeCSS,
                baseURL: entry.url,
                browserGenerated: true
            )
            document.append(Data("<p class=\"eyebrow\">History</p><h1>\(HTMLDocumentStreamRenderer.escape(entry.title ?? displayTitle(for: entry.url)))</h1>".utf8))
            document.append(renderer.documentEnd())
            return document
        }

        var document = renderer.documentStart(
            themeCSS: themeCSS,
            baseURL: cached.url,
            browserGenerated: ViewSourceURL.isViewSource(cached.url)
        )
        if ViewSourceURL.isViewSource(cached.url) {
            document.append(Data(Self.sourceViewPrologue.utf8))
            for line in SourceLineSplitter.lines(of: String(decoding: cached.body, as: UTF8.self)) {
                document.append(Data(
                    ("<div class=\"source-line\"><code>"
                        + HTMLDocumentStreamRenderer.escape(line)
                        + "</code></div>").utf8
                ))
            }
            document.append(Data("</div>".utf8))
        } else if cached.mimeType == "text/gemini" {
            var decoder = IncrementalUTF8Decoder()
            var parser = IncrementalGemtextParser()
            let events = parser.receive(decoder.decode(cached.body) + decoder.finish()) + parser.finish()
            for event in events {
                document.append(renderer.render(
                    event,
                    options: settings.preferences.renderingOptions,
                    baseURL: cached.url
                ))
            }
        } else if cached.mimeType.hasPrefix("text/") {
            let text = HTMLDocumentStreamRenderer.escape(String(decoding: cached.body, as: UTF8.self))
            document.append(Data("<pre><code>\(text)</code></pre>".utf8))
        } else if cached.mimeType.hasPrefix("image/") {
            let source = "data:\(HTMLDocumentStreamRenderer.escapeAttribute(cached.mimeType));base64,\(cached.body.base64EncodedString())"
            document.append(Data("<img alt=\"\" src=\"\(source)\">".utf8))
        } else {
            document.append(Data("<p class=\"eyebrow\">History</p><h1>\(HTMLDocumentStreamRenderer.escape(entry.title ?? displayTitle(for: entry.url)))</h1>".utf8))
        }
        document.append(renderer.documentEnd())
        return document
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
            if isExpandableImage,
               let absolute = URL(string: destination, relativeTo: baseURL)?.absoluteURL,
               let linkIdentifier {
                expandableImageLines[absolute] = linkIdentifier
            }
        }

        yieldToDocument(renderer.render(
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
            yieldToDocument(renderer.renderInlineImage(
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
        yieldToDocument(renderer.renderInlineImage(
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
                redirects: 0,
                bypassesContentCache: bypassesContentCacheForPage
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
            navigation.setImage(url, expanded: false)
            scheduleBackForwardPersistence()
            Task { await removeInlineImage(lineIdentifier: lineIdentifier) }
            return
        }

        expandedInlineImages.insert(lineIdentifier)
        navigation.setImage(url, expanded: true)
        scheduleBackForwardPersistence()
        let task = Task { [weak self] in
            guard let self else { return }
            await self.expandInlineImage(lineIdentifier: lineIdentifier, url: url)
        }
        imageTasks.append(task)
    }

    /// Restored image links need a second scroll correction after their layout completes.
    /// Otherwise WebKit clamps the initial offset against the shorter document and leaves
    /// a reader above their original position after the image appears.
    private func expandInlineImage(
        lineIdentifier: String,
        url: URL,
        completesScrollRestoration: Bool = false
    ) async {
        let figureIdentifier = "mt-inline-\(lineIdentifier)"
        let fileName = inlineImageFileName(for: url, fallback: nil)
        let resource = resourceStore.createResource()
        // Markup first: the image element has to exist for WebKit to request the
        // resource URL that the fetch below streams into.
        await insertInlineImage(
            lineIdentifier: lineIdentifier,
            resourceURL: resource.url,
            linkURL: url,
            figureIdentifier: figureIdentifier,
            fileName: fileName
        )
        await imageLimiter.acquire()
        let metadata = await loadInlineImage(
            url,
            continuation: resource.continuation,
            redirects: 0,
            bypassesContentCache: bypassesContentCacheForPage
        )
        await imageLimiter.release()
        if let metadata {
            await updateInlineImageMetadata(
                figureIdentifier: figureIdentifier,
                metadata: metadata
            )
        }
        await setLineLoading(lineIdentifier: lineIdentifier, isLoading: false)
        if completesScrollRestoration {
            await restoredInlineImageDidFinishLoading()
        }
    }

    private func restoredInlineImageDidFinishLoading() async {
        guard pendingRestoredInlineImageCount > 0 else { return }
        pendingRestoredInlineImageCount -= 1
        guard pendingRestoredInlineImageCount == 0,
              let correction = pendingInlineImageScrollCorrection else { return }
        pendingInlineImageScrollCorrection = nil
        _ = try? await page.callJavaScript(
            scrollCorrectionScript(offset: correction.offset)
        )
    }

    /// A resource stream finishing does not guarantee that WebKit has decoded and laid
    /// out its image yet. Wait for every restored inline image, not merely the one whose
    /// stream happened to finish last, before applying the final absolute offset.
    private func scrollCorrectionScript(offset: Double) -> String {
        """
        await Promise.all(Array.from(document.querySelectorAll('img[data-mt-inline-image]')).map(async (image) => {
          if (!image.complete) {
            await new Promise((resolve) => {
              image.addEventListener('load', resolve, { once: true });
              image.addEventListener('error', resolve, { once: true });
            });
          }
          if (image.decode) { await image.decode().catch(() => {}); }
        }));
        await new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve)));
        window.scrollTo(0, \(offset));
        """
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
        case found(String, ContentResponse)
        /// The capsule answered, but not with a conforming favicon.
        case absent(receivedAt: Date)
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
              let faviconURL = GeminiFavicon.url(for: endpoint),
              let probeTarget = try? GeminiRequestTarget(faviconURL.absoluteString) else {
            favicon = nil
            return
        }

        if let response = try? await contentCache?.freshResponse(for: faviconURL) {
            let emoji = GeminiFavicon.parse(response: response)
            if emoji == nil, response.status != 51 {
                let negative = GeminiFavicon.negativeResponse(
                    for: faviconURL,
                    receivedAt: response.receivedAt
                )
                enqueueContentCacheWrite { [contentCache] in
                    _ = try? await contentCache?.store(
                        negative,
                        resourceType: .favicon,
                        lifetime: GeminiFavicon.cacheLifetime
                    )
                }
            }
            favicon = emoji
            navigation.updateCurrentMetadata(title: documentTitle ?? title, favicon: favicon)
            persistCurrentBackForwardEntry()
            BookmarksModel.shared.updateFavicon(
                emoji,
                for: endpoint,
                fetchedAt: response.receivedAt
            )
            return
        }
        favicon = nil

        let probe = await self.probeFavicon(probeTarget)
        switch probe {
        case .failed:
            // A connection that never completed says nothing about whether a favicon
            // exists and must not create a negative cache entry.
            return
        case .found(let emoji, let response):
            enqueueContentCacheWrite { [contentCache] in
                _ = try? await contentCache?.store(
                    response,
                    resourceType: .favicon,
                    lifetime: GeminiFavicon.cacheLifetime
                )
            }
            BookmarksModel.shared.updateFavicon(emoji, for: endpoint, fetchedAt: response.receivedAt)
            applyFaviconIfStillCurrent(emoji, endpoint: endpoint)
        case .absent(let receivedAt):
            let negative = GeminiFavicon.negativeResponse(
                for: faviconURL,
                receivedAt: receivedAt
            )
            enqueueContentCacheWrite { [contentCache] in
                _ = try? await contentCache?.store(
                    negative,
                    resourceType: .favicon,
                    lifetime: GeminiFavicon.cacheLifetime
                )
            }
            BookmarksModel.shared.updateFavicon(nil, for: endpoint, fetchedAt: receivedAt)
            applyFaviconIfStillCurrent(nil, endpoint: endpoint)
        }
    }

    /// The probe outlives the navigation that started it, so a slow answer must not
    /// decorate a page the reader has since left.
    private func applyFaviconIfStillCurrent(_ emoji: String?, endpoint: CapsuleEndpoint) {
        guard let current = committedURL.flatMap(CapsuleEndpoint.init(url:)),
              current == endpoint else { return }
        favicon = emoji
        navigation.updateCurrentMetadata(title: documentTitle ?? title, favicon: emoji)
        persistCurrentBackForwardEntry()
    }

    private func probeFavicon(_ target: GeminiRequestTarget) async -> FaviconProbe {
        var body = Data()
        var responseHeader: GeminiResponseHeader?
        var receivedAt = Date()
        var completed = false
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
                    responseHeader = header
                    receivedAt = Date()
                case .body(let data):
                    body.append(data)
                case .completed:
                    completed = true
                default:
                    break
                }
            }
        } catch {
            return .failed
        }
        guard completed, let responseHeader else { return .failed }
        let mime = responseHeader.meta.split(separator: ";", maxSplits: 1).first
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        let response = ContentResponse(
            url: target.url,
            status: responseHeader.status,
            meta: Data(responseHeader.meta.utf8),
            mimeType: mime,
            body: body,
            receivedAt: receivedAt
        )
        guard let emoji = GeminiFavicon.parse(response: response) else {
            return .absent(receivedAt: receivedAt)
        }
        return .found(emoji, response)
    }

    private func loadInlineImage(
        _ url: URL,
        continuation: AsyncThrowingStream<URLSchemeTaskResult, any Error>.Continuation,
        redirects: Int,
        bypassesContentCache: Bool
    ) async -> LoadedInlineImage? {
        guard redirects <= 5,
              let target = try? GeminiRequestTarget(url.absoluteString) else {
            continuation.finish(throwing: URLError(.badURL))
            return nil
        }
        do {
            if bypassesContentCache {
                try? await contentCache?.removeResponse(for: target.url)
            }
            let cachedResponse = bypassesContentCache
                ? nil
                : try? await contentCache?.freshResponse(for: target.url)
            let responseIsCached = cachedResponse != nil
            var receivedAt = cachedResponse?.receivedAt ?? Date()
            let events: AsyncThrowingStream<GeminiTransportEvent, any Error>
            if let cachedResponse {
                events = GeminiResponseReplay.events(for: cachedResponse)
            } else {
                events = transport.events(
                    for: target,
                    configuration: GeminiTransportConfiguration(
                        maximumResponseByteCount: 16 * 1_024 * 1_024
                    )
                ) { [weak self] identity, _ in
                    guard let self else { return false }
                    return await self.authorize(identity)
                }
            }
            var accepted = false
            var mimeType = ""
            var byteCount = 0
            var body = Data()
            var responseHeader: GeminiResponseHeader?
            for try await event in events {
                switch event {
                case .responseHeader(let header):
                    if !responseIsCached { receivedAt = Date() }
                    responseHeader = header
                    if header.isRedirect,
                       let redirected = URL(string: header.meta, relativeTo: url)?.absoluteURL,
                       isSameCapsule(redirected, url) {
                        return await loadInlineImage(
                            redirected,
                            continuation: continuation,
                            redirects: redirects + 1,
                            bypassesContentCache: bypassesContentCache
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
                    body.append(data)
                    continuation.yield(.data(data))
                case .completed:
                    if !responseIsCached, let responseHeader, accepted {
                        storeInContentCacheIfNeeded(ContentResponse(
                            url: target.url,
                            status: responseHeader.status,
                            meta: Data(responseHeader.meta.utf8),
                            mimeType: mimeType,
                            body: body,
                            receivedAt: receivedAt
                        ), for: target)
                    }
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
            throw GeminiTransportError.connectionFailed(.message("The capsule redirected too many times."))
        }
        guard let target = try? GeminiRequestTarget(url.absoluteString) else {
            throw URLError(.badURL)
        }
        var body = Data()
        var mimeType = "application/octet-stream"
        let cachedResponse = try? await contentCache?.freshResponse(for: target.url)
        let responseIsCached = cachedResponse != nil
        var receivedAt = cachedResponse?.receivedAt ?? Date()
        let events: AsyncThrowingStream<GeminiTransportEvent, any Error>
        if let cachedResponse {
            events = GeminiResponseReplay.events(for: cachedResponse)
        } else {
            events = transport.events(
                for: target,
                configuration: GeminiTransportConfiguration()
            ) { [weak self] identity, _ in
                guard let self else { return false }
                return await self.authorize(identity)
            }
        }
        var responseHeader: GeminiResponseHeader?
        var completed = false
        for try await event in events {
            switch event {
            case .responseHeader(let header):
                if !responseIsCached { receivedAt = Date() }
                responseHeader = header
                // A download that redirects previously died with "Gemini status 31".
                if header.isRedirect {
                    let meta = header.meta.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard let next = URL(string: meta, relativeTo: url)?.absoluteURL else {
                        throw GeminiTransportError.connectionFailed(.message(
                            "The capsule returned a redirect Major Tom could not understand: \(header.meta)"
                        ))
                    }
                    return try await retrieveGeminiResource(next, redirects: redirects + 1)
                }
                guard header.isSuccess else {
                    throw GeminiTransportError.connectionFailed(.message(
                        "The capsule returned Gemini status \(header.status): \(header.meta)"
                    ))
                }
                // Trim and lowercase, or the charset parameter and stray whitespace
                // defeat BrowserFilenameSuggestion's extension mapping.
                mimeType = header.meta.split(separator: ";", maxSplits: 1).first
                    .map { $0.trimmingCharacters(in: .whitespaces).lowercased() } ?? mimeType
            case .body(let data):
                body.append(data)
            case .completed:
                completed = true
            default:
                break
            }
        }
        guard completed, let responseHeader else {
            throw GeminiTransportError.connectionFailed(.message(
                "The response ended before it completed."
            ))
        }
        if !responseIsCached {
            storeInContentCacheIfNeeded(ContentResponse(
                url: target.url,
                status: responseHeader.status,
                meta: Data(responseHeader.meta.utf8),
                mimeType: mimeType,
                body: body,
                receivedAt: receivedAt
            ), for: target)
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

@available(macOS 26.0, *)
private extension NavigationState.Disposition {
    init(_ disposition: BrowserModel.HistoryDisposition) {
        switch disposition {
        case .new: self = .new
        case .reload: self = .reload
        case .traversal: self = .traversal
        }
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
                    ? browser?.canGoBack == true
                    : browser?.canGoForward == true
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
                "trackpad swipe recognized direction=\(direction == .back ? "back" : "forward", privacy: .public) deltaX=\(self.horizontalDelta) canBack=\(self.browser?.canGoBack ?? false) canForward=\(self.browser?.canGoForward ?? false)"
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
