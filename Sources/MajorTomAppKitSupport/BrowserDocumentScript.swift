import Foundation
import WebKit

/// Isolated client scripts for the native document bridge. Capsule scripts stay disabled.
@MainActor
public enum BrowserDocumentScript {
    public static let contextMenuName = "majorTomContextMenu"

    public static let contextMenu = WKUserScript(
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
            const imageLine = anchor?.closest('a[data-mt-expandable]') ||
              anchor?.closest('figure')?.previousElementSibling;
            window.webkit.messageHandlers.majorTomContextMenu.postMessage({
              href: anchor?.href ?? '', imageLine: imageLine?.matches('a[data-mt-expandable]') ? imageLine.id : ''
            });
        }, true);
        """,
        injectionTime: .atDocumentStart,
        forMainFrameOnly: true,
        in: .defaultClient
    )

    public static let linkHoverName = "majorTomLinkHover"

    public static let linkHover = WKUserScript(
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
                window.webkit.messageHandlers.majorTomLinkHover.postMessage({
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

    public static let scrollPositionName = "majorTomScrollPosition"

    public static let scrollPosition = WKUserScript(
        source: """
        (() => {
          var scheduled = false;
          const report = () => {
            scheduled = false;
            window.webkit.messageHandlers.majorTomScrollPosition.postMessage(Math.max(0, window.scrollY));
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

    public static let linkActivationName = "majorTomLinkActivation"

    public static let linkActivation = WKUserScript(
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
            window.webkit.messageHandlers.majorTomLinkActivation.postMessage({
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

    public static let preformattedStateName = "majorTomPreformattedState"

    public static let preformattedState = WKUserScript(
        source: """
        (() => {
          const report = (block) => {
            if (!(block instanceof HTMLDetailsElement) || !block.matches('details.is-multiline')) { return; }
            const blocks = Array.from(document.querySelectorAll('details'));
            const index = blocks.indexOf(block);
            if (index < 0) { return; }
            window.webkit.messageHandlers.majorTomPreformattedState.postMessage({ index: index + 1, collapsed: !block.open });
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

}

/// A preview or replaced document cannot issue actions against the active visit.
@MainActor
public enum DocumentMessageFence {
    public static func accepts(_ message: WKScriptMessage, currentDocumentURL: URL?) -> Bool {
        guard let currentDocumentURL else { return false }
        return message.frameInfo.isMainFrame && message.frameInfo.request.url == currentDocumentURL
    }
}

@MainActor
extension BrowserDocumentScript {
    public static func scoped(_ source: String, to documentURL: URL) -> String {
        "if (location.href !== \(jsLiteral(documentURL.absoluteString))) { return; }\n" + source
    }

    public static func restoreScroll(offset: Double) -> String {
        """
        window.scrollTo(0, \(offset));
        await new Promise(resolve => {
            requestAnimationFrame(() => requestAnimationFrame(resolve));
        });
        document.documentElement.style.setProperty('visibility', 'visible', 'important');
        await new Promise(resolve => {
            requestAnimationFrame(() => requestAnimationFrame(resolve));
        });
        """
    }

    public static let revealDocument = "document.documentElement.style.setProperty('visibility', 'visible', 'important');"

    public static func restoreCollapsed(indices: [Int]) -> String {
        """
        (() => {
          const collapsed = new Set([\(indices.sorted().map(String.init).joined(separator: ","))]);
          document.querySelectorAll('details').forEach((block, index) => {
            if (collapsed.has(index + 1)) { block.open = false; }
          });
        })();
        """
    }

    public static func themeUpdate(css: String, appearance: String) -> String {
        """
        (() => {
          const theme = document.getElementById('majortom-theme');
          document.documentElement.dataset.appearance = \(jsLiteral(appearance));
          if (theme) { theme.textContent = \(jsLiteral(css)); }
        })();
        """
    }

    public static func restorePreview(collapsed: [Int], offset: Double) -> String {
        """
        (() => {
          const collapsed = new Set([\(collapsed.sorted().map(String.init).joined(separator: ","))]);
          document.querySelectorAll('details').forEach((block, index) => {
            if (collapsed.has(index + 1)) { block.open = false; }
          });
          window.scrollTo(0, \(offset));
        })();
        """
    }

    public static func correctScrollAfterImages(offset: Double) -> String {
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

    public static func insertImage(lineIdentifier: String, figure: String) -> String {
        """
        const line = document.getElementById(\(jsLiteral(lineIdentifier)));
        if (!line) { return false; }
        const container = document.createElement('div');
        container.innerHTML = \(jsLiteral(figure));
        const figure = container.querySelector('figure');
        const image = figure?.querySelector('img[data-mt-inline-image]');
        if (!image) { return false; }
        // Keep the figure detached: neither a caption nor layout space is visible
        // until WebKit confirms that the complete response is a usable image.
        // Only app-generated figure markup is parsed here. Response bytes stay
        // behind the img src, including SVG; never parse them as document markup.
        line._majorTomPendingImage = figure;
        try {
          await image.decode();
          if (!image.naturalWidth || !image.naturalHeight) { return false; }
          if (!line.isConnected || line._majorTomPendingImage !== figure) { return false; }
          if (!line.nextElementSibling?.classList.contains('inline-image')) { line.after(figure); }
          line.dataset.mtImageLoaded = 'true';
          window.majorTomSetImageFailure?.(line.id, null);
          window.majorTomEnhanceInlineImage?.(image);
          return true;
        } catch {
          return false;
        } finally {
          if (line._majorTomPendingImage === figure) { delete line._majorTomPendingImage; }
        }
        """
    }

    public static func removeImage(lineIdentifier: String) -> String {
        """
        (() => {
          const line = document.getElementById(\(jsLiteral(lineIdentifier)));
          if (!line) { return; }
          delete line._majorTomPendingImage;
          delete line.dataset.mtImageLoaded;
          line.classList.remove('is-loading');
          const figure = line.nextElementSibling;
          if (figure?.classList.contains('inline-image')) { figure.remove(); }
        })();
        """
    }

    public static func imageViewport(topInset: Double) -> String { "window.majorTomSetImageViewport?.(\(topInset));" }
    /// Encodes a Swift string as a JavaScript string literal, so page content can never
    /// break out of the script being evaluated.
    private static func jsLiteral(_ value: String) -> String {
        guard let data = try? JSONEncoder().encode(value),
              let literal = String(data: data, encoding: .utf8) else { return "\"\"" }
        return literal
    }

}
