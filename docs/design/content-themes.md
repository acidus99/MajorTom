# Content themes

Major Tom themes are ordinary UTF-8 CSS files. The app loads its base stylesheet first,
then the selected theme, then the print stylesheet. Themes can override variables or use
normal CSS selectors, including nesting. No Sass compilation is required.

This is the theme-authoring reference. [Content Presentation](subsystems/content-presentation.md)
owns rendering and theme behavior; [TODO](TODOs.txt) tracks future theme-management UI.

## Installing and editing

In Settings > Appearance, click **Open Custom Themes in Finder**. Add `.css` files to
that folder and select them in the light or dark content theme menu. Appearance labels
next to each theme name show which modes it supports. A theme marked `both` appears in
both menus. Content appearance chooses System, Light, or Dark; System follows macOS
independently of application appearance.

The production folder is `~/Library/Application Support/Major Tom/Themes`; development
builds use `Major Tom Development/Themes`. Sandboxed builds resolve Application Support
inside the app container. Use the Finder button rather than relying on a particular path.

Saving edits in an external editor updates the selected theme in all open tabs. Both
in-place writes and atomic file replacement are supported. Changing only the display
name preserves the selection; renaming the file changes its identity. Missing or
incompatible themes temporarily use Dracula Light or Dracula Dark without forgetting
the saved filename. Restore the file to restore that selection. Malformed metadata and
unreadable files are reported in Appearance settings. Files must be no larger than 1 MB;
subdirectories, hidden files, and symbolic links are not themes.

Built-in themes remain in the app bundle and are replaced by app updates. Custom files
and all Appearance settings stay local to this Mac.

## Metadata

The first CSS comment must contain these two fields, each on its own line:

```css
/*
@name Evening Reading
@appearance dark
@author Your Name
@description A quiet theme for reading.
@version 1.0.0
@license MIT
*/

/* Page background, ordinary text, and links for evening reading. */
:root {
  --background: #202530;
  --foreground: #eef0f5;
  --link: #9bdcff;
}
```

`@appearance` accepts `light`, `dark`, or `both`. `@name` is the display name, so it may
contain spaces. Other metadata fields are optional descriptive metadata rather than
Settings controls. Duplicate fields are rejected. Field names
and appearance values are case-sensitive. This is Major Tom's metadata convention,
inspired by UserCSS, rather than an implementation of the full UserCSS format.

## Supporting both appearances

Major Tom sets `data-appearance="light"` or `data-appearance="dark"` on the document's
`html` element and supplies the matching CSS `color-scheme`. Use that attribute rather
than `prefers-color-scheme`, which follows the system and cannot express a reader's
explicit content appearance choice.

```css
/*
@name Day and Night
@appearance both
*/

/* Light content colors for the dual-appearance theme. */
:root {
  --background: #faf8f2;
  --foreground: #242424;
  --link: #005a9c;
}

/* Dark content colors selected by Major Tom. */
:root[data-appearance="dark"] {
  --background: #202530;
  --foreground: #eef0f5;
  --link: #9bdcff;
}
```

The metadata declares support; the CSS must implement both appearances. Light and Dark
mode selections can use the same file or different files.

## Supported variables

Declare these on `:root`. Unspecified variables retain the base stylesheet's defaults,
many of which derive from other variables. For example, the default surface mixes the
foreground and background, and headings default to the foreground.

| Variable | Role |
| --- | --- |
| `--background`, `--foreground` | Page background and ordinary text |
| `--surface` | Preformatted blocks, inline code, and generated detail panels |
| `--heading` | Headings and focus outlines |
| `--link`, `--link-hover` | Links and hovered/focused links |
| `--strong`, `--emphasis`, `--code` | Strong emphasis, emphasis, and code text |
| `--muted`, `--accent` | Supporting palette values available to other variables/rules |
| `--caption` | Preformatted captions, image captions, generated labels, source gutter |
| `--list-marker` | List bullets |
| `--blockquote` | Quotation text |
| `--quote-border`, `--quote-surface`, `--quote-radius` | Quotation border color, background, and corner radius |
| `--selection`, `--selection-foreground` | Selected text background and foreground |
| `--danger` | Incomplete response borders and generated error headings |

Normal CSS controls typography and spacing. The renderer uses native semantic elements:
`h1`–`h3`, `p`, `a`, `strong`, `em`, inline `code`, `ul`/`li`, `blockquote`/`p`, plain
`pre`, and `figure`/`figcaption`. Consecutive list items share one `ul`. Consecutive quoted
lines share one `blockquote`; an empty quoted line separates paragraphs. Blank Gemtext
lines end groups and emit ordinary `br` line breaks, preserving intentional extra spacing. Preformatted text contains raw escaped
text; only ANSI-styled runs need spans.

Additional stable targets are `.link-line`, `.link-line.has-hint`, `.link-hint`,
`.link-line.is-loading`, `.preformatted`, `.preformatted > summary`, `.incomplete`,
`.source-lines`, `.source-lines > li`, `.message-details`, `.image-frame`, and `.image-toggle`.
Source, plain-text, image, message, and history documents have corresponding body classes
(`.source-page`, `.plain-text-page`, `.image-page`, `.message-page`, `.history-page`).
Use `ul > li::marker` for content bullets and `.source-lines > li::marker` for source line
numbers. No manual bullet or line-number elements are generated.

Every CSS rule in bundled stylesheets has a comment describing its content or interaction.
Colors are declared first, followed by document layout, typography, and component sections.
The root `--navigation-height` layout variable reserves space for native app chrome;
standalone review exports set it to zero.

Explicit content width and zoom settings are applied after theme styles. Print styles
provide a light, readable printed page. Keep normal theme rules low in specificity and
avoid `!important` so these reading controls continue to work as expected.

Themes style presentation only. They do not alter received source bytes, View Source,
or saved output. The document's resource policy blocks external stylesheets, web fonts,
and remote images from CSS; use installed fonts and self-contained styles. WebKit
ignores invalid CSS declarations normally. The native background and ANSI contrast
adapter sample renderer-generated markup and use computed solid body and preformatted colors; gradients or styling that
depends on individual capsule content may have different backgrounds at different points.

Default typography is the 16px macOS system font (San Francisco) at 1.4 line height.
H1, H2, and H3 use 32px, 28px, and 22px respectively at 100% zoom. H2 headings use
semibold weight (600) for a calmer subsection hierarchy.
Each source blank line retains its own vertical space. Directly adjacent headings,
quotes, and art receive a modest gap when no source blank line separates them.
The default reading width is 60ch; Wide is 80ch; Full has no width limit. Side gutters
shrink with the viewport.
Preformatted content uses `ui-monospace` (SF Mono on macOS) at 14px/1.4, with system
fallback for unsupported characters. Kerning and ligatures are disabled for art.
Custom styles cannot fetch remote fonts.

Typography variables (all declared together at the top of `Base.css`):

| Variable | Default | Purpose |
| --- | --- | --- |
| `--body-font` | macOS system stack | Reading face |
| `--body-size` | `16px` | Base size |
| `--body-leading` | `1.4` | Unitless body line height |
| `--mono-font` | macOS system monospace stack | Code, art, and source face |
| `--mono-size` | `0.875rem` | Art/source size |
| `--mono-leading` | `1.4` | Art line height |
| `--h1-size`, `--h2-size`, `--h3-size` | `2rem`, `1.75rem`, `1.375rem` | Heading sizes |
| `--heading-leading` | `1.25` | Heading line height |
| `--caption-size` | `0.82rem` | Supporting text size |
| `--reading-width`, `--wide-reading-width` | `60ch`, `80ch` | Content width excluding gutters |
| `--page-gutter` | `clamp(1rem, 3vw, 2rem)` | Responsive side padding |

`--caption` blends foreground toward muted by default. Dracula Classic's `--muted`
retains the official comment color `#6272a4`; its captions use a 40% foreground /
60% muted blend to stay readable on both document and source-hover surfaces. All bundled
caption roles are verified at 4.5:1 or better. Motion behavior is unchanged.
