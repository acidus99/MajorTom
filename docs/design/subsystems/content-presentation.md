# Content Presentation

[Architecture](../architecture.md)

## Purpose and ownership

Turn parsed content into a safe, readable WebKit document. Own the controlled HTML
shell, semantic markup, themes, document scripts, resource delivery to WebKit, and
reading-state restoration. UI owns the surrounding native controls and dialogs.

## Boundary

Browser supplies semantic updates, source bytes for source view, content settings,
and approved resource bytes. Presentation exposes a surface for UI to host and
reports link activation, resource needs, and reading-state changes to Browser.
It never opens dialogs, accesses repositories, or initiates network retrieval.

Each document has independent rendering state and an identity that fences script
messages and asynchronous updates. History-swipe previews use a separate renderer
and surface; preparing a preview cannot mutate the active document or history cursor.

## Rendering guarantees

- Stream safe content while keeping selection, scrolling, and available links usable.
  Preserve complete versus stopped/failed content. Never save generated HTML as source.
- Escape capsule text and validate interaction destinations. Use a restrictive CSP
  and isolated client scripting world. WebKit must not independently fetch arbitrary
  capsule resources; Browser/Networking authorize and supply resource bytes.
- Use semantic headings, links, lists, quotations, and preformatted text. Preserve
  blank-line spacing and preformatted leading newlines. Optional inline formatting
  keeps author markers. View Source shows escaped original lines with native numbering.
- Preserve native selection, find, copying, and accessibility semantics. Preformatted
  art scrolls within its block rather than overflowing the whole page.
- Inline images preserve the original link and fail without breaking navigation.
  Visible-only auto loading excludes hidden tabs and navigation overlays. Report
  discovery once per link; Networking owns queuing, pacing, and backoff. Render pending,
  requesting, completed, and failed states with accessible labels, not color alone.
- Browser's saved visit state restores scroll, expanded images, and collapsed
  preformatted sections after reconstruction. Ignore callbacks from old documents.
- Document background extends beneath glass chrome. Apply measured navigation height
  to scroller insets rather than removing that background from the glass context.

## Themes and reading

Application appearance and content appearance are independent. Content supports
System, Light, and Dark, separate light/dark selections, and Narrow (60ch), Wide
(80ch), and Full widths. Default content is Dracula Dark; the default light theme
is Dracula Light. Use system typography and responsive gutters.

CSS is the palette authority. Resolve computed colors in isolated WebKit and apply
ANSI foreground contrast of at least 4.5:1. Honor ANSI backgrounds only with an
explicit foreground. Theme changes use retained bytes without another request and
preserve reading state. Publish stylesheet and palette as one coherent update.

Data Persistence supplies custom-theme files and change observations. Presentation
owns metadata interpretation and CSS resolution. Custom CSS cannot fetch remote
styles, fonts, or images. See [Content themes](../content-themes.md) for the authoring
contract and [reading specimens](../reading-test-pages.md) for visual checks.

## Verification

Test semantic rendering, escaping, and chunk invariance without WebKit where possible.
Use WebKit tests for CSP, theme resolution, contrast, accessibility structure, live
updates, selection, and stale document messages. Check both content appearances and
multiple widths/zoom levels. Do not assert copied HTML/CSS implementation literals.

Code landmarks: `HTMLDocumentStreamRenderer.swift`, `ContentTheme.swift`, and the
presentation scripts and `ContentThemeResolver.swift` in AppKitSupport.
