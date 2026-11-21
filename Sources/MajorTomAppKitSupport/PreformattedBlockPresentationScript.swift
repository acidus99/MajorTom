import WebKit

/// Makes only multiline preformatted blocks collapsible.
///
/// The document itself contains no executable script. This runs in WebKit's isolated
/// client world, outside capsule content and its CSP, and progressively enhances the
/// native details/summary markup as streamed lines arrive.
@available(macOS 26.0, *)
@MainActor
public enum PreformattedBlockPresentationScript {
    public static let userScript = WKUserScript(
        source: """
        (() => {
          const enhance = (block) => {
            if (!(block instanceof HTMLDetailsElement) || !block.matches('details')) { return; }
            const pre = block.querySelector(':scope > pre');
            if (!pre) { return; }
            const text = pre.textContent.replace(/\\n$/, '');
            const multiline = text.split('\\n').length > 1;
            block.classList.toggle('is-multiline', multiline);
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
            node = node instanceof Element ? node : node.parentElement;
            if (!node) { return []; }
            const blocks = Array.from(node.querySelectorAll?.('details') || []);
            const containing = node.closest?.('details');
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
          }).observe(document, { childList: true, characterData: true, subtree: true });

          document.addEventListener('DOMContentLoaded', () => {
            document.querySelectorAll('details').forEach(enhance);
          });

          const expandedMultilineBlockFor = (target) => {
            const element = target instanceof Element ? target : target?.parentElement;
            const pre = element?.closest('pre');
            const block = pre?.parentElement;
            return block?.matches('details.is-multiline[open]') ? block : null;
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

