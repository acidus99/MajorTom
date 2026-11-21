import AppKit
import MajorTomCore
import WebKit

/// Discovers streamed image links once, observes visibility without scroll polling,
/// and presents the requestor's authoritative idle/pending/requesting state.
@available(macOS 26.0, *)
@MainActor
public enum InlineImagePresentationScript {
    /// Use the document identity in both processes: a late event from an abandoned
    /// page must never annotate a new page whose line numbering starts over.
    public static func stateUpdateScript(identifier: String, state: GeminiImageLoader.State, documentURL: URL) -> String {
        return """
        if (window.location.href === \(literal(documentURL.absoluteString))) {
          window.majorTomSetImageState?.(\(literal(identifier)), \(literal(state.rawValue)));
        }
        """
    }

    public static func stopScript(identifiers: [String], documentURL: URL) -> String {
        """
        if (window.location.href === \(literal(documentURL.absoluteString))) {
          window.majorTomStopImages?.(\(literal(identifiers)));
        }
        """
    }

    private static func literal<Value: Encodable>(_ value: Value) -> String {
        String(decoding: try! JSONEncoder().encode(value), as: UTF8.self)
    }

    /// A system symbol used as a CSS mask so it follows the link's semantic color.
    public static let pendingIconCSS: String = {
        guard let image = NSImage(systemSymbolName: "clock", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 32, weight: .regular)),
              let tiff = image.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
        else { return "none" }
        return "url(\"data:image/png;base64,\(png.base64EncodedString())\")"
    }()

    public static let userScript = WKUserScript(
        source: """
        (() => {
          const states = new Map();
          const submitted = new Set();
          const observed = new Set();
          let observer;
          let topInset;
          let automaticLoadingStopped = false;
          const updateLine = (line) => {
            const state = states.get(line.id) || 'idle';
            line.classList.toggle('is-image-pending', state === 'pending');
            line.classList.toggle('is-loading', state === 'requesting');
            line.setAttribute('aria-busy', String(state === 'requesting'));
            const anchor = line;
            if (!anchor) { return; }
            if (state === 'idle') {
              anchor.removeAttribute('title');
              anchor.removeAttribute('aria-description');
            } else {
              const description = state === 'requesting' ? 'Loading Image' :
                (line.dataset.mtImageAuto ? 'Auto Load Pending' : 'Image Pending');
              anchor.title = description;
              anchor.setAttribute('aria-description', description);
            }
          };
          window.majorTomSetImageState = (identifier, state) => {
            if (state === 'idle') { states.delete(identifier); }
            else { states.set(identifier, state); }
            const line = document.getElementById(identifier);
            if (line) { updateLine(line); }
          };
          window.majorTomStopImages = (identifiers) => {
            automaticLoadingStopped = true;
            observer?.disconnect();
            observed.clear();
            for (const identifier of identifiers) {
              states.delete(identifier);
              const line = document.getElementById(identifier);
              if (!line) { continue; }
              updateLine(line);
              delete line.dataset.mtImageLoaded;
              const figure = line.nextElementSibling;
              if (figure?.classList.contains('inline-image')) { figure.remove(); }
            }
          };
          const send = (line, action) => {
            if (action === 'load' && automaticLoadingStopped) { return; }
            const anchor = line;
            if (!anchor) { return; }
            submitted.add(line.id);
            observer?.unobserve(line);
            observed.delete(line);
            window.webkit.messageHandlers.majorTomInlineImage.postMessage({
              id: line.id, href: anchor.href, action, documentURL: location.href
            });
          };
          const observeVisibleLinks = () => {
            observer?.disconnect();
            observer = new IntersectionObserver((entries) => {
              if (document.hidden || getComputedStyle(document.documentElement).visibility === 'hidden') { return; }
              for (const entry of entries) {
                if (entry.isIntersecting && entry.intersectionRect.width > 0 && entry.intersectionRect.height > 0 &&
                    !submitted.has(entry.target.id)) { send(entry.target, 'load'); }
              }
            }, { rootMargin: `-${topInset}px 0px 0px 0px`, threshold: 0 });
            observed.forEach(line => observer.observe(line));
          };
          window.majorTomSetImageViewport = (inset) => {
            inset = Math.max(0, Number(inset) || 0);
            if (topInset === inset && observer) { return; }
            topInset = inset;
            observer?.disconnect();
            observer = undefined;
            if (observed.size) { observeVisibleLinks(); }
          };
          const discover = (line) => {
            if (!line.id) { return; }
            updateLine(line);
            if (submitted.has(line.id) || automaticLoadingStopped) { return; }
            if (line.dataset.mtImageAuto === 'whenVisible' && !observed.has(line)) {
              observed.add(line);
              if (!observer) {
                topInset ??= parseFloat(getComputedStyle(document.documentElement).getPropertyValue('--mt-content-top-inset')) || 0;
                observeVisibleLinks();
              } else { observer.observe(line); }
            }
          };
          document.addEventListener('visibilitychange', () => {
            if (!document.hidden && observed.size) { observeVisibleLinks(); }
          });
          document.addEventListener('click', (event) => {
            if (event.metaKey || event.ctrlKey || event.shiftKey || event.altKey || event.button !== 0) { return; }
            const element = event.target instanceof Element ? event.target : event.target?.parentElement;
            const line = element?.closest('a[href]')?.closest('a[data-mt-expandable]');
            if (!line) { return; }
            // Once automatically displayed, the original link remains ordinary navigation.
            if (line.dataset.mtImageAuto && line.dataset.mtImageLoaded === 'true') { return; }
            event.preventDefault();
            event.stopPropagation();
            send(line, 'click');
          }, true);
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
          const discoverTree = (node) => {
            if (!(node instanceof Element)) { return; }
            if (node.matches('a[data-mt-expandable]')) { discover(node); }
            node.querySelectorAll('a[data-mt-expandable]').forEach(discover);
            if (node.matches('[data-mt-inline-image]')) { enhance(node); }
            node.querySelectorAll('[data-mt-inline-image]').forEach(enhance);
          };
          new MutationObserver((records) => {
            for (const record of records) {
              record.addedNodes.forEach(discoverTree);
              if (record.type === 'attributes' && record.target === document.documentElement &&
                  !document.hidden && observed.size) { observeVisibleLinks(); }
            }
          }).observe(document, { childList: true, subtree: true, attributes: true, attributeFilter: ['style'] });
          document.addEventListener('DOMContentLoaded', () => discoverTree(document.documentElement));
        })();
        """,
        injectionTime: .atDocumentStart,
        forMainFrameOnly: true,
        in: .defaultClient
    )
}
